#Requires -Modules ActiveDirectory
<#
.SYNOPSIS
    Exports AD Organizational Units and Security Groups into a CSV formatted
    for LucidChart org-chart import.

.DESCRIPTION
    Queries Active Directory for all OUs and Security Groups, derives parent-child
    relationships from DistinguishedName parsing, and outputs a single CSV.

    LucidChart import mapping:
      - Name        → shape label
      - Parent      → "Reports To" / hierarchy connector
      - Type        → OU or SecurityGroup (use for conditional formatting)
      - Description → tooltip / secondary text
      - Path        → full DN for reference

.PARAMETER SearchBase
    The DN to start the search from. Defaults to the current domain root.

.PARAMETER OutputPath
    Path for the output CSV. Defaults to .\AD_OrgChart_Export.csv

.PARAMETER IncludeBuiltinOUs
    Switch to include default containers (Users, Computers, Builtin).
    Excluded by default since they clutter the chart.

.EXAMPLE
    .\Export-ADToLucidChart.ps1
    .\Export-ADToLucidChart.ps1 -SearchBase "OU=Corp,DC=contoso,DC=com"
    .\Export-ADToLucidChart.ps1 -IncludeBuiltinOUs -OutputPath "C:\exports\ad_chart.csv"
#>

[CmdletBinding()]
param(
    [string]$SearchBase,
    [string]$OutputPath = ".\AD_OrgChart_Export.csv",
    [switch]$IncludeBuiltinOUs
)

# ── Helper: extract the immediate parent name from a DN ──
function Get-ParentName {
    param([string]$DistinguishedName)

    # Split DN into components, skip the first (self), take the next
    $components = $DistinguishedName -split '(?<!\\),'
    if ($components.Count -lt 2) { return "" }

    $parentRDN = $components[1].Trim()

    # Extract the name portion (after OU= or CN= or DC=)
    if ($parentRDN -match '^(OU|CN)=(.+)$') {
        return $Matches[2]
    }
    elseif ($parentRDN -match '^DC=(.+)$') {
        # Parent is domain root — build the FQDN for readability
        $dcComponents = $components[1..($components.Count - 1)] |
            Where-Object { $_ -match '^DC=' } |
            ForEach-Object { ($_ -split '=')[1] }
        return ($dcComponents -join '.')
    }
    return $parentRDN
}

# ── Helper: build full parent DN ──
function Get-ParentDN {
    param([string]$DistinguishedName)
    $components = $DistinguishedName -split '(?<!\\),'
    if ($components.Count -lt 2) { return "" }
    return ($components[1..($components.Count - 1)] -join ',')
}

# ── Resolve domain root if SearchBase not specified ──
if (-not $SearchBase) {
    $SearchBase = (Get-ADDomain).DistinguishedName
    Write-Host "[*] Using domain root: $SearchBase" -ForegroundColor Cyan
}

$results = [System.Collections.Generic.List[PSCustomObject]]::new()

# ── Default containers to exclude (unless -IncludeBuiltinOUs) ──
$builtinContainers = @('Users', 'Computers', 'Builtin', 'ForeignSecurityPrincipals',
                        'Managed Service Accounts', 'Program Data', 'System',
                        'LostAndFound', 'Infrastructure', 'NTDS Quotas')

# ── Add the domain root as the top-level node ──
$domainFQDN = ($SearchBase -split ',' |
    Where-Object { $_ -match '^DC=' } |
    ForEach-Object { ($_ -split '=')[1] }) -join '.'

$results.Add([PSCustomObject]@{
    Name        = $domainFQDN
    Parent      = ""
    Type        = "DomainRoot"
    Description = "Active Directory Domain Root"
    GroupScope  = ""
    MemberCount = ""
    Path        = $SearchBase
})

# ── Export OUs ──
Write-Host "[*] Querying Organizational Units..." -ForegroundColor Cyan
$ous = Get-ADOrganizationalUnit -Filter * -SearchBase $SearchBase -Properties Description |
    Sort-Object DistinguishedName

foreach ($ou in $ous) {
    $ouName = $ou.Name

    # Skip builtin containers unless requested
    if (-not $IncludeBuiltinOUs -and $ouName -in $builtinContainers) { continue }

    $parentName = Get-ParentName -DistinguishedName $ou.DistinguishedName
    $parentDN   = Get-ParentDN -DistinguishedName $ou.DistinguishedName

    # If parent is the domain root, use the FQDN as parent name
    if ($parentDN -eq $SearchBase) {
        $parentName = $domainFQDN
    }

    $results.Add([PSCustomObject]@{
        Name        = $ouName
        Parent      = $parentName
        Type        = "OU"
        Description = ($ou.Description -replace '[\r\n]', ' ')
        GroupScope  = ""
        MemberCount = ""
        Path        = $ou.DistinguishedName
    })
}

Write-Host "    Found $($ous.Count) OUs" -ForegroundColor Green

# ── Export Security Groups ──
Write-Host "[*] Querying Security Groups..." -ForegroundColor Cyan
$groups = Get-ADGroup -Filter 'GroupCategory -eq "Security"' -SearchBase $SearchBase `
    -Properties Description, ManagedBy, MemberOf |
    Sort-Object DistinguishedName

foreach ($group in $groups) {
    $parentDN = Get-ParentDN -DistinguishedName $group.DistinguishedName

    # Determine parent name (the OU or container the group sits in)
    $parentName = Get-ParentName -DistinguishedName $group.DistinguishedName

    if ($parentDN -eq $SearchBase) {
        $parentName = $domainFQDN
    }

    # Skip groups in builtin containers unless requested
    if (-not $IncludeBuiltinOUs) {
        $parentRDN = ($group.DistinguishedName -split '(?<!\\),')[1].Trim()
        if ($parentRDN -match '^CN=(Users|Computers|Builtin)$') { continue }
    }

    # Get member count (separate call to avoid pulling full member list into memory)
    try {
        $memberCount = (Get-ADGroupMember -Identity $group.DistinguishedName -ErrorAction Stop).Count
    }
    catch {
        $memberCount = "N/A"
    }

    $results.Add([PSCustomObject]@{
        Name        = $group.Name
        Parent      = $parentName
        Type        = "SecurityGroup"
        Description = ($group.Description -replace '[\r\n]', ' ')
        GroupScope  = $group.GroupScope
        MemberCount = $memberCount
        Path        = $group.DistinguishedName
    })
}

Write-Host "    Found $($groups.Count) Security Groups" -ForegroundColor Green

# ── Export CSV ──
$results | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
Write-Host "`n[+] Exported $($results.Count) objects to: $OutputPath" -ForegroundColor Green

# ── Summary ──
Write-Host "`n── LucidChart Import Instructions ──" -ForegroundColor Yellow
Write-Host @"

1. Open LucidChart → File → Import Data → CSV
2. Choose 'Org Chart' as the diagram type
3. Map columns:
     Name        → Shape label / Name
     Parent      → Reports To / Parent
     Type        → (optional) use for conditional formatting
     Description → (optional) secondary text field
     GroupScope  → (optional) for security group detail
     MemberCount → (optional) for security group detail
4. After import, use conditional formatting:
     Type = "OU"            → one color (e.g., blue)
     Type = "SecurityGroup" → another color (e.g., green)
     Type = "DomainRoot"    → root color (e.g., gray)
5. Clean up layout as needed — LucidChart auto-arranges but
   large exports may need manual adjustment.

"@ -ForegroundColor White
