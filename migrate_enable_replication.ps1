param(
    [Parameter(Mandatory)]
    [string]$CsvFilePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------- LOGGER ----------
. "$PSScriptRoot\migrate_logger.ps1"
$log = New-Logger -Component "AzureMigrate-Replication"

$log.Step("Script started")

# ---------- LOGIN ----------
$ctx = Get-AzContext
if (-not $ctx) {
    throw "Azure login missing. Run Connect-AzAccount."
}
$log.Info("Logged in as $($ctx.Account.Id)")

# ---------- CSV ----------
if (-not (Test-Path $CsvFilePath)) {
    throw "CSV not found: $CsvFilePath"
}

$rows = Import-Csv $CsvFilePath
if ($rows.Count -eq 0) {
    throw "CSV is empty"
}

$log.Info("Loaded $($rows.Count) record(s)")

foreach ($row in $rows) {

    $log.Step("Processing VM '$($row.VM_NAME)'")

    # ---------- VALIDATION ----------
    foreach ($col in @(
        "AZMIGRATE_PROJECT_SUBSCRIPTION",
        "AZMIGRATE_PROJECT_RESOURCE_GROUP",
        "AZMIGRATE_PROJECT_NAME",
        "VM_NAME",
        "TARGET_SUBSCRIPTION_ID",
        "TARGET_RESOURCE_GROUP",
        "TARGET_VNET_ID",
        "TARGET_SUBNET_NAME"
    )) {
        if (-not $row.$col) {
            throw "Missing required CSV column: $col"
        }
    }

    # ---------- CONTEXT ----------
    Set-AzContext -SubscriptionId $row.AZMIGRATE_PROJECT_SUBSCRIPTION | Out-Null
    $log.Info("Set context to Azure Migrate project subscription")

    # ---------- FIND MACHINE (RESOURCE GRAPH) ----------
    $query = @"
resources
| where resourceGroup == '$($row.AZMIGRATE_PROJECT_RESOURCE_GROUP)'
| where type =~ 'microsoft.offazure/vmwaresites/machines'
| where name =~ '$($row.VM_NAME)'
| where properties.migrateProjectName =~ '$($row.AZMIGRATE_PROJECT_NAME)'
| project id, name
"@

    $result = Search-AzGraph -Query $query

    if ($result.Count -eq 0) {
        throw "VM '$($row.VM_NAME)' not found in Azure Migrate project '$($row.AZMIGRATE_PROJECT_NAME)'"
    }

    if ($result.Count -gt 1) {
        throw "Multiple machines named '$($row.VM_NAME)' found. Use explicit MACHINE_ID."
    }

    $machineId = $result[0].id
    $log.Info("Resolved MACHINE_ID: $machineId")

    # ---------- TARGET CONTEXT ----------
    Set-AzContext -SubscriptionId $row.TARGET_SUBSCRIPTION_ID | Out-Null
    $log.Info("Switched to target subscription")

    # ---------- BUILD PAYLOAD ----------
    $properties = @{
        targetResourceGroupId = "/subscriptions/$($row.TARGET_SUBSCRIPTION_ID)/resourceGroups/$($row.TARGET_RESOURCE_GROUP)"
        networkSettings = @{
            targetVNetId     = $row.TARGET_VNET_ID
            targetSubnetName = $row.TARGET_SUBNET_NAME
        }
    }

    if ($row.TARGET_VM_SIZE) {
        $properties.computeSettings = @{
            targetVmSize = $row.TARGET_VM_SIZE
        }
        $log.Info("VM size set to $($row.TARGET_VM_SIZE)")
    }

    if ($row.TARGET_DISK_TYPE) {
        $allowed = @("StandardHDD","StandardSSD","PremiumSSD")
        if ($allowed -notcontains $row.TARGET_DISK_TYPE) {
            throw "Invalid TARGET_DISK_TYPE"
        }
        $properties.storageSettings = @{
            targetDiskType = $row.TARGET_DISK_TYPE
        }
        $log.Info("Disk type set to $($row.TARGET_DISK_TYPE)")
    }

    if ($row.AVAILABILITY_TYPE -eq "Zone") {
        $properties.availabilitySettings = @{
            availabilityType = "Zone"
        }
        $log.Info("Availability set to Zone")
    }

    if ($row.TAGS) {
        $tagHash = @{}
        $row.TAGS.Split(';') | ForEach-Object {
            $kv = $_.Split('=')
            if ($kv.Count -eq 2) {
                $tagHash[$kv[0]] = $kv[1]
            }
        }
        $properties.tags = $tagHash
        $log.Info("Tags applied")
    }

    $body = @{ properties = $properties } | ConvertTo-Json -Depth 10
    $uri  = "https://management.azure.com$machineId/replicate?api-version=2023-06-06"

    # ---------- EXECUTE ----------
    $log.Step("Submitting replication request")
    Invoke-AzRestMethod -Method POST -Uri $uri -Payload $body | Out-Null
    $log.Info("Replication request ACCEPTED")
}

$log.Step("Script completed successfully")
