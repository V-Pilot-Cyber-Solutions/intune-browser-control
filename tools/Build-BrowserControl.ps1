param([string]$Version='DEV-7.0',[string]$OutputPath='./output/DigiTrans-Browser-Control-Developer.ps1')
$ErrorActionPreference='Stop'
function Convert-List([string]$Path){
 if(!(Test-Path $Path)){throw "Missing $Path"}
 $v=Get-Content $Path|ForEach-Object{$_.Trim()}|Where-Object{$_ -and !$_.StartsWith('#')}|Sort-Object -Unique
 foreach($e in $v){if($e -match '<|>|href=|target=|class=|\s'){throw "Invalid entry in $Path : $e"}}
 return (($v|ForEach-Object{"    '$($_.Replace("'","''"))'"}) -join [Environment]::NewLine)
}
$t=Get-Content './src/Browser-Control-Template.ps1' -Raw
$m=@{
 '{{POLICY_VERSION}}'=$Version
 '{{COMMON_ALLOWLIST}}'=Convert-List './config/common-allowlist.txt'
 '{{CHROME_ONLY_ALLOWLIST}}'=Convert-List './config/chrome-only-allowlist.txt'
 '{{EDGE_ONLY_ALLOWLIST}}'=Convert-List './config/edge-only-allowlist.txt'
 '{{GOOGLE_PERSONAL_BLOCKLIST}}'=Convert-List './config/google-personal-blocklist.txt'
 '{{TRUSTED_DOWNLOAD_ORIGINS}}'=Convert-List './config/trusted-download-origins.txt'
 '{{ORACLE_COOKIE_SITES}}'=Convert-List './config/oracle-cookie-sites.txt'
}
foreach($k in $m.Keys){if(!$t.Contains($k)){throw "Missing placeholder $k"};$t=$t.Replace($k,$m[$k])}
if($t -match '\{\{'){throw 'Unresolved placeholder'}
New-Item (Split-Path $OutputPath) -ItemType Directory -Force|Out-Null
[IO.File]::WriteAllText($OutputPath,$t,[Text.UTF8Encoding]::new($true))
Write-Output $OutputPath
