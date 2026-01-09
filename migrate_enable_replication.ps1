param(
    [Parameter(Mandatory)]
    [string]$CsvFilePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------- LOGGER ----------
. "$PSScriptRoot\migrate_logger.ps1"
$log = New-Logger -Component "AzureMigrate-EnableReplication"

$log.Step("Script started")

# ---------- LOGIN CHECK ----------
$ctx = Get-AzContext
if (-not $ctx) {
    throw "Azure context not found. Run Connect-AzAccount."
}
$log.Info("Logged in as $($ctx.Account.Id)")
$log.Info("Default subscription $($ctx.Subscription.Id)")

# ---------- CSV LOAD ----------
if (-not (Test-Path $CsvFilePath)) {
    throw "CSV file not found: $CsvFilePath"
}

$rows = Import-Csv $CsvFilePath
if ($rows.Count -eq 0) {
    throw "CSV is empty"
}

$log.Info("Loaded $($rows.Count) machine(s) from CSV")

# ---------- PROCESS EACH MACHINE ----------
foreach ($row in $rows) {

    $log.Step("Processing new machine")

    # ----- Mandatory fields -----
    foreach ($col in @(
        "MACHINE_ID",
        "TARGET_SUBSCRIPTION_ID",
        "TARGET_RESOURCE_GROUP",
        "TARGET_LOCATION",
        "TARGET_VNET_ID",
        "TARGET_SUBNET_NAME"
    )) {
        if (-not $row.$col) {
            throw "Missing required CSV column value: $col"
        }
    }

    $machineId = $row.MACHINE_ID.Trim()
    $subId     = $row.TARGET_SUBSCRIPTION_ID.Trim()
    $rg        = $row.TARGET_RESOURCE_GROUP.Trim()
    $location  = $row.TARGET_LOCATION.Trim()
    $vnetId    = $row.TARGET_VNET_ID.Trim()
    $subnet    = $row.TARGET_SUBNET_NAME.Trim()

    $vmSize    = $row.TARGET_VM_SIZE
    $diskType  = $row.TARGET_DISK_TYPE
    $availType = $row.AVAILABILITY_TYPE
    $tagsRaw   = $row.TAGS

    $log.Info("Machine ID : $machineId")
    $log.Info("Target RG  : $rg")
    $log.Info("Region     : $location")
    $log.Info("VNet       : $vnetId")
    $log.Info("Subnet     : $subnet")

    # ----- Subscription context -----
    Set-AzContext -SubscriptionId $subId | Out-Null
    $log.Info("Switched to subscription $subId")

    # ----- Build properties -----
    $properties = @{
        targetResourceGroupId = "/subscriptions/$subId/resourceGroups/$rg"
        targetLocation        = $location
        networkSettings       = @{
            targetVNetId     = $vnetId
            targetSubnetName = $subnet
        }
    }

    # Compute (VM size)
    if ($vmSize) {
        $properties.computeSettings = @{
            targetVmSize = $vmSize
        }
        $log.Info("Target VM size set to $vmSize")
    } else {
        $log.Info("No VM size specified – Azure Migrate will use recommendation")
    }

    # Disk type
    if ($diskType) {
        $allowedDisk = @("StandardHDD","StandardSSD","PremiumSSD")
        if ($allowedDisk -notcontains $diskType) {
            throw "Invalid TARGET_DISK_TYPE. Allowed: $($allowedDisk -join ', ')"
        }
        $properties.storageSettings = @{
            targetDiskType = $diskType
        }
        $log.Info("Target disk type set to $diskType")
    } else {
        $log.Info("No disk type specified – Azure Migrate will use recommendation")
    }

    # Availability
    if ($availType -eq "Zone") {
        $properties.availabilitySettings = @{
            availabilityType = "Zone"
        }
        $log.Info("Availability set to Zone")
    } else {
        $log.Info("No availability option selected")
    }

    # Tags
    if ($tagsRaw) {
        $tagHash = @{}
        $tagsRaw.Split(';') | ForEach-Object {
            $kv = $_.Split('=')
            if ($kv.Count -eq 2) {
                $tagHash[$kv[0]] = $kv[1]
            }
        }
        $properties.tags = $tagHash
        $log.Info("Tags applied")
    }

    # ----- REST call -----
    $body = @{ properties = $properties } | ConvertTo-Json -Depth 10
    $apiVersion = "2023-06-06"
    $uri = "https://management.azure.com$machineId/replicate?api-version=$apiVersion"

    $log.Step("Submitting replication request to Azure Migrate")

    try {
        Invoke-AzRestMethod -Method POST -Uri $uri -Payload $body | Out-Null
        $log.Info("Replication request ACCEPTED")
    }
    catch {
        $log.Error("Replication request FAILED")
        $log.Error($_.Exception.Message)
        throw
    }
}

$log.Step("Replication automation completed successfully")
