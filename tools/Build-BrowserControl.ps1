param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-z0-9-]+$')]
    [string]$TenantKey,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9._-]+$')]
    [string]$Version,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'

$RepositoryRoot = Split-Path -Path $PSScriptRoot -Parent
$TenantRoot = Join-Path -Path $RepositoryRoot -ChildPath "tenants\$TenantKey"
$TenantMetadataPath = Join-Path -Path $TenantRoot -ChildPath 'tenant.json'
$ConfigDirectory = Join-Path -Path $TenantRoot -ChildPath 'config'
$TemplatePath = Join-Path -Path $RepositoryRoot -ChildPath 'src\Browser-Control-Template.ps1'

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path -Path $RepositoryRoot -ChildPath "output\$TenantKey\Browser-Control.ps1"
}
elseif (-not [System.IO.Path]::IsPathRooted($OutputPath)) {
    $OutputPath = Join-Path -Path $RepositoryRoot -ChildPath $OutputPath
}

foreach ($RequiredPath in @($TenantRoot, $TenantMetadataPath, $ConfigDirectory, $TemplatePath)) {
    if (-not (Test-Path -LiteralPath $RequiredPath)) {
        throw "Required repository path was not found: $RequiredPath"
    }
}

try {
    $TenantMetadata = Get-Content -LiteralPath $TenantMetadataPath -Raw |
        ConvertFrom-Json -ErrorAction Stop
}
catch {
    throw "Unable to read tenant metadata file '$TenantMetadataPath': $($_.Exception.Message)"
}

if ($TenantMetadata.tenantKey -ne $TenantKey) {
    throw "Tenant key mismatch. Command requested '$TenantKey', but tenant.json contains '$($TenantMetadata.tenantKey)'."
}

function Convert-PolicyList {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Required configuration file not found: $Path"
    }

    [string[]]$Entries = @(
        Get-Content -LiteralPath $Path |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -and -not $_.StartsWith('#') } |
            Sort-Object -Unique
    )

    if ($Entries.Count -eq 0) {
        throw "Configuration file contains no policy entries: $Path"
    }

    foreach ($Entry in $Entries) {
        if ([string]::IsNullOrWhiteSpace($Entry)) {
            throw "Empty policy entry detected in: $Path"
        }

        if ($Entry -match '<|>|&lt;|&gt;|&quot;|href=|target=|rel=|title=|class=|</?a\b|<br') {
            throw "HTML content detected in $Path : $Entry"
        }

        if ($Entry -match '\s') {
            throw "Whitespace detected in $Path : $Entry"
        }

        if ($Entry -match ',https?://') {
            throw "Multiple origins detected in one entry: $Entry"
        }
    }

    [string[]]$FormattedEntries = @(
        foreach ($Entry in $Entries) {
            "    '$($Entry.Replace("'", "''"))'"
        }
    )

    return ($FormattedEntries -join [Environment]::NewLine)
}

$Template = Get-Content -LiteralPath $TemplatePath -Raw

$ReplacementMap = [ordered]@{
    '{{POLICY_VERSION}}' = $Version
    '{{POLICY_PROFILE}}' = [string]$TenantMetadata.policyProfile
    '{{ORGANIZATION_NAME}}' = [string]$TenantMetadata.organizationName
    '{{TENANT_KEY}}' = [string]$TenantMetadata.tenantKey
    '{{COMMON_ALLOWLIST}}' = Convert-PolicyList -Path (Join-Path $ConfigDirectory 'common-allowlist.txt')
    '{{CHROME_ONLY_ALLOWLIST}}' = Convert-PolicyList -Path (Join-Path $ConfigDirectory 'chrome-only-allowlist.txt')
    '{{EDGE_ONLY_ALLOWLIST}}' = Convert-PolicyList -Path (Join-Path $ConfigDirectory 'edge-only-allowlist.txt')
    '{{GOOGLE_PERSONAL_BLOCKLIST}}' = Convert-PolicyList -Path (Join-Path $ConfigDirectory 'google-personal-blocklist.txt')
    '{{TRUSTED_DOWNLOAD_ORIGINS}}' = Convert-PolicyList -Path (Join-Path $ConfigDirectory 'trusted-download-origins.txt')
    '{{ORACLE_COOKIE_SITES}}' = Convert-PolicyList -Path (Join-Path $ConfigDirectory 'oracle-cookie-sites.txt')
}

$RequiredPlaceholders = @(
    '{{POLICY_VERSION}}',
    '{{COMMON_ALLOWLIST}}',
    '{{CHROME_ONLY_ALLOWLIST}}',
    '{{EDGE_ONLY_ALLOWLIST}}',
    '{{GOOGLE_PERSONAL_BLOCKLIST}}',
    '{{TRUSTED_DOWNLOAD_ORIGINS}}',
    '{{ORACLE_COOKIE_SITES}}'
)

foreach ($Replacement in $ReplacementMap.GetEnumerator()) {
    if ($Template.Contains($Replacement.Key)) {
        $Template = $Template.Replace($Replacement.Key, $Replacement.Value)
    }
    elseif ($Replacement.Key -in $RequiredPlaceholders) {
        throw "Required template placeholder is missing: $($Replacement.Key)"
    }
}

if ($Template -match '\{\{[A-Z0-9_]+\}\}') {
    $RemainingPlaceholders = @(
        [regex]::Matches($Template, '\{\{[A-Z0-9_]+\}\}') |
            ForEach-Object { $_.Value } |
            Sort-Object -Unique
    ) -join ', '

    throw "Unresolved template placeholders remain: $RemainingPlaceholders"
}

$OutputDirectory = Split-Path -Path $OutputPath -Parent
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    throw "Unable to determine output directory: $OutputPath"
}

New-Item -Path $OutputDirectory -ItemType Directory -Force | Out-Null
$ResolvedOutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).Path
$ResolvedOutputPath = Join-Path -Path $ResolvedOutputDirectory -ChildPath (Split-Path -Path $OutputPath -Leaf)

[System.IO.File]::WriteAllText(
    $ResolvedOutputPath,
    $Template,
    [System.Text.UTF8Encoding]::new($true)
)

Write-Output "Created $Version policy for tenant '$TenantKey': $ResolvedOutputPath"
