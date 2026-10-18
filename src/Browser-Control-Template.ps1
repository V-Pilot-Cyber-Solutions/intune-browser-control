# DigiTrans - Chrome and Edge Browser Control
# GitHub-managed template. Preserve verified DEV-7.0 policy logic below.
$ErrorActionPreference = 'Stop'
$PolicyProfile = 'Developer'
$PolicyVersion = '{{POLICY_VERSION}}'
$HomePage = 'https://www.google.com/'
$LogFolder = 'C:\ProgramData\DigiTrans\Logs'
$LogFile = Join-Path $LogFolder ('Browser-Control-' + $PolicyProfile + '.log')
New-Item -Path $LogFolder -ItemType Directory -Force | Out-Null

function Write-Log { param([Parameter(Mandatory)][string]$Message); Add-Content -LiteralPath $LogFile -Value ('{0} - {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),$Message) -Encoding UTF8 }
function Get-CleanUniqueList { param([Parameter(Mandatory)][string[]]$Items); @($Items | ForEach-Object { if ($null -ne $_) {$_.Trim()} } | Where-Object {$_} | Sort-Object -Unique) }
function Test-UrlPolicyEntry {
 param([Parameter(Mandatory)][string]$Entry)
 if ([string]::IsNullOrWhiteSpace($Entry)) { throw 'Empty URL policy entry detected.' }
 if ($Entry -match '<|>|&lt;|&gt;|&quot;|href=|target=|rel=|title=|class=|</?a\b|<br') { throw ('HTML detected: '+$Entry) }
 if ($Entry -match '\s') { throw ('Whitespace detected: '+$Entry) }
 if ($Entry -match ',https?://') { throw ('Multiple origins in one entry: '+$Entry) }
}
function Set-PolicyList {
 param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string[]]$Items)
 $Clean=Get-CleanUniqueList $Items; foreach($Item in $Clean){Test-UrlPolicyEntry $Item}
 if($Clean.Count -gt 1000){throw ('Policy exceeds 1,000 entries: '+$Clean.Count)}
 if(Test-Path -LiteralPath $Path){Remove-Item -LiteralPath $Path -Recurse -Force}
 New-Item -Path $Path -Force|Out-Null; $Index=1
 foreach($Item in $Clean){New-ItemProperty -Path $Path -Name ([string]$Index) -Value $Item -PropertyType String -Force|Out-Null;$Index++}
 return $Clean.Count
}

$CommonAllowlist = @(
{{COMMON_ALLOWLIST}}
)
$ChromeOnly = @(
{{CHROME_ONLY_ALLOWLIST}}
)
$EdgeOnly = @(
{{EDGE_ONLY_ALLOWLIST}}
)
$PersonalGoogleBlocklist = @(
{{GOOGLE_PERSONAL_BLOCKLIST}}
)
# Default-deny URL controls.
# The wildcard blocks every URL that isn't explicitly allowed.
# URLAllowlist entries take precedence over URLBlocklist entries.

$ChromeBlocklist = Get-CleanUniqueList -Items @(
    '*'
    $PersonalGoogleBlocklist
)

$EdgeBlocklist = Get-CleanUniqueList -Items @(
    '*'
    $PersonalGoogleBlocklist
)

if ($ChromeBlocklist -notcontains '*') {
    throw 'Chrome zero-trust URLBlocklist wildcard is missing.'
}

if ($EdgeBlocklist -notcontains '*') {
    throw 'Edge zero-trust URLBlocklist wildcard is missing.'
}

$TrustedBusinessOrigins = @(
{{TRUSTED_DOWNLOAD_ORIGINS}}
)
$OracleCookieSites = @(
{{ORACLE_COOKIE_SITES}}
)
$ChromeAllowlist=Get-CleanUniqueList @($CommonAllowlist+$ChromeOnly)
$EdgeAllowlist=Get-CleanUniqueList @($CommonAllowlist+$EdgeOnly)
$ChromeBlocklist=Get-CleanUniqueList @('*'+$PersonalGoogleBlocklist)
$EdgeBlocklist=Get-CleanUniqueList @('*'+$PersonalGoogleBlocklist)
$ChromeRoot='HKLM:\SOFTWARE\Policies\Google\Chrome'
$EdgeRoot='HKLM:\SOFTWARE\Policies\Microsoft\Edge'

try {
 Write-Log ('Starting '+$PolicyVersion)
 foreach($e in @($CommonAllowlist+$ChromeOnly+$EdgeOnly+$PersonalGoogleBlocklist+$TrustedBusinessOrigins+$OracleCookieSites)){Test-UrlPolicyEntry $e}
 New-Item -Path $ChromeRoot -Force|Out-Null; New-Item -Path $EdgeRoot -Force|Out-Null
 foreach($Root in @($ChromeRoot,$EdgeRoot)){
  New-ItemProperty -Path $Root -Name HomepageLocation -Value $HomePage -PropertyType String -Force|Out-Null
  New-ItemProperty -Path $Root -Name HomepageIsNewTabPage -Value 0 -PropertyType DWord -Force|Out-Null
  New-ItemProperty -Path $Root -Name ShowHomeButton -Value 1 -PropertyType DWord -Force|Out-Null
  New-ItemProperty -Path $Root -Name RestoreOnStartup -Value 4 -PropertyType DWord -Force|Out-Null
  New-ItemProperty -Path $Root -Name DeveloperToolsAvailability -Value 1 -PropertyType DWord -Force|Out-Null
  New-ItemProperty -Path $Root -Name PrintingEnabled -Value 1 -PropertyType DWord -Force|Out-Null
  New-ItemProperty -Path $Root -Name AlwaysOpenPdfExternally -Value 0 -PropertyType DWord -Force|Out-Null
  New-ItemProperty -Path $Root -Name DownloadRestrictions -Value 1 -PropertyType DWord -Force|Out-Null
 }
 New-ItemProperty -Path $ChromeRoot -Name CloudAPAuthEnabled -Value 1 -PropertyType DWord -Force|Out-Null
 New-ItemProperty -Path $ChromeRoot -Name BrowserSignin -Value 0 -PropertyType DWord -Force|Out-Null
 New-ItemProperty -Path $ChromeRoot -Name SecondaryGoogleAccountSigninAllowed -Value 0 -PropertyType DWord -Force|Out-Null
 New-ItemProperty -Path $ChromeRoot -Name IncognitoModeAvailability -Value 1 -PropertyType DWord -Force|Out-Null
 New-ItemProperty -Path $EdgeRoot -Name InPrivateModeAvailability -Value 1 -PropertyType DWord -Force|Out-Null
 [void](Set-PolicyList (Join-Path $ChromeRoot 'ExtensionInstallBlocklist') @('*'))
 [void](Set-PolicyList (Join-Path $ChromeRoot 'RestoreOnStartupURLs') @($HomePage))
 [void](Set-PolicyList (Join-Path $EdgeRoot 'RestoreOnStartupURLs') @($HomePage))
 $ChromeCount=Set-PolicyList (Join-Path $ChromeRoot 'URLAllowlist') $ChromeAllowlist
 [void](Set-PolicyList (Join-Path $ChromeRoot 'URLBlocklist') $ChromeBlocklist)
 $EdgeCount=Set-PolicyList (Join-Path $EdgeRoot 'URLAllowlist') $EdgeAllowlist
 [void](Set-PolicyList (Join-Path $EdgeRoot 'URLBlocklist') $EdgeBlocklist)
 [void](Set-PolicyList (Join-Path $ChromeRoot 'AutomaticDownloadsAllowedForUrls') $TrustedBusinessOrigins)
 [void](Set-PolicyList (Join-Path $EdgeRoot 'AutomaticDownloadsAllowedForUrls') $TrustedBusinessOrigins)
 [void](Set-PolicyList (Join-Path $ChromeRoot 'PopupsAllowedForUrls') $TrustedBusinessOrigins)
 [void](Set-PolicyList (Join-Path $EdgeRoot 'PopupsAllowedForUrls') $TrustedBusinessOrigins)
 [void](Set-PolicyList (Join-Path $ChromeRoot 'CookiesAllowedForUrls') $OracleCookieSites)
 [void](Set-PolicyList (Join-Path $EdgeRoot 'CookiesAllowedForUrls') $OracleCookieSites)
 $Marker='HKLM:\SOFTWARE\DigiTrans\BrowserControl';New-Item -Path $Marker -Force|Out-Null
 New-ItemProperty -Path $Marker -Name PolicyProfile -Value $PolicyProfile -PropertyType String -Force|Out-Null
 New-ItemProperty -Path $Marker -Name PolicyVersion -Value $PolicyVersion -PropertyType String -Force|Out-Null
 New-ItemProperty -Path $Marker -Name LastAppliedUtc -Value ((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')) -PropertyType String -Force|Out-Null
 New-ItemProperty -Path $Marker -Name ChromeAllowlistCount -Value $ChromeCount -PropertyType DWord -Force|Out-Null
 New-ItemProperty -Path $Marker -Name EdgeAllowlistCount -Value $EdgeCount -PropertyType DWord -Force|Out-Null
 Write-Log ('Completed. Chrome={0}; Edge={1}' -f $ChromeCount,$EdgeCount); exit 0
} catch { Write-Log ('ERROR: '+$_.Exception.Message); Write-Error $_.Exception.Message; exit 1 }
