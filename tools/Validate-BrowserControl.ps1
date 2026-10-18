param(
    [Parameter(Mandatory = $true)]
    [string]$ScriptPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepositoryRoot = Split-Path -Path $PSScriptRoot -Parent
if (-not [System.IO.Path]::IsPathRooted($ScriptPath)) {
    $ScriptPath = Join-Path -Path $RepositoryRoot -ChildPath $ScriptPath
}
if (-not (Test-Path -LiteralPath $ScriptPath)) {
    throw "Generated policy script not found: $ScriptPath"
}

$ResolvedScriptPath = (Resolve-Path -LiteralPath $ScriptPath).Path
$Content = Get-Content -LiteralPath $ResolvedScriptPath -Raw -Encoding UTF8

function Assert-ResolvedIntegerVariable {
    param(
        [Parameter(Mandatory = $true)][string]$VariableName,
        [Parameter(Mandatory = $true)][int[]]$AllowedValues,
        [Parameter(Mandatory = $true)][string]$ErrorMessage
    )

    $EscapedName = [regex]::Escape($VariableName)
    $Pattern = '(?m)^\s*\$' + $EscapedName + '\s*=\s*\[int\]\s*[''"]?([0-9]+)[''"]?\s*$'
    $Match = [regex]::Match($Content, $Pattern)

    if (-not $Match.Success) {
        throw "$ErrorMessage Expected a rendered integer assignment for `$$VariableName."
    }

    $Value = [int]$Match.Groups[1].Value
    if ($Value -notin $AllowedValues) {
        throw "$ErrorMessage Current value: $Value. Allowed values: $($AllowedValues -join ', ')."
    }

    return $Value
}

if ($Content -match '(?i)<a\s+[^>]*href\s*=' -or $Content -match '(?i)&lt;a\s+[^&]*href') {
    throw 'Actual or encoded HTML anchor markup was found.'
}

[System.Text.RegularExpressions.Match[]]$RemainingPlaceholderMatches = @(
    [regex]::Matches($Content, '\{\{[A-Z0-9_]+\}\}')
)
if ($RemainingPlaceholderMatches.Count -gt 0) {
    [string[]]$RemainingPlaceholders = @(
        $RemainingPlaceholderMatches | ForEach-Object { $_.Value } | Sort-Object -Unique
    )
    throw "Unresolved template placeholders: $($RemainingPlaceholders -join ', ')"
}

$CloudAPValue = Assert-ResolvedIntegerVariable -VariableName 'ChromeCloudAPAuthEnabled' -AllowedValues @(1) -ErrorMessage 'CloudAP authentication is missing or disabled.'
$ChromeIncognitoDisabled = Assert-ResolvedIntegerVariable -VariableName 'ChromeIncognitoDisabled' -AllowedValues @(1) -ErrorMessage 'Chrome Incognito is enabled or missing.'
$EdgeInPrivateDisabled = Assert-ResolvedIntegerVariable -VariableName 'EdgeInPrivateDisabled' -AllowedValues @(1) -ErrorMessage 'Edge InPrivate is enabled or missing.'
$DownloadRestrictions = Assert-ResolvedIntegerVariable -VariableName 'DownloadRestrictions' -AllowedValues @(0, 1, 2, 3, 4) -ErrorMessage 'DownloadRestrictions is missing or invalid.'

$RequiredPolicyApplications = @(
    @{ Pattern = 'Set-DWordPolicy\s+-Path\s+\$ChromeRoot\s+-Name\s+''CloudAPAuthEnabled''\s+-Value\s+\$ChromeCloudAPAuthEnabled'; Message = 'CloudAPAuthEnabled is not applied to Chrome.' },
    @{ Pattern = 'Set-DWordPolicy\s+-Path\s+\$ChromeRoot\s+-Name\s+''IncognitoModeAvailability'''; Message = 'Chrome Incognito policy application is missing.' },
    @{ Pattern = 'Set-DWordPolicy\s+-Path\s+\$EdgeRoot\s+-Name\s+''InPrivateModeAvailability'''; Message = 'Edge InPrivate policy application is missing.' },
    @{ Pattern = 'Set-DWordPolicy\s+-Path\s+\$Root\s+-Name\s+''DownloadRestrictions''\s+-Value\s+\$DownloadRestrictions'; Message = 'DownloadRestrictions is not applied to both browsers.' }
)
foreach ($Check in $RequiredPolicyApplications) {
    if ($Content -notmatch $Check.Pattern) {
        throw $Check.Message
    }
}

if ($Content -match "(?m)^\s*'google\.com'\s*$" -or $Content -match "(?m)^\s*'\[\*\.\]google\.com'\s*$") {
    throw 'A broad Google allow rule was detected.'
}

$ArrayVariableNames = @(
    'CommonAllowlist',
    'ChromeOnlyAllowlist',
    'EdgeOnlyAllowlist',
    'GooglePersonalBlocklist',
    'TrustedDownloadOrigins',
    'OracleCookieSites'
)

foreach ($ArrayVariableName in $ArrayVariableNames) {
    $EscapedVariableName = [regex]::Escape($ArrayVariableName)
    $ArrayPattern = '(?ms)^\s*\$' + $EscapedVariableName + '\s*=\s*@\((.*?)^\s*\)'
    $ArrayMatch = [regex]::Match($Content, $ArrayPattern)

    if (-not $ArrayMatch.Success) {
        throw ('Generated array was not found: ${0}' -f $ArrayVariableName)
    }

    [System.Text.RegularExpressions.Match[]]$EntryMatches = @(
        [regex]::Matches($ArrayMatch.Groups[1].Value, "(?m)^\s*'([^']*)'\s*$")
    )
    if ($EntryMatches.Count -eq 0) {
        throw ('Generated array contains no entries: ${0}' -f $ArrayVariableName)
    }

    foreach ($EntryMatch in $EntryMatches) {
        $Entry = $EntryMatch.Groups[1].Value
        if ($Entry -match '\s') {
            throw ('Multiple policy values appear combined in ${0}: {1}' -f $ArrayVariableName, $Entry)
        }
        if ($Entry.StartsWith('.')) {
            throw ('Leading-dot entry found in ${0}: {1}' -f $ArrayVariableName, $Entry)
        }
    }
}

if ($Content -match 'return\s+,\s*\$CleanItems') {
    throw 'Get-CleanUniqueList uses a unary comma and can create a nested policy array.'
}
if ($Content -notmatch 'return\s+\$CleanItems') {
    throw 'Get-CleanUniqueList does not return the flat CleanItems array.'
}

$Tokens = $null
$ParseErrors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile(
    $ResolvedScriptPath,
    [ref]$Tokens,
    [ref]$ParseErrors
)

if ($ParseErrors.Count -gt 0) {
    $ParseErrors | Format-List | Out-String | Write-Error
    throw 'PowerShell syntax validation failed.'
}

Write-Output "Validation passed: $ResolvedScriptPath"
Write-Output "CloudAP=$CloudAPValue; ChromeIncognitoDisabled=$ChromeIncognitoDisabled; EdgeInPrivateDisabled=$EdgeInPrivateDisabled; DownloadRestrictions=$DownloadRestrictions"
