#######################################
# MoveProtectedItemsToNewLRSVault-CUI #
#######################################

<#
.SYNOPSIS
	Move all Protected Items and Servers to a new LRS Recovery Service Vault, and delete old Vault
.DESCRIPTION
	The script follows these steps:
		Searches for all Recovery Service Vaults (RSVs) in one or multiple subscriptions
		Allows for end user to select a RSV to migrate & delete
		Creates a new RSV in the same region and resource group as the selected vault, and names it "[old-vault-name]-LRS"
		Changes the new RSV's storage replication type to Locally-Redudant
		Copies all custom policies from the old RSV to the new RSV-LRS
		Disables soft-delete protection and deletes all Backup Items from old RSV
		Re-Enables protection for all types of Backup Items in new RSV-LRS
		Deletes old RSV
.NOTES
	WARNING: This is a destructive process. ALL BACKUP DATA WILL BE DELETED!
.LINK
	Requires Windows plaftorm for out-GridView cmdlet support
	Microsoft.PowerShell.ConsoleGuiTools Module is required for all Console User Interface components 
.EXAMPLE
	Run the script: .\MoveProtectedItemsToNewLRSVault-CUI.ps1
#>


######################################
###### User-Defined parameters #######

# Home folder location for all log files
# Example
#   $logFilePath = "c:\"
#   $logFilePath = "\\server1\"
$logFilePath = ".\Logs\"     # current folder

######################################


Write-Host "WARNING: Please ensure that you have at least PowerShell 7 and have upgraded to the latest Az module before running this script. Visit https://go.microsoft.com/fwlink/?linkid=2181071 for the procedure." -ForegroundColor Yellow

# Variables
$oldRecoveryServiceVaults = @() 		# Recovery Service Vault array
$subscriptions = $null					# Subscription List


# Set preferences
$ErrorActionPreference = "Stop"
$VerbosePreference = "SilentlyContinue"

# Import Modules
Import-Module -Name Az.Accounts
Import-Module -Name Az.RecoveryServices
Import-Module -Name Microsoft.PowerShell.ConsoleGuiTools

# Rollback preferences
$VerbosePreference = "Continue"


# Functions
function Write-Log {
    param (
        [Parameter(Mandatory=$true)][string]$Message,
        [Parameter(Mandatory=$false)][switch]$OnlyLog)
    
    if (!$OnlyLog) {
        Write-Verbose -Message $Message
    }
    $dateToday = (Get-Date).ToUniversalTime() | Get-Date -Format o
    $Message = "[" + $dateToday + " UTC] " + $Message
    Add-Content -Value $Message -Path $logMoveRSVtoLRSFile
}

function Wait-ForAnyKey {
    Write-Host -ForegroundColor Green "Press any key to continue..."
    $VerbosePreference = "SilentlyContinue"
    $response = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    Write-Log -Message "User Input - Wait-ForAnyKey: $($response.VirtualKeyCode)" -OnlyLog
    $VerbosePreference = "Continue"
}


# Create the required Log file if it does not exist
$logCreationTime = Get-Date -Format "-yyyy.MM.dd-HH.mm"
$logMoveRSVtoLRSFile = "$($logFilePath)MoveProtectedItemsToNewLRSVault$($logCreationTime).log"

if ((Test-Path -Path $logFilePath) -eq $false) {
	Write-Verbose "No '.\Logs' folder found. Creating new Logs folder."
	New-Item $logFilePath -ItemType "directory"
}

if ((Test-Path -Path $logMoveRSVtoLRSFile) -eq $false) {
    New-Item $logMoveRSVtoLRSFile
    Add-Content -Value "Log File '$($logMoveRSVtoLRSFile)'" -Path $logMoveRSVtoLRSFile
    $dateToday = Get-Date -Format "yyyy/MM/dd - HH:mm:ss UTC"
    $timestamp = Get-Date -Format o
    Add-Content -Value "[$($timestamp)] Log created: $($dateToday)" -Path $logMoveRSVtoLRSFile
}




# --- Start ---
# Connect to Azure
try {
    Connect-AzAccount
    }

catch {
	Write-Log -Message "Error connecting to Azure" -OnlyLog
    Write-Log $_.Exception.message -OnlyLog
	Write-Output "Error connecting to Azure"
    Write-Output $_.Exception.message
    }


# User selection of Subscription for Recovery Service Vault search
Write-Log -Message "Getting list of Subscriptions"
$VerbosePreference = "SilentlyContinue"
$subscriptions = Get-AzSubscription | Out-ConsoleGridView -Title "Select Subscriptions to search for Recovery Service Vaults"
$VerbosePreference = "Continue"

if (!$subscriptions) {
	Write-Host -Message "No subscription selected. Please select an available subscription to continue. Exiting script." -ForegroundColor Red
	Write-Log -Message "No subscription selected. Exiting script. No changes made." -OnlyLog
	Exit
}


# Cycle through all Azure subscriptions and display the Recovery Service Vaults.
try {
    foreach ($subscription in $subscriptions) {
        # Set Context to subscription
        Write-Log -Message "Searching for Recovery Service Vaults in Subscription: [$($subscription.Name)] - ID: [($($subscription.id))] "
        Set-AzContext -Subscription $subscription.Id | Format-List
                
        # Search for all Recovery Service Vaults within the selected subscriptions
        $oldRecoveryServiceVaults += @(Get-AzRecoveryServicesVault)                 
    }
}
catch {
    # Catch anything that went wrong
	Write-Log -Message $_.Exception -OnlyLog
    Write-Error -Message $_.Exception
    throw $_.Exception
}


# Display list of queried subscriptions
Write-Verbose -Message "Queried Subscriptions for Recovery Service Vaults"
$subscriptions | Format-Table
Wait-ForAnyKey


# User selects a Recovery Service Vault to migrate and delete
$VerbosePreference = "SilentlyContinue"
$oldRecoveryServiceVault = $oldRecoveryServiceVaults |  Out-ConsoleGridView -Title "Select the Recovery Service Vault to Migrate to LRS & Delete" -OutputMode Single
$VerbosePreference = "Continue"
if (!$oldRecoveryServiceVault) {
	Write-Host -Message "No Recovery Service Vault selected. Exiting script. No changes made" -ForegroundColor Red
	Write-Log -Message "No Recovery Service Vault selected. Terminating. No changes made."
	Exit
}
Write-Log -Message "Recovery Service Vault selected: [$($oldRecoveryServiceVault.name)]"


# Prepare working variables
$Subscription = Get-AzSubscription | Where-Object {$_.id -eq $oldRecoveryServiceVault.SubscriptionId} | Select-Object Name
$ResourceGroup = $oldRecoveryServiceVault.ResourceGroupName
$SubscriptionId = $oldRecoveryServiceVault.SubscriptionId


# Set context to the selected RSV for deletion
Write-Log -Message "Vault [$($oldRecoveryServiceVault.Name)] selected for migration & deletion"
Set-AzRecoveryServicesAsrVaultContext -Vault $oldRecoveryServiceVault


# User types new name for the RSV
Write-Host -ForegroundColor Green -Message "Please type the new Recovery Services Vault name or leave blank for default. " 
Write-Host -ForegroundColor Yellow "(Default name: [$($oldRecoveryServiceVault.Name)-LRS]): " -NoNewline
$newVaultName = read-host
Write-Host


# Check for new vault name or default name
if ($newVaultName -eq "" ) {
	Write-Log -Message "Default Recovery Services Vault name selected for new vault: [$($oldRecoveryServiceVault.Name)-LRS]"
	$newVaultName = "$($oldRecoveryServiceVault.Name)-LRS"
}
else {
	Write-Log -Message "Checking for Recovery Services Vault [$($newVaultName)] in ResourceGroup [$($oldRecoveryServiceVault.ResourceGroupName)] ..."
}


# Checks if the new vault has already been created in the same resource group
if (Get-AzRecoveryServicesVault -Name "$($newVaultName)" -ResourceGroupName $($oldRecoveryServiceVault.ResourceGroupName)) {
	Write-Log -Message "Recovery Service Vault [$($newVaultName)] already exists in Resource Group [$($oldRecoveryServiceVault.ResourceGroupName)]"
	
	# Previous existing vault found. User options to proceed.
	Write-Host -ForegroundColor Red "WARNING: Please select an option to proceed:"
	Write-Host -ForegroundColor Green " OPTION: [1] Clean Migration." -NoNewline
	Write-Host -foregroundcolor Yellow  " Delete Vault [$($newVaultName)] and all its content before migrating any items."
	Write-Host -ForegroundColor Green " OPTION: [2] Continue Migration." -NoNewline 
	Write-Host -foregroundcolor Yellow " Migrate all Backup Items to [$($newVaultName)] without deleting it first."
    $response = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    Write-Log -Message "User Input - Wait-ForAnyKey: $($response.VirtualKeyCode)" -OnlyLog
	Write-Host

	# Check selected option
	if ($response.Character -eq '1') {
		Write-Log -Message "Option [1] Selected. Please run DeleteAnyRecoveryServicesVault.ps1 on Vault [$($newVaultName)] and then re-run this script."
		Write-Log -Message "DeleteAnyRecoveryServicesVault.ps1 can be found at https://github.com/CarlosRuizH/Powershell-Azure-RecoveryServiceVault" -OnlyLog
		Write-Log -Message "Exiting script. No changes made."
		Exit
	}
	elseif ($response.Character -eq '2') {
		Write-Log -Message "Option [2] Selected. Migrating all Backup Items to [$($newVaultName)] without deleting it first."
		
		Write-Host -ForegroundColor Red "WARNING: This is a destructive process. ALL BACKUP DATA WILL BE DELETED!"
		Write-Host -ForegroundColor Red "WARNING: Please select [Y] to proceed. "
		$confirmation = read-host

		# Final confirmation before taking action
		if ($confirmation -ne 'y') {
			Write-Host -ForegroundColor Green "No changes were made to Backup Items. Exiting script. Goodbye"
			Write-Log -Message "User Cancellation. No changes were made to Backup Items. Exiting script. Goodbye" -OnlyLog
			Exit
		}
	}
	else {
		Write-Log -Message "Invalid Option selected. Exiting script. No changes made."
		Exit
	}
}
else {
	Write-Log -Message "Creating new Recovery Service Vault: [$($newVaultName)] ..."
	Write-Host
	try {
		$newVault = New-AzRecoveryServicesVault -Name "$($newVaultName)" -Location $oldRecoveryServiceVault.Location -ResourceGroupName $oldRecoveryServiceVault.ResourceGroupName
		Write-Log -Message "Recovery Service Vault [$($newVaultName)] created in Resource Group [$($oldRecoveryServiceVault.ResourceGroupName)] successfully"
	}
	catch {
		Write-Host -ForegroundColor Red "[ERROR] Error creating new Recovery Services Vault [$($newVaultName)]"
		Write-Log -Message "Error creating new Recovery Services Vault [$($newVaultName)]" -OnlyLog
		Write-Log -Message $_.Exception.Message
		Write-Log -Message $_.Exception -OnlyLog
		Exit
	}
}


$newVault = Get-AzRecoveryServicesVault -Name "$($newVaultName)" -ResourceGroupName $($oldRecoveryServiceVault.ResourceGroupName)

# Get Backup Protection Policies from the old Vault and move them to the new Vault
Write-Log -Message "Looking for custom backup policies in vault [$($oldRecoveryServiceVault.Name)]"

$oldVaultPolicies = Get-AzRecoveryServicesBackupProtectionPolicy -VaultId $oldRecoveryServiceVault.ID
$newVaultPolicies = Get-AzRecoveryServicesBackupProtectionPolicy -VaultId $newVault.ID

Set-AzRecoveryServicesVaultContext -Vault $newVault

# Compare all Backup Protection Policies from both RSVs and create missing policies
foreach ($oldVaultPolicy in $oldVaultPolicies) {
	Write-Log -Message "Looking for Policy: $($oldVaultPolicy.Name) in Vault: $($newVaultName)" -OnlyLog
	$policyFound = $false
	
	foreach ($newVaultPolicy in $newVaultPolicies) {
		if ($oldVaultPolicy.Name -eq $newVaultPolicy.Name) {
			Write-Log -Message "Policy MATCH FOUND. Policy [$($oldVaultPolicy.Name)] found in [$($newVault.Name)]. Skipped" -OnlyLog
			$policyFound = $true
		}
	}

	if (!$policyFound) {
		Write-Log -Message "Creating a new Policy in new Vault [$($newVault.Name)] Policy named: [$($oldVaultPolicy.Name)]"
		New-AzRecoveryServicesBackupProtectionPolicy -Name $oldVaultPolicy.Name -WorkloadType $oldVaultPolicy.WorkloadType -RetentionPolicy $oldVaultPolicy.RetentionPolicy -SchedulePolicy $oldVaultPolicy.SchedulePolicy
		Write-Log -Message "New custom backup policy [$($oldVaultPolicy.Name)] created in vault [$($newVault.Name)] "
	}
}


# Change the storage replication type of the new vault to Locally Redundant
Set-AzRecoveryServicesBackupProperty -Vault $newVault -BackupStorageRedundancy LocallyRedundant
$newVaultStorageReplicationType = Get-AzRecoveryServicesBackupProperty -Vault $newVault
Write-Log -Message "Storage Replication Type of [$($newVault.Name)] set to [$($newVaultStorageReplicationType.BackupStorageRedundancy)]"


# Disable soft-delete of old vault
Set-AzRecoveryServicesVaultProperty -Vault $oldRecoveryServiceVault.ID -SoftDeleteFeatureState Disable
Write-Log -Message "Soft-delete disabled for the vault $oldRecoveryServiceVault.Name"


# Rollback any soft deleted items pending for deletion from old vault
$containerSoftDelete = Get-AzRecoveryServicesBackupItem -BackupManagementType AzureVM -WorkloadType AzureVM -VaultId $oldRecoveryServiceVault.ID | Where-Object {$_.DeleteState -eq "ToBeDeleted"} #fetch backup items in soft delete state
foreach ($softitem in $containerSoftDelete)
{
    Write-Log -Message "Rolling back any soft deleted items pending for deletion from old vault [$($oldRecoveryServiceVault.Name)]"
	Undo-AzRecoveryServicesBackupItemDeletion -Item $softitem -VaultId $oldRecoveryServiceVault.ID -Force #undelete items in soft delete state
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
$restUri = 'https://management.azure.com/subscriptions/'+$SubscriptionId+'/resourcegroups/'+$ResourceGroup+'/providers/Microsoft.RecoveryServices/vaults/'+$oldRecoveryServiceVault.Name+'/backupconfig/vaultconfig?api-version=2019-05-13' #Replace "management.azure.com" with "management.usgovcloudapi.net" if your subscription is in USGov
$response = Invoke-RestMethod -Uri $restUri -Headers $authHeader -Body ($body | ConvertTo-JSON -Depth 9) -Method PATCH
Write-Log -Message "Disabled Security features for the vault [$($oldRecoveryServiceVault.Name)]"


# Fetch all protected items and servers, and force dissable & delete them
Write-Log -Message "Fetching all protected items and servers, force dissabling, deleting, and re-enabling them on the new vault."
Write-Log -Message "Please wait. This may take a while..."

$backupItemsVM = Get-AzRecoveryServicesBackupItem -BackupManagementType AzureVM -WorkloadType AzureVM -VaultId $oldRecoveryServiceVault.ID
$backupItemsSQL = Get-AzRecoveryServicesBackupItem -BackupManagementType AzureWorkload -WorkloadType MSSQL -VaultId $oldRecoveryServiceVault.ID
$backupItemsAFS = Get-AzRecoveryServicesBackupItem -BackupManagementType AzureStorage -WorkloadType AzureFiles -VaultId $oldRecoveryServiceVault.ID
$backupItemsSAP = Get-AzRecoveryServicesBackupItem -BackupManagementType AzureWorkload -WorkloadType SAPHanaDatabase -VaultId $oldRecoveryServiceVault.ID
$backupContainersSQL = Get-AzRecoveryServicesBackupContainer -ContainerType AzureVMAppContainer -Status Registered -VaultId $oldRecoveryServiceVault.ID | Where-Object {$_.ExtendedInfo.WorkloadType -eq "SQL"}
$protectableItemsSQL = Get-AzRecoveryServicesBackupProtectableItem -WorkloadType MSSQL -VaultId $oldRecoveryServiceVault.ID | Where-Object {$_.IsAutoProtected -eq $true}
$backupContainersSAP = Get-AzRecoveryServicesBackupContainer -ContainerType AzureVMAppContainer -Status Registered -VaultId $oldRecoveryServiceVault.ID | Where-Object {$_.ExtendedInfo.WorkloadType -eq "SAPHana"}
$StorageAccounts = Get-AzRecoveryServicesBackupContainer -ContainerType AzureStorage -Status Registered -VaultId $oldRecoveryServiceVault.ID
$backupServersMARS = Get-AzRecoveryServicesBackupContainer -ContainerType "Windows" -BackupManagementType MAB -VaultId $oldRecoveryServiceVault.ID
$backupServersMABS = Get-AzRecoveryServicesBackupManagementServer -VaultId $oldRecoveryServiceVault.ID| Where-Object { $_.BackupManagementType -eq "AzureBackupServer" }
$backupServersDPM = Get-AzRecoveryServicesBackupManagementServer -VaultId $oldRecoveryServiceVault.ID | Where-Object { $_.BackupManagementType-eq "SCDPM" }
$pvtendpoints = Get-AzPrivateEndpointConnection -PrivateLinkResourceId $oldRecoveryServiceVault.ID

Write-Log -Message "Disabling Azure VM backups from vault [$($oldRecoveryServiceVault.Name)] and Re-enabling on vault [$($newVault.Name)]"
foreach($item in $backupItemsVM)
    {
		$customVaultPolicy = Get-AzRecoveryServicesBackupProtectionPolicy -VaultId $oldRecoveryServiceVault.ID | Where-Object {$_.Name -eq $item.ProtectionPolicyName} 
		Write-Log -Message "Disabling Azure VM [$($item.Name)] from vault [$($oldRecoveryServiceVault.Name)] and re-enabling on vault [$($newVault.Name)]"
		Disable-AzRecoveryServicesBackupProtection -Item $item -VaultId $oldRecoveryServiceVault.ID -RemoveRecoveryPoints -Force #stop backup and delete Azure VM backup items
		Enable-AzRecoveryServicesBackupProtection -Item $item -Policy $customVaultPolicy -VaultId $newVault.ID 
    }
Write-Log -Message "Azure VM backup items disabled and deleted from vault [$($oldRecoveryServiceVault.Name)] and re-enabled on vault [$($newVault.Name)]"
Write-Host


Write-Log -Message "Disabling SQL Server backups from vault [$($oldRecoveryServiceVault.Name)] and Re-enabling on vault [$($newVault.Name)]"
foreach($item in $backupItemsSQL)
    {
		$customVaultPolicy = Get-AzRecoveryServicesBackupProtectionPolicy -VaultId $oldRecoveryServiceVault.ID | Where-Object {$_.Name -eq $item.ProtectionPolicyName} 
		Write-Log -Message "Disabling SQL Server [$($item.Name)] from vault [$($oldRecoveryServiceVault.Name)] and re-enabling on vault [$($newVault.Name)]"
		Disable-AzRecoveryServicesBackupProtection -Item $item -VaultId $oldRecoveryServiceVault.ID -RemoveRecoveryPoints -Force #stop backup and delete SQL Server in Azure VM backup items
		Enable-AzRecoveryServicesBackupProtection -Item $item -Policy $customVaultPolicy -VaultId $newVault.ID 
	}
Write-Log -Message "SQL Server backup items disabled and deleted from vault [$($oldRecoveryServiceVault.Name)] and re-enabled on vault [$($newVault.Name)]"
Write-Host


Write-Log -Message "Disabling SQL protectable items from vault [$($oldRecoveryServiceVault.Name)] and Re-enabling on vault [$($newVault.Name)]"
foreach($item in $protectableItemsSQL)
    {
		$customVaultPolicy = Get-AzRecoveryServicesBackupProtectionPolicy -VaultId $oldRecoveryServiceVault.ID | Where-Object {$_.Name -eq $item.ProtectionPolicyName} 
		Write-Log -Message "Disabling SQL protectable item [$($item.Name)] from vault [$($oldRecoveryServiceVault.Name)] and re-enabling on vault [$($newVault.Name)]"
		Disable-AzRecoveryServicesBackupAutoProtection -BackupManagementType AzureWorkload -WorkloadType MSSQL -InputItem $item -VaultId $oldRecoveryServiceVault.ID #disable auto-protection for SQL
		Enable-AzRecoveryServicesBackupProtection -Item $item -Policy $customVaultPolicy -VaultId $newVault.ID
	}
Write-Log -Message "SQL protectable items disabled and deleted from vault [$($oldRecoveryServiceVault.Name)] and re-enabled on vault [$($newVault.Name)]"
Write-Host


Write-Log -Message "Disabling SQL Servers in Azure VM containers from vault [$($oldRecoveryServiceVault.Name)] and Re-enabling on vault [$($newVault.Name)]"
foreach($item in $backupContainersSQL)
    {
		Write-Log -Message "Disabling SQL Server in Azure VM container [$($item.Name)] from vault [$($oldRecoveryServiceVault.Name)] and re-enabling on vault [$($newVault.Name)]"
		Unregister-AzRecoveryServicesBackupContainer -Container $item -Force -VaultId $oldRecoveryServiceVault.ID #unregister SQL Server in Azure VM protected server
		Register-AzRecoveryServicesBackupContainer -ResourceId $item.Id -VaultId $newVault.ID -WorkloadType $item.WorkloadType -BackupManagementType $item.BackupManagementType
    }
Write-Log -Message "SQL Server in Azure VM containers disabled and deleted from vault [$($oldRecoveryServiceVault.Name)] and re-enabled on vault [$($newVault.Name)]"
Write-Host


Write-Log -Message "Disabling SAP HANA backup items from vault [$($oldRecoveryServiceVault.Name)] and Re-enabling on vault [$($newVault.Name)]"
foreach($item in $backupItemsSAP)
    {
        $customVaultPolicy = Get-AzRecoveryServicesBackupProtectionPolicy -VaultId $oldRecoveryServiceVault.ID | Where-Object {$_.Name -eq $item.ProtectionPolicyName} 
		Write-Log -Message "Disabling SAP HANA backup item [$($item.Name)] from vault [$($oldRecoveryServiceVault.Name)] and re-enabling on vault [$($newVault.Name)]"
		Disable-AzRecoveryServicesBackupProtection -Item $item -VaultId $oldRecoveryServiceVault.ID -RemoveRecoveryPoints -Force #stop backup and delete SAP HANA in Azure VM backup items
		Enable-AzRecoveryServicesBackupProtection -Item $item -Policy $customVaultPolicy -VaultId $newVault.ID
	}
Write-Log -Message "SAP HANA backup items disabled and deleted from vault [$($oldRecoveryServiceVault.Name)] and re-enabled on vault [$($newVault.Name)]"
Write-Host


Write-Log -Message "Disabling SAP HANA in Azure VM containers from vault [$($oldRecoveryServiceVault.Name)] and Re-enabling on vault [$($newVault.Name)]"
foreach($item in $backupContainersSAP)
    {
		Write-Log -Message "Disabling SAP HANA in Azure VM container [$($item.Name)] from vault [$($oldRecoveryServiceVault.Name)] and re-enabling on vault [$($newVault.Name)]"
		Unregister-AzRecoveryServicesBackupContainer -Container $item -Force -VaultId $oldRecoveryServiceVault.ID #unregister SAP HANA in Azure VM protected server
		Register-AzRecoveryServicesBackupContainer -ResourceId $item.Id -VaultId $newVault.ID -WorkloadType $item.WorkloadType -BackupManagementType $item.BackupManagementType

    }
Write-Log -Message "SAP HANA in Azure VM containers disabled and deleted from vault [$($oldRecoveryServiceVault.Name)] and re-enabled on vault [$($newVault.Name)]"
Write-Host


Write-Log -Message "Disabling Azure File Share backups from vault [$($oldRecoveryServiceVault.Name)] and Re-enabling on vault [$($newVault.Name)]"
foreach($item in $backupItemsAFS)
    {
		$customVaultPolicy = Get-AzRecoveryServicesBackupProtectionPolicy -VaultId $oldRecoveryServiceVault.ID | Where-Object {$_.Name -eq $item.ProtectionPolicyName} 
		Write-Log -Message "Disabling Azure File Share backup [$($item.Name)] from vault [$($oldRecoveryServiceVault.Name)] and re-enabling on vault [$($newVault.Name)]"
		Disable-AzRecoveryServicesBackupProtection -Item $item -VaultId $oldRecoveryServiceVault.ID -RemoveRecoveryPoints -Force #stop backup and delete Azure File Shares backup items
		Enable-AzRecoveryServicesBackupProtection -Item $item -Policy $customVaultPolicy -VaultId $newVault.ID
	}
Write-Log -Message "Azure File Share backups disabled and deleted from vault [$($oldRecoveryServiceVault.Name)] and re-enabled on vault [$($newVault.Name)]"
Write-Host


Write-Log -Message "Disabling Storage Accounts registerd in vault [$($oldRecoveryServiceVault.Name)] and Re-enabling on vault [$($newVault.Name)]"
foreach($item in $StorageAccounts)
    {
		Write-Log -Message "Disabling Storage Account register [$($item.Name)] from vault [$($oldRecoveryServiceVault.Name)] and re-enabling on vault [$($newVault.Name)]"
		Unregister-AzRecoveryServicesBackupContainer -container $item -Force -VaultId $oldRecoveryServiceVault.ID #unregister storage accounts
		Register-AzRecoveryServicesBackupContainer -ResourceId $item.Id -VaultId $newVault.ID -WorkloadType $item.WorkloadType -BackupManagementType $item.BackupManagementType
    }
Write-Log -Message "Storage Accounts unregistered on vault [$($oldRecoveryServiceVault.Name)] and registered on vault [$($newVault.Name)]"
Write-Host


Write-Log -Message "Deleting MARS Servers on vault [$($oldRecoveryServiceVault.Name)] and Re-enabling on vault [$($newVault.Name)]"
foreach($item in $backupServersMARS)
    {
		Write-Log -Message "Deleting MARS Server [$($item.Name)] from vault [$($oldRecoveryServiceVault.Name)] and re-enabling on vault [$($newVault.Name)]"
		Unregister-AzRecoveryServicesBackupContainer -Container $item -Force -VaultId $oldRecoveryServiceVault.ID #unregister MARS servers and delete corresponding backup items
		Register-AzRecoveryServicesBackupContainer -ResourceId $item.Id -VaultId $newVault.ID -WorkloadType $item.WorkloadType -BackupManagementType $item.BackupManagementType
	}
Write-Log "Deleted MARS Servers on vault [$($oldRecoveryServiceVault.Name)] and registered on vault [$($newVault.Name)]"
Write-Host


Write-Log -Message "Deleting MAB Servers on vault [$($oldRecoveryServiceVault.Name)] and Re-enabling on vault [$($newVault.Name)]"
foreach($item in $backupServersMABS)
    {
		Write-Log -Message "Disabling SAP HANA backup item [$($item.Name)] from vault [$($oldRecoveryServiceVault.Name)] and re-enabling on vault [$($newVault.Name)]"
		Unregister-AzRecoveryServicesBackupManagementServer -AzureRmBackupManagementServer $item -VaultId $oldRecoveryServiceVault.ID #unregister MABS servers and delete corresponding backup items
		Register-AzRecoveryServicesBackupContainer -ResourceId $item.Id -VaultId $newVault.ID -WorkloadType $item.WorkloadType -BackupManagementType $item.BackupManagementType
	}
Write-Log "Deleted MAB Servers on vault [$($oldRecoveryServiceVault.Name)] and registered on vault [$($newVault.Name)]"
Write-Host


Write-Log -Message "Deleting DPM Servers on vault [$($oldRecoveryServiceVault.Name)] and Re-enabling on vault [$($newVault.Name)]"
foreach($item in $backupServersDPM)
    {
		Write-Log -Message "Deleting DPM Server [$($item.Name)] from vault [$($oldRecoveryServiceVault.Name)] and re-enabling on vault [$($newVault.Name)]"
		Unregister-AzRecoveryServicesBackupManagementServer -AzureRmBackupManagementServer $item -VaultId $oldRecoveryServiceVault.ID #unregister DPM servers and delete corresponding backup items
		Register-AzRecoveryServicesBackupContainer -ResourceId $item.Id -VaultId $newVault.ID -WorkloadType $item.WorkloadType -BackupManagementType $item.BackupManagementType
	}
Write-Log -Message "Deleted DPM Servers on vault [$($oldRecoveryServiceVault.Name)] and registered on vault [$($newVault.Name)]"
Write-Log -Message "Ensure that you stop protection and delete backup items from the respective MARS, MAB and DPM consoles as well. Visit https://go.microsoft.com/fwlink/?linkid=2186234 to learn more."


# Deletion of ASR Items
Set-AzRecoveryServicesAsrVaultContext -Vault $oldRecoveryServiceVault
$fabricObjects = Get-AzRecoveryServicesAsrFabric
if ($null -ne $fabricObjects) {
	# First DisableDR all VMs.
	foreach ($fabricObject in $fabricObjects) {
		$containerObjects = Get-AzRecoveryServicesAsrProtectionContainer -Fabric $fabricObject
		foreach ($containerObject in $containerObjects) {
			$protectedItems = Get-AzRecoveryServicesAsrReplicationProtectedItem -ProtectionContainer $containerObject
			# DisableDR all protected items
			foreach ($protectedItem in $protectedItems) {
				Write-Log -Message "Triggering DisableDR(Purge) for item:" $protectedItem.Name
				Remove-AzRecoveryServicesAsrReplicationProtectedItem -InputObject $protectedItem -Force
				Write-Log -Message "DisableDR(Purge) completed"
			}

			$containerMappings = Get-AzRecoveryServicesAsrProtectionContainerMapping -ProtectionContainer $containerObject
			# Remove all Container Mappings
			foreach ($containerMapping in $containerMappings) {
				Write-Log "Triggering Remove Container Mapping: " $containerMapping.Name
				Remove-AzRecoveryServicesAsrProtectionContainerMapping -ProtectionContainerMapping $containerMapping -Force
				Write-Log "Removed Container Mapping."
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
		Write-Log "Triggering Remove Fabric:" $fabricObject.FriendlyName
		Remove-AzRecoveryServicesAsrFabric -InputObject $fabricObject -Force
		Write-Log "Removed Fabric."
	}
}
Write-Log "Warning: This script will only remove the replication configuration from Azure Site Recovery and not from the source. Please cleanup the source manually. Visit https://go.microsoft.com/fwlink/?linkid=2182781 to learn more."
foreach($item in $pvtendpoints)
	{
		$penamesplit = $item.Name.Split(".")
		$pename = $penamesplit[0]
		Remove-AzPrivateEndpointConnection -ResourceId $item.PrivateEndpoint.Id -Force #remove private endpoint connections
		Remove-AzPrivateEndpoint -Name $pename -ResourceGroupName $ResourceGroup -Force #remove private endpoints
	}
Write-Log "Removed Private Endpoints"


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
$backupItemsVMFin = Get-AzRecoveryServicesBackupItem -BackupManagementType AzureVM -WorkloadType AzureVM -VaultId $oldRecoveryServiceVault.ID
$backupItemsSQLFin = Get-AzRecoveryServicesBackupItem -BackupManagementType AzureWorkload -WorkloadType MSSQL -VaultId $oldRecoveryServiceVault.ID
$backupContainersSQLFin = Get-AzRecoveryServicesBackupContainer -ContainerType AzureVMAppContainer -Status Registered -VaultId $oldRecoveryServiceVault.ID | Where-Object {$_.ExtendedInfo.WorkloadType -eq "SQL"}
$protectableItemsSQLFin = Get-AzRecoveryServicesBackupProtectableItem -WorkloadType MSSQL -VaultId $oldRecoveryServiceVault.ID | Where-Object {$_.IsAutoProtected -eq $true}
$backupItemsSAPFin = Get-AzRecoveryServicesBackupItem -BackupManagementType AzureWorkload -WorkloadType SAPHanaDatabase -VaultId $oldRecoveryServiceVault.ID
$backupContainersSAPFin = Get-AzRecoveryServicesBackupContainer -ContainerType AzureVMAppContainer -Status Registered -VaultId $oldRecoveryServiceVault.ID | Where-Object {$_.ExtendedInfo.WorkloadType -eq "SAPHana"}
$backupItemsAFSFin = Get-AzRecoveryServicesBackupItem -BackupManagementType AzureStorage -WorkloadType AzureFiles -VaultId $oldRecoveryServiceVault.ID
$StorageAccountsFin = Get-AzRecoveryServicesBackupContainer -ContainerType AzureStorage -Status Registered -VaultId $oldRecoveryServiceVault.ID
$backupServersMARSFin = Get-AzRecoveryServicesBackupContainer -ContainerType "Windows" -BackupManagementType MAB -VaultId $oldRecoveryServiceVault.ID
$backupServersMABSFin = Get-AzRecoveryServicesBackupManagementServer -VaultId $oldRecoveryServiceVault.ID| Where-Object { $_.BackupManagementType -eq "AzureBackupServer" }
$backupServersDPMFin = Get-AzRecoveryServicesBackupManagementServer -VaultId $oldRecoveryServiceVault.ID | Where-Object { $_.BackupManagementType-eq "SCDPM" }
$pvtendpointsFin = Get-AzPrivateEndpointConnection -PrivateLinkResourceId $oldRecoveryServiceVault.ID

# Display items which are still present in the vault and might be preventing vault deletion.
if($backupItemsVMFin.count -ne 0) {Write-Log "[$($backupItemsVMFin.count)] Azure VM backups are still present in the vault. Remove the same for successful vault deletion." }
if($backupItemsSQLFin.count -ne 0) {Write-Log "[$($backupItemsSQLFin.count)] SQL Server Backup Items are still present in the vault. Remove the same for successful vault deletion." }
if($backupContainersSQLFin.count -ne 0) {Write-Log "[$($backupContainersSQLFin.count)] SQL Server Backup Containers are still registered to the vault. Remove the same for successful vault deletion." }
if($protectableItemsSQLFin.count -ne 0) {Write-Log "[$($protectableItemsSQLFin.count)] SQL Server Instances are still present in the vault. Remove the same for successful vault deletion." }
if($backupItemsSAPFin.count -ne 0) {Write-Log "[$($backupItemsSAPFin.count)] SAP HANA Backup Items are still present in the vault. Remove the same for successful vault deletion." }
if($backupContainersSAPFin.count -ne 0) {Write-Log "[$($backupContainersSAPFin.count)] SAP HANA Backup Containers are still registered to the vault. Remove the same for successful vault deletion." }
if($backupItemsAFSFin.count -ne 0) {Write-Log "[$($backupItemsAFSFin.count)] Azure File Shares are still present in the vault. Remove the same for successful vault deletion." }
if($StorageAccountsFin.count -ne 0) {Write-Log "[$($StorageAccountsFin.count)] Storage Accounts are still registered to the vault. Remove the same for successful vault deletion." }
if($backupServersMARSFin.count -ne 0) {Write-Log "[$($backupServersMARSFin.count)] MARS Servers are still registered to the vault. Remove the same for successful vault deletion." }
if($backupServersMABSFin.count -ne 0) {Write-Log "[$($backupServersMABSFin.count)] MAB Servers are still registered to the vault. Remove the same for successful vault deletion." }
if($backupServersDPMFin.count -ne 0) {Write-Log "[$($backupServersDPMFin.count)] DPM Servers are still registered to the vault. Remove the same for successful vault deletion." }
if($ASRProtectedItems -ne 0) {Write-Log "[$($ASRProtectedItems)] ASR protected items are still present in the vault. Remove the same for successful vault deletion." }
if($ASRPolicyMappings -ne 0) {Write-Log "[$($ASRPolicyMappings)] ASR policy mappings are still present in the vault. Remove the same for successful vault deletion." }
if($fabricCount -ne 0) {Write-Log "[$($fabricCount)] ASR Fabrics are still present in the vault. Remove the same for successful vault deletion." }
if($pvtendpointsFin.count -ne 0) {Write-Log "[$($pvtendpointsFin.count)] Private endpoints are still linked to the vault. Remove the same for successful vault deletion." }


# Attempt to delete the old Vault
$Error.Clear()
try {
	Write-Log -Message "Deleting old Recovery Services Vault [$($oldRecoveryServiceVault.Name)]"
	Remove-AzRecoveryServicesVault -Vault $oldRecoveryServiceVault
}
catch {
	Write-Verbose -Message "$($oldRecoveryServiceVault.Name) Recovery Services Vault could not be deleted"
	Write-Host -ForegroundColor Red "[ERROR] Error deleting Recovery Services Vault [$($oldRecoveryServiceVault.Name)]"
	Write-Log -Message "Error deleting old Recovery Services Vault [$($oldRecoveryServiceVault.Name)]" -OnlyLog
	Write-Log -Message $_.Exception.Message
	Write-Log -Message $_.Exception -OnlyLog
	Exit
}

Write-Log -Message "$($oldRecoveryServiceVault.Name) Recovery Services Vault has been deleted."
Write-Log -Message "Operation completed successfully!"	

# Done!
