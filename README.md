# Entra Device Hygiene

Automated stale-device detection for Microsoft Entra ID using a scheduled Azure Logic App and Microsoft Graph.

## What it does

1. **Logic App** runs on a schedule (default: daily).
2. Queries Microsoft Graph for devices whose `approximateLastSignInDateTime` is older than `staleThresholdDays` (default: 90).
3. Filters out **Autopilot** devices (`physicalIds` containing `[ZTDID]`) and **hybrid-joined** devices (`trustType = ServerAd`) by default.
4. Adds the remaining candidates to a **review security group** so admins can verify before any disable/delete action.
5. Runs in **dry-run mode by default** — set `dryRun = false` to enable group writes.

Disable / delete stages are intentionally **not** part of this template; they should be a separate, gated workflow that operates on the review group after human approval.

## Layout

```
arm/
  azuredeploy.json              # Logic App + system-assigned MI
  azuredeploy.parameters.json   # Tweakables (threshold, schedule, group, dryRun)
scripts/
  Test-Prerequisites.ps1        # Checks PS version, az CLI, required modules (no duplicate installs)
  Bootstrap-ReviewGroup.ps1     # Creates the Entra review group, returns ObjectId
  Grant-GraphPermissions.ps1    # Grants Device.Read.All + GroupMember.ReadWrite.All to the Logic App MI
  Deploy.ps1                    # az deployment group create wrapper
```

## Deployment

```powershell
# 0. (Recommended) Verify prerequisites
./scripts/Test-Prerequisites.ps1
# Add -Install to auto-install missing modules, -Upgrade to update outdated ones

# 1. Create the review group (one-time)
$groupId = ./scripts/Bootstrap-ReviewGroup.ps1

# 2. Deploy the Logic App
./scripts/Deploy.ps1 -ResourceGroupName rg-entra-hygiene `
                     -SubscriptionId   <sub-id> `
                     -ReviewGroupObjectId $groupId

# 3. Grant Graph app-role permissions to the Logic App's managed identity
#    (the principalId is in the Deploy.ps1 output)
./scripts/Grant-GraphPermissions.ps1 -ManagedIdentityPrincipalId <principalId>
```

## Parameters

| Name                 | Default | Notes |
|----------------------|---------|-------|
| `staleThresholdDays` | 90      | Cutoff for `approximateLastSignInDateTime` |
| `scheduleFrequency`  | Day     | Hour / Day / Week / Month |
| `scheduleInterval`   | 1       | Combined with frequency |
| `excludeAutopilot`   | true    | Skip devices with a ZTDID |
| `excludeHybridJoined`| true    | Skip `trustType = ServerAd` (clean up in on-prem AD) |
| `dryRun`             | true    | When true, only logs candidates |
| `reviewGroupObjectId`| —       | Required; from `Bootstrap-ReviewGroup.ps1` |

## Required Graph permissions (application)

- `Device.Read.All` — list devices
- `GroupMember.ReadWrite.All` — add to review group

These are granted to the Logic App's **system-assigned managed identity** by `Grant-GraphPermissions.ps1`.

## Roadmap (next phases)

- Phase 2: Reporting workflow — email/Teams summary of new candidates with deep-links.
- Phase 3: Approval-gated disable workflow (operates on the review group, with rollback window).
- Phase 4: Delete workflow with Autopilot/Hybrid safety net and audit log export.
