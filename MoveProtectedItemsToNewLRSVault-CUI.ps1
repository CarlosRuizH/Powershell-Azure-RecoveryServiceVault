# Move all Protected Items and Servers to a new LRS Recovery Service Vault, and delete old Vault
# 
# WARNING: This is a destructive process. ALL BACKUP DATA WILL BE DELETED!
#
# The script follows these steps:
#    Searches for all Recovery Service Vaults (RSVs) in one or multiple subscriptions
#    Allows for end user to select a RSV to migrate & delete
#    Creates a new RSV in the same region and resource group as the selected vault, and names it "[old-vault-name]-LRS"
#    Changes the new RSV's storage replication type to Locally-Redudant
#    Copies all custom policies from the old RSV to the new RSV-LRS
#    Disables soft-delete protection and deletes all Backup Items from old RSV
#    Re-Enables protection for all types of Backup Items in new RSV-LRS
#    Deletes old RSV
#
# Requires Windows plaftorm for out-GridView cmdlet support

Write-Host "WARNING: Please ensure that you have at least PowerShell 7 and have upgraded to the latest Az module before running this script. Visit https://go.microsoft.com/fwlink/?linkid=2181071 for the procedure." -ForegroundColor Yellow

# Input Variables
$RecoveryServiceVaults = @() 		#Recovery Service Vault array

# Set preferences
$ErrorActionPreference = "Stop"
$VerbosePreference = "SilentlyContinue"
$subscriptions = $null
$RecoveryServiceVaults = $null

# Import Modules
Import-Module -Name Az.Accounts
Import-Module -Name Az.RecoveryServices

# Set Prefrences
$VerbosePreference = "Continue"

# --- Start ---
# Connect to Azure
try {
    Connect-AzAccount
    }

catch {
    Write-Output "Error connecting to Azure"
    Write-Output $_.Exception.message
    }


# User selection of Subscription for Recovery Service Vault search
Write-Verbose -Message "Getting list of Subscriptions"
$subscriptions = Get-AzSubscription | Out-ConsoleGridView -Title "Select Subscriptions to search for Recovery Service Vaults"

if (!$subscriptions) {
	Write-Host -Message "Please select an available subscription. Exiting script." -ForegroundColor Red
	Exit
}

# Cycle through all Azure subscriptions and display the Recovery Service Vaults.
try {

    foreach ($subscription in $subscriptions) {

        # Set Context to subscription
        Write-Verbose -Message "Searching in Subscription: [$($subscription.Name)] - ID: [($($subscription.id))] "
        Set-AzContext -Subscription $subscription.Id | Format-List
                
        # Search for all StorageAccounts within the selected subscriptions
        $RecoveryServiceVaults += @(Get-AzRecoveryServicesVault)  
                      
    }
}
catch {
    
    # Catch anything that went wrong
    Write-Error -Message $_.Exception
    throw $_.Exception

}


# Display list of queried subscriptions
Write-Verbose -Message "Queried Subscriptions for Recovery Service Vaults"
$subscriptions | Format-Table


# User selects a Recovery Service Vault to migrate and delete
Write-verbose -Message "Recovery Service Vaults"
$RecoveryServiceVault = $RecoveryServiceVaults |  Out-ConsoleGridView -Title "Select the Recovery Service Vault to Migrate to LRS & Delete" -OutputMode Single

if (!$RecoveryServiceVault) {
	Write-Host -Message "Please select a Recovery Service Vault. Exiting script." -ForegroundColor Red
	Exit
}

# Prepare working variables
$VaultName = $RecoveryServiceVault.Name
$Subscription = Get-AzSubscription | Where-Object {$_.id -eq $RecoveryServiceVault.SubscriptionId} | Select-Object Name
$ResourceGroup = $RecoveryServiceVault.ResourceGroupName
$SubscriptionId = $RecoveryServiceVault.SubscriptionId


# Set context to the selected RSV for deletion
$VaultToDelete = Get-AzRecoveryServicesVault -Name $VaultName -ResourceGroupName $ResourceGroup
Write-Verbose -Message "Vault [$($VaultToDelete.Name)] selected for migration & deletion"
Set-AzRecoveryServicesAsrVaultContext -Vault $VaultToDelete


# Checks if the new vault has already been created in the same resource group

try {
	$newVault = Get-AzRecoveryServicesVault -Name "$($VaultToDelete.Name)-LRS" -ResourceGroupName $($VaultToDelete.ResourceGroupName)
	Write-Verbose -Message "Recovery Service Vault [$($newVault.Name)] has already been created in Resource Group [$($newVault.ResourceGroupName)]"
	Write-Host  "New Recovery Service Vault [$($newVault.name)] already created - Please remove this vault first" -ForegroundColor Red
	Exit # Exits script for user remediation}
}
catch {
	# Creates a new vault with suffix -LRS in the same Resource Group and Region as selected RSV
	Write-Verbose -Message "Creating new Recovery Service Vault: [$($VaultToDelete.Name)-LRS] ..."
	New-AzRecoveryServicesVault -Name "$($VaultToDelete.Name)-LRS" -Location $VaultToDelete.Location -ResourceGroupName $VaultToDelete.ResourceGroupName
	$newVault = Get-AzRecoveryServicesVault -Name "$($VaultToDelete.Name)-LRS" -ResourceGroupName $($VaultToDelete.ResourceGroupName)
	Write-Verbose -Message "Recovery Service Vault [$($newVault.Name)] created in Resource Group [$($newVault.ResourceGroupName)] successfully"

}


# Change the storage replication type of the new vault to Locally Redundant
Set-AzRecoveryServicesBackupProperty -Vault $newVault -BackupStorageRedundancy LocallyRedundant
Write-Verbose -Message "Storage Replication Type of [$($newVault.Name)] changed to LocallyRedundant"


# Disable soft-delete of old vault
Set-AzRecoveryServicesVaultProperty -Vault $VaultToDelete.ID -SoftDeleteFeatureState Disable
Write-Verbose -Message "Soft-delete disabled for the vault $VaultName"


# Rollback any soft deleted items pending for deletion from old vault
$containerSoftDelete = Get-AzRecoveryServicesBackupItem -BackupManagementType AzureVM -WorkloadType AzureVM -VaultId $VaultToDelete.ID | Where-Object {$_.DeleteState -eq "ToBeDeleted"} #fetch backup items in soft delete state
foreach ($softitem in $containerSoftDelete)
{
    Undo-AzRecoveryServicesBackupItemDeletion -Item $softitem -VaultId $VaultToDelete.ID -Force #undelete items in soft delete state
}


# Invoking API to disable Security features (Enhanced Security) to remove MARS/MAB/DPM servers.
$azProfile = [Microsoft.Azure.Commands.Common.Authentication.Abstractions.AzureRmProfileProvider]::Instance.Profile
$profileClient = New-Object -TypeName Microsoft.Azure.Commands.ResourceManager.Common.RMProfileClient -ArgumentList ($azProfile)
$accesstoken = Get-AzAccessToken
$token = $accesstoken.Token
$authHeader = @{
    'Content-Type'='application/json'
    'Authorization'='Bearer ' + $token
}
$body = @{properties=@{enhancedSecurityState= "Disabled"}}
$restUri = 'https://management.azure.com/subscriptions/'+$SubscriptionId+'/resourcegroups/'+$ResourceGroup+'/providers/Microsoft.RecoveryServices/vaults/'+$VaultName+'/backupconfig/vaultconfig?api-version=2019-05-13' #Replace "management.azure.com" with "management.usgovcloudapi.net" if your subscription is in USGov
$response = Invoke-RestMethod -Uri $restUri -Headers $authHeader -Body ($body | ConvertTo-JSON -Depth 9) -Method PATCH
Write-Verbose -Message "Disabled Security features for the vault"


# Copy Custom Backup Protection Policy from old Vault to new Vault
Write-Verbose -Message "Looking for custom backup policies in [$($VaultToDelete.Name)]"
$customVaultPolicy = Get-AzRecoveryServicesBackupProtectionPolicy -VaultId $VaultToDelete.ID
$customVaultPolicy = $customVaultPolicy | Where-Object {($_.name -ne "DefaultPolicy") -and ($_.name -ne "EnhancedPolicy") -and ($_.name -ne "HourlyLogBackup")} 

Set-AzRecoveryServicesVaultContext -Vault $newVault
New-AzRecoveryServicesBackupProtectionPolicy -Name $customVaultPolicy.Name -WorkloadType $customVaultPolicy.WorkloadType -RetentionPolicy $customVaultPolicy.RetentionPolicy -SchedulePolicy $customVaultPolicy.SchedulePolicy
Write-Verbose -Message "New custom backup policy [$($customVaultPolicy.Name)] created in vault [$($newVault.Name)] "


# Fetch all protected items and servers, and force dissable & delete them
Write-Verbose -Message "Fetching all protected items and servers, force dissabling, deleting, and re-enabling them on the new vault."
Write-Verbose -Message "Please wait. This may take a while..."

$backupItemsVM = Get-AzRecoveryServicesBackupItem -BackupManagementType AzureVM -WorkloadType AzureVM -VaultId $VaultToDelete.ID
$backupItemsSQL = Get-AzRecoveryServicesBackupItem -BackupManagementType AzureWorkload -WorkloadType MSSQL -VaultId $VaultToDelete.ID
$backupItemsAFS = Get-AzRecoveryServicesBackupItem -BackupManagementType AzureStorage -WorkloadType AzureFiles -VaultId $VaultToDelete.ID
$backupItemsSAP = Get-AzRecoveryServicesBackupItem -BackupManagementType AzureWorkload -WorkloadType SAPHanaDatabase -VaultId $VaultToDelete.ID
$backupContainersSQL = Get-AzRecoveryServicesBackupContainer -ContainerType AzureVMAppContainer -Status Registered -VaultId $VaultToDelete.ID | Where-Object {$_.ExtendedInfo.WorkloadType -eq "SQL"}
$protectableItemsSQL = Get-AzRecoveryServicesBackupProtectableItem -WorkloadType MSSQL -VaultId $VaultToDelete.ID | Where-Object {$_.IsAutoProtected -eq $true}
$backupContainersSAP = Get-AzRecoveryServicesBackupContainer -ContainerType AzureVMAppContainer -Status Registered -VaultId $VaultToDelete.ID | Where-Object {$_.ExtendedInfo.WorkloadType -eq "SAPHana"}
$StorageAccounts = Get-AzRecoveryServicesBackupContainer -ContainerType AzureStorage -Status Registered -VaultId $VaultToDelete.ID
$backupServersMARS = Get-AzRecoveryServicesBackupContainer -ContainerType "Windows" -BackupManagementType MAB -VaultId $VaultToDelete.ID
$backupServersMABS = Get-AzRecoveryServicesBackupManagementServer -VaultId $VaultToDelete.ID| Where-Object { $_.BackupManagementType -eq "AzureBackupServer" }
$backupServersDPM = Get-AzRecoveryServicesBackupManagementServer -VaultId $VaultToDelete.ID | Where-Object { $_.BackupManagementType-eq "SCDPM" }
$pvtendpoints = Get-AzPrivateEndpointConnection -PrivateLinkResourceId $VaultToDelete.ID

foreach($item in $backupItemsVM)
    {
        Disable-AzRecoveryServicesBackupProtection -Item $item -VaultId $VaultToDelete.ID -RemoveRecoveryPoints -Force #stop backup and delete Azure VM backup items
		Enable-AzRecoveryServicesBackupProtection -Item $item -Policy $customVaultPolicy -VaultId $newVault.ID 
    }
Write-Verbose -Message "Azure VM backup items disabled and deleted from vault [$($VaultToDelete.Name)] and re-enabled on vault [$($newVault.Name)]"


foreach($item in $backupItemsSQL)
    {
        Disable-AzRecoveryServicesBackupProtection -Item $item -VaultId $VaultToDelete.ID -RemoveRecoveryPoints -Force #stop backup and delete SQL Server in Azure VM backup items
		Enable-AzRecoveryServicesBackupProtection -Item $item -Policy $customVaultPolicy -VaultId $newVault.ID 
	}
Write-Verbose -Message "SQL Server backup items disabled and deleted from vault [$($VaultToDelete.Name)] and re-enabled on vault [$($newVault.Name)]"


foreach($item in $protectableItemsSQL)
    {
        Disable-AzRecoveryServicesBackupAutoProtection -BackupManagementType AzureWorkload -WorkloadType MSSQL -InputItem $item -VaultId $VaultToDelete.ID #disable auto-protection for SQL
		Enable-AzRecoveryServicesBackupProtection -Item $item -Policy $customVaultPolicy -VaultId $newVault.ID
	}
Write-Verbose -Message "SQL protectable items disabled and deleted from vault [$($VaultToDelete.Name)] and re-enabled on vault [$($newVault.Name)]"


foreach($item in $backupContainersSQL)
    {
        Unregister-AzRecoveryServicesBackupContainer -Container $item -Force -VaultId $VaultToDelete.ID #unregister SQL Server in Azure VM protected server
		Register-AzRecoveryServicesBackupContainer -ResourceId $item.Id -VaultId $newVault.ID -WorkloadType $item.WorkloadType -BackupManagementType $item.BackupManagementType
    }
Write-Verbose -Message "SQL Server in Azure VM containers disabled and deleted from vault [$($VaultToDelete.Name)] and re-enabled on vault [$($newVault.Name)]"


foreach($item in $backupItemsSAP)
    {
        Disable-AzRecoveryServicesBackupProtection -Item $item -VaultId $VaultToDelete.ID -RemoveRecoveryPoints -Force #stop backup and delete SAP HANA in Azure VM backup items
		Enable-AzRecoveryServicesBackupProtection -Item $item -Policy $customVaultPolicy -VaultId $newVault.ID
	}
Write-Verbose -Message "SAP HANA backup items disabled and deleted from vault [$($VaultToDelete.Name)] and re-enabled on vault [$($newVault.Name)]"


foreach($item in $backupContainersSAP)
    {
        Unregister-AzRecoveryServicesBackupContainer -Container $item -Force -VaultId $VaultToDelete.ID #unregister SAP HANA in Azure VM protected server
		Register-AzRecoveryServicesBackupContainer -ResourceId $item.Id -VaultId $newVault.ID -WorkloadType $item.WorkloadType -BackupManagementType $item.BackupManagementType

    }
Write-Verbose -Message "SAP HANA in Azure VM containers disabled and deleted from vault [$($VaultToDelete.Name)] and re-enabled on vault [$($newVault.Name)]"


foreach($item in $backupItemsAFS)
    {
        Disable-AzRecoveryServicesBackupProtection -Item $item -VaultId $VaultToDelete.ID -RemoveRecoveryPoints -Force #stop backup and delete Azure File Shares backup items
		Enable-AzRecoveryServicesBackupProtection -Item $item -Policy $customVaultPolicy -VaultId $newVault.ID
	}
Write-Verbose -Message "Azure File Share backups disabled and deleted from vault [$($VaultToDelete.Name)] and re-enabled on vault [$($newVault.Name)]"


foreach($item in $StorageAccounts)
    {
        Unregister-AzRecoveryServicesBackupContainer -container $item -Force -VaultId $VaultToDelete.ID #unregister storage accounts
		Register-AzRecoveryServicesBackupContainer -ResourceId $item.Id -VaultId $newVault.ID -WorkloadType $item.WorkloadType -BackupManagementType $item.BackupManagementType
    }
Write-Verbose -Message "Storage Accounts unregistered on vault [$($VaultToDelete.Name)] and registered on vault [$($newVault.Name)]"


foreach($item in $backupServersMARS)
    {
    	Unregister-AzRecoveryServicesBackupContainer -Container $item -Force -VaultId $VaultToDelete.ID #unregister MARS servers and delete corresponding backup items
		Register-AzRecoveryServicesBackupContainer -ResourceId $item.Id -VaultId $newVault.ID -WorkloadType $item.WorkloadType -BackupManagementType $item.BackupManagementType
	}
Write-Verbose "Deleted MARS Servers on vault [$($VaultToDelete.Name)] and registered on vault [$($newVault.Name)]"


foreach($item in $backupServersMABS)
    {
	    Unregister-AzRecoveryServicesBackupManagementServer -AzureRmBackupManagementServer $item -VaultId $VaultToDelete.ID #unregister MABS servers and delete corresponding backup items
		Register-AzRecoveryServicesBackupContainer -ResourceId $item.Id -VaultId $newVault.ID -WorkloadType $item.WorkloadType -BackupManagementType $item.BackupManagementType
	}
Write-Verbose "Deleted MAB Servers on vault [$($VaultToDelete.Name)] and registered on vault [$($newVault.Name)]"


foreach($item in $backupServersDPM)
    {
	    Unregister-AzRecoveryServicesBackupManagementServer -AzureRmBackupManagementServer $item -VaultId $VaultToDelete.ID #unregister DPM servers and delete corresponding backup items
		Register-AzRecoveryServicesBackupContainer -ResourceId $item.Id -VaultId $newVault.ID -WorkloadType $item.WorkloadType -BackupManagementType $item.BackupManagementType
	}
Write-Verbose "Deleted DPM Servers on vault [$($VaultToDelete.Name)] and registered on vault [$($newVault.Name)]"
Write-Host "Ensure that you stop protection and delete backup items from the respective MARS, MAB and DPM consoles as well. Visit https://go.microsoft.com/fwlink/?linkid=2186234 to learn more." -ForegroundColor Yellow


# Deletion of ASR Items
Set-AzRecoveryServicesAsrVaultContext -Vault $VaultToDelete
$fabricObjects = Get-AzRecoveryServicesAsrFabric
if ($null -ne $fabricObjects) {
	# First DisableDR all VMs.
	foreach ($fabricObject in $fabricObjects) {
		$containerObjects = Get-AzRecoveryServicesAsrProtectionContainer -Fabric $fabricObject
		foreach ($containerObject in $containerObjects) {
			$protectedItems = Get-AzRecoveryServicesAsrReplicationProtectedItem -ProtectionContainer $containerObject
			# DisableDR all protected items
			foreach ($protectedItem in $protectedItems) {
				Write-Host "Triggering DisableDR(Purge) for item:" $protectedItem.Name
				Remove-AzRecoveryServicesAsrReplicationProtectedItem -InputObject $protectedItem -Force
				Write-Host "DisableDR(Purge) completed"
			}

			$containerMappings = Get-AzRecoveryServicesAsrProtectionContainerMapping -ProtectionContainer $containerObject
			# Remove all Container Mappings
			foreach ($containerMapping in $containerMappings) {
				Write-Host "Triggering Remove Container Mapping: " $containerMapping.Name
				Remove-AzRecoveryServicesAsrProtectionContainerMapping -ProtectionContainerMapping $containerMapping -Force
				Write-Host "Removed Container Mapping."
			}
		}
		$NetworkObjects = Get-AzRecoveryServicesAsrNetwork -Fabric $fabricObject
		foreach ($networkObject in $NetworkObjects)
		{
			#Get the PrimaryNetwork
			$PrimaryNetwork = Get-AzRecoveryServicesAsrNetwork -Fabric $fabricObject -FriendlyName $networkObject
			$NetworkMappings = Get-AzRecoveryServicesAsrNetworkMapping -Network $PrimaryNetwork
			foreach ($networkMappingObject in $NetworkMappings)
			{
				#Get the Neetwork Mappings
				$NetworkMapping = Get-AzRecoveryServicesAsrNetworkMapping -Name $networkMappingObject.Name -Network $PrimaryNetwork
				Remove-AzRecoveryServicesAsrNetworkMapping -InputObject $NetworkMapping
			}
		}
		# Remove Fabric
		Write-Host "Triggering Remove Fabric:" $fabricObject.FriendlyName
		Remove-AzRecoveryServicesAsrFabric -InputObject $fabricObject -Force
		Write-Host "Removed Fabric."
	}
}
Write-Host "Warning: This script will only remove the replication configuration from Azure Site Recovery and not from the source. Please cleanup the source manually. Visit https://go.microsoft.com/fwlink/?linkid=2182781 to learn more." -ForegroundColor Yellow
foreach($item in $pvtendpoints)
	{
		$penamesplit = $item.Name.Split(".")
		$pename = $penamesplit[0]
		Remove-AzPrivateEndpointConnection -ResourceId $item.PrivateEndpoint.Id -Force #remove private endpoint connections
		Remove-AzPrivateEndpoint -Name $pename -ResourceGroupName $ResourceGroup -Force #remove private endpoints
	}
Write-Host "Removed Private Endpoints"


# Recheck ASR items in vault
$fabricCount = 0
$ASRProtectedItems = 0
$ASRPolicyMappings = 0
$fabricObjects = Get-AzRecoveryServicesAsrFabric
if ($null -ne $fabricObjects) {
	foreach ($fabricObject in $fabricObjects) {
		$containerObjects = Get-AzRecoveryServicesAsrProtectionContainer -Fabric $fabricObject
		foreach ($containerObject in $containerObjects) {
			$protectedItems = Get-AzRecoveryServicesAsrReplicationProtectedItem -ProtectionContainer $containerObject
			foreach ($protectedItem in $protectedItems) {
				$ASRProtectedItems++
			}
			$containerMappings = Get-AzRecoveryServicesAsrProtectionContainerMapping -ProtectionContainer $containerObject
			foreach ($containerMapping in $containerMappings) {
				$ASRPolicyMappings++
			}
		}
		$fabricCount++
	}
}
# Recheck presence of backup items in vault
$backupItemsVMFin = Get-AzRecoveryServicesBackupItem -BackupManagementType AzureVM -WorkloadType AzureVM -VaultId $VaultToDelete.ID
$backupItemsSQLFin = Get-AzRecoveryServicesBackupItem -BackupManagementType AzureWorkload -WorkloadType MSSQL -VaultId $VaultToDelete.ID
$backupContainersSQLFin = Get-AzRecoveryServicesBackupContainer -ContainerType AzureVMAppContainer -Status Registered -VaultId $VaultToDelete.ID | Where-Object {$_.ExtendedInfo.WorkloadType -eq "SQL"}
$protectableItemsSQLFin = Get-AzRecoveryServicesBackupProtectableItem -WorkloadType MSSQL -VaultId $VaultToDelete.ID | Where-Object {$_.IsAutoProtected -eq $true}
$backupItemsSAPFin = Get-AzRecoveryServicesBackupItem -BackupManagementType AzureWorkload -WorkloadType SAPHanaDatabase -VaultId $VaultToDelete.ID
$backupContainersSAPFin = Get-AzRecoveryServicesBackupContainer -ContainerType AzureVMAppContainer -Status Registered -VaultId $VaultToDelete.ID | Where-Object {$_.ExtendedInfo.WorkloadType -eq "SAPHana"}
$backupItemsAFSFin = Get-AzRecoveryServicesBackupItem -BackupManagementType AzureStorage -WorkloadType AzureFiles -VaultId $VaultToDelete.ID
$StorageAccountsFin = Get-AzRecoveryServicesBackupContainer -ContainerType AzureStorage -Status Registered -VaultId $VaultToDelete.ID
$backupServersMARSFin = Get-AzRecoveryServicesBackupContainer -ContainerType "Windows" -BackupManagementType MAB -VaultId $VaultToDelete.ID
$backupServersMABSFin = Get-AzRecoveryServicesBackupManagementServer -VaultId $VaultToDelete.ID| Where-Object { $_.BackupManagementType -eq "AzureBackupServer" }
$backupServersDPMFin = Get-AzRecoveryServicesBackupManagementServer -VaultId $VaultToDelete.ID | Where-Object { $_.BackupManagementType-eq "SCDPM" }
$pvtendpointsFin = Get-AzPrivateEndpointConnection -PrivateLinkResourceId $VaultToDelete.ID

# Display items which are still present in the vault and might be preventing vault deletion.
if($backupItemsVMFin.count -ne 0) {Write-Host $backupItemsVMFin.count "Azure VM backups are still present in the vault. Remove the same for successful vault deletion." -ForegroundColor Red}
if($backupItemsSQLFin.count -ne 0) {Write-Host $backupItemsSQLFin.count "SQL Server Backup Items are still present in the vault. Remove the same for successful vault deletion." -ForegroundColor Red}
if($backupContainersSQLFin.count -ne 0) {Write-Host $backupContainersSQLFin.count "SQL Server Backup Containers are still registered to the vault. Remove the same for successful vault deletion." -ForegroundColor Red}
if($protectableItemsSQLFin.count -ne 0) {Write-Host $protectableItemsSQLFin.count "SQL Server Instances are still present in the vault. Remove the same for successful vault deletion." -ForegroundColor Red}
if($backupItemsSAPFin.count -ne 0) {Write-Host $backupItemsSAPFin.count "SAP HANA Backup Items are still present in the vault. Remove the same for successful vault deletion." -ForegroundColor Red}
if($backupContainersSAPFin.count -ne 0) {Write-Host $backupContainersSAPFin.count "SAP HANA Backup Containers are still registered to the vault. Remove the same for successful vault deletion." -ForegroundColor Red}
if($backupItemsAFSFin.count -ne 0) {Write-Host $backupItemsAFSFin.count "Azure File Shares are still present in the vault. Remove the same for successful vault deletion." -ForegroundColor Red}
if($StorageAccountsFin.count -ne 0) {Write-Host $StorageAccountsFin.count "Storage Accounts are still registered to the vault. Remove the same for successful vault deletion." -ForegroundColor Red}
if($backupServersMARSFin.count -ne 0) {Write-Host $backupServersMARSFin.count "MARS Servers are still registered to the vault. Remove the same for successful vault deletion." -ForegroundColor Red}
if($backupServersMABSFin.count -ne 0) {Write-Host $backupServersMABSFin.count "MAB Servers are still registered to the vault. Remove the same for successful vault deletion." -ForegroundColor Red}
if($backupServersDPMFin.count -ne 0) {Write-Host $backupServersDPMFin.count "DPM Servers are still registered to the vault. Remove the same for successful vault deletion." -ForegroundColor Red}
if($ASRProtectedItems -ne 0) {Write-Host $ASRProtectedItems "ASR protected items are still present in the vault. Remove the same for successful vault deletion." -ForegroundColor Red}
if($ASRPolicyMappings -ne 0) {Write-Host $ASRPolicyMappings "ASR policy mappings are still present in the vault. Remove the same for successful vault deletion." -ForegroundColor Red}
if($fabricCount -ne 0) {Write-Host $fabricCount "ASR Fabrics are still present in the vault. Remove the same for successful vault deletion." -ForegroundColor Red}
if($pvtendpointsFin.count -ne 0) {Write-Host $pvtendpointsFin.count "Private endpoints are still linked to the vault. Remove the same for successful vault deletion." -ForegroundColor Red}


# Attempt to delete the old Vault
$Error.Clear()
try {
	Remove-AzRecoveryServicesVault -Vault $VaultToDelete
}
catch {
	$_
	Write-Verbose -Message "$($VaultToDelete.Name) Recovery Services Vault could not be deleted"
	Exit
}
Write-Verbose -Message "$($VaultToDelete.Name) Recovery Services Vault has been deleted."
Write-Verbose -Message "Operation completed successfully!"	

# Done!
