param(
    [string]$Version = 'DEV-7.1',
    [string]$OutputPath
)
$ErrorActionPreference = 'Stop'
$RepositoryRoot = Split-Path -Path $PSScriptRoot -Parent
$ConfigDirectory = Join-Path $RepositoryRoot 'config'
$TemplatePath = Join-Path $RepositoryRoot 'src\Browser-Control-Template.ps1'
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $RepositoryRoot 'output\DigiTrans-Browser-Control-Developer.ps1'
} elseif (-not [IO.Path]::IsPathRooted($OutputPath)) {
    $OutputPath = Join-Path $RepositoryRoot $OutputPath
}
function Convert-PolicyList([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { throw "Required configuration file not found: $Path" }
    $Entries = Get-Content -LiteralPath $Path | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') } | Sort-Object -Unique
    foreach ($Entry in $Entries) { if ($Entry -match '<|>|href=|target=|class=|\s') { throw "Invalid entry in $Path : $Entry" } }
    return (($Entries | ForEach-Object { "    '$($_.Replace("'", "''"))'" }) -join [Environment]::NewLine)
}
if (-not (Test-Path -LiteralPath $TemplatePath)) { throw "PowerShell template not found: $TemplatePath" }
$Template = Get-Content -LiteralPath $TemplatePath -Raw
$ReplacementMap = @{
    '{{POLICY_VERSION}}' = $Version
    '{{COMMON_ALLOWLIST}}' = Convert-PolicyList (Join-Path $ConfigDirectory 'common-allowlist.txt')
    '{{CHROME_ONLY_ALLOWLIST}}' = Convert-PolicyList (Join-Path $ConfigDirectory 'chrome-only-allowlist.txt')
    '{{EDGE_ONLY_ALLOWLIST}}' = Convert-PolicyList (Join-Path $ConfigDirectory 'edge-only-allowlist.txt')
    '{{GOOGLE_PERSONAL_BLOCKLIST}}' = Convert-PolicyList (Join-Path $ConfigDirectory 'google-personal-blocklist.txt')
    '{{TRUSTED_DOWNLOAD_ORIGINS}}' = Convert-PolicyList (Join-Path $ConfigDirectory 'trusted-download-origins.txt')
    '{{ORACLE_COOKIE_SITES}}' = Convert-PolicyList (Join-Path $ConfigDirectory 'oracle-cookie-sites.txt')
}
foreach ($Key in $ReplacementMap.Keys) { if (-not $Template.Contains($Key)) { throw "Missing placeholder: $Key" }; $Template = $Template.Replace($Key, $ReplacementMap[$Key]) }
if ($Template -match '\{\{[A-Z0-9_]+\}\}') { throw 'An unresolved placeholder remains.' }
$OutputDirectory = Split-Path -Path $OutputPath -Parent
New-Item -Path $OutputDirectory -ItemType Directory -Force | Out-Null
$OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).Path
$OutputPath = Join-Path $OutputDirectory (Split-Path -Path $OutputPath -Leaf)
[IO.File]::WriteAllText($OutputPath, $Template, [Text.UTF8Encoding]::new($true))
Write-Output "Created consolidated script: $OutputPath"
