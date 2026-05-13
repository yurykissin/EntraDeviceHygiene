# Entra Device Hygiene

Automated stale-device lifecycle for Microsoft Entra ID using a scheduled Azure Logic App and Microsoft Graph. **One workflow** disables stale devices, deletes ones that have been disabled long enough, and emails an HTML report.

## What it does (per run)

1. **Total tenant device count** — `GET /devices/$count`.
2. **Disable stale devices** — `accountEnabled=true` AND `approximateLastSignInDateTime` older than `staleThresholdDays` (default **30**) → `PATCH accountEnabled=false`.
3. **Delete long-disabled devices** — `accountEnabled=false` AND `approximateLastSignInDateTime` older than `staleThresholdDays + disabledDeletionThresholdDays` (default **30 + 30 = 60**) → `DELETE`.
4. **Skip** Autopilot devices (`[ZTDID]` in `physicalIds`) and hybrid-joined devices (`trustType = ServerAd`) by default.
5. **Email an HTML report** to the configured recipients via Graph `sendMail`, including: total devices, count disabled, count deleted, full table of each, and any errors.

`dryRun = true` (the default) sends the report **without making changes**.

## Layout

```
arm/
  azuredeploy.json              # Logic App + system-assigned MI
  azuredeploy.parameters.json
scripts/
  Test-Prerequisites.ps1        # PS version, az CLI, required Graph modules
  Grant-GraphPermissions.ps1    # Device.ReadWrite.All + Mail.Send to the MI
  Deploy.ps1                    # az deployment wrapper
```

## Parameters

| Name                            | Default          | Notes |
|---------------------------------|------------------|-------|
| `staleThresholdDays`            | 30               | Inactivity threshold to **disable** a device. Override at deploy time. |
| `disabledDeletionThresholdDays` | 30               | Extra inactivity beyond `staleThresholdDays` after which a disabled device is **deleted**. |
| `scheduleFrequency` / `scheduleInterval` | Day / 1 | Recurrence. |
| `emailFromUpn`                  | — (required)     | Sender mailbox UPN. The MI needs `Mail.Send` (optionally scoped via an ApplicationAccessPolicy). |
| `emailToRecipients`             | — (required)     | Semicolon-separated recipient list. |
| `excludeAutopilot`              | true             | Skip ZTDID devices. |
| `excludeHybridJoined`           | true             | Skip `trustType = ServerAd` (clean up via on-prem AD instead). |
| `dryRun`                        | true             | When true: no PATCH / DELETE, only the report is sent. |

Override any default at deploy time, e.g. `-StaleThresholdDays 60`.

## Required Graph application permissions

Granted to the Logic App's **system-assigned managed identity**:

| Permission             | Why |
|------------------------|-----|
| `Device.ReadWrite.All` | List + disable + delete device objects |
| `Mail.Send`            | Send the HTML report via `/users/{from}/sendMail` |

`Grant-GraphPermissions.ps1` assigns these. Without them you'll see `Authorization_RequestDenied` in the run history.

> Tip: scope `Mail.Send` to just the sender mailbox with an `New-ApplicationAccessPolicy` in Exchange Online so the MI can only send as that one identity.

## Deployment

The flow targets three control planes in order: ARM for the Logic App, Microsoft Graph for the role grant, then back to the Logic App to flip `dryRun` off when you're ready.

### 0. Verify prerequisites

```powershell
./scripts/Test-Prerequisites.ps1            # report only
./scripts/Test-Prerequisites.ps1 -Install   # install missing modules
```

### 1. Deploy the Logic App

```powershell
az login

./scripts/Deploy.ps1 `
    -ResourceGroupName   rg-entra-hygiene `
    -SubscriptionId      <subscription-id> `
    -EmailFromUpn        reports@yourtenant.onmicrosoft.com `
    -EmailToRecipients   'admin@yourtenant.com;security@yourtenant.com'
```

Optional overrides: `-StaleThresholdDays 60`, `-DisabledDeletionThresholdDays 60`, `-DryRun $false`.

Copy the **`managedIdentityPrincipalId`** value from the outputs for the next step.

### 2. Grant Graph permissions to the managed identity

```powershell
Connect-MgGraph -Scopes 'AppRoleAssignment.ReadWrite.All','Application.Read.All'
./scripts/Grant-GraphPermissions.ps1 -ManagedIdentityPrincipalId <principalId-from-step-1>
```

### 3. Validate, then go live

- Run the workflow once on demand (**Portal → Logic App → Run Trigger → Recurrence**).
- Check the inbox for the dry-run report.
- When the report looks right, redeploy with `-DryRun $false`, or flip the workflow parameter directly in the portal.

## Safety defaults

- `dryRun = true` — no writes until you flip it.
- Autopilot and Hybrid-joined excluded.
- Delete only happens after a device is already disabled *and* an additional inactivity window has elapsed — so a missed run won't cascade into instant deletion.

## Known limitations

- Single Graph page (`$top=999`); no `@odata.nextLink` follow yet. Fine for most tenants; add paging if you exceed 999 candidates in either bucket per run.
- No `disabledDateTime` exists on the device object, so the delete criterion uses `approximateLastSignInDateTime` past the combined cutoff. In practice this means a device disabled by this workflow becomes deletable once it has been inactive for the *sum* of both thresholds.
