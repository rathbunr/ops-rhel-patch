# ops-rhel-patch

Ansible role and playbook for automated RHEL 8/9/10 fleet patching,
orchestrated via AAP 2.7. Hosts must be registered to Satellite before
patching — see [ops-rhel-satellite-registration](https://github.com/rathbunr/ops-rhel-satellite-registration).

---

## Repository layout

```
ops-rhel-patch/
├── ansible.cfg
├── requirements.yml
├── survey_spec.json                 # AAP survey definition (version controlled)
├── .gitignore
│
├── playbooks/
│   ├── patch_hosts.yml              # Site playbook (gates + role invocation)
│   └── post_sync.yml                # Pushes survey_spec.json to the controller
│
├── roles/
│   └── rhel_patching/
│       ├── defaults/main.yml        # All variable defaults
│       ├── meta/main.yml            # Role metadata + dependencies
│       ├── tasks/
│       │   ├── main.yml             # Orchestrator (block/rescue/always)
│       │   ├── pre_validate.yml     # Disk space, kernel retention, package state
│       │   ├── patch.yml            # dnf update
│       │   ├── cleanup.yml          # Autoremove, cache clean
│       │   └── reboot.yml           # Reboot detection + service validation
│       └── templates/
│           └── audit_log.json.j2    # Single template for all audit phases
│
└── inventory/
    ├── hosts.yml
    └── group_vars/
        └── all.yml
```

---

## Quick start

```bash
# 1. Install collections
ansible-galaxy collection install -r requirements.yml

# 2. Patch all hosts
ansible-playbook playbooks/patch_hosts.yml -e target_hosts=all
```

---

## Usage

```bash
# Patch all hosts
ansible-playbook playbooks/patch_hosts.yml -e target_hosts=all

# Security updates only
ansible-playbook playbooks/patch_hosts.yml -e "target_hosts=all patch_security_only=true"

# Exclude packages
ansible-playbook playbooks/patch_hosts.yml -e '{"target_hosts":"all","exclude_packages":["kernel*","podman*"]}'

# Serial batching (10 hosts at a time)
ansible-playbook playbooks/patch_hosts.yml -e "target_hosts=all patch_serial=10"
```

---

## Role: rhel_patching

### Lifecycle

```
Init (run timestamp, log directory)
    ↓
block:
  Pre-validate (disk space, kernel retention, package state)
      ↓
  Patch (dnf update, record updated packages)
      ↓
  Post-patch (only when patches were applied):
      Cleanup (autoremove, cache clean)
          ↓
      Reboot (needs-restarting detection, conditional reboot, service validation)
rescue:
  Record failure → audit log → fail with details
always:
  Audit logs (pre-patch + completion, only when patches were applied)
      ↓
  Prune logs beyond retention period
      ↓
  Summary output
```

The `block/rescue/always` structure guarantees cleanup and summary output
run even when patching fails. Audit logs are only written when patches
are applied, keeping subsequent runs idempotent.

### Idempotency

A run against an already-patched fleet produces **zero changes**. Cleanup,
reboot, and audit log writes are all gated on `_patch_result.changed`, so
when dnf has nothing to do the entire post-patch path skips. Only
pre-validation runs, and asserts are non-mutating.

```
PLAY RECAP
host-01 : ok=18 changed=0 unreachable=0 failed=0 skipped=8
```

### Variables

All defaults are in `roles/rhel_patching/defaults/main.yml`.

| Variable | Default | Description |
|---|---|---|
| `patch_security_only` | `false` | Apply security updates only |
| `patch_update_only` | `true` | Prevent accidental new package installs |
| `enable_autoremove` | `false` | Remove orphaned dependencies |
| `exclude_packages` | `[]` | Packages/patterns to exclude |
| `installonly_limit` | `2` | Kernel retention count (applied before patching) |
| `min_boot_free_mb` | `300` | Minimum free space on /boot |
| `min_root_free_gb` | `5` | Minimum free space on / |
| `min_var_free_gb` | `3` | Minimum free space on /var |
| `patch_reboot_timeout` | `1800` | Seconds to wait for reboot |
| `patch_reboot_delay` | `30` | Seconds to wait after reboot before validation |
| `critical_services` | `[sshd, chronyd]` | Services validated post-reboot |
| `patch_log_dir` | `/var/log/patching` | JSON audit log directory |
| `patch_log_retention_days` | `90` | Days to retain audit logs before pruning |

### Audit trail

Each patching run that applies updates produces JSON logs in
`/var/log/patching/` on each host. All logs share a `run_id` for
correlation. Logs are retained for `patch_log_retention_days` (default 90)
and pruned automatically at the end of each run.

| File | Contents |
|---|---|
| `pre-patch-*.json` | Kernel, package count, disk space |
| `packages-updated-*.json` | List of packages updated |
| `patch-complete-*.json` | Final state, kernel delta, reboot status |
| `patch-failure-*.json` | Error details (failure only) |

---

## AAP integration

### Job templates

| Job Template | Playbook | Trigger |
|---|---|---|
| ops-rhel-patch | `playbooks/patch_hosts.yml` | On-demand / scheduled |
| ops-rhel-patch-survey-sync | `playbooks/post_sync.yml` | After project sync / on survey change |

### Survey

The survey definition lives in `survey_spec.json` at the repo root so it is
version controlled alongside the playbook it drives.

| Parameter | Type | Default | Description |
|---|---|---|---|
| `target_hosts` | Text | `all` | Host group, collection, or search query |
| `patch_security_only` | Choice | `false` | Security updates only |
| `exclude_packages` | Text | *(blank)* | Comma-separated package exclusions |
| `patch_serial` | Integer | `0` | Hosts to patch simultaneously (0 = all) |
| `enable_autoremove` | Choice | `false` | Remove orphaned dependencies |

Thresholds, timeouts, log retention, and `critical_services` are
deliberately **not** in the survey — they are set-and-forget defaults, and
exposing them invites per-run drift. Override them in `group_vars` if a
host group genuinely needs different values.

`exclude_packages` arrives from a survey as a comma-separated **string**,
but the role expects a **list**. `patch_hosts.yml` normalizes this in
`pre_tasks`, so `kernel*,podman*` is split into two entries. Passing a real
list via `-e` on the CLI still works — the parsing task only fires when the
value is a string.

### Applying the survey

AAP does not read `survey_spec.json` from the repo automatically; surveys
live in the controller database. `playbooks/post_sync.yml` pushes the file
to the controller via the API.

Run it as a workflow node after the project sync, or on demand after
changing the survey:

```bash
ansible-playbook playbooks/post_sync.yml
```

Requirements for the job template running it:

- **Inventory** containing the controller host (`aap-01`), reachable with
  `connection: local`
- **Credential** of type *Red Hat Ansible Automation Platform*, which
  injects `CONTROLLER_HOST` and `CONTROLLER_OAUTH_TOKEN` as environment
  variables. The playbook reads both from the environment — no token is
  stored in the repo.

Override the target template name if it ever changes:

```bash
ansible-playbook playbooks/post_sync.yml -e job_template_name="some-other-template"
```

> **Gateway API path.** On AAP 2.5+ the controller API is proxied by the
> platform gateway at `/api/controller/v2/`. The `awx.awx` and
> `ansible.controller` modules hardcode `/api/v2/` onto `controller_host`,
> which 404s against the gateway — and no value of `controller_host` can
> produce the correct path, since prefixing it yields
> `/api/controller/api/v2/`. `post_sync.yml` therefore calls the API
> directly with `ansible.builtin.uri` against the gateway path. Verify the
> endpoint with:
>
> ```bash
> curl -s "https://aap-01.rh.corp.ritcsusa.com/api/controller/v2/organizations/" \
>   -H "Authorization: Bearer <token>" | jq '.results[].name'
> ```

---

## Operational notes

**Connection user.** Hosts are patched as `svc_ansible_local`, a local
account rather than a domain one, so patching does not depend on the domain
being reachable — which matters when a reboot is part of the run. If a host
was previously touched by a different Ansible account, a stale
`/tmp/.ansible/tmp` owned by that account (mode 700) will cause
`UNREACHABLE! Failed to create temporary directory`. Remove it and let
Ansible recreate it:

```bash
rm -rf /tmp/.ansible/tmp
```

**Unreachable hosts bypass rescue.** `block/rescue` catches task failures,
not lost connections. A host that goes unreachable mid-run is dropped from
the play entirely and writes no failure log. Check the PLAY RECAP for
`unreachable=1` rather than relying on the audit trail alone.

---

## Related projects

- [ops-rhel-satellite-registration](https://github.com/rathbunr/ops-rhel-satellite-registration) — Satellite client registration (prerequisite)

---

## Validated against

- Red Hat Satellite 6.19
- RHEL 10.2, 9.8, 8.10
- Ansible Core 2.16
- AAP 2.7 (containerized)

---

## Author

Robert Rathbun
