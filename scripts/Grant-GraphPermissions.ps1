# Grants Microsoft Graph application permissions to the Logic App's system-assigned managed identity.
# Required because Logic Apps cannot consent to Graph app roles via the portal UI.
#
# Pass either the Logic App's name + resource group (script looks up the MI), or the MI's
# principal ID directly.

[CmdletBinding(DefaultParameterSetName = 'ByLogicApp')]
param(
    [Parameter(Mandatory, ParameterSetName = 'ByLogicApp')] [string]$LogicAppName,
    [Parameter(Mandatory, ParameterSetName = 'ByLogicApp')] [string]$ResourceGroupName,
    [Parameter(Mandatory, ParameterSetName = 'ByPrincipal')] [string]$ManagedIdentityPrincipalId,
    [string[]]$GraphAppRoles = @('Device.ReadWrite.All','Mail.Send')
)

$ErrorActionPreference = 'Stop'
Import-Module Microsoft.Graph.Applications -ErrorAction Stop

if ($PSCmdlet.ParameterSetName -eq 'ByLogicApp') {
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        throw "Azure CLI ('az') not found. Install it, or pass -ManagedIdentityPrincipalId instead."
    }
    Write-Host "Looking up managed identity for $LogicAppName in $ResourceGroupName..." -ForegroundColor Cyan
    $ManagedIdentityPrincipalId = az resource show `
        --resource-group $ResourceGroupName `
        --name           $LogicAppName `
        --resource-type  'Microsoft.Logic/workflows' `
        --query          'identity.principalId' `
        --output         tsv
    if (-not $ManagedIdentityPrincipalId) {
        throw "Could not resolve managed identity for Logic App '$LogicAppName' in resource group '$ResourceGroupName'. Ensure it exists and has System Assigned identity enabled."
    }
    Write-Host "  principalId = $ManagedIdentityPrincipalId" -ForegroundColor Cyan
}

if (-not (Get-MgContext)) {
    Connect-MgGraph -Scopes "AppRoleAssignment.ReadWrite.All","Application.Read.All" | Out-Null
}

$graphSp = Get-MgServicePrincipal -Filter "appId eq '00000003-0000-0000-c000-000000000000'"
if (-not $graphSp) { throw "Microsoft Graph service principal not found in tenant." }

foreach ($roleName in $GraphAppRoles) {
    $appRole = $graphSp.AppRoles | Where-Object { $_.Value -eq $roleName -and $_.AllowedMemberTypes -contains 'Application' }
    if (-not $appRole) { Write-Warning "Role '$roleName' not found on Graph SP. Skipping."; continue }

    $existing = Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $ManagedIdentityPrincipalId |
                Where-Object { $_.AppRoleId -eq $appRole.Id -and $_.ResourceId -eq $graphSp.Id }

    if ($existing) {
        Write-Host "Already assigned: $roleName" -ForegroundColor Yellow
        continue
    }

    New-MgServicePrincipalAppRoleAssignment `
        -ServicePrincipalId $ManagedIdentityPrincipalId `
        -PrincipalId        $ManagedIdentityPrincipalId `
        -ResourceId         $graphSp.Id `
        -AppRoleId          $appRole.Id | Out-Null

    Write-Host "Granted: $roleName" -ForegroundColor Green
}
