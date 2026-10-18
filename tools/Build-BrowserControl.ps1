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

Set-StrictMode -Version Latest
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
    $TenantMetadata = Get-Content -LiteralPath $TenantMetadataPath -Raw -Encoding UTF8 |
        ConvertFrom-Json -ErrorAction Stop
}
catch {
    throw "Unable to read tenant metadata file '$TenantMetadataPath': $($_.Exception.Message)"
}

if ([string]$TenantMetadata.tenantKey -ne $TenantKey) {
    throw "Tenant key mismatch. Command requested '$TenantKey', but tenant.json contains '$($TenantMetadata.tenantKey)'."
}

function Test-JsonProperty {
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [object]$Object,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    return ($null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name])
}

function Get-JsonString {
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [object]$Object,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$DefaultValue
    )

    if (Test-JsonProperty -Object $Object -Name $Name) {
        $Value = [string]$Object.$Name
        if (-not [string]::IsNullOrWhiteSpace($Value)) {
            return $Value
        }
    }

    return $DefaultValue
}

function Get-PolicyFlag {
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [object]$Object,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [ValidateSet(0, 1)]
        [int]$DefaultValue
    )

    if (-not (Test-JsonProperty -Object $Object -Name $Name)) {
        return $DefaultValue
    }

    $Value = $Object.$Name
    if ($Value -is [bool]) {
        return [int]$Value
    }

    $ParsedValue = 0
    if ([int]::TryParse([string]$Value, [ref]$ParsedValue) -and $ParsedValue -in @(0, 1)) {
        return $ParsedValue
    }

    throw "tenant.json property 'policyControls.$Name' must be true, false, 0, or 1. Current value: $Value"
}

function Get-DownloadRestrictions {
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [object]$PolicyControls
    )

    # Secure backward-compatible default. Set downloadRestrictions to 0 in a
    # tenant.json when that tenant must allow approved downloads.
    if (-not (Test-JsonProperty -Object $PolicyControls -Name 'downloadRestrictions')) {
        return 1
    }

    $ParsedValue = 0
    $RawValue = $PolicyControls.downloadRestrictions
    if (-not [int]::TryParse([string]$RawValue, [ref]$ParsedValue)) {
        throw "tenant.json property 'policyControls.downloadRestrictions' must be an integer from 0 through 4. Current value: $RawValue"
    }

    if ($ParsedValue -notin @(0, 1, 2, 3, 4)) {
        throw "tenant.json property 'policyControls.downloadRestrictions' must be 0, 1, 2, 3, or 4. Current value: $ParsedValue"
    }

    return $ParsedValue
}

function Resolve-TenantConfigPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$MetadataProperty,

        [Parameter(Mandatory = $true)]
        [string]$DefaultRelativePath
    )

    $RelativePath = $DefaultRelativePath
    if (
        (Test-JsonProperty -Object $TenantMetadata -Name 'configurationFiles') -and
        (Test-JsonProperty -Object $TenantMetadata.configurationFiles -Name $MetadataProperty)
    ) {
        $ConfiguredPath = [string]$TenantMetadata.configurationFiles.$MetadataProperty
        if (-not [string]::IsNullOrWhiteSpace($ConfiguredPath)) {
            $RelativePath = $ConfiguredPath
        }
    }

    return Join-Path -Path $TenantRoot -ChildPath $RelativePath
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
        Get-Content -LiteralPath $Path -Encoding UTF8 |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -and -not $_.StartsWith('#') } |
            Sort-Object -Unique
    )

    if ($Entries.Count -eq 0) {
        throw "Configuration file contains no policy entries: $Path"
    }

    [string[]]$FormattedEntries = @(
        foreach ($Entry in $Entries) {
            if ($Entry -match '<|>|&lt;|&gt;|&quot;|href=|target=|rel=|title=|class=|</?a\b|<br') {
                throw "HTML content detected in $Path : $Entry"
            }
            if ($Entry -match '\s') {
                throw "Whitespace detected in $Path : $Entry"
            }
            if ($Entry -match ',https?://') {
                throw "Multiple origins detected in one entry: $Entry"
            }
            if ($Entry.StartsWith('.')) {
                throw "Leading-dot domain syntax is not permitted in $Path : $Entry"
            }

            "    '$($Entry.Replace("'", "''"))'"
        }
    )

    return ($FormattedEntries -join [Environment]::NewLine)
}

$PolicyControls = $null
if (Test-JsonProperty -Object $TenantMetadata -Name 'policyControls') {
    $PolicyControls = $TenantMetadata.policyControls
}

$HomePage = Get-JsonString -Object $TenantMetadata -Name 'homePage' -DefaultValue 'https://www.google.com/'
$DownloadRestrictions = Get-DownloadRestrictions -PolicyControls $PolicyControls

$ConfigPathMap = [ordered]@{
    commonAllowlist = Resolve-TenantConfigPath -MetadataProperty 'commonAllowlist' -DefaultRelativePath 'config/common-allowlist.txt'
    chromeOnlyAllowlist = Resolve-TenantConfigPath -MetadataProperty 'chromeOnlyAllowlist' -DefaultRelativePath 'config/chrome-only-allowlist.txt'
    edgeOnlyAllowlist = Resolve-TenantConfigPath -MetadataProperty 'edgeOnlyAllowlist' -DefaultRelativePath 'config/edge-only-allowlist.txt'
    googlePersonalBlocklist = Resolve-TenantConfigPath -MetadataProperty 'googlePersonalBlocklist' -DefaultRelativePath 'config/google-personal-blocklist.txt'
    trustedDownloadOrigins = Resolve-TenantConfigPath -MetadataProperty 'trustedDownloadOrigins' -DefaultRelativePath 'config/trusted-download-origins.txt'
    oracleCookieSites = Resolve-TenantConfigPath -MetadataProperty 'oracleCookieSites' -DefaultRelativePath 'config/oracle-cookie-sites.txt'
}

$Template = Get-Content -LiteralPath $TemplatePath -Raw -Encoding UTF8

$ReplacementMap = [ordered]@{
    '{{POLICY_VERSION}}' = $Version
    '{{POLICY_PROFILE}}' = [string]$TenantMetadata.policyProfile
    '{{ORGANIZATION_NAME}}' = [string]$TenantMetadata.organizationName
    '{{TENANT_KEY}}' = [string]$TenantMetadata.tenantKey
    '{{TENANT_DOMAIN}}' = [string]$TenantMetadata.tenantDomain
    '{{HOME_PAGE}}' = $HomePage
    '{{DOWNLOAD_RESTRICTIONS}}' = [string]$DownloadRestrictions
    '{{DEFAULT_DENY_ENABLED}}' = [string](Get-PolicyFlag -Object $PolicyControls -Name 'defaultDeny' -DefaultValue 1)
    '{{CHROME_CLOUD_AP_AUTH_ENABLED}}' = [string](Get-PolicyFlag -Object $PolicyControls -Name 'chromeCloudAPAuthEnabled' -DefaultValue 1)
    '{{CHROME_BROWSER_SIGNIN_DISABLED}}' = [string](Get-PolicyFlag -Object $PolicyControls -Name 'chromeBrowserSigninDisabled' -DefaultValue 1)
    '{{CHROME_INCOGNITO_DISABLED}}' = [string](Get-PolicyFlag -Object $PolicyControls -Name 'chromeIncognitoDisabled' -DefaultValue 1)
    '{{EDGE_INPRIVATE_DISABLED}}' = [string](Get-PolicyFlag -Object $PolicyControls -Name 'edgeInPrivateDisabled' -DefaultValue 1)
    '{{PERSONAL_GOOGLE_RESTRICTIONS_ENABLED}}' = [string](Get-PolicyFlag -Object $PolicyControls -Name 'personalGoogleRestrictionsEnabled' -DefaultValue 1)
    '{{COMMON_ALLOWLIST}}' = Convert-PolicyList -Path $ConfigPathMap.commonAllowlist
    '{{CHROME_ONLY_ALLOWLIST}}' = Convert-PolicyList -Path $ConfigPathMap.chromeOnlyAllowlist
    '{{EDGE_ONLY_ALLOWLIST}}' = Convert-PolicyList -Path $ConfigPathMap.edgeOnlyAllowlist
    '{{GOOGLE_PERSONAL_BLOCKLIST}}' = Convert-PolicyList -Path $ConfigPathMap.googlePersonalBlocklist
    '{{TRUSTED_DOWNLOAD_ORIGINS}}' = Convert-PolicyList -Path $ConfigPathMap.trustedDownloadOrigins
    '{{ORACLE_COOKIE_SITES}}' = Convert-PolicyList -Path $ConfigPathMap.oracleCookieSites
}

foreach ($Replacement in $ReplacementMap.GetEnumerator()) {
    if (-not $Template.Contains($Replacement.Key)) {
        throw "Required template placeholder is missing: $($Replacement.Key)"
    }

    $Template = $Template.Replace($Replacement.Key, $Replacement.Value)
}

$RemainingPlaceholders = @(
    [regex]::Matches($Template, '\{\{[A-Z0-9_]+\}\}') |
        ForEach-Object { $_.Value } |
        Sort-Object -Unique
)

if ($RemainingPlaceholders.Count -gt 0) {
    throw "Unresolved template placeholders remain: $($RemainingPlaceholders -join ', ')"
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
Write-Output "DownloadRestrictions=$DownloadRestrictions; HomePage=$HomePage"
