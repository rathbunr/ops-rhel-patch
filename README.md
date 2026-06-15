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
├── .gitignore
│
├── playbooks/
│   └── patch_hosts.yml              # Site playbook (gates + role invocation)
│
├── roles/
│   └── rhel_patching/
│       ├── defaults/main.yml        # All variable defaults
│       ├── meta/main.yml            # Role metadata + dependencies
│       ├── tasks/
│       │   ├── main.yml             # Orchestrator (block/rescue/always)
│       │   ├── pre_validate.yml     # Disk space, package state, pre-log
│       │   ├── patch.yml            # dnf update
│       │   ├── cleanup.yml          # Kernel retention, autoremove, cache
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

# Dry run
ansible-playbook playbooks/patch_hosts.yml -e target_hosts=all --check
```

---

## Role: rhel_patching

### Lifecycle

```
Init (run timestamp, log directory)
    ↓
block:
  Pre-validate (disk space, package state, pre-patch audit log)
      ↓
  Patch (dnf update, record updated packages)
      ↓
  Cleanup (kernel retention, autoremove, cache)
      ↓
  Reboot (needs-restarting detection, conditional reboot, service validation)
rescue:
  Record failure → audit log → fail with details
always:
  Final package count → completion audit log → summary output
```

The `block/rescue/always` structure guarantees audit logging and cleanup
run even when patching fails.

### Variables

All defaults are in `roles/rhel_patching/defaults/main.yml`.

| Variable | Default | Description |
|---|---|---|
| `patch_security_only` | `false` | Apply security updates only |
| `patch_update_only` | `true` | Prevent accidental new package installs |
| `enable_autoremove` | `false` | Remove orphaned dependencies |
| `exclude_packages` | `[]` | Packages/patterns to exclude |
| `installonly_limit` | `2` | Kernel retention count |
| `min_boot_free_mb` | `300` | Minimum free space on /boot |
| `min_root_free_gb` | `5` | Minimum free space on / |
| `min_var_free_gb` | `3` | Minimum free space on /var |
| `patch_reboot_timeout` | `1800` | Seconds to wait for reboot |
| `patch_reboot_delay` | `30` | Seconds to wait after reboot before validation |
| `critical_services` | `[sshd, chronyd]` | Services validated post-reboot |
| `patch_log_dir` | `/var/log/patching` | JSON audit log directory |

### Audit trail

Each patching run produces JSON logs in `/var/log/patching/` on each host.
All logs share a `run_id` for correlation.

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
| Patch RHEL Hosts | `playbooks/patch_hosts.yml` | On-demand / scheduled |
| Security Patch Only | `playbooks/patch_hosts.yml` | On-demand (`patch_security_only=true`) |

### Survey parameters

| Parameter | Type | Description |
|---|---|---|
| `target_hosts` | Text | Host group, collection, or search query |
| `patch_security_only` | Boolean | Security updates only |
| `exclude_packages` | Text | Comma-separated package exclusions |
| `patch_serial` | Integer | Hosts to patch simultaneously |

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
