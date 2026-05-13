# Grants Microsoft Graph application permissions to the Logic App's system-assigned managed identity.
# Required because Logic Apps cannot consent to Graph app roles via the portal UI.

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$ManagedIdentityPrincipalId,
    [string[]]$GraphAppRoles = @('Device.Read.All','GroupMember.ReadWrite.All')
)

$ErrorActionPreference = 'Stop'
Import-Module Microsoft.Graph.Applications -ErrorAction Stop

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
