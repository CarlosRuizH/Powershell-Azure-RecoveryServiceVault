# Creat multiple dummy v1 StorageAccount


# Input Variables
$StorageAccounts = @() #StorageAccount array
$StorageKinds = @('Storage','StorageV2','BlobStorage')
$NumberofStorageAccounts = 15
$TestRGName = "test_" + (-join ((48..57) + (97..122) | Get-Random -Count 20 | % {[char]$_}))
$TestRGLocation = "eastus"


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


# 2. Allow user selection of Subcription for TEST StorageAccount creation

Write-Verbose -Message "Getting list of Subscriptions"
$subscription = Get-AzSubscription | Out-GridView  -Title "Select Subscription" -OutputMode Single


# Set Context to the selected subscription
Write-Verbose -Message "Setting the scope to Subscription: $($subscription.Name) - ID: ($($subscription.id)) "
Set-AzContext -Subscription $subscription.Id | Format-List

# 3. Create TEST ResourceGroup
New-AzResourceGroup -Name $TestRGName -Location $TestRGLocation


# 4. Create Random storage accounts in the selected subscription

for ($i = 1; $i -lt $NumberofStorageAccounts+1; $i++) {
    
    # Random names for StorageAccounts and Kinds
    $TestStorageAccount = "test" + (-join ((48..57) + (97..122) | Get-Random -Count 20 | % {[char]$_}))
    $AccountKind = Get-Random $StorageKinds
    
    # Create a randomly named StorageAccount of random type
    Write-Verbose -Message "#$($i) Creating the $AccountKind test StorageAccount: $TestStorageAccount"

    if ($AccountKind -eq 'BlobStorage') {
        New-AzStorageAccount -ResourceGroupName $TestRGName -Name $TestStorageAccount -Location $TestRGLocation -SkuName Standard_LRS -Kind $AccountKind -AccessTier Hot -AsJob | Format-List
    }
    else {
        New-AzStorageAccount -ResourceGroupName $TestRGName -Name $TestStorageAccount -Location $TestRGLocation -SkuName Standard_LRS -Kind $AccountKind -AsJob | Format-List
    }
}
Write-Verbose -Message "List of StorageAccounts created"
Get-AzStorageAccount -ResourceGroupName $TestRGName
Write-Verbose -Message "Operation Completed."