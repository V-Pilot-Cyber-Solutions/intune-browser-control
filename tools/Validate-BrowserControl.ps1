param([string]$ScriptPath='./output/DigiTrans-Browser-Control-Developer.ps1')
$ErrorActionPreference='Stop';$c=Get-Content $ScriptPath -Raw
foreach($bad in @('<a ','href=','target=','class=')){if($c.IndexOf($bad,[StringComparison]::OrdinalIgnoreCase)-ge 0){throw "HTML found: $bad"}}
if($c -match "IncognitoModeAvailability.+Value 0"){throw 'Incognito enabled'}
if($c -match "InPrivateModeAvailability.+Value 0"){throw 'InPrivate enabled'}
if($c -notmatch "CloudAPAuthEnabled.+Value 1"){throw 'CloudAP missing'}
if($c -match "(?m)^\s*'google\.com'\s*$|(?m)^\s*'\[\*\.\]google\.com'\s*$"){throw 'Broad Google allow rule'}
$tok=$null;$err=$null;[void][Management.Automation.Language.Parser]::ParseFile((Resolve-Path $ScriptPath),[ref]$tok,[ref]$err)
if($err.Count){$err|Format-List;throw 'Syntax validation failed'}
'Validation passed'
