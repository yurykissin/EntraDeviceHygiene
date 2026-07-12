# End-to-end deployment helper for the Entra Device Hygiene Logic App.
#
# Prereqs (verify with Test-Prerequisites.ps1):
#   - Azure CLI logged in:  az login
#   - Permissions to deploy to the target subscription
#
# What it does:
#   1. Selects the subscription and ensures the resource group exists
#   2. Deploys the ARM template (managed-identity variant by default, or app-registration
#      variant if -AuthMode AppRegistration is passed with -GraphClientId + -GraphClientSecret)
#   3. Prints the deployment outputs and post-deploy next steps

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$ResourceGroupName,
    [Parameter(Mandatory)] [string]$SubscriptionId,
    [Parameter(Mandatory)] [string]$EmailFromUpn,
    [Parameter(Mandatory)] [string]$EmailToRecipients,
    [string]$Location           = 'westeurope',
    [ValidateSet('ManagedIdentity','AppRegistration')]
    [string]$AuthMode           = 'ManagedIdentity',
    [string]$TemplateFile,
    [string]$ParametersFile     = (Join-Path $PSScriptRoot '..' 'arm' 'azuredeploy.parameters.json'),
    [int]$StaleThresholdDays,
    [int]$DisabledDeletionThresholdDays,
    [Nullable[bool]]$DryRun,
    [string]$GraphTenantId,
    [string]$GraphClientId,
    [securestring]$GraphClientSecret
)

$ErrorActionPreference = 'Stop'

if (-not $TemplateFile) {
    $TemplateFile = if ($AuthMode -eq 'AppRegistration') {
        Join-Path $PSScriptRoot '..' 'arm' 'azuredeploy-appreg.json'
    } else {
        Join-Path $PSScriptRoot '..' 'arm' 'azuredeploy.json'
    }
}

if ($AuthMode -eq 'AppRegistration') {
    if (-not $GraphClientId)     { throw "-GraphClientId is required when -AuthMode AppRegistration." }
    if (-not $GraphClientSecret) { throw "-GraphClientSecret is required when -AuthMode AppRegistration." }
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw "Azure CLI not found. Install it and run 'az login'."
}

$account = az account show --output json 2>$null | ConvertFrom-Json
if (-not $account) { throw "Not signed in. Run 'az login' first." }

Write-Host "Setting subscription: $SubscriptionId" -ForegroundColor Cyan
az account set --subscription $SubscriptionId | Out-Null

Write-Host "Ensuring resource group '$ResourceGroupName' in $Location" -ForegroundColor Cyan
az group create --name $ResourceGroupName --location $Location --output none

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

if ($AuthMode -eq 'AppRegistration') {
    if ($GraphTenantId) { $overrides += "graphTenantId=$GraphTenantId" }
    $overrides += "graphClientId=$GraphClientId"
    $plain = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [Runtime.InteropServices.Marshal]::SecureStringToBSTR($GraphClientSecret))
    $overrides += "graphClientSecret=$plain"
}

$azArgs += @('--parameters') + $overrides
$azArgs += @('--query', 'properties.outputs', '--output', 'json')

Write-Host "Deploying ARM template ($AuthMode variant): $TemplateFile" -ForegroundColor Cyan
$json = az @azArgs
if ($LASTEXITCODE -ne 0) { throw "az deployment failed (exit $LASTEXITCODE)." }

$outputs = $json | ConvertFrom-Json

Write-Host ""
Write-Host "Deployment outputs:" -ForegroundColor Green
$outputs | Format-List

if ($AuthMode -eq 'ManagedIdentity') {
    $principalId = $outputs.managedIdentityPrincipalId.value
    Write-Host ""
    Write-Host "Logic App MI principalId: $principalId" -ForegroundColor Cyan
    Write-Host "NEXT STEP: grant Graph app roles to the MI." -ForegroundColor Yellow
    Write-Host "  ./scripts/Grant-GraphPermissions.ps1 -LogicAppName la-entra-device-hygiene -ResourceGroupName $ResourceGroupName"
    Write-Host "  ./scripts/Test-GraphPermissions.ps1  -LogicAppName la-entra-device-hygiene -ResourceGroupName $ResourceGroupName"
    Write-Host ""
    Write-Host "Then force a managed-identity token refresh (tokens cache up to ~24h):" -ForegroundColor Cyan
    Write-Host "  az logic workflow update -g $ResourceGroupName -n la-entra-device-hygiene --state Disabled"
    Write-Host "  az logic workflow update -g $ResourceGroupName -n la-entra-device-hygiene --state Enabled"
} else {
    Write-Host ""
    Write-Host "App-registration mode. Ensure Device.ReadWrite.All + Mail.Send are added to app $GraphClientId in Entra ID -> App registrations -> API permissions, and click Grant admin consent." -ForegroundColor Yellow
    Write-Host "REMINDER: rotate the client secret on your org schedule and redeploy when it changes." -ForegroundColor Yellow
}

