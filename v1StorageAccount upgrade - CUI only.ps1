# Upgrade Storage Accounts v1 to v2 script


# Input Variables
$StorageAccounts = @() #StorageAccount array


# Set preferences
$ErrorActionPreference = "Stop"
$VerbosePreference = "SilentlyContinue"


# Import Modules
Import-Module -Name Az.Accounts
Import-Module -Name Az.Storage


# Set Prefrences
$VerbosePreference = "Continue"

# --- Start ---
# 1. Connect to Azure

try {
    Connect-AzAccount
    }

catch {
    Write-Output "Error connecting to Azure"
    Write-Output $_.Exception.message
    }


# 2. Allow user selection of Subscription for v1 StorageAccount search

Write-Verbose -Message "Getting list of Subscriptions"

$VerbosePreference = "SilentlyContinue"
$subscriptions = Get-AzSubscription | Out-ConsoleGridView -Title "Select Subscriptions to search for v1 StorageAccounts" 
$VerbosePreference = "Continue"


# 3. Cycle through all Azure subscriptions and display the storage accounts.
try {

    foreach ($subscription in $subscriptions) {

        # Set Context to subscription
        Write-Verbose -Message "Searching in Subscription: $($subscription.Name) - ID: ($($subscription.id)) "
        Set-AzContext -Subscription $subscription.Id | Format-List
                
        # Search for all StorageAccounts within the selected subscriptions
        $StorageAccounts += @(Get-AzStorageAccount)  
                      
    }
}
catch {
    
    # Catch anything that went wrong
    Write-Error -Message $_.Exception
    throw $_.Exception

}

# 4. Display list of queried subscriptions
Write-Verbose -Message "Queried Subscriptions for v1 StorageAccounts"
$subscriptions | Format-Table

# 5. Purge StorageAccounts to only keep v1 StoreAccounts
# 6. User selects which accounts to convert to v2
Write-verbose -Message "v1 Storage Accounts"

$VerbosePreference = "SilentlyContinue"
$StorageAccounts = $StorageAccounts | Where-Object -Property Kind -EQ "Storage" | Out-ConsoleGridView -Title "Select v1 Storage Accounts to upgrade"
$VerbosePreference = "Continue"


# 7. Converting v1 StorageAccounts to v2
Write-Verbose -Message "Converting $($StorageAccounts.Count) v1 StorageAccounts to v2"
foreach ($StorageAccount in $StorageAccounts) {
    Set-AzStorageAccount -ResourceGroupName $StorageAccount.ResourceGroupName -Name $StorageAccount.StorageAccountName -UpgradeToStorageV2
}

# 8. Display final operation results
Write-Verbose -Message "Operation completed"
