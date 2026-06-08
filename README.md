# ops-rhel-patch

Ansible playbooks for automated RHEL 8/9/10 Satellite registration and
patching against Red Hat Satellite, orchestrated via AAP 2.7.

---

## Repository layout

```
ops-rhel-patch/
├── ansible.cfg                        # Ansible configuration
├── requirements.yml                   # Collection dependencies
├── CODEOWNERS                         # Review requirements
├── .gitignore                         # Excludes vault password, logs, etc.
├── .vault_pass.example                # Template for local vault password file
│
├── playbooks/
│   ├── 01_satellite_registration.yml  # Satellite client registration
│   └── 02_patch_hosts.yml             # Full RHEL patching cycle
│
├── inventory/
│   ├── hosts.yml                      # Static inventory scaffold
│   ├── group_vars/
│   │   └── all.yml                    # All variable defaults (non-secret)
│   └── host_vars/                     # Per-host overrides (if needed)
│
├── vault/
│   └── vault.yml                      # Encrypted secrets (ansible-vault)
│
├── vars/                              # Additional variable files (env-specific)
├── files/                             # Static files for copy tasks
└── templates/                         # Jinja2 templates
```

---

## Quick start

```bash
# 1. Install collections
ansible-galaxy collection install -r requirements.yml

# 2. Set up vault password file (never commit this)
cp .vault_pass.example .vault_pass
echo "your-vault-password" > .vault_pass
chmod 600 .vault_pass

# 3. Encrypt the vault
ansible-vault encrypt vault/vault.yml

# 4. Register unregistered hosts to Satellite
ansible-playbook playbooks/01_satellite_registration.yml -e target_hosts=all

# 5. Patch all hosts
ansible-playbook playbooks/02_patch_hosts.yml -e target_hosts=all
```

---

## Playbooks

### 01 — Satellite registration

Ensures all targeted RHEL hosts are registered to Satellite with the
correct activation key for their major version. Already-registered hosts
are skipped. Non-RHEL and Satellite server hosts are excluded automatically.

```bash
# Register all unregistered hosts
ansible-playbook playbooks/01_satellite_registration.yml -e target_hosts=all

# Register only RHEL 10 hosts
ansible-playbook playbooks/01_satellite_registration.yml -e target_hosts=rhel_10

# Dry run
ansible-playbook playbooks/01_satellite_registration.yml -e target_hosts=all --check
```

**Registration pipeline:**

```
Gate non-RHEL / Satellite server hosts
    ↓
Check subscription-manager identity
    ↓
Skip already-registered hosts
    ↓
Resolve activation key from registration_map
    ↓
Install Satellite CA certificate (idempotent)
    ↓
Register via activation key + org
    ↓
Verify registration
```

### 02 — Fleet patching

Full patching cycle with pre-validation, update, cleanup, reboot, and
post-reboot service validation.

```bash
# Patch all hosts
ansible-playbook playbooks/02_patch_hosts.yml -e target_hosts=all

# Patch a specific host group
ansible-playbook playbooks/02_patch_hosts.yml -e target_hosts=RHEL_10_Lab

# Security updates only
ansible-playbook playbooks/02_patch_hosts.yml -e "target_hosts=all patch_security_only=true"

# Exclude packages
ansible-playbook playbooks/02_patch_hosts.yml -e '{"target_hosts":"all","exclude_packages":["kernel*","podman*"]}'

# Serial batching (10 hosts at a time)
ansible-playbook playbooks/02_patch_hosts.yml -e "target_hosts=all patch_serial=10"

# Dry run
ansible-playbook playbooks/02_patch_hosts.yml -e target_hosts=all --check
```

**Patching pipeline:**

```
Pre-patch validation (disk space, subscription, yum-utils)
    ↓
Capture pre-patch state (kernel, package count)
    ↓
Apply updates (dnf, with security-only and exclusion support)
    ↓
Record updated packages (JSON audit log)
    ↓
Post-patch cleanup (kernel retention, cache)
    ↓
Reboot detection (needs-restarting)
    ↓
Conditional reboot + service validation
    ↓
Record final state (JSON audit log)
```

---

## Variables

All defaults are defined in `inventory/group_vars/all.yml`. Secrets
are in `vault/vault.yml` and referenced via `vault_*` prefixed variables.

| Variable | Default | Description |
|---|---|---|
| `patch_serial` | `0` | Hosts to patch simultaneously (0 = all) |
| `patch_security_only` | `false` | Apply security updates only |
| `patch_update_only` | `true` | Prevent accidental new package installs |
| `enable_autoremove` | `false` | Remove orphaned dependencies |
| `exclude_packages` | `[]` | Packages/patterns to exclude |
| `installonly_limit` | `2` | Kernel retention count |
| `min_boot_free_mb` | `300` | Minimum free space on /boot |
| `min_root_free_gb` | `5` | Minimum free space on / |
| `min_var_free_gb` | `3` | Minimum free space on /var |
| `patch_reboot_timeout` | `1800` | Seconds to wait for reboot |
| `critical_services` | `[sshd, chronyd]` | Services validated post-reboot |
| `patch_log_dir` | `/var/log/patching` | JSON audit log directory |

**Registration map** (in `group_vars/all.yml`):

| RHEL Version | Activation Key | Content View | Lifecycle Env | Host Collection |
|---|---|---|---|---|
| 10 | `AK-RHEL10` | `CV-RHEL10` | `Library` | `RHEL_10_Lab` |
| 9 | `AK-RHEL9` | `CV-RHEL9` | `Library` | `RHEL_9_Lab` |
| 8 | `AK-RHEL8` | `CV-RHEL8` | `Library` | `RHEL_8_Lab` |

---

## Vault

Secrets are managed with Ansible Vault. The vault file references variables
prefixed with `vault_` which are mapped to their runtime names in
`inventory/group_vars/all.yml`.

```bash
# Encrypt
ansible-vault encrypt vault/vault.yml

# Edit in place
ansible-vault edit vault/vault.yml

# View without decrypting to disk
ansible-vault view vault/vault.yml
```

**Never commit a decrypted vault file or `.vault_pass`.**

---

## Audit trail

Each patching run produces JSON logs in `/var/log/patching/` on each host.

| File | Contents |
|---|---|
| `pre-patch-*.json` | Kernel, package count, disk space before patching |
| `packages-updated-*.json` | Packages installed or removed |
| `post-patch-*.json` | Kernel, reboot status after patching |
| `patch-complete-*.json` | Final validation result |
| `patch-failure-*.json` | Error details (failure only) |

Logs are structured for ITSM integration via the `servicenow.itsm` collection.

---

## AAP integration

| Job Template | Playbook | Trigger |
|---|---|---|
| Satellite Registration | `01_satellite_registration.yml` | On-demand / scheduled |
| Patch RHEL Hosts | `02_patch_hosts.yml` | On-demand / scheduled |
| Security Patch Only | `02_patch_hosts.yml` | On-demand (`patch_security_only=true`) |

Survey parameters for the registration template:

| Parameter | Type | Description |
|---|---|---|
| `target_hosts` | Text | Host group, collection, or search query |

Survey parameters for the patching template:

| Parameter | Type | Description |
|---|---|---|
| `target_hosts` | Text | Host group, collection, or search query |
| `patch_security_only` | Boolean | Security updates only |
| `exclude_packages` | Text | Comma-separated package exclusions |
| `patch_serial` | Integer | Hosts to patch simultaneously |

---

## Validated against

- Red Hat Satellite 6.19
- RHEL 10.1 / kernel 6.12.0
- RHEL 9.7 / kernel 5.14.0
- Ansible Core 2.16
- AAP 2.7 (containerized)

---

## Author

Robert Rathbun
