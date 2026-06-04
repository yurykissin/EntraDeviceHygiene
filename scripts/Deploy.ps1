# End-to-end deployment helper for the Entra Device Hygiene Logic App.
#
# Prereqs (verify with Test-Prerequisites.ps1):
#   - Azure CLI logged in:  az login
#   - Permissions to deploy to the target subscription
#
# What it does:
#   1. Selects the subscription and ensures the resource group exists
#   2. Deploys the ARM template, overriding reviewGroupObjectId if supplied
#   3. Prints the deployment outputs and the next-step command for granting Graph permissions

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$ResourceGroupName,
    [Parameter(Mandatory)] [string]$SubscriptionId,
    [Parameter(Mandatory)] [string]$EmailFromUpn,
    [Parameter(Mandatory)] [string]$EmailToRecipients,
    [string]$Location           = 'westeurope',
    [string]$TemplateFile       = (Join-Path $PSScriptRoot '..' 'arm' 'azuredeploy.json'),
    [string]$ParametersFile     = (Join-Path $PSScriptRoot '..' 'arm' 'azuredeploy.parameters.json'),
    [int]$StaleThresholdDays,
    [int]$DisabledDeletionThresholdDays,
    [Nullable[bool]]$DryRun
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw "Azure CLI not found. Install it and run 'az login'."
}

# Ensure logged in
$account = az account show --output json 2>$null | ConvertFrom-Json
if (-not $account) { throw "Not signed in. Run 'az login' first." }

Write-Host "Setting subscription: $SubscriptionId" -ForegroundColor Cyan
az account set --subscription $SubscriptionId | Out-Null

Write-Host "Ensuring resource group '$ResourceGroupName' in $Location" -ForegroundColor Cyan
az group create --name $ResourceGroupName --location $Location --output none

# Build az args; append override only when supplied so we don't shadow the parameters file with empty values
$azArgs = @(
    'deployment','group','create',
    '--resource-group', $ResourceGroupName,
    '--template-file',  $TemplateFile,
    '--parameters',     "@$ParametersFile"
)
$overrides = @(
    "emailFromUpn=$EmailFromUpn",
    "emailToRecipients=$EmailToRecipients"
)
if ($PSBoundParameters.ContainsKey('StaleThresholdDays'))            { $overrides += "staleThresholdDays=$StaleThresholdDays" }
if ($PSBoundParameters.ContainsKey('DisabledDeletionThresholdDays')) { $overrides += "disabledDeletionThresholdDays=$DisabledDeletionThresholdDays" }
if ($PSBoundParameters.ContainsKey('DryRun'))                        { $overrides += ("dryRun={0}" -f $DryRun.ToString().ToLower()) }

$azArgs += @('--parameters') + $overrides
$azArgs += @('--query', 'properties.outputs', '--output', 'json')

Write-Host "Deploying ARM template..." -ForegroundColor Cyan
$json = az @azArgs
if ($LASTEXITCODE -ne 0) { throw "az deployment failed (exit $LASTEXITCODE)." }

$outputs = $json | ConvertFrom-Json

Write-Host ""
Write-Host "Deployment outputs:" -ForegroundColor Green
$outputs | Format-List

$principalId = $outputs.managedIdentityPrincipalId.value
if ($principalId) {
    Write-Host ""
    Write-Host "Logic App MI principalId: $principalId" -ForegroundColor Cyan
    Write-Host "Graph application roles (Device.ReadWrite.All, Mail.Send) were granted as part of this deployment." -ForegroundColor Green
    Write-Host ""
    Write-Host "Force a managed-identity token refresh (tokens cache up to ~24h):" -ForegroundColor Cyan
    Write-Host "  az logic workflow update -g $ResourceGroupName -n la-entra-device-hygiene --state Disabled"
    Write-Host "  az logic workflow update -g $ResourceGroupName -n la-entra-device-hygiene --state Enabled"
}
