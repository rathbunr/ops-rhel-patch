# AAP Credential Type: Microsoft AD LDAP — Replication Guide

## Overview

This is the verified working credential type configuration from the lab
(AAP 2.7, aap-01.rh.corp.ritcsusa.com). Copy both the Input Configuration
and Injector Configuration exactly into the work AAP system.

**The injector env var names are non-negotiable.** The `microsoft.ad.ldap`
plugin only reads `MICROSOFT_AD_LDAP_*` names. Custom names (e.g. `MSAD_*`)
are invisible to the plugin — it falls back to ccache lookup and fails with
`SpnegoError ... Matching credential not found`.

## Step 1: Create the Credential Type

**Administration → Credential Types → Add**

**Name:** Microsoft AD LDAP

### Input Configuration

Paste this exactly:

```yaml
fields:
  - id: ldap_server
    type: string
    label: LDAP Server
    default: dc-01.corp.ritcsusa.com
    help_text: FQDN of Domain Controller (e.g., dc-01.corp.ritcsusa.com)
  - id: ldap_port
    type: string
    label: LDAP Port
    default: '636'
    help_text: 'LDAPS port (default: 636, Global Catalog: 3269)'
  - id: search_base
    type: string
    label: Search Base DN
    default: DC=corp,DC=ritcsusa,DC=com
    help_text: LDAP search base (e.g., DC=corp,DC=ritcsusa,DC=com)
  - id: auth_protocol
    type: string
    label: Authentication Protocol
    choices:
      - kerberos
      - certificate
    default: kerberos
    help_text: kerberos=username+password, certificate=client cert+key (mTLS)
  - id: username
    type: string
    label: Username (UPN)
    default: svc_ansible_win@CORP.RITCSUSA.COM
    help_text: Service account UPN (e.g., svc_ansible_win@CORP.RITCSUSA.COM)
  - id: password
    type: string
    label: Password
    secret: true
    help_text: Service account password (required for Kerberos)
  - id: ca_cert
    type: string
    label: CA Certificate (PEM)
    help_text: PEM CA certificate for LDAPS validation
    multiline: true
  - id: client_cert
    type: string
    label: Client Certificate (PEM)
    help_text: PEM client certificate for mTLS authentication
    multiline: true
  - id: client_key
    type: string
    label: Client Private Key (PEM)
    secret: true
    help_text: PEM private key for client certificate
    multiline: true
  - id: cert_password
    type: string
    label: Certificate Password
    secret: true
    help_text: Password for encrypted private key (if applicable)
required:
  - auth_protocol
  - ldap_server
  - search_base
  - ca_cert
```

### Injector Configuration

Paste this exactly:

```yaml
env:
  KRB5_CONFIG: /runner/project/files/krb5.conf
  MICROSOFT_AD_LDAP_PORT: '{{ ldap_port }}'
  MICROSOFT_AD_LDAP_SERVER: '{{ ldap_server }}'
  MICROSOFT_AD_LDAP_CA_CERT: '{{ tower.filename.ca_cert }}'
  MICROSOFT_AD_LDAP_PASSWORD: '{{ password }}'
  MICROSOFT_AD_LDAP_USERNAME: '{{ username }}'
  MICROSOFT_AD_LDAP_CERTIFICATE: '{{ tower.filename.client_cert }}'
  MICROSOFT_AD_LDAP_AUTH_PROTOCOL: '{{ auth_protocol }}'
  MICROSOFT_AD_LDAP_CERTIFICATE_KEY: '{{ tower.filename.client_key }}'
  MICROSOFT_AD_LDAP_CERTIFICATE_PASSWORD: '{{ cert_password }}'
file:
  template.ca_cert: '{{ ca_cert }}'
  template.client_key: '{{ client_key }}'
  template.client_cert: '{{ client_cert }}'
```

## Step 2: Create the Credential

**Resources → Credentials → Add**

| Field | Lab Value | Work Value |
|-------|-----------|------------|
| Name | CORP AD Service Account | (your name) |
| Credential Type | Microsoft AD LDAP | Microsoft AD LDAP |
| LDAP Server | dc-01.corp.ritcsusa.com | (your work DC FQDN) |
| LDAP Port | 636 | 636 |
| Search Base DN | DC=corp,DC=ritcsusa,DC=com | (your work search base) |
| Authentication Protocol | kerberos | kerberos |
| Username (UPN) | svc_ansible_win@CORP.RITCSUSA.COM | (your work UPN) |
| Password | (service account password) | (service account password) |
| CA Certificate (PEM) | (root CA PEM — corp-DC-01-CA) | (your work CA PEM chain) |

## Step 3: Project Must Include krb5.conf

The injector sets `KRB5_CONFIG=/runner/project/files/krb5.conf`. This file
must exist in the project repository at `files/krb5.conf`. It does three
critical things that the stock EE does not:

1. Sets `default_ccache_name = FILE:/tmp/krb5cc_%{uid}` (replaces KEYRING)
2. Sets `permitted_enctypes` to SHA-1 AES (replaces RHEL 9 SHA-2-only policy)
3. Defines the realm and KDC list

For work, create `files/krb5.conf` with your work realm and DCs:

```
[libdefaults]
  default_realm = YOUR.REALM.HERE
  default_ccache_name = FILE:/tmp/krb5cc_%{uid}
  dns_lookup_realm = true
  dns_lookup_kdc = true
  rdns = false
  forwardable = true
  renewable = true
  default_tkt_enctypes = aes256-cts-hmac-sha1-96 aes128-cts-hmac-sha1-96
  default_tgs_enctypes = aes256-cts-hmac-sha1-96 aes128-cts-hmac-sha1-96
  permitted_enctypes = aes256-cts-hmac-sha1-96 aes128-cts-hmac-sha1-96

[realms]
  YOUR.REALM.HERE = {
    kdc = your-dc-01.domain.com
    kdc = your-dc-02.domain.com
  }

[domain_realm]
  .your.domain.com = YOUR.REALM.HERE
  your.domain.com = YOUR.REALM.HERE
```

## Step 4: Inventory Source Configuration

| Setting | Value |
|---------|-------|
| Source | Sourced from a Project |
| Project | (select your project) |
| Inventory File | inventories/microsoft.ad.ldap.yml |
| Credential | (the credential from Step 2) |
| Overwrite | Yes |
| Overwrite variables | Yes |
| Inventory Plugins Allow List | microsoft.ad.ldap |

## What to Check If Work Still Fails

If the credential type and credential are correct but syncs still fail:

1. **Compare the injector at work against this document character by character.**
   A prior patch may have overwritten it. The most common breakage is renamed
   env vars (e.g. `MSAD_*` instead of `MICROSOFT_AD_LDAP_*`).

2. **Verify `files/krb5.conf` exists in the work project repo.** If the file
   is missing, `KRB5_CONFIG` points to nothing and the EE falls back to its
   stock config, which fails on both ccache type and enctypes.

3. **Verify the EE has the required Python packages.** The stock
   `ee-supported-rhel9` has them. A custom EE may not. Required: `pyspnego`,
   `gssapi`, `krb5`, `sansldap`, `dnspython`.

4. **Verify the CA certificate in the credential is correct.** For the lab,
   this is the single root CA (`corp-DC-01-CA`). For work, include the full
   chain (root + all subordinate CAs). The DC leaf cert must NOT be included.

5. **Run the independent layer tests** (see `independent-layer-tests.md`)
   on the work host and inside the work EE to confirm the layers work
   outside of AAP.
