# Multi-tenant Chrome and Edge browser-control template
# This file must remain tenant-neutral. The build process replaces all {{...}} tokens.
# Deployment target: Microsoft Intune Platform Script, 64-bit SYSTEM context.

#requires -version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$OrganizationName = '{{ORGANIZATION_NAME}}'
$TenantKey = '{{TENANT_KEY}}'
$TenantDomain = '{{TENANT_DOMAIN}}'
$PolicyProfile = '{{POLICY_PROFILE}}'
$PolicyVersion = '{{POLICY_VERSION}}'
$HomePage = '{{HOME_PAGE}}'

# Integer policy values rendered from tenant.json by the build script.
$DownloadRestrictions = [int]'{{DOWNLOAD_RESTRICTIONS}}'
$DefaultDenyEnabled = [int]'{{DEFAULT_DENY_ENABLED}}'
$ChromeCloudAPAuthEnabled = [int]'{{CHROME_CLOUD_AP_AUTH_ENABLED}}'
$ChromeBrowserSigninDisabled = [int]'{{CHROME_BROWSER_SIGNIN_DISABLED}}'
$ChromeIncognitoDisabled = [int]'{{CHROME_INCOGNITO_DISABLED}}'
$EdgeInPrivateDisabled = [int]'{{EDGE_INPRIVATE_DISABLED}}'
$PersonalGoogleRestrictionsEnabled = [int]'{{PERSONAL_GOOGLE_RESTRICTIONS_ENABLED}}'

# The build script renders configuration-file entries as single-quoted PowerShell strings.
$CommonAllowlist = @(
{{COMMON_ALLOWLIST}}
)

$ChromeOnlyAllowlist = @(
{{CHROME_ONLY_ALLOWLIST}}
)

$EdgeOnlyAllowlist = @(
{{EDGE_ONLY_ALLOWLIST}}
)

$GooglePersonalBlocklist = @(
{{GOOGLE_PERSONAL_BLOCKLIST}}
)

$TrustedDownloadOrigins = @(
{{TRUSTED_DOWNLOAD_ORIGINS}}
)

$OracleCookieSites = @(
{{ORACLE_COOKIE_SITES}}
)

$SafeTenantKey = $TenantKey -replace '[^A-Za-z0-9._-]', '_'
$LogFolder = Join-Path $env:ProgramData (Join-Path $SafeTenantKey 'Logs')
$LogFile = Join-Path $LogFolder ('Browser-Control-{0}.log' -f $PolicyProfile)
$Marker = 'HKLM:\SOFTWARE\BrowserControl\Tenants\{0}' -f $SafeTenantKey
$ChromeRoot = 'HKLM:\SOFTWARE\Policies\Google\Chrome'
$EdgeRoot = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'

New-Item -Path $LogFolder -ItemType Directory -Force | Out-Null

function Write-Log {
    param([Parameter(Mandatory = $true)][string]$Message)
    $line = '{0} - {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
}

function ConvertTo-PolicyFlag {
    param(
        [Parameter(Mandatory = $true)][int]$Value,
        [Parameter(Mandatory = $true)][string]$Name
    )
    if ($Value -notin @(0, 1)) {
        throw "$Name must be 0 or 1. Current value: $Value"
    }
    return $Value
}

function Test-TemplateRendered {
    [string[]]$UnresolvedValues = @(
        @(
            $OrganizationName
            $TenantKey
            $TenantDomain
            $PolicyProfile
            $PolicyVersion
            $HomePage
        ) |
            Where-Object {
                $_ -match '\{\{[^}]+\}\}'
            }
    )

    if ($UnresolvedValues.Count -gt 0) {
        throw (
            'The generated script contains unresolved scalar template values: {0}' -f
            ($UnresolvedValues -join ', ')
        )
    }

    $RawScript = Get-Content `
        -LiteralPath $PSCommandPath `
        -Raw `
        -Encoding UTF8

    [System.Text.RegularExpressions.Match[]]$UnresolvedTokenMatches = @(
        [regex]::Matches(
            $RawScript,
            '\{\{[A-Z0-9_]+\}\}'
        )
    )

    if ($UnresolvedTokenMatches.Count -gt 0) {
        [string[]]$UnresolvedTokens = @(
            $UnresolvedTokenMatches |
                ForEach-Object {
                    $_.Value
                } |
                Sort-Object -Unique
        )

        throw (
            'The generated script contains unresolved tokens: {0}' -f
            ($UnresolvedTokens -join ', ')
        )
    }
}

function Get-CleanUniqueList {
    param([AllowEmptyCollection()][string[]]$Items)
    return @(
        $Items |
            ForEach-Object {
                if ($null -ne $_) { $_.Trim() }
            } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Sort-Object -Unique
    )
}

function Test-UrlPolicyEntry {
    param([Parameter(Mandatory = $true)][string]$Entry)

    if ($Entry -match '<|>|&lt;|&gt;|&quot;|href=|target=|rel=|title=|class=|</?a\b|<br') {
        throw ('HTML detected in URL policy entry: ' + $Entry)
    }
    if ($Entry -match '\s') {
        throw ('Whitespace detected in URL policy entry: ' + $Entry)
    }
    if ($Entry -match ',https?://') {
        throw ('Multiple origins found in one policy entry: ' + $Entry)
    }
    if ($Entry.StartsWith('.')) {
        throw ('Leading-dot domain syntax is not permitted: ' + $Entry)
    }
}

function Set-PolicyList {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [AllowEmptyCollection()][string[]]$Items
    )

    $clean = Get-CleanUniqueList -Items $Items
    foreach ($item in $clean) {
        Test-UrlPolicyEntry -Entry $item
    }
    if ($clean.Count -gt 1000) {
        throw ('Policy exceeds 1,000 entries: ' + $clean.Count)
    }

    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Recurse -Force
    }
    New-Item -Path $Path -Force | Out-Null

    $index = 1
    foreach ($item in $clean) {
        New-ItemProperty -Path $Path -Name ([string]$index) -Value $item -PropertyType String -Force | Out-Null
        $index++
    }
    return $clean.Count
}

function Set-DWordPolicy {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][int]$Value
    )
    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType DWord -Force | Out-Null
}

try {
    Test-TemplateRendered

    $DefaultDenyEnabled = ConvertTo-PolicyFlag $DefaultDenyEnabled 'defaultDeny'
    $ChromeCloudAPAuthEnabled = ConvertTo-PolicyFlag $ChromeCloudAPAuthEnabled 'chromeCloudAPAuthEnabled'
    $ChromeBrowserSigninDisabled = ConvertTo-PolicyFlag $ChromeBrowserSigninDisabled 'chromeBrowserSigninDisabled'
    $ChromeIncognitoDisabled = ConvertTo-PolicyFlag $ChromeIncognitoDisabled 'chromeIncognitoDisabled'
    $EdgeInPrivateDisabled = ConvertTo-PolicyFlag $EdgeInPrivateDisabled 'edgeInPrivateDisabled'
    $PersonalGoogleRestrictionsEnabled = ConvertTo-PolicyFlag $PersonalGoogleRestrictionsEnabled 'personalGoogleRestrictionsEnabled'

    if ($DownloadRestrictions -notin @(0, 1, 2, 3, 4)) {
        throw "downloadRestrictions must be 0, 1, 2, 3, or 4. Current value: $DownloadRestrictions"
    }

    Write-Log ('Starting {0}/{1}, profile {2}, version {3}' -f $OrganizationName, $TenantKey, $PolicyProfile, $PolicyVersion)

    New-Item -Path $ChromeRoot -Force | Out-Null
    New-Item -Path $EdgeRoot -Force | Out-Null

    foreach ($root in @($ChromeRoot, $EdgeRoot)) {
        New-ItemProperty -Path $root -Name 'HomepageLocation' -Value $HomePage -PropertyType String -Force | Out-Null
        Set-DWordPolicy -Path $root -Name 'HomepageIsNewTabPage' -Value 0
        Set-DWordPolicy -Path $root -Name 'ShowHomeButton' -Value 1
        Set-DWordPolicy -Path $root -Name 'RestoreOnStartup' -Value 4
        Set-DWordPolicy -Path $root -Name 'DeveloperToolsAvailability' -Value 1
        Set-DWordPolicy -Path $root -Name 'PrintingEnabled' -Value 1
        Set-DWordPolicy -Path $root -Name 'AlwaysOpenPdfExternally' -Value 0
        Set-DWordPolicy -Path $root -Name 'DownloadRestrictions' -Value $DownloadRestrictions
    }

    Set-DWordPolicy -Path $ChromeRoot -Name 'CloudAPAuthEnabled' -Value $ChromeCloudAPAuthEnabled
    Set-DWordPolicy -Path $ChromeRoot -Name 'BrowserSignin' -Value $(if ($ChromeBrowserSigninDisabled) { 0 } else { 1 })
    Set-DWordPolicy -Path $ChromeRoot -Name 'IncognitoModeAvailability' -Value $(if ($ChromeIncognitoDisabled) { 1 } else { 0 })
    Set-DWordPolicy -Path $EdgeRoot -Name 'InPrivateModeAvailability' -Value $(if ($EdgeInPrivateDisabled) { 1 } else { 0 })

    $chromeAllowlist = Get-CleanUniqueList -Items @($CommonAllowlist + $ChromeOnlyAllowlist)
    $edgeAllowlist = Get-CleanUniqueList -Items @($CommonAllowlist + $EdgeOnlyAllowlist)

    $baseBlocklist = @()
    if ($DefaultDenyEnabled -eq 1) {
        $baseBlocklist += '*'
    }
    if ($PersonalGoogleRestrictionsEnabled -eq 1) {
        $baseBlocklist += $GooglePersonalBlocklist
        Set-DWordPolicy -Path $ChromeRoot -Name 'SecondaryGoogleAccountSigninAllowed' -Value 0
    }

    $chromeCount = Set-PolicyList -Path (Join-Path $ChromeRoot 'URLAllowlist') -Items $chromeAllowlist
    $edgeCount = Set-PolicyList -Path (Join-Path $EdgeRoot 'URLAllowlist') -Items $edgeAllowlist
    [void](Set-PolicyList -Path (Join-Path $ChromeRoot 'URLBlocklist') -Items $baseBlocklist)
    [void](Set-PolicyList -Path (Join-Path $EdgeRoot 'URLBlocklist') -Items $baseBlocklist)

    # These origins control automatic downloads and popups. They do not bypass Defender or SmartScreen.
    foreach ($root in @($ChromeRoot, $EdgeRoot)) {
        [void](Set-PolicyList -Path (Join-Path $root 'AutomaticDownloadsAllowedForUrls') -Items $TrustedDownloadOrigins)
        [void](Set-PolicyList -Path (Join-Path $root 'PopupsAllowedForUrls') -Items $TrustedDownloadOrigins)
        [void](Set-PolicyList -Path (Join-Path $root 'CookiesAllowedForUrls') -Items $OracleCookieSites)
    }

    New-Item -Path $Marker -Force | Out-Null
    New-ItemProperty -Path $Marker -Name 'OrganizationName' -Value $OrganizationName -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $Marker -Name 'TenantKey' -Value $TenantKey -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $Marker -Name 'TenantDomain' -Value $TenantDomain -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $Marker -Name 'PolicyProfile' -Value $PolicyProfile -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $Marker -Name 'PolicyVersion' -Value $PolicyVersion -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $Marker -Name 'LastAppliedUtc' -Value ((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')) -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $Marker -Name 'ChromeAllowlistCount' -Value $chromeCount -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path $Marker -Name 'EdgeAllowlistCount' -Value $edgeCount -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path $Marker -Name 'DownloadRestrictions' -Value $DownloadRestrictions -PropertyType DWord -Force | Out-Null

    Write-Log ('Completed successfully. Chrome allowlist={0}; Edge allowlist={1}; DownloadRestrictions={2}' -f $chromeCount, $edgeCount, $DownloadRestrictions)
    Write-Output ('{0} browser-control policy {1} installed successfully.' -f $OrganizationName, $PolicyVersion)
    exit 0
}
catch {
    Write-Log ('ERROR: ' + $_.Exception.Message)
    Write-Log ('ERROR LINE: ' + $_.InvocationInfo.ScriptLineNumber)
    Write-Error $_.Exception.Message
    exit 1
}
