# AAP Inventory Sync Failure — Initial Evidence Capture Procedure

**Target:** AAP 2.6-11 (containerized, install user `aap`) —
`microsoft.ad.ldap` inventory sync failing with
`SpnegoError (4294967295) / Major (851968) / Matching credential not found`

**Purpose:** Capture all discriminating evidence from a single failed sync
**before changing anything.** Every artifact below feeds the decision table at
the end. Total time: ~15 minutes. No configuration changes are made in this
procedure.

**Validated:** Lab (AAP 2.7 containerized, aap-01), 7-run experiment series,
2026-07. Path/user differences between lab and work are called out inline.

---

## Rule 0 — Change nothing first

Do not edit the credential, credential type, settings, or project before
capturing. The failure state IS the evidence. Rebuilding components before
capture (already done once with the credential) destroys discriminating
information.

---

## Step 0 — Container orientation and entry

All commands run as the **`aap` install user** on the work controller node
(the account that ran the containerized installer — NOT root, no `awx` host
user exists on containerized deployments).

```bash
ssh aap@<work-controller>
podman ps        # expect: automation-controller-task, -web, redis, etc.
podman images    # EE images live in THIS user's rootless storage
```

**Two different containers — do not confuse them (lab lesson learned):**

| Container | What it is | What it has |
|---|---|---|
| `automation-controller-task` | The AAP task dispatcher | Projects mount, private data dirs, nested podman view of job containers. **NO ansible, NO collections, NO python EE stack** |
| The EE image (e.g. `ee-supported-rhel9`) | What actually runs syncs | ansible-inventory, microsoft.ad collection, spnego/gssapi stack |

**Enter the task container** (for private data dirs, nested job containers):

```bash
podman exec -it automation-controller-task /bin/bash
```

**Enter the EE image** (for inspection and reproduction):

```bash
podman run -it --rm --entrypoint /bin/bash <ee-image>:<tag>
```

If `podman ps` during a sync shows no job container as `aap`, the job
containers are nested — enter the task container and run `podman ps` there.

**Sanity check you're in an EE, not the task container:**

```bash
which ansible-inventory && ls /usr/share/ansible/collections/ansible_collections/
# Both must succeed and show 'microsoft' — otherwise wrong container
```

**Find the projects checkout** (repeatable — don't hardcode):

```bash
# From the host as aap — ask the mount table:
podman inspect automation-controller-task \
  --format '{{range .Mounts}}{{.Source}} -> {{.Destination}}{{println}}{{end}}' | grep -i project

# Or search for a file known to be in the project:
find ~ -name 'microsoft.ad.ldap.yml' 2>/dev/null
```

Expected pattern: `~/aap/controller/data/projects/_<id>__<name>/` (lab
confirmed: `/home/svc_ansible/aap/controller/data/projects/_8__infra_ldap_inventory`;
work will be under `/home/aap/...`). Record the exact path found.

---

## Step 1 — Trigger a failed sync at high verbosity

1. AAP UI → Inventories → *(the AD inventory)* → Sources → edit the source
2. Set **Verbosity: 2 (More Verbose)** — this is a capture aid, not a config
   change; note the original value to restore later
3. Record before launching:
   - **Execution Environment** field on the source (and the org/global default
     EE if the field is blank) — exact image:tag
   - **Credential** field — exact credential name attached (screenshot it)
4. Launch the sync, let it fail

**Capture:** full job output (Download Output button, or copy all). File as
`work-sync-fail-<jobid>.log`.

**What to look for immediately in the traceback:**

| Signature | Meaning |
|---|---|
| `Getting initial credentials` / AS-REQ activity | Password reached the plugin |
| Fails at `spnego.client(` (context creation) | No password; ccache empty/unreachable |
| Fails at `ctx.step(` (context step) | No password; ccache resolvable but stale — OR older lazy-acquire gssapi |
| Frames in `_negotiate.py` | auth_protocol NOT injected (plugin defaulted to negotiate) |
| No `_negotiate.py` frames, straight to `_context.py` wrapper | auth_protocol=kerberos IS injected |

---

## Step 2 — Capture the injected environment (ground truth)

This is the single most valuable artifact. It shows exactly which variables
AAP delivered to the sync container — no inference required.

On the work controller node as `aap`. Job containers may appear at the host
level as siblings, or nested inside the task container — check both.

**Method A — exited container inspection** (works after the failure):

```bash
# Host level first:
podman ps -a                       # look for a recently exited EE container

# If nothing there, check the nested view:
podman exec -it automation-controller-task /bin/bash
podman ps -a                       # nested job containers show here
```

Wherever the exited container is found, run in that context:

```bash
podman inspect <container-id> --format '{{.Config.Env}}' | tr ' ' '\n' | grep -E 'MICROSOFT|KRB5'
podman inspect <container-id> --format '{{range .Mounts}}{{.Source}} -> {{.Destination}}{{println}}{{end}}'
```

**Method B — private data directory** (kept briefly after the job; on
containerized AAP it lives INSIDE the task container):

```bash
podman exec -it automation-controller-task /bin/bash
ls -dt /tmp/awx_* 2>/dev/null | head -3
cat /tmp/awx_<jobid>_*/env/envvars | grep -E 'MICROSOFT|KRB5'
```

**Method C — live capture** (if A and B miss; syncs die fast, have this ready
before re-launching — run in whichever context showed job containers in
Method A):

```bash
watch -n1 'podman ps'
# grab the ID while running:
podman exec <container-id> env | grep -E 'MICROSOFT|KRB5'
```

**Capture:** the full env var list (values of secrets will be visible in
Method B/C — record presence/absence and names only; do not file the password
value). Also capture the Mounts list from Method A.

**Record explicitly, present or absent:**

- [ ] `MICROSOFT_AD_LDAP_SERVER`
- [ ] `MICROSOFT_AD_LDAP_PORT`
- [ ] `MICROSOFT_AD_LDAP_AUTH_PROTOCOL` (and its value)
- [ ] `MICROSOFT_AD_LDAP_USERNAME`
- [ ] `MICROSOFT_AD_LDAP_PASSWORD`
- [ ] `MICROSOFT_AD_LDAP_CA_CERT`
- [ ] `KRB5_CONFIG`
- [ ] `KRB5CCNAME` (if present: the ccache-based legacy flow is/was in play)

---

## Step 3 — Capture the credential type definition

AAP UI → Administration → Credential Types → **Microsoft AD LDAP**

**Capture:** full text of BOTH tabs — Input Configuration and Injector
Configuration. Copy verbatim (screenshots + text). Check also whether more
than one similarly named type exists — capture all of them.

**Compare offline against the repo:**

- Injector env names must be exactly: `MICROSOFT_AD_LDAP_SERVER`, `_PORT`,
  `_AUTH_PROTOCOL`, `_USERNAME`, `_PASSWORD`, `_CA_CERT`, `_CERTIFICATE`,
  `_CERTIFICATE_KEY`, `_CERTIFICATE_PASSWORD`, plus `KRB5_CONFIG`
- Input field `id` values must match the injector template variables
  (`username` ↔ `{{ username }}`, `password` ↔ `{{ password }}`)
- Note which type ID the attached credential actually uses (URL shows the id)

---

## Step 4 — Capture AAP job settings

AAP UI → Settings → Jobs. **Capture** current values of:

- `AWX_TASK_ENV`
- `AWX_ISOLATION_SHOW_PATHS`
- Any `KRB5CCNAME` or Kerberos-related entries

If any of these reference keytabs, ccaches, or krb5 paths, the legacy
ccache-based auth flow existed here — cross-reference with Step 2's
`KRB5CCNAME` and mount findings. If pre-patch values are known (backups,
change tickets, `awx-manage` exports), capture those for the delta.

---

## Step 5 — Capture the work EE fingerprint

As `aap` on the host (EE images are in the install user's rootless storage;
if `podman images` doesn't show the EE there, check the nested view inside
`automation-controller-task`):

```bash
podman images                      # confirm exact image:tag from Step 1
podman run --rm --entrypoint /bin/bash <image>:<tag> -c '
grep "\"version\"" /usr/share/ansible/collections/ansible_collections/microsoft/ad/MANIFEST.json
pip3 list 2>/dev/null | grep -Ei "spnego|gssapi|sansldap|krb5|dnspython"
python3 --version
cat /etc/krb5.conf | grep -E "default_ccache|default_realm"
'
```

**Capture:** output verbatim. Key values: microsoft.ad version (need ≥ 1.2.0
for env vars), pyspnego + gssapi versions (older versions acquire credentials
lazily and change WHERE the failure surfaces — see decision table note).

Lab baseline for comparison: microsoft.ad 1.11.0, pyspnego 0.12.1,
gssapi 1.11.1, krb5 0.9.0, Python 3.12, krb5-libs 1.21.1.

---

## Step 6 — Interpret against the decision table

Established by lab runs 1–7 (stock ee-supported-rhel9, AAP 2.7 stack):

| # | Env state | Failure point | Error signature |
|---|---|---|---|
| 1 | All vars + password | — (success) | AS-REQ → TGS → host JSON |
| 2 | Password **empty string** | `get_init_creds_password` (kinit) | Preauth I/O error / "No pkinit_anchors supplied" (misleading text) |
| 3 | Username set, password absent | `spnego.client` (creation) | SpnegoError (7), Major 458752, "Can't find client principal" |
| 4 | No auth_protocol (negotiate default), no identity | `ctx.step` via `_negotiate.py` | SpnegoError (1), BadMechanismError |
| 5 | kerberos set, no identity, FILE ccache missing | creation (`acquire_cred`) | Major 458752, "default cache: FILE:..." |
| 6 | kerberos set, no identity, KEYRING ccache | creation (`acquire_cred`) | Major 458752, "Function not implemented" (rootless container) |
| 7 | kerberos set, no identity, empty MEMORY ccache | creation (`acquire_cred`) | Major 458752, "No Kerberos credentials available" |

**The work signature (Major 851968 at `ctx.step`) matched NONE of rows 2–7.**
On the current-gen stack, an empty ccache always fails eagerly at creation
with Major 458752. Reaching `ctx.step` and failing with 851968 /
KRB5_CC_NOTFOUND requires one of:

- **Story A:** an older pyspnego/gssapi in the work EE that acquires
  credentials lazily (creation succeeds with no identity; step fails) —
  Step 5 answers this
- **Story B:** a ccache that RESOLVES AND HAS CONTENTS, but no usable
  matching credential — i.e., a **stale ccache** from a legacy keytab/kinit
  flow whose refresh mechanism broke (patch dropped settings, keytab mount
  gone) — Steps 2 and 4 answer this

**Decision logic on the captured evidence:**

1. Step 2 shows `_USERNAME`/`_PASSWORD` **absent** but `_AUTH_PROTOCOL`
   present → injector on the work credential type is incomplete → Step 3
   diff shows the exact missing/misnamed lines. (Story A confirmed if Step 5
   shows old pyspnego.)
2. Step 2 shows **all vars present including `_PASSWORD`** → injection is
   fine; the plugin isn't using them → check Step 5 collection version
   (< 1.2.0 = blind to env vars) — though the traceback loading paths
   suggest a modern stock EE, so this is unlikely.
3. Step 2 shows `KRB5CCNAME` set or ccache/keytab mounts → Story B: legacy
   ccache flow, broken by the patch → Step 4 delta identifies what was lost.
4. Step 2 shows NO `MICROSOFT_AD_LDAP_*` vars at all → credential not
   attached to the source, or attached credential uses a different/broken
   type → re-check Step 1's credential field and Step 3's type id.

---

## Step 7 — The fix (same regardless of story)

Whatever the root cause, converge on the lab-validated password flow — it
needs no ccache, no keytab, no KRB5CCNAME, no AWX settings overrides, and is
therefore patch-resilient:

1. Credential type injector = repo `credential-types/injectors.yml`, verbatim
2. Credential = username (UPN) + password populated, CA chain PEM populated
3. Credential attached to the inventory source
4. `files/krb5.conf` present in the project checkout (injected via
   `KRB5_CONFIG`)

**Success verification:** re-sync and confirm the job log shows the run-1
baseline signature — `Getting initial credentials for svc_ansible@...` and
`Encrypted timestamp` (the AS-REQ), then host JSON. Those two lines are the
proof the password path is active. Absence of `_negotiate.py` frames and
absence of any ccache retrieval failure confirm full injection.

Restore the source's Verbosity to its original value afterward.

---

## Appendix — Lab vs Work navigation quick reference

Both environments are **containerized** — same layout, different install user
and version:

| | Lab (2.7 containerized) | Work (2.6-11 containerized) |
|---|---|---|
| Shell user | `svc_ansible@aap-01` | `aap@<work-controller>` |
| EE images | install user's rootless podman storage (host `podman images`; nested view inside task container if absent) | same, as `aap` |
| Projects root | `/home/svc_ansible/aap/controller/data/projects/_<id>__<name>/` (confirmed) | expect `/home/aap/aap/controller/data/projects/_<id>__<name>/` — confirm via podman inspect mounts or find (Step 0) |
| Job containers | siblings at host level, or nested inside `automation-controller-task` | same — check both |
| Private data dirs (`/tmp/awx_<jobid>_*`) | inside task container | inside task container |
| Task container | has NO ansible/collections — always inspect the EE image, never the task container | same |

**CA certificate pre-flight** — verify the PEM before mounting it into the
EE, so a bad bundle never pollutes the reproduction results:

```bash
# 1. File exists and parses as a certificate:
openssl x509 -in <path>/ca-chain.pem -noout -subject -issuer -dates

# 2. Count certs — single-tier PKI (root only): expect 1;
#    two-tier (root + subordinate): expect 2:
grep -c "BEGIN CERTIFICATE" <path>/ca-chain.pem

# 3. Confirm it is CA material, not a DC leaf (single-cert bundle:
#    subject == issuer means self-signed root — correct for single-tier):
openssl crl2pkcs7 -nocrl -certfile <path>/ca-chain.pem | openssl pkcs7 -print_certs -noout

# 4. Prove it validates what the DC actually presents on 636:
openssl s_client -connect <dc-fqdn>:636 \
  -CAfile <path>/ca-chain.pem -verify_return_error </dev/null 2>&1 \
  | grep -E "Verify return|subject|issuer"
# REQUIRED: Verify return code: 0 (ok) — do not proceed on any other code
```

Interpretation:
- Check 1 fails → not PEM / wrong file → re-export from the credential UI
- Check 3 shows a `dc-*` subject → leaf cert pasted by mistake → re-export
  the CA chain from AD CS, never the DC certificate
- Check 4 non-zero → chain incomplete (missing subordinate) or wrong CA →
  fix BEFORE the EE run, otherwise the reproduction fails at TLS and tells
  you nothing about the Kerberos path
- All pass → TLS is eliminated as a variable; any EE-run failure is
  authentication-side

CA PEM source if not on disk: the credential's CA Certificate Chain field is
non-secret and copy-pasteable from the AAP UI (`cat > ca-chain.pem`, paste,
Ctrl-D). This doubles as verification of the credential's CA field contents.

**Repeatable EE reproduction command** (adjust paths per column above):

```bash
podman run -it --rm \
  -v <projects-root>/_<id>__<name>:/runner/project:ro,Z \
  -v <path>/ca-chain.pem:/tmp/ca-chain.pem:ro,Z \
  --entrypoint /bin/bash <ee-image>:<tag>

# inside:
export KRB5_CONFIG=/runner/project/files/krb5.conf
export MICROSOFT_AD_LDAP_SERVER=<dc-fqdn>
export MICROSOFT_AD_LDAP_PORT=636
export MICROSOFT_AD_LDAP_AUTH_PROTOCOL=kerberos
export MICROSOFT_AD_LDAP_USERNAME=<upn>
read -s -p "Password: " MICROSOFT_AD_LDAP_PASSWORD; export MICROSOFT_AD_LDAP_PASSWORD; echo
export MICROSOFT_AD_LDAP_CA_CERT=/tmp/ca-chain.pem
KRB5_TRACE=/dev/stderr ansible-inventory -i /runner/project/inventories/microsoft.ad.ldap.yml --list -vvv 2>&1 | tee /tmp/sync-test.log
```
