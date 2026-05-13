# Lists Microsoft Graph application roles currently assigned to a managed identity.
# Use after Grant-GraphPermissions.ps1 to confirm the grant landed.

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$ManagedIdentityPrincipalId
)

$ErrorActionPreference = 'Stop'
Import-Module Microsoft.Graph.Applications -ErrorAction Stop

if (-not (Get-MgContext)) {
    Connect-MgGraph -Scopes 'Application.Read.All' | Out-Null
}

$graphSp = Get-MgServicePrincipal -Filter "appId eq '00000003-0000-0000-c000-000000000000'"

$assignments = Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $ManagedIdentityPrincipalId |
    Where-Object { $_.ResourceId -eq $graphSp.Id }

if (-not $assignments) {
    Write-Host "No Microsoft Graph app roles assigned to $ManagedIdentityPrincipalId." -ForegroundColor Red
    exit 1
}

$roleMap = @{}
foreach ($r in $graphSp.AppRoles) { $roleMap[$r.Id] = $r.Value }

Write-Host "Microsoft Graph app roles on $ManagedIdentityPrincipalId" -ForegroundColor Cyan
$assignments |
    Select-Object @{N='Role';E={ $roleMap[$_.AppRoleId] }}, CreatedDateTime |
    Sort-Object Role |
    Format-Table -AutoSize

$expected = @('Device.ReadWrite.All','Mail.Send')
$have     = $assignments | ForEach-Object { $roleMap[$_.AppRoleId] }
$missing  = $expected | Where-Object { $_ -notin $have }

if ($missing) {
    Write-Host ""
    Write-Host "Missing required roles: $($missing -join ', ')" -ForegroundColor Red
    Write-Host "Run: ./Grant-GraphPermissions.ps1 -ManagedIdentityPrincipalId $ManagedIdentityPrincipalId" -ForegroundColor Yellow
    exit 2
} else {
    Write-Host ""
    Write-Host "All required roles present." -ForegroundColor Green
    Write-Host "Note: managed-identity tokens are cached up to ~24h. If the workflow still gets 403," -ForegroundColor DarkGray
    Write-Host "disable then re-enable the Logic App in the portal to force a fresh token." -ForegroundColor DarkGray
}
