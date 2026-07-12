# Entra Device Hygiene

[![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fyurykissin%2FEntraDeviceHygiene%2Fmain%2Farm%2Fazuredeploy.json)
[![Visualize](https://raw.githubusercontent.com/Azure/azure-quickstart-templates/master/1-CONTRIBUTION-GUIDE/images/visualizebutton.svg)](http://armviz.io/#/?load=https%3A%2F%2Fraw.githubusercontent.com%2Fyurykissin%2FEntraDeviceHygiene%2Fmain%2Farm%2Fazuredeploy.json)

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
  azuredeploy.bicep             # source of truth
  azuredeploy.json              # compiled output - referenced by the Deploy to Azure button
  azuredeploy.parameters.json
  workflow-definition.json      # Logic App definition (loaded by Bicep at compile time)
scripts/
  Test-Prerequisites.ps1        # PS version, az CLI, required modules
  Deploy.ps1                    # az deployment wrapper (alternative to the portal button)
  Grant-GraphPermissions.ps1    # post-deploy: grant Graph app roles to the Logic App MI
  Test-GraphPermissions.ps1     # confirm the grant landed
```

If you edit `azuredeploy.bicep` or `workflow-definition.json`, recompile:

```bash
az bicep build --file arm/azuredeploy.bicep
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

These are granted to the Logic App's **system-assigned managed identity** as a one-time post-deploy step (see below):

| Permission             | Why |
|------------------------|-----|
| `Device.ReadWrite.All` | List + disable + delete device objects |
| `Mail.Send`            | Send the HTML report via `/users/{from}/sendMail` |

> Tip: scope `Mail.Send` to just the sender mailbox with `New-ApplicationAccessPolicy` in Exchange Online so the MI can only send as that one identity.

## Deployment

Deployment is two short steps: (1) deploy the ARM template (portal button or CLI), (2) grant the two Graph app roles to the resulting managed identity. Step 2 must be a separate step because Azure Portal-triggered deployments cannot obtain a Microsoft Graph token — there is no way to grant Graph app roles from ARM in a portal one-click deploy.

> **The principal running step 2 must be Global Administrator or Privileged Role Administrator** (required to consent to Graph application roles).

### Step 1a - Deploy from the portal (one click)

Use the **Deploy to Azure** button at the top of the README. Fill in `emailFromUpn` and `emailToRecipients`, leave other defaults, click Review + create.

When the deployment finishes, copy the **`managedIdentityPrincipalId`** value from the deployment Outputs — you need it for step 2.

### Step 1b - Deploy from PowerShell / CLI (alternative)

```powershell
./scripts/Test-Prerequisites.ps1            # report only
./scripts/Test-Prerequisites.ps1 -Install   # install missing modules

az login --tenant <customer-tenant-id>

./scripts/Deploy.ps1 `
    -ResourceGroupName   rg-entra-hygiene `
    -SubscriptionId      <subscription-id> `
    -EmailFromUpn        reports@yourtenant.onmicrosoft.com `
    -EmailToRecipients   'admin@yourtenant.com;security@yourtenant.com'
```

Optional overrides: `-StaleThresholdDays 60`, `-DisabledDeletionThresholdDays 60`, `-DryRun $false`.

### Step 2 - Grant Graph permissions to the managed identity

Sign in as **Global Administrator** or **Privileged Role Administrator** and run:

```powershell
./scripts/Grant-GraphPermissions.ps1 -LogicAppName la-entra-device-hygiene -ResourceGroupName rg-entra-hygiene
# verify
./scripts/Test-GraphPermissions.ps1  -LogicAppName la-entra-device-hygiene -ResourceGroupName rg-entra-hygiene
```

This grants `Device.ReadWrite.All` + `Mail.Send` to the Logic App's system-assigned managed identity. Idempotent — safe to re-run.

If you prefer a GUI, you can do the same in [Microsoft Graph Explorer](https://developer.microsoft.com/graph/graph-explorer) by POSTing to `/servicePrincipals/{miObjectId}/appRoleAssignments` twice (once per role) — but the script is faster.

### Step 3 - Force a managed-identity token refresh

Managed-identity tokens are cached up to ~24 hours. After granting the new Graph roles, cycle the workflow once so the MI re-fetches its token:

```powershell
az logic workflow update -g rg-entra-hygiene -n la-entra-device-hygiene --state Disabled
az logic workflow update -g rg-entra-hygiene -n la-entra-device-hygiene --state Enabled
```

### Validate, then go live

- Run the workflow once on demand (**Portal → Logic App → Run Trigger → Recurrence**).
- Check the inbox for the dry-run report.
- When the report looks right, change `dryRun` to `false` (see *Changing parameters* below).

## Changing parameters after deployment

Workflow parameters are baked into the Logic App at deploy time. There are two supported ways to change them.

### Option A — Redeploy (recommended for repeatable / IaC flows)

Re-run `Deploy.ps1` with the new values. Any value passed on the command line **overrides** what's in `azuredeploy.parameters.json`.

```powershell
# Go live (turn off dry run)
./scripts/Deploy.ps1 `
    -ResourceGroupName   rg-entra-hygiene `
    -SubscriptionId      <subscription-id> `
    -EmailFromUpn        admin@yourtenant.com `
    -EmailToRecipients   'admin@yourtenant.com;security@yourtenant.com' `
    -DryRun              $false

# Loosen the disable threshold to 60 days, push delete to 60+30=90
./scripts/Deploy.ps1 `
    -ResourceGroupName   rg-entra-hygiene `
    -SubscriptionId      <subscription-id> `
    -EmailFromUpn        admin@yourtenant.com `
    -EmailToRecipients   'admin@yourtenant.com' `
    -StaleThresholdDays  60 `
    -DisabledDeletionThresholdDays 30
```

> **Gotcha:** if you forget to pass an override, the value from `azuredeploy.parameters.json` is used. Edit the file *and* redeploy if you want a permanent default change.

For long-term changes, edit `azuredeploy.parameters.json` directly and commit; future deploys (with no overrides) will pick it up.

### Option B — Edit live in the portal (no redeploy)

Useful for one-off tweaks or to flip `dryRun` quickly without a pipeline run.

1. Azure portal → **Logic App** → *la-entra-device-hygiene* → **Logic app code view**.
2. Scroll to the bottom; under `parameters`, change the `value` for the parameter you want.
   ```jsonc
   "parameters": {
     "dryRun":            { "value": false },
     "emailFromUpn":      { "value": "admin@yourtenant.com" },
     "staleThresholdDays":{ "value": 60 }
   }
   ```
3. **Save**.
4. Run the workflow on demand to confirm (**Run Trigger → Recurrence**).

Changes made in the portal will be **overwritten on the next ARM redeploy**, so mirror anything important into `azuredeploy.parameters.json`.

### Forcing a new managed-identity token

See "After deployment - force a managed-identity token refresh" above.

## Safety defaults

- `dryRun = true` — no writes until you flip it.
- Autopilot and Hybrid-joined excluded.
- Delete only happens after a device is already disabled *and* an additional inactivity window has elapsed — so a missed run won't cascade into instant deletion.

## Known limitations

- Single Graph page (`$top=999`); no `@odata.nextLink` follow yet. Fine for most tenants; add paging if you exceed 999 candidates in either bucket per run.
- No `disabledDateTime` exists on the device object, so the delete criterion uses `approximateLastSignInDateTime` past the combined cutoff. In practice this means a device disabled by this workflow becomes deletable once it has been inactive for the *sum* of both thresholds.

## License

MIT — see [LICENSE](LICENSE).

## Disclaimer

This ARM template is provided **"as is"**, without warranties or guarantees of any kind. Use at your own risk. You are responsible for reviewing, validating, and testing this template in a non‑production environment before deploying it to production. The author assumes no liability for resource costs, configuration issues, or service disruptions resulting from the use of this template.

## Security Considerations

- Review all resource configurations before deployment.
- Validate role assignments, network rules, and identity configurations.
- Confirm compliance with your organization's security and governance standards.
- Ensure secrets/keys are not hard‑coded in templates or parameter files.

## Contributing

Contributions are welcome! When contributing:

- Do not include sensitive information.
- Ensure resource configurations follow Azure best practices.
- Confirm the template passes ARM validation (`az deployment group validate ...`).
- Follow the Code of Conduct (below).

## Code of Conduct

This project adopts the [Microsoft Open Source Code of Conduct](https://opensource.microsoft.com/codeofconduct/).
