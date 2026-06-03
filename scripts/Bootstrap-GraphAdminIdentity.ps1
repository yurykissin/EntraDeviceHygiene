# One-time per tenant: creates a user-assigned managed identity (UAMI) and grants it the
# Microsoft Graph application permissions needed to assign app roles to other principals.
# Hand the resulting UAMI resource ID to azuredeploy.json's graphAdminIdentityResourceId
# parameter to enable one-click deployment (Logic App + Graph role grants in one ARM run).
#
# Required signed-in roles:
#   - Azure: Contributor (or Owner) on the chosen subscription/RG
#   - Entra: Privileged Role Administrator OR Global Admin (to grant Graph app roles)

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$SubscriptionId,
    [Parameter(Mandatory)] [string]$ResourceGroupName,
    [string]$IdentityName     = 'id-graph-app-role-admin',
    [string]$Location         = 'westeurope',
    [string[]]$GraphAppRoles  = @('AppRoleAssignment.ReadWrite.All','Application.Read.All')
)

$ErrorActionPreference = 'Stop'

# ---- Azure resource: create / reuse the UAMI ---------------------------------------------
if (-not (Get-Command az -ErrorAction SilentlyContinue)) { throw "Azure CLI not found. Install it and run 'az login'." }
az account set --subscription $SubscriptionId | Out-Null
az group create --name $ResourceGroupName --location $Location --output none

Write-Host "Ensuring UAMI '$IdentityName' in $ResourceGroupName..." -ForegroundColor Cyan
$uami = az identity show --name $IdentityName --resource-group $ResourceGroupName --output json 2>$null | ConvertFrom-Json
if (-not $uami) {
    $uami = az identity create --name $IdentityName --resource-group $ResourceGroupName --location $Location --output json | ConvertFrom-Json
}
$principalId   = $uami.principalId
$resourceId    = $uami.id
Write-Host "  principalId: $principalId" -ForegroundColor DarkGray
Write-Host "  resourceId : $resourceId"  -ForegroundColor DarkGray

# ---- Graph: grant the requested app roles to the UAMI -----------------------------------
Import-Module Microsoft.Graph.Applications -ErrorAction Stop
if (-not (Get-MgContext)) {
    Connect-MgGraph -Scopes 'AppRoleAssignment.ReadWrite.All','Application.Read.All' | Out-Null
}

$graphSp = Get-MgServicePrincipal -Filter "appId eq '00000003-0000-0000-c000-000000000000'"
if (-not $graphSp) { throw "Microsoft Graph service principal not found in tenant." }

# Graph propagation can take a few seconds before the new UAMI's SP is queryable
for ($i = 0; $i -lt 12; $i++) {
    try { $miSp = Get-MgServicePrincipal -ServicePrincipalId $principalId -ErrorAction Stop; break }
    catch { Start-Sleep -Seconds 5 }
}
if (-not $miSp) { throw "UAMI service principal $principalId not visible to Graph after 60s." }

foreach ($roleName in $GraphAppRoles) {
    $appRole = $graphSp.AppRoles | Where-Object { $_.Value -eq $roleName -and $_.AllowedMemberTypes -contains 'Application' }
    if (-not $appRole) { Write-Warning "Role '$roleName' not found on Graph SP. Skipping."; continue }

    $existing = Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $principalId |
                Where-Object { $_.AppRoleId -eq $appRole.Id -and $_.ResourceId -eq $graphSp.Id }
    if ($existing) { Write-Host "Already assigned: $roleName" -ForegroundColor Yellow; continue }

    New-MgServicePrincipalAppRoleAssignment `
        -ServicePrincipalId $principalId `
        -PrincipalId        $principalId `
        -ResourceId         $graphSp.Id `
        -AppRoleId          $appRole.Id | Out-Null
    Write-Host "Granted: $roleName" -ForegroundColor Green
}

Write-Host ""
Write-Host "UAMI ready. Pass this resource ID to azuredeploy.json:" -ForegroundColor Cyan
Write-Host "  graphAdminIdentityResourceId = $resourceId" -ForegroundColor Green
