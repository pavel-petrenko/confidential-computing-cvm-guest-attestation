﻿<#
.SYNOPSIS
 This script can be used to turn on data disk encryption one for an existing Azure Linux confidential VM.
 Usage: Open this script file in "Windows PowerShell ISE", or use CloudShell in Azure portal. Review and update each "Step". Afterwards, highlight the section and hit F8 to run in ISE or copy and paste into cloud shell.

 Requirements: 1-) The confidential VM is already created with confidential OS disk encryption on.
               2-) One or more data disks are attached and partitioned. The data volumes are formatted as ext4 or xfs.
               3-) A Customer Managed Key (RSA 3072 bits) is created in AKV or mHSM with the modified SKR policy.
               4-) A user assigned managed identity (UAI) is created and granted Get,Release permissions on the RSA key.

 Status: This script is for private preview. Do not use in Production.
#>

#### Step 0: Make sure your Az powershell modules are up-to-date.

if ((Get-Module Az.Compute).Version.Major -lt 6)
{
    Update-Module -Name Az* -Force                                          # Requires elevated (admin) Powershell window
}

#### End of step 0



#### Step 1 - Set the global parameters which will be used throughout the script.

$subscriptionId    = "__SUB_ID_HERE__"                                      # User must have at least contributor access.
$inCloudShell      = if ($env:AZD_IN_CLOUDSHELL) { $true } else { $false }  # Determine if running in CloudShell.
$resourceGroup     = "__RG_HERE__"                                          # Resource group
$cvmName           = "__CVM_NAME_HERE__"                                    # CVM must have been created beforehand. Follow https://learn.microsoft.com/en-us/azure/confidential-computing/quick-create-confidential-vm-portal-amd
$location          = "__REGION_HERE__"                                      # Azure region where the CVM is created.
$kvName            = "__AKV_NAME_HERE__"                                    # Azure KeyVault name. It must exists
$rsaKeyName        = "__RSA_KEY_NAME_HERE__"                                # RSA key will be created and associated with an SKR policy for DDE.
# The SKR policy is slightly modified version for DDE. Copy it to your cloud shell or local drive and update path.
$skrPolicyFile     = if ($inCloudShell) { "public_SKR_policy-datadisk.json" } else { "C:\Temp\cvm\public_SKR_policy-datadisk.json" }
$uaManagedIdentity = "__MANAGED_ID_NAME_HERE__"                             # The user assigned managed identity must be created and granted Get,Release permissions in AKV. Paste here the ARM resource id, or client_id=<GUID>, or object_id=<GUID< format.

#### End of step 1



#### Step 2- Login to Azure and set context to the subscription

Login-AzAccount -Subscription $subscriptionId
Select-AzSubscription -SubscriptionId $subscriptionId

#### End of step 2



#### Step 3- Assign the Managed identity to the CVM

$userAssignedMI = Get-AzUserAssignedIdentity -Name $uaManagedIdentity -ResourceGroupName $resourceGroup

$vm = Get-AzVM -Name $cvmName -ResourceGroupName $resourceGroup
Update-AzVM -VM $vm -ResourceGroupName $resourceGroup -IdentityType UserAssigned -IdentityId $userAssignedMI.Id

#### End of step 3.

#### Step 4 - Create a Key Encryption Key in Azure Key Vault and assign permissions.

Add-AzKeyVaultKey -VaultName $kvName -Name $rsaKeyName -Destination HSM -KeyType RSA -Size 3072 -KeyOps wrapKey,unwrapKey -Exportable -ReleasePolicyPath $skrPolicyFile
# Assign Get,Release permissions on the CMK to the User assigned MI.
Set-AzKeyVaultAccessPolicy -VaultName $kvName -ResourceGroupName $resourceGroup -ObjectId $userAssignedMI.PrincipalId -PermissionsToKeys get,release

#### End of step 4

#### Step 5 - Install ADE with public settings defined below.

$keyvault = Get-AzKeyVault -VaultName $kvName -ResourceGroupName $resourceGroup
$rsaKey = Get-AzKeyVaultKey -VaultName $kvName -Name $rsaKeyName

# ADE settings:
$KV_URL                      = $keyvault.VaultUri
$KV_RID                      = $keyvault.ResourceId
$KEK_URL                     = $rsaKey.Id
$EncryptionManagedIdentity   = "EncryptionManagedIdentity";
$KV_UAI_RID                  = $userAssignedMI.Id

$Publisher                   = "Microsoft.Azure.Security"
$ExtName                     = "AzureDiskEncryptionForLinux"
$ExtHandlerVer               = "1.4"
$EncryptionOperation         = "EnableEncryption"
$PrivatePreviewFlag_DataDisk = "PrivatePreview.ConfidentialEncryptionDataDisk"

# Settings for enabling temp disk encryption only providing Azure Key Vault resource.
# Note: Key names in PublicSetting are case sensitive. Do not change the case.
$pubSettings = @{};
$pubSettings.Add("KeyVaultURL", $KV_URL)
$pubSettings.Add("KeyVaultResourceId", $KV_RID)
$pubSettings.Add("KeyEncryptionKeyURL", $KEK_URL)
$pubSettings.Add("KekVaultResourceId", $KV_RID)
$pubSettings.Add("KeyEncryptionAlgorithm", "RSA-OAEP")
$pubSettings.Add($EncryptionManagedIdentity, $KV_UAI_RID)
$pubSettings.Add("VolumeType", "Data")
$pubSettings.Add("EncryptionOperation", $EncryptionOperation)

# Settings for enabling temp disk encryption only providing Azure managed HSM (mHSM) resource. For more info, see https://learn.microsoft.com/en-us/azure/key-vault/managed-hsm/overview
#$pubsettings                                  = @{};
#$pubSettings.Add("KekVaultResourceId",        "__AZURE_MHSM_RESOURCE_ID_HERE__")
#$pubSettings.Add("KeyEncryptionKeyURL",       "__AZURE_KEK_URL_HERE__")
#$pubsettings.Add("EncryptionManagedIdentity", "__AZURE_USER_ASSIGNED_MANAGED_IDENTITY_RESOURCE_ID_HERE")  # Asign "Managed HSM Crypto User" role on key in local RBAC for SKR. (Either)
#$pubsettings.Add("EncryptionManagedIdentity", "client_id=__CLIENT_ID_OF_MSI_HERE")                        # Asign "Managed HSM Crypto User" role on key in local RBAC for SKR. (Or)
#$pubSettings.Add("VolumeType",                "Data")
#$pubsettings.Add("KeyStoreType",              "ManagedHSM")
#$pubsettings.Add("EncryptionOperation",       $EncryptionOperation)
#$pubSettings.Add("KeyEncryptionAlgorithm",    "RSA-OAEP")

#this feature is in private preview, So to set the below flag to enable data disk encryption feature.
$pubSettings.Add($PrivatePreviewFlag_DataDisk, "true")

Set-AzVMExtension `
    -ResourceGroupName $resourceGroup `
    -VMName $cvmName `
    -Publisher $Publisher `
    -ExtensionType $ExtName `
    -TypeHandlerVersion $ExtHandlerVer `
    -Name $ExtName `
    -EnableAutomaticUpgrade $false `
    -Settings $pubSettings `
    -Location $location

# Verify: switch to the portal and verify that the extension provision is succeded.
Write-Host "Waiting 2 minutes for extension status update"
Start-Sleep 120
$status = Get-AzVMExtension -ResourceGroupName $resourceGroup -VMName $cvmName -Name $ExtName
$status
$status.SubStatuses

#### End of step 5.

Write-Host "Script ended"