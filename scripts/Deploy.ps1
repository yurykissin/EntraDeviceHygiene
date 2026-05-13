# End-to-end deployment helper.

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$ResourceGroupName,
    [Parameter(Mandatory)] [string]$SubscriptionId,
    [string]$Location = 'westeurope',
    [string]$TemplateFile      = (Join-Path $PSScriptRoot '..\arm\azuredeploy.json'),
    [string]$ParametersFile    = (Join-Path $PSScriptRoot '..\arm\azuredeploy.parameters.json'),
    [string]$ReviewGroupObjectId
)

$ErrorActionPreference = 'Stop'

az account set --subscription $SubscriptionId | Out-Null
az group create -n $ResourceGroupName -l $Location | Out-Null

$extra = @()
if ($ReviewGroupObjectId) { $extra += "reviewGroupObjectId=$ReviewGroupObjectId" }

$result = az deployment group create `
    --resource-group $ResourceGroupName `
    --template-file  $TemplateFile `
    --parameters     "@$ParametersFile" `
    @( if ($extra) { @('--parameters') + $extra } ) `
    --query 'properties.outputs' -o json | ConvertFrom-Json

Write-Host "Deployment outputs:" -ForegroundColor Green
$result | Format-List

if ($result.managedIdentityPrincipalId.value) {
    Write-Host ""
    Write-Host "Now grant Graph permissions:" -ForegroundColor Cyan
    Write-Host "  ./Grant-GraphPermissions.ps1 -ManagedIdentityPrincipalId $($result.managedIdentityPrincipalId.value)"
}
