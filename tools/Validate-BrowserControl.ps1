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

# Block actual HTML markup accidentally copied into policy data or source.
if (
    $Content -match '(?i)<a\s+[^>]*href\s*=' -or
    $Content -match '(?i)&lt;a\s+[^&]*href'
) {
    throw 'Actual or encoded HTML anchor markup was found.'
}

if ($Content -match '\{\{[A-Z0-9_]+\}\}') {
    $RemainingPlaceholders = @(
        [regex]::Matches($Content, '\{\{[A-Z0-9_]+\}\}') |
            ForEach-Object { $_.Value } |
            Sort-Object -Unique
    )
    throw "An unresolved template placeholder was detected: $($RemainingPlaceholders -join ', ')"
}

# Validate the rendered tenant-control values. The generated template applies
# these variables through Set-DWordPolicy, so validation must inspect the
# assignments rather than expect a literal '-Value 1' beside each policy name.
$CloudAPValue = Assert-ResolvedIntegerVariable `
    -VariableName 'ChromeCloudAPAuthEnabled' `
    -AllowedValues @(1) `
    -ErrorMessage 'CloudAP authentication is missing or disabled.'

$ChromeIncognitoDisabled = Assert-ResolvedIntegerVariable `
    -VariableName 'ChromeIncognitoDisabled' `
    -AllowedValues @(1) `
    -ErrorMessage 'Chrome Incognito is enabled or its control is missing.'

$EdgeInPrivateDisabled = Assert-ResolvedIntegerVariable `
    -VariableName 'EdgeInPrivateDisabled' `
    -AllowedValues @(1) `
    -ErrorMessage 'Edge InPrivate is enabled or its control is missing.'

$DownloadRestrictions = Assert-ResolvedIntegerVariable `
    -VariableName 'DownloadRestrictions' `
    -AllowedValues @(0, 1, 2, 3, 4) `
    -ErrorMessage 'DownloadRestrictions is missing or invalid.'

# Confirm that the template actually consumes the rendered variables.
$RequiredPolicyApplications = @(
    @{ Pattern = 'Set-DWordPolicy\s+-Path\s+\$ChromeRoot\s+-Name\s+''CloudAPAuthEnabled''\s+-Value\s+\$ChromeCloudAPAuthEnabled'; Message = 'CloudAPAuthEnabled is not applied to the Chrome policy root.' },
    @{ Pattern = 'Set-DWordPolicy\s+-Path\s+\$ChromeRoot\s+-Name\s+''IncognitoModeAvailability'''; Message = 'Chrome Incognito policy application is missing.' },
    @{ Pattern = 'Set-DWordPolicy\s+-Path\s+\$EdgeRoot\s+-Name\s+''InPrivateModeAvailability'''; Message = 'Edge InPrivate policy application is missing.' },
    @{ Pattern = 'Set-DWordPolicy\s+-Path\s+\$root\s+-Name\s+''DownloadRestrictions''\s+-Value\s+\$DownloadRestrictions'; Message = 'DownloadRestrictions is not applied to both browser roots.' }
)

foreach ($Check in $RequiredPolicyApplications) {
    if ($Content -notmatch $Check.Pattern) {
        throw $Check.Message
    }
}

if (
    $Content -match "(?m)^\s*'google\.com'\s*$" -or
    $Content -match "(?m)^\s*'\[\*\.\]google\.com'\s*$"
) {
    throw 'A broad Google allow rule was detected.'
}

$ArrayVariableNames = @(
    'CommonAllowlist'
    'ChromeOnlyAllowlist'
    'EdgeOnlyAllowlist'
    'GooglePersonalBlocklist'
    'TrustedDownloadOrigins'
    'OracleCookieSites'
)

foreach ($ArrayVariableName in $ArrayVariableNames) {
    $EscapedVariableName = :Escape($ArrayVariableName)

    $ArrayPattern = (
        '(?ms)^\s*\${0}\s*=\s*@\((.*?)^\s*\)' -f
        $EscapedVariableName
    )

    $ArrayMatch = :Match(
        $Content,
        $ArrayPattern
    )

    if (-not $ArrayMatch.Success) {
        throw (
            'Generated array was not found: ${0}' -f
            $ArrayVariableName
        )
    }

    [string[]]$GeneratedEntries = @(
        :Matches(
            $ArrayMatch.Groups[1].Value,
            "(?m)^\s*'([^']*)'\s*$"
        ) |
            ForEach-Object {
                $_.Groups[1].Value
            }
    )

    foreach ($GeneratedEntry in $GeneratedEntries) {
        if ($GeneratedEntry -match '\s') {
            throw (
                'Multiple policy values appear to be combined in ${0}: {1}' -f
                $ArrayVariableName,
                $GeneratedEntry
            )
        }
    }
}

# Detect a configuration list accidentally rendered as one whitespace-separated string.
$QuotedPolicyEntries = [regex]::Matches($Content, "(?m)^\s*'([^']+)'\s*$")
foreach ($EntryMatch in $QuotedPolicyEntries) {
    $Entry = $EntryMatch.Groups[1].Value
    if ($Entry -match '\s') {
        throw "Whitespace was detected inside a generated policy entry: $Entry"
    }
    if ($Entry.StartsWith('.')) {
        throw "Leading-dot domain syntax was detected in a generated policy entry: $Entry"
    }
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
