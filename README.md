# RHEL Patching Automation

Ansible playbooks for automated RHEL 8/9/10 host registration compliance
and patching against Red Hat Satellite, designed for AAP 2.6 self-service
deployment.

---

## Project Layout

```
.
├── README.md
├── requirements.yml
├── ansible.cfg
├── inventory/
│   ├── hosts.yml
│   └── group_vars/
│       └── all.yml
└── playbooks/
    ├── 01_reg_comply.yml       # Registration compliance check
    └── 02_patch_hosts.yml      # Fleet patching
```

---

## Host Discovery (Prerequisite)

These playbooks operate against a known inventory. Host discovery is handled
externally through one or more of the following sources:

| Source | Method | Notes |
|---|---|---|
| **Red Hat Satellite** | `redhat.satellite.resource_info` module or `redhat.satellite.foreman` dynamic inventory plugin | Primary source of truth for registered hosts |
| **Active Directory** | `microsoft.ad` inventory plugin querying computer objects | Finds domain-joined RHEL hosts that may not be registered to Satellite |
| **Red Hat Insights** | Hosts registered to Insights auto-populate in Satellite inventory | Passive discovery, no scanning required |

Network scanning (e.g., NMAP) is intentionally excluded. Enterprise
micro-segmentation policies block port scanning and trigger NAC alerts.
All discovery is API-driven.

---

## Playbooks

### 01 — Registration Compliance

Validates all managed hosts are properly registered to Satellite with the
correct content view, lifecycle environment, and host collection for their
RHEL major version.

```bash
ansible-playbook playbooks/01_reg_comply.yml -i inventory/
```

**What it checks per host:**

| Check | Expected State |
|---|---|
| Content View | Matches RHEL version (e.g., CV-RHEL10 for RHEL 10) |
| Lifecycle Environment | Library (rapid patching model) |
| Host Collection | Matches RHEL version (e.g., RHEL_10_Lab) |
| Global Status | OK or Warning |

**Output:** Per-host compliance report with pass/fail indicators and a
summary showing compliant vs non-compliant counts. Non-compliant hosts
are flagged for remediation.

**Configuration:** Edit the `registration_map` variable in the playbook
to match your Satellite content view and activation key naming conventions.

---

### 02 — Fleet Patching

Full patching cycle: pre-validation, update, cleanup, reboot, post-validation.

```bash
# Patch all hosts
ansible-playbook playbooks/02_patch_hosts.yml -i inventory/ -e target_hosts=all

# Patch specific host group or collection
ansible-playbook playbooks/02_patch_hosts.yml -i inventory/ -e target_hosts=RHEL_10_Lab

# Patch single host
ansible-playbook playbooks/02_patch_hosts.yml -i inventory/ -l zabbix-01.example.com

# Security-only patching
ansible-playbook playbooks/02_patch_hosts.yml -i inventory/ -e "target_hosts=all patch_security_only=true"

# Exclude specific packages
ansible-playbook playbooks/02_patch_hosts.yml -i inventory/ -e '{"target_hosts": "all", "exclude_packages": ["kernel*", "podman*"]}'

# Serial batching for large fleets
ansible-playbook playbooks/02_patch_hosts.yml -i inventory/ -e "target_hosts=all patch_serial=10"

# Dry run
ansible-playbook playbooks/02_patch_hosts.yml -i inventory/ -e target_hosts=all --check
```

**Pipeline:**

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

### Registration Compliance (01)

| Variable | Description |
|---|---|
| `satellite_server_url` | Satellite API URL |
| `satellite_username` | Satellite admin username |
| `satellite_password` | Satellite admin password |
| `satellite_validate_certs` | Validate Satellite SSL certificate |
| `satellite_organization` | Satellite organization name |

### Fleet Patching (02)

| Variable | Default | Description |
|---|---|---|
| `target_hosts` | `all` | Host pattern, group, or collection to patch |
| `patch_serial` | `0` (all at once) | Number of hosts to patch simultaneously |
| `patch_security_only` | `false` | Apply only security updates |
| `patch_update_only` | `true` | Prevent accidental new package installs |
| `enable_autoremove` | `false` | Remove orphaned dependencies (risky in enterprise) |
| `exclude_packages` | `[]` | List of packages/patterns to exclude |
| `installonly_limit` | `2` | Kernel retention count (current + fallback) |
| `min_boot_free_mb` | `300` | Minimum free space on /boot |
| `min_root_free_gb` | `5` | Minimum free space on / |
| `min_var_free_gb` | `5` | Minimum free space on /var |
| `patch_reboot_timeout` | `1800` | Seconds to wait for reboot completion |
| `critical_services` | `[sshd, chronyd]` | Services to validate after reboot |
| `patch_log_dir` | `/var/log/patching` | Directory for JSON audit logs |

---

## Audit Trail

Each patching run produces JSON logs in `/var/log/patching/` on each host.
Previous run logs are cleaned at the start of each new run.

| File | Contents |
|---|---|
| `pre-patch-*.json` | Pre-patch state: kernel, package count, disk space |
| `packages-updated-*.json` | List of packages installed/removed |
| `post-patch-*.json` | Post-patch state: kernel, reboot status |
| `patch-complete-*.json` | Final validation: success/failure |
| `patch-failure-*.json` | Error details (only on failure) |

These logs are structured for consumption by ITSM workflows (e.g.,
ServiceNow `servicenow.itsm` collection) for automated change ticket
creation and compliance evidence.

---

## AAP Integration

### Job Templates

| Template Name | Playbook | Trigger | Notes |
|---|---|---|---|
| Registration Compliance | `01_reg_comply.yml` | Scheduled / On-demand | Monthly recommended |
| Patch RHEL Hosts | `02_patch_hosts.yml` | On-demand / Scheduled | Survey for target_hosts |
| Security Patch Only | `02_patch_hosts.yml` | On-demand | Extra var: patch_security_only=true |

### Self-Service Portal

Deploy patching templates via AAP Platform Gateway for self-service
kiosk access. System owners see only their authorized templates with
RBAC-scoped host visibility.

Survey parameters for the patching template:

| Parameter | Type | Description |
|---|---|---|
| `target_hosts` | Text | Host group, collection, or search query |
| `patch_security_only` | Boolean | Security-only update |
| `exclude_packages` | Text | Comma-separated package exclusions |

---

## Requirements

### Collections

```yaml
collections:
  - name: community.general
    version: ">=8.0.0"
  - name: redhat.satellite
    version: ">=5.0.0"
```

### Host Requirements

- RHEL 8, 9, or 10 registered to Red Hat Satellite
- `yum-utils` (RHEL 10) or `dnf-utils` (RHEL 8/9) for `needs-restarting`
- Valid subscription and enabled repositories

---

## Design Decisions

| Decision | Rationale |
|---|---|
| `installonly_limit=2` | One fallback kernel. Balances /boot space against rollback safety. Increase to 3 for critical/FIPS systems. |
| `min_boot_free_mb=300` | Calibrated for RHEL default 960MB /boot partition with 2 kernels. |
| `autoremove` disabled | Can remove operationally required packages in enterprise environments. Enable explicitly when safe. |
| `needs-restarting` over kernel comparison | `package_facts` kernel version doesn't include full release string, making direct comparison unreliable. |
| `update_only=true` | Prevents wildcard `dnf update` from accidentally installing new packages. |
| Logs cleaned each run | Fresh audit trail per cycle. Historical evidence belongs in ITSM/SIEM, not local files. |
| No NMAP discovery | Enterprise micro-segmentation blocks port scanning. All discovery is API-driven. |

---

## Validated Against

- Red Hat Satellite 6.19.0
- RHEL 10.1 (kernel 6.12.0)
- RHEL 9.7 (kernel 5.14.0)
- Ansible Core 2.16
- AAP 2.6 (containerized)

---

## Future Enhancements

- ServiceNow ITSM integration for automated change ticket lifecycle
- Pre-patch Hyper-V checkpoint creation via WinRM
- OpenSCAP/CIS post-patch validation
- CVE remediation evidence collection
- Windows patching via MECM API integration
- SatShell interactive menu for Satellite operations

---

## Author

Robert Rathbun

## License

MIT
