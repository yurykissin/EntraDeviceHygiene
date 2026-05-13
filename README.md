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

The flow has three sign-ins because the steps target different control planes (Graph for the group, ARM for the Logic App, Graph again for the app-role grant).

### 0. Verify prerequisites (recommended)

```powershell
./scripts/Test-Prerequisites.ps1            # report only
./scripts/Test-Prerequisites.ps1 -Install   # install missing modules
```

### 1. Create the review group (one-time, Microsoft Graph)

```powershell
Connect-MgGraph -Scopes 'Group.ReadWrite.All'
$groupId = ./scripts/Bootstrap-ReviewGroup.ps1
$groupId   # save this; you'll pass it to step 2
```

### 2. Deploy the Logic App (Azure ARM)

```powershell
az login
./scripts/Deploy.ps1 `
    -ResourceGroupName    rg-entra-hygiene `
    -SubscriptionId       <subscription-id> `
    -ReviewGroupObjectId  $groupId
```

`Deploy.ps1` writes the deployment outputs, including the Logic App's **managedIdentityPrincipalId** — copy it for the next step.

### 3. Grant Graph permissions to the managed identity (Microsoft Graph)

```powershell
Connect-MgGraph -Scopes 'AppRoleAssignment.ReadWrite.All','Application.Read.All'
./scripts/Grant-GraphPermissions.ps1 -ManagedIdentityPrincipalId <principalId-from-step-2>
```

After this completes, the Logic App's first scheduled run will succeed. To trigger it manually, open the workflow in the Azure portal and choose **Run Trigger → Recurrence**.

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
