# Independent Kerberos & LDAPS Layer Tests

## Purpose

Isolate Kerberos authentication and LDAPS connectivity as independent layers,
tested outside and inside the Execution Environment, without involving the
`microsoft.ad.ldap` plugin or AAP credential injection. If both layers pass
independently and the plugin still fails, the problem is credential injection.

These tests require no external scripts or project files — just CLI commands
available on any RHEL system with `krb5-workstation` and `openldap-clients`.

## Prerequisites

Install on both lab and work AAP hosts:

```
sudo dnf install -y krb5-workstation openldap-clients
```

## Environment Variables

Adapt these for your environment before running:

| Variable | Lab Value | Work Value |
|----------|-----------|------------|
| DC FQDN | dc-01.corp.ritcsusa.com | (your work DC FQDN) |
| Realm | CORP.RITCSUSA.COM | (your work realm) |
| Service Account UPN | svc_ansible@CORP.RITCSUSA.COM | (your work UPN) |
| LDAPS Port | 636 | 636 |
| EE Image | registry.redhat.io/ansible-automation-platform-27/ee-supported-rhel9:latest | (work EE image) |

## Test 1: Kerberos on the Host

Proves KDC reachability and credential acceptance from the AAP host itself.
No LDAP, no TLS, no plugin involved.

```
kinit svc_ansible@CORP.RITCSUSA.COM
klist
kdestroy
```

Expected output: TGT issued, valid ticket shown, no errors.

### Lab Result (aap-01.rh.corp.ritcsusa.com, 2026-08-04)

```
Ticket cache: KCM:1000:24732
Default principal: svc_ansible@CORP.RITCSUSA.COM
Valid starting       Expires              Service principal
08/04/2026 10:20:28  08/04/2026 20:20:28  krbtgt/CORP.RITCSUSA.COM@CORP.RITCSUSA.COM
        renew until 08/05/2026 10:20:16
```

PASS. Host Kerberos is clean.

## Test 2: LDAPS on the Host

Proves TLS connectivity and LDAP protocol to the DC from the AAP host.
Anonymous simple bind to rootDSE — no Kerberos, no credentials beyond TLS.

```
ldapsearch -H ldaps://dc-01.corp.ritcsusa.com:636 -x -b "" -s base "(objectClass=*)" defaultNamingContext dnsHostName
```

Expected output: `result: 0 Success` with `defaultNamingContext` and
`dnsHostName` attributes returned.

### Lab Result

```
dnsHostName: dc-01.corp.ritcsusa.com
defaultNamingContext: DC=corp,DC=ritcsusa,DC=com
result: 0 Success
```

PASS. Host LDAPS is clean. The corp CA (`corp-DC-01-CA`) is in the system
trust store, so no explicit CA file is needed on the host.

## Test 3: Kerberos Inside the EE

Enter the stock EE:

```
podman run -it --rm --entrypoint /bin/bash <EE_IMAGE>
```

### 3a. Naive kinit (expected to fail)

```
kinit svc_ansible@CORP.RITCSUSA.COM
```

### Lab Result — Failure 1: KEYRING ccache

```
kinit: Function not implemented while getting default ccache
```

The stock EE ships `default_ccache_name = KEYRING:persistent:%{uid}` in
`/etc/krb5.conf`. KEYRING requires kernel keyring support, which is not
available inside a container. Fix by overriding `KRB5CCNAME`:

```
KRB5CCNAME=FILE:/tmp/krb5cc_test kinit svc_ansible@CORP.RITCSUSA.COM
```

### Lab Result — Failure 2: Encryption type mismatch

```
kinit: KDC has no support for encryption type while getting initial credentials
```

The stock EE's RHEL 9 crypto policy (`/etc/krb5.conf.d/crypto-policies`)
restricts to RFC 8009 SHA-2 enctypes only:

```
permitted_enctypes = aes256-cts-hmac-sha384-192 aes128-cts-hmac-sha256-128
```

AD does not support these. AD uses the SHA-1 enctypes:
`aes256-cts-hmac-sha1-96` and `aes128-cts-hmac-sha1-96`.

### 3b. Fix: Write a minimal krb5.conf inside the container

This is what the project's `files/krb5.conf` does at sync time (delivered via
the `KRB5_CONFIG` injector variable).

```
cat > /tmp/krb5.conf << 'EOF'
[libdefaults]
  default_realm = CORP.RITCSUSA.COM
  default_ccache_name = FILE:/tmp/krb5cc_%{uid}
  permitted_enctypes = aes256-cts-hmac-sha1-96 aes128-cts-hmac-sha1-96
  rdns = false
[realms]
  CORP.RITCSUSA.COM = {
    kdc = dc-01.corp.ritcsusa.com
    kdc = dc-02.corp.ritcsusa.com
  }
[domain_realm]
  .corp.ritcsusa.com = CORP.RITCSUSA.COM
  corp.ritcsusa.com = CORP.RITCSUSA.COM
EOF

KRB5_CONFIG=/tmp/krb5.conf kinit svc_ansible@CORP.RITCSUSA.COM
KRB5_CONFIG=/tmp/krb5.conf klist
```

### Lab Result — With fix

```
Ticket cache: FILE:/tmp/krb5cc_0
Default principal: svc_ansible@CORP.RITCSUSA.COM
Valid starting     Expires            Service principal
08/04/26 14:26:42  08/05/26 00:26:42  krbtgt/CORP.RITCSUSA.COM@CORP.RITCSUSA.COM
        renew until 08/05/26 14:26:28
```

PASS. Kerberos works inside the EE once krb5.conf is correct.

## Test 4: LDAPS Inside the EE

Still inside the same container. `ldapsearch` is not installed in the stock
EE, so use Python's `ssl` module (same TLS path the plugin uses).

### 4a. With default trust store (expected to fail)

```
python3 -c "
import ssl, socket
ctx = ssl.create_default_context()
with socket.create_connection(('dc-01.corp.ritcsusa.com', 636), timeout=10) as s:
    with ctx.wrap_socket(s, server_hostname='dc-01.corp.ritcsusa.com') as ss:
        print(f'TLS OK: {ss.version()}')
"
```

### Lab Result

```
ssl.SSLCertVerificationError: [SSL: CERTIFICATE_VERIFY_FAILED] certificate verify failed:
unable to get local issuer certificate (_ssl.c:998)
```

Expected. The stock EE has no corp CA in its trust store. In production, the
injector writes the CA PEM to a temp file and passes the path via
`MICROSOFT_AD_LDAP_CA_CERT`.

### 4b. Without certificate verification (proves TLS transport works)

```
python3 -c "
import ssl, socket
ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE
with socket.create_connection(('dc-01.corp.ritcsusa.com', 636), timeout=10) as s:
    with ctx.wrap_socket(s, server_hostname='dc-01.corp.ritcsusa.com') as ss:
        print(f'TLS OK (no verify): {ss.version()}')
        print(f'Cipher: {ss.cipher()[0]}')
"
```

### Lab Result

```
TLS OK (no verify): TLSv1.3
Cipher: TLS_AES_256_GCM_SHA384
```

PASS. TLS transport works from inside the EE. Certificate validation is the
injector's responsibility (CA cert delivered via credential).

## Stock EE Failure Modes Summary

The stock `ee-supported-rhel9` has three issues that the project's credential
injection resolves at sync time:

| Issue | Stock EE Default | Fix (Injector) | Error If Missing |
|-------|------------------|----------------|------------------|
| KEYRING ccache | `KEYRING:persistent:%{uid}` | `KRB5_CONFIG` points to project krb5.conf with `FILE:` ccache | `Function not implemented while getting default ccache` |
| SHA-2-only enctypes | `aes256-cts-hmac-sha384-192`, `aes128-cts-hmac-sha256-128` | Project krb5.conf sets `aes256-cts-hmac-sha1-96`, `aes128-cts-hmac-sha1-96` | `KDC has no support for encryption type` |
| No corp CA | Empty `/etc/pki/ca-trust/source/anchors/` | `MICROSOFT_AD_LDAP_CA_CERT` temp file | `unable to get local issuer certificate` |

If `KRB5_CONFIG` is not injected, `includedir /etc/krb5.conf.d/` loads the
crypto-policies file, which overrides any enctypes the plugin might set. The
project krb5.conf does not use `includedir`, so setting `KRB5_CONFIG` bypasses
the crypto policy entirely.

## Adapting for Work

When running these tests on the work AAP system:

1. **Substitute your work values** for DC FQDN, realm, UPN, and EE image
   (see Environment Variables table above).

2. **Host tests (1 and 2)** should pass if the work host is domain-joined
   and the CA is in the system trust store. If `ldapsearch` gives a TLS error,
   you need to find the CA. Check `trust list | grep -i <your-org>` or
   pull the CA from the DC's AIA endpoint.

3. **EE tests (3 and 4)** — expect the same three failures as lab if the work
   environment uses the same stock `ee-supported-rhel9` image. Verify by
   checking the crypto-policies file inside the container:
   `cat /etc/krb5.conf.d/crypto-policies`

4. **For the krb5.conf inside the EE** (test 3b), update the `[realms]`
   section with your work DCs and realm. If the work realm is different from
   `CORP.RITCSUSA.COM`, update `default_realm` and `[domain_realm]` too.

5. **Work is AAP 2.6 RPM-based** — the EE image registry path may differ.
   Check with `podman images | grep ee-supported` on the work host.

6. **If both layers pass independently but the plugin fails in AAP**, the
   problem is credential injection. Verify the injector uses
   `MICROSOFT_AD_LDAP_*` variable names, not custom names like `MSAD_*`.

## Diagnostic Decision Tree

```
Host kinit fails?
  → KDC unreachable, wrong password, or realm misconfigured
  → Fix the host Kerberos config first

Host ldapsearch fails?
  → TLS cert error: CA not in trust store
  → Connection refused: DC down or port 636 blocked
  → Fix network/cert before touching the EE

EE kinit fails with "Function not implemented"?
  → KEYRING ccache — need KRB5_CONFIG override

EE kinit fails with "no support for encryption type"?
  → Crypto policy mismatch — need project krb5.conf

EE Python TLS fails with "unable to get local issuer certificate"?
  → Expected — CA cert must be injected via credential

All layers pass but plugin fails?
  → Credential injection broken
  → Check: env var names in injector (MICROSOFT_AD_LDAP_* not MSAD_*)
  → Check: KRB5_CONFIG path in injector points to project krb5.conf
```
