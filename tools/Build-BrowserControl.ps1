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

# Resolve all paths relative to the repository instead of the
# current PowerShell working directory.
$RepositoryRoot = Split-Path `
    -Path $PSScriptRoot `
    -Parent

$TenantRoot = Join-Path `
    -Path $RepositoryRoot `
    -ChildPath "tenants\$TenantKey"

$TenantMetadataPath = Join-Path `
    -Path $TenantRoot `
    -ChildPath 'tenant.json'

$ConfigDirectory = Join-Path `
    -Path $TenantRoot `
    -ChildPath 'config'

$TemplatePath = Join-Path `
    -Path $RepositoryRoot `
    -ChildPath 'src\Browser-Control-Template.ps1'

if (:IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path `
        -Path $RepositoryRoot `
        -ChildPath "output\$TenantKey\Browser-Control.ps1"
}
elseif (-not [System.IO.Path]::IsPathRooted($OutputPath)) {
    $OutputPath = Join-Path `
        -Path $RepositoryRoot `
        -ChildPath $OutputPath
}

if (-not (Test-Path -LiteralPath $TenantRoot)) {
    throw "Unknown tenant key or tenant folder is missing: $TenantKey"
}

if (-not (Test-Path -LiteralPath $TenantMetadataPath)) {
    throw "Tenant metadata file not found: $TenantMetadataPath"
}

if (-not (Test-Path -LiteralPath $ConfigDirectory)) {
    throw "Tenant configuration directory not found: $ConfigDirectory"
}

if (-not (Test-Path -LiteralPath $TemplatePath)) {
    throw "Browser-control template not found: $TemplatePath"
}

try {
    $TenantMetadata = Get-Content `
        -LiteralPath $TenantMetadataPath `
        -Raw |
        ConvertFrom-Json `
            -ErrorAction Stop
}
catch {
    throw (
        "Unable to read tenant metadata file '{0}': {1}" -f
        $TenantMetadataPath,
        $_.Exception.Message
    )
}

if ($TenantMetadata.tenantKey -ne $TenantKey) {
    throw (
        "Tenant key mismatch. Command requested '{0}', " +
        "but tenant.json contains '{1}'." -f
        $TenantKey,
        $TenantMetadata.tenantKey
    )
}

function Convert-PolicyList {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Required configuration file not found: $Path"
    }

    $Entries = Get-Content -LiteralPath $Path |
        ForEach-Object {
            $_.Trim()
        } |
        Where-Object {
            $_ -and -not $_.StartsWith('#')
        } |
        Sort-Object -Unique

    if ($Entries.Count -eq 0) {
        throw "Configuration file contains no policy entries: $Path"
    }

    foreach ($Entry in $Entries) {
        if ([string]::IsNullOrWhiteSpace($Entry)) {
            throw "Empty policy entry detected in: $Path"
        }

        if (
            $Entry -match '<|>|&lt;|&gt;|href=|target=|class='
        ) {
            throw "HTML content detected in $Path : $Entry"
        }

        if ($Entry -match '\s') {
            throw "Whitespace detected in $Path : $Entry"
        }

        if ($Entry -match ',https?://') {
            throw "Multiple origins detected in one entry: $Entry"
        }
    }

    return (
    $Entries |
        ForEach-Object {
            "    '$($_.Replace("'", "''"))'"
        }
) -join [Environment]::NewLine
}

$Template = Get-Content `
    -LiteralPath $TemplatePath `
    -Raw

$ReplacementMap = @{
    '{{POLICY_VERSION}}' =
        $Version

    '{{POLICY_PROFILE}}' =
        [string]$TenantMetadata.policyProfile

    '{{ORGANIZATION_NAME}}' =
        [string]$TenantMetadata.organizationName

    '{{TENANT_KEY}}' =
        [string]$TenantMetadata.tenantKey

    '{{COMMON_ALLOWLIST}}' =
        Convert-PolicyList `
            -Path (
                Join-Path `
                    $ConfigDirectory `
                    'common-allowlist.txt'
            )

    '{{CHROME_ONLY_ALLOWLIST}}' =
        Convert-PolicyList `
            -Path (
                Join-Path `
                    $ConfigDirectory `
                    'chrome-only-allowlist.txt'
            )

    '{{EDGE_ONLY_ALLOWLIST}}' =
        Convert-PolicyList `
            -Path (
                Join-Path `
                    $ConfigDirectory `
                    'edge-only-allowlist.txt'
            )

    '{{GOOGLE_PERSONAL_BLOCKLIST}}' =
        Convert-PolicyList `
            -Path (
                Join-Path `
                    $ConfigDirectory `
                    'google-personal-blocklist.txt'
            )

    '{{TRUSTED_DOWNLOAD_ORIGINS}}' =
        Convert-PolicyList `
            -Path (
                Join-Path `
                    $ConfigDirectory `
                    'trusted-download-origins.txt'
            )

    '{{ORACLE_COOKIE_SITES}}' =
        Convert-PolicyList `
            -Path (
                Join-Path `
                    $ConfigDirectory `
                    'oracle-cookie-sites.txt'
            )
}

foreach ($Replacement in $ReplacementMap.GetEnumerator()) {
    if ($Template.Contains($Replacement.Key)) {
        $Template = $Template.Replace(
            $Replacement.Key,
            $Replacement.Value
        )
    }
    elseif (
        $Replacement.Key -in @(
            '{{POLICY_VERSION}}',
            '{{COMMON_ALLOWLIST}}',
            '{{CHROME_ONLY_ALLOWLIST}}',
            '{{EDGE_ONLY_ALLOWLIST}}',
            '{{GOOGLE_PERSONAL_BLOCKLIST}}',
            '{{TRUSTED_DOWNLOAD_ORIGINS}}',
            '{{ORACLE_COOKIE_SITES}}'
        )
    ) {
        throw (
            "Required template placeholder is missing: {0}" -f
            $Replacement.Key
        )
    }
}

if ($Template -match '\{\{[A-Z0-9_]+\}\}') {
    $RemainingPlaceholders = (
        :Matches(
            $Template,
            '\{\{[A-Z0-9_]+\}\}'
        ) |
        ForEach-Object {
            $_.Value
        } |
        Sort-Object -Unique
    ) -join ', '

    throw (
        "Unresolved template placeholders remain: {0}" -f
        $RemainingPlaceholders
    )
}

$OutputDirectory = Split-Path `
    -Path $OutputPath `
    -Parent

if (:IsNullOrWhiteSpace($OutputDirectory)) {
    throw "Unable to determine output directory: $OutputPath"
}

New-Item `
    -Path $OutputDirectory `
    -ItemType Directory `
    -Force |
    Out-Null

$ResolvedOutputDirectory = (
    Resolve-Path `
        -LiteralPath $OutputDirectory
).Path

$ResolvedOutputPath = Join-Path `
    -Path $ResolvedOutputDirectory `
    -ChildPath (
        Split-Path `
            -Path $OutputPath `
            -Leaf
    )

[System.IO.File]::WriteAllText(
    $ResolvedOutputPath,
    $Template,
    [System.Text.UTF8Encoding]::new($true)
)

Write-Output (
    "Created {0} policy for tenant '{1}': {2}" -f
    $Version,
    $TenantKey,
    $ResolvedOutputPath
)
