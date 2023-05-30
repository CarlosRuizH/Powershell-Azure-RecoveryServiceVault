# Powershell-Azure-RecoveryServiceVault

PowerShell tools:
* Help move and remove Recovery Service Vaults
* Delete a Recovery Service Vault
* Migrate Backup Items from one Recovery Service Vault to a new LRS RSV
* Console-UI version of tools (CUI)


## [DeleteAnyRecoveryServicesVault.ps1]
The PowerShell script is used to convert a Recovery Services Vault Backup Property from Geo-Redundant Storage (GRS) to Locally Redundant Storage (LRS) in Microsoft Azure. However, it's important to note that running this script will delete all backup data within the vault, so caution should be exercised.

Here's a summary of what the script does:

1. It connects to Azure using the Azure PowerShell module.
2. It prompts the user to select the subscriptions to search for Recovery Service Vaults.
3. It searches for Recovery Service Vaults in the selected subscriptions.
4. It displays a list of the queried subscriptions.
5. It prompts the user to select the Recovery Service Vault to convert to LRS.
6. It prepares variables for the selected vault.
7. It sets the context to the selected Recovery Service Vault for deletion.
8. It disables soft-delete for the vault.
9. It rolls back any soft-deleted items pending for deletion.
10. It invokes an API to disable security features (Enhanced Security) and remove MARS/MAB/DPM servers.
11. It fetches all protected items and servers, disables and deletes them.
12. It deletes ASR (Azure Site Recovery) items and related configurations.
13. It rechecks the presence of ASR items and backup items in the vault.
14. The script ends.

The script makes use of various Azure PowerShell cmdlets to perform these actions. It's important to review and understand the script before running it, as it involves destructive operations that can result in the permanent deletion of backup data.


## [MoveProtectedItemstoNewLRSVault.ps1]
This PowerShell script is designed to move all protected items and servers from an existing Recovery Service Vault (RSV) to a new Locally Redundant Storage (LRS) Recovery Service Vault, and then delete the old vault. It performs the following steps:

1. It searches for all Recovery Service Vaults (RSVs) in one or multiple subscriptions.
2. The user is prompted to select a specific RSV to migrate and delete.
3. It creates a new RSV with the name "[old-vault-name]-LRS" in the same region and resource group as the selected vault.
4. It changes the storage replication type of the new RSV to Locally Redundant.
5. It copies all custom policies from the old RSV to the new RSV-LRS.
6. It disables soft-delete protection and deletes all backup items from the old RSV.
7. It re-enables protection for all types of backup items in the new RSV-LRS.
8. It deletes the old RSV.

The script requires the Windows platform for the "out-GridView" cmdlet support. Before running the script, it displays a warning to ensure that PowerShell 7 is installed and the latest Az module is upgraded.


## [MoveProtectedItemstoNewLRSVault-CUI.ps1]
This PowerShell script works without the out-GridView cmdlet and uses console-only output
