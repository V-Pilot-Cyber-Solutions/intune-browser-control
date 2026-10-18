param([string]$ScriptPath)
$ErrorActionPreference = 'Stop'
$RepositoryRoot = Split-Path -Path $PSScriptRoot -Parent
if ([string]::IsNullOrWhiteSpace($ScriptPath)) { $ScriptPath = Join-Path $RepositoryRoot 'output\DigiTrans-Browser-Control-Developer.ps1' }
elseif (-not [IO.Path]::IsPathRooted($ScriptPath)) { $ScriptPath = Join-Path $RepositoryRoot $ScriptPath }
if (-not (Test-Path -LiteralPath $ScriptPath)) { throw "Generated script not found: $ScriptPath. Run Build-BrowserControl.ps1 first." }
$Content = Get-Content -LiteralPath $ScriptPath -Raw
# Detect actual HTML anchor markup only. Do not search globally for words such as
# href=, target=, or class= because Test-UrlPolicyEntry intentionally contains
# those words as validation patterns.
if ($Content -match '(?i)<a\s+[^>]*href\s*=' -or $Content -match '(?i)&lt;a\s+[^&]*href') {
    throw 'Actual HTML anchor markup was found in the generated script.'
}
if ($Content -match "IncognitoModeAvailability.+Value 0") { throw 'Incognito enabled' }
if ($Content -match "InPrivateModeAvailability.+Value 0") { throw 'InPrivate enabled' }
if ($Content -notmatch "CloudAPAuthEnabled.+Value 1") { throw 'CloudAP missing' }
if ($Content -match "(?m)^\s*'google\.com'\s*$|(?m)^\s*'\[\*\.\]google\.com'\s*$") { throw 'Broad Google allow rule' }
$Tokens=$null; $Errors=$null
[void][Management.Automation.Language.Parser]::ParseFile((Resolve-Path -LiteralPath $ScriptPath).Path,[ref]$Tokens,[ref]$Errors)
if ($Errors.Count) { $Errors | Format-List; throw 'Syntax validation failed' }
Write-Output "Validation passed: $((Resolve-Path -LiteralPath $ScriptPath).Path)"
