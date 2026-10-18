param(
    [Parameter(Mandatory = $true)]
    [string]$ScriptPath
)

$ErrorActionPreference = 'Stop'

$RepositoryRoot = Split-Path `
    -Path $PSScriptRoot `
    -Parent

if (-not [System.IO.Path]::IsPathRooted($ScriptPath)) {
    $ScriptPath = Join-Path `
        -Path $RepositoryRoot `
        -ChildPath $ScriptPath
}

if (-not (Test-Path -LiteralPath $ScriptPath)) {
    throw "Generated policy script not found: $ScriptPath"
}

$Content = Get-Content `
    -LiteralPath $ScriptPath `
    -Raw

if (
    $Content -match '(?i)<a\s+[^>]*href\s*=' -or
    $Content -match '(?i)&lt;a\s+[^&]*href'
) {
    throw 'Actual HTML anchor markup was found.'
}

if ($Content -match "IncognitoModeAvailability.+Value 0") {
    throw 'Chrome Incognito is enabled.'
}

if ($Content -match "InPrivateModeAvailability.+Value 0") {
    throw 'Edge InPrivate is enabled.'
}

if ($Content -notmatch "CloudAPAuthEnabled.+Value 1") {
    throw 'CloudAP authentication is missing or disabled.'
}

if (
    $Content -match "(?m)^\s*'google\.com'\s*$" -or
    $Content -match "(?m)^\s*'\[\*\.\]google\.com'\s*$"
) {
    throw 'A broad Google allow rule was detected.'
}

if ($Content -match '\{\{[A-Z0-9_]+\}\}') {
    throw 'An unresolved template placeholder was detected.'
}

$Tokens = $null
$ParseErrors = $null

[void][System.Management.Automation.Language.Parser]::ParseFile(
    (Resolve-Path -LiteralPath $ScriptPath).Path,
    [ref]$Tokens,
    [ref]$ParseErrors
)

if ($ParseErrors.Count -gt 0) {
    $ParseErrors | Format-List
    throw 'PowerShell syntax validation failed.'
}

Write-Output (
    "Validation passed: {0}" -f
    (Resolve-Path -LiteralPath $ScriptPath).Path
)
