# Creates the Entra security group used to hold stale device candidates for review.
# Outputs the group's ObjectId so you can pass it to the ARM template.

[CmdletBinding()]
param(
    [string]$DisplayName = "sec-EntraDeviceHygiene-StaleReview",
    [string]$MailNickname = "secEntraDeviceHygieneStaleReview",
    [string]$Description  = "Holds Entra devices flagged as stale by the Device Hygiene Logic App. Review before disable/delete."
)

$ErrorActionPreference = 'Stop'
Import-Module Microsoft.Graph.Groups -ErrorAction Stop

if (-not (Get-MgContext)) {
    Connect-MgGraph -Scopes "Group.ReadWrite.All" | Out-Null
}

$existing = Get-MgGroup -Filter "displayName eq '$DisplayName'" -ConsistencyLevel eventual -CountVariable c -ErrorAction SilentlyContinue
if ($existing) {
    Write-Host "Group already exists: $($existing.Id)" -ForegroundColor Yellow
    return $existing.Id
}

$group = New-MgGroup -DisplayName $DisplayName `
                     -MailNickname $MailNickname `
                     -Description $Description `
                     -SecurityEnabled `
                     -MailEnabled:$false `
                     -GroupTypes @()

Write-Host "Created group:" -ForegroundColor Green
Write-Host "  DisplayName : $($group.DisplayName)"
Write-Host "  ObjectId    : $($group.Id)"
Write-Host ""
Write-Host "Use this ObjectId as the 'reviewGroupObjectId' parameter in azuredeploy.parameters.json."
return $group.Id
