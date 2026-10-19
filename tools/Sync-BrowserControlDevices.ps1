param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-z0-9-]+$')]
    [string]$TenantKey,

    [Parameter(Mandatory = $false)]
    [ValidatePattern('^https://graph\.microsoft\.com/(v1\.0|beta)$')]
    [string]$GraphBaseUri = 'https://graph.microsoft.com/v1.0'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepositoryRoot = Split-Path -Path $PSScriptRoot -Parent
$TenantJsonPath = Join-Path -Path $RepositoryRoot -ChildPath "tenants\$TenantKey\tenant.json"

if (-not (Test-Path -LiteralPath $TenantJsonPath)) {
    throw "Tenant metadata was not found: $TenantJsonPath"
}

$Tenant = Get-Content -LiteralPath $TenantJsonPath -Raw -Encoding UTF8 |
    ConvertFrom-Json -ErrorAction Stop

if ([string]$Tenant.tenantKey -ne $TenantKey) {
    throw "Tenant key mismatch. Requested=$TenantKey; tenant.json=$($Tenant.tenantKey)"
}

if ($null -eq $Tenant.PSObject.Properties['deploymentSync']) {
    Write-Output 'Device sync is not configured. Skipping.'
    exit 0
}

$SyncConfiguration = $Tenant.deploymentSync
if (
    $null -eq $SyncConfiguration.PSObject.Properties['enabled'] -or
    -not [bool]$SyncConfiguration.enabled
) {
    Write-Output 'Device sync is disabled for this tenant. Skipping.'
    exit 0
}

[string[]]$GroupIds = @(
    $SyncConfiguration.groupIds |
        ForEach-Object { [string]$_ } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Sort-Object -Unique
)

if ($GroupIds.Count -eq 0) {
    throw 'deploymentSync.enabled is true, but no groupIds are configured.'
}

[int]$MaximumDevices = 100
if ($null -ne $SyncConfiguration.PSObject.Properties['maximumDevices']) {
    $MaximumDevices = [int]$SyncConfiguration.maximumDevices
}
if ($MaximumDevices -lt 1 -or $MaximumDevices -gt 5000) {
    throw "deploymentSync.maximumDevices must be between 1 and 5000. Current value: $MaximumDevices"
}

[int]$DelayMilliseconds = 250
if ($null -ne $SyncConfiguration.PSObject.Properties['delayMilliseconds']) {
    $DelayMilliseconds = [int]$SyncConfiguration.delayMilliseconds
}
if ($DelayMilliseconds -lt 0 -or $DelayMilliseconds -gt 10000) {
    throw "deploymentSync.delayMilliseconds must be between 0 and 10000. Current value: $DelayMilliseconds"
}

[bool]$FailWhenSyncFails = $false
if ($null -ne $SyncConfiguration.PSObject.Properties['failDeploymentWhenSyncFails']) {
    $FailWhenSyncFails = [bool]$SyncConfiguration.failDeploymentWhenSyncFails
}

[string[]]$AllowedOperatingSystems = @('Windows')
if ($null -ne $SyncConfiguration.PSObject.Properties['operatingSystems']) {
    $AllowedOperatingSystems = @(
        $SyncConfiguration.operatingSystems |
            ForEach-Object { [string]$_ } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
}

# Obtain a Microsoft Graph token from the existing azure/login session.
$GraphToken = az account get-access-token `
    --resource-type ms-graph `
    --query accessToken `
    --output tsv

if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($GraphToken)) {
    throw 'Microsoft Graph access token was not returned. Ensure azure/login ran before this script.'
}

$GraphHeaders = @{
    Authorization = "Bearer $GraphToken"
    Accept        = 'application/json'
}

function Invoke-GraphRequest {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('GET', 'POST')]
        [string]$Method,

        [Parameter(Mandatory = $true)]
        [string]$Uri
    )

    if ($Uri -notmatch '^https://graph\.microsoft\.com/(v1\.0|beta)/') {
        throw "Refusing non-Microsoft Graph URI: $Uri"
    }

    $MaximumAttempts = 5
    for ($Attempt = 1; $Attempt -le $MaximumAttempts; $Attempt++) {
        try {
            if ($Method -eq 'GET') {
                return Invoke-RestMethod -Method Get -Uri $Uri -Headers $GraphHeaders
            }

            Invoke-RestMethod -Method Post -Uri $Uri -Headers $GraphHeaders | Out-Null
            return
        }
        catch {
            $StatusCode = $null
            if ($null -ne $_.Exception.Response) {
                $StatusCode = [int]$_.Exception.Response.StatusCode
            }

            $IsRetryable = $StatusCode -in @(408, 429, 500, 502, 503, 504)
            if ($Attempt -ge $MaximumAttempts -or -not $IsRetryable) {
                throw
            }

            $DelaySeconds = [math]::Pow(2, $Attempt)
            Write-Warning (
                ('Graph request failed. Attempt={0}/{1}; Status={2}; Delay={3}s; URI={4}; Error={5}') -f
                $Attempt,
                $MaximumAttempts,
                $StatusCode,
                $DelaySeconds,
                $Uri,
                $_.Exception.Message
            )
            Start-Sleep -Seconds $DelaySeconds
        }
    }
}

function Get-GraphCollection {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uri
    )

    [object[]]$Results = @()
    $NextUri = $Uri

    while (-not [string]::IsNullOrWhiteSpace($NextUri)) {
        $Response = Invoke-GraphRequest -Method GET -Uri $NextUri
        if ($null -ne $Response.value) {
            $Results += @($Response.value)
        }

        $NextUri = $null
        if ($null -ne $Response.PSObject.Properties['@odata.nextLink']) {
            $NextUri = [string]$Response.'@odata.nextLink'
        }
    }

    return $Results
}

Write-Output ('Resolving assigned devices. Tenant={0}; Groups={1}' -f $TenantKey, ($GroupIds -join ', '))

$GuidPattern = '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
[object[]]$EntraDeviceObjects = @()

foreach ($GroupId in $GroupIds) {
    if ($GroupId -notmatch $GuidPattern) {
        throw "Invalid Microsoft Entra group Object ID: $GroupId"
    }

    $EncodedGroupId = [uri]::EscapeDataString($GroupId)
    $MembersUri = (
        $GraphBaseUri +
        '/groups/' +
        $EncodedGroupId +
        '/transitiveMembers/microsoft.graph.device' +
        '?$select=id,deviceId,displayName,accountEnabled'
    )

    [object[]]$GroupDevices = @(Get-GraphCollection -Uri $MembersUri)
    Write-Output ('Resolved {0} Entra devices from group {1}.' -f $GroupDevices.Count, $GroupId)
    $EntraDeviceObjects += $GroupDevices
}

$EntraDeviceObjects = @(
    $EntraDeviceObjects |
        Where-Object {
            $null -ne $_.deviceId -and
            -not [string]::IsNullOrWhiteSpace([string]$_.deviceId) -and
            $_.accountEnabled -ne $false
        } |
        Sort-Object -Property deviceId -Unique
)

if ($EntraDeviceObjects.Count -eq 0) {
    Write-Warning 'No enabled Entra device members were found. No sync requested.'
    exit 0
}

if ($EntraDeviceObjects.Count -gt $MaximumDevices) {
    throw "Safety limit exceeded. ResolvedDevices=$($EntraDeviceObjects.Count); MaximumDevices=$MaximumDevices"
}

$ManagedDevicesUri = (
    $GraphBaseUri +
    '/deviceManagement/managedDevices' +
    '?$select=id,deviceName,azureADDeviceId,operatingSystem,managementState,lastSyncDateTime'
)

[object[]]$ManagedDevices = @(Get-GraphCollection -Uri $ManagedDevicesUri)
$ManagedDeviceIndex = @{}

foreach ($ManagedDevice in $ManagedDevices) {
    $AzureAdDeviceId = [string]$ManagedDevice.azureADDeviceId
    if (-not [string]::IsNullOrWhiteSpace($AzureAdDeviceId)) {
        $ManagedDeviceIndex[$AzureAdDeviceId.ToLowerInvariant()] = $ManagedDevice
    }
}

$SyncResults = [System.Collections.Generic.List[object]]::new()

foreach ($EntraDevice in $EntraDeviceObjects) {
    $AzureAdDeviceId = ([string]$EntraDevice.deviceId).ToLowerInvariant()

    if (-not $ManagedDeviceIndex.ContainsKey($AzureAdDeviceId)) {
        $SyncResults.Add([PSCustomObject]@{
            DeviceName       = [string]$EntraDevice.displayName
            AzureAdDeviceId   = [string]$EntraDevice.deviceId
            ManagedDeviceId   = $null
            OperatingSystem   = $null
            LastSyncDateTime  = $null
            SyncRequestStatus = 'NotManagedByIntune'
            Message           = 'No Intune managedDevice record found.'
        })
        continue
    }

    $ManagedDevice = $ManagedDeviceIndex[$AzureAdDeviceId]

    if (
        $AllowedOperatingSystems.Count -gt 0 -and
        [string]$ManagedDevice.operatingSystem -notin $AllowedOperatingSystems
    ) {
        $SyncResults.Add([PSCustomObject]@{
            DeviceName       = [string]$ManagedDevice.deviceName
            AzureAdDeviceId   = [string]$ManagedDevice.azureADDeviceId
            ManagedDeviceId   = [string]$ManagedDevice.id
            OperatingSystem   = [string]$ManagedDevice.operatingSystem
            LastSyncDateTime  = $ManagedDevice.lastSyncDateTime
            SyncRequestStatus = 'SkippedOperatingSystem'
            Message           = 'Operating system is outside the allowlist.'
        })
        continue
    }

    if ([string]$ManagedDevice.managementState -ne 'managed') {
        $SyncResults.Add([PSCustomObject]@{
            DeviceName       = [string]$ManagedDevice.deviceName
            AzureAdDeviceId   = [string]$ManagedDevice.azureADDeviceId
            ManagedDeviceId   = [string]$ManagedDevice.id
            OperatingSystem   = [string]$ManagedDevice.operatingSystem
            LastSyncDateTime  = $ManagedDevice.lastSyncDateTime
            SyncRequestStatus = 'SkippedManagementState'
            Message           = "Management state is $($ManagedDevice.managementState)."
        })
        continue
    }

    $EncodedManagedDeviceId = [uri]::EscapeDataString(
        [string]$ManagedDevice.id
    )

    $SyncUri = (
        $GraphBaseUri +
        '/deviceManagement/managedDevices/' +
        $EncodedManagedDeviceId +
        '/syncDevice'
    )

    try {
        Invoke-GraphRequest -Method POST -Uri $SyncUri

        $SyncResults.Add([PSCustomObject]@{
            DeviceName       = [string]$ManagedDevice.deviceName
            AzureAdDeviceId   = [string]$ManagedDevice.azureADDeviceId
            ManagedDeviceId   = [string]$ManagedDevice.id
            OperatingSystem   = [string]$ManagedDevice.operatingSystem
            LastSyncDateTime  = $ManagedDevice.lastSyncDateTime
            SyncRequestStatus = 'Queued'
            Message           = 'Microsoft Graph accepted the sync request.'
        })
        Write-Output ('Sync queued: {0} [{1}]' -f $ManagedDevice.deviceName, $ManagedDevice.id)
    }
    catch {
        $SyncResults.Add([PSCustomObject]@{
            DeviceName       = [string]$ManagedDevice.deviceName
            AzureAdDeviceId   = [string]$ManagedDevice.azureADDeviceId
            ManagedDeviceId   = [string]$ManagedDevice.id
            OperatingSystem   = [string]$ManagedDevice.operatingSystem
            LastSyncDateTime  = $ManagedDevice.lastSyncDateTime
            SyncRequestStatus = 'Failed'
            Message           = $_.Exception.Message
        })
        Write-Warning ('Sync request failed: {0}; Error={1}' -f $ManagedDevice.deviceName, $_.Exception.Message)
    }

    if ($DelayMilliseconds -gt 0) {
        Start-Sleep -Milliseconds $DelayMilliseconds
    }
}

[int]$QueuedCount = @($SyncResults | Where-Object { $_.SyncRequestStatus -eq 'Queued' }).Count
[int]$FailedCount = @($SyncResults | Where-Object { $_.SyncRequestStatus -eq 'Failed' }).Count
[int]$SkippedCount = $SyncResults.Count - $QueuedCount - $FailedCount

Write-Output ''
Write-Output 'Device sync summary'
Write-Output "Queued=$QueuedCount"
Write-Output "Failed=$FailedCount"
Write-Output "Skipped=$SkippedCount"
Write-Output "Total=$($SyncResults.Count)"

$SyncResults |
    Sort-Object DeviceName |
    Format-Table DeviceName, OperatingSystem, SyncRequestStatus, LastSyncDateTime, Message -AutoSize |
    Out-String |
    Write-Output

$ResultDirectory = if ([string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) {
    [System.IO.Path]::GetTempPath()
}
else {
    $env:RUNNER_TEMP
}

$ResultPath = Join-Path -Path $ResultDirectory -ChildPath "device-sync-$TenantKey.json"
$SyncResults | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $ResultPath -Encoding UTF8
Write-Output "Sync result file: $ResultPath"

if ($FailedCount -gt 0 -and $FailWhenSyncFails) {
    throw "$FailedCount device sync request or requests failed."
}
