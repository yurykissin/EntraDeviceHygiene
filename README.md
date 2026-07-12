# Entra Device Hygiene

Automated stale-device lifecycle for Microsoft Entra ID using a scheduled Azure Logic App and Microsoft Graph. **One workflow** disables stale devices, deletes ones that have been disabled long enough, and emails an HTML report.

## Deploy — pick one path

Two supported deployment paths ship in this repo. They produce the **same Logic App behavior**; they differ only in **how the workflow authenticates to Microsoft Graph** and where you grant the Graph permissions.

| | **Path A — Managed Identity** ★ recommended | **Path B — App Registration** |
|---|---|---|
| Deploy button | [![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fyurykissin%2FEntraDeviceHygiene%2Fmain%2Farm%2Fazuredeploy.json) [![Visualize](https://raw.githubusercontent.com/Azure/azure-quickstart-templates/master/1-CONTRIBUTION-GUIDE/images/visualizebutton.svg)](http://armviz.io/#/?load=https%3A%2F%2Fraw.githubusercontent.com%2Fyurykissin%2FEntraDeviceHygiene%2Fmain%2Farm%2Fazuredeploy.json) | [![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fyurykissin%2FEntraDeviceHygiene%2Fmain%2Farm%2Fazuredeploy-appreg.json) [![Visualize](https://raw.githubusercontent.com/Azure/azure-quickstart-templates/master/1-CONTRIBUTION-GUIDE/images/visualizebutton.svg)](http://armviz.io/#/?load=https%3A%2F%2Fraw.githubusercontent.com%2Fyurykissin%2FEntraDeviceHygiene%2Fmain%2Farm%2Fazuredeploy-appreg.json) |
| How workflow authenticates to Graph | Logic App **system-assigned managed identity** | Entra **app registration** + client secret (client\_credentials) |
| Credentials to manage | ❌ None — Azure rotates automatically | ⚠️ Client secret — you rotate on schedule + redeploy |
| GUI to grant Graph app roles | ❌ No portal UI exists for MIs. Post-deploy step required: PowerShell script *or* 2 POSTs in Graph Explorer *or* wire via CLI. See Path A step 2. | ✅ Yes. Entra portal → App registrations → **API permissions** → Add + **Grant admin consent** (one click) |
| Portal one-click deploy | ✅ Works | ✅ Works |
| Post-deploy admin role | GA or PRA (to consent to Graph app roles on the MI) | GA or PRA (to grant admin consent on the app reg) |
| Secret in deployment inputs | None | `graphClientSecret` (securestring; encrypted at rest on the workflow) |
| Recommended when | Default choice for unattended, long-running automation. Fewest moving parts. | Your org policy mandates the app-registration model, or you want the fully GUI-driven consent flow. |

> **Neither path can be zero-touch.** Consenting to Graph application permissions always requires a Global Administrator or Privileged Role Administrator, regardless of path.

---

## What it does (per run)

1. **Total tenant device count** — `GET /devices/$count`.
2. **Disable stale devices** — `accountEnabled=true` AND `approximateLastSignInDateTime` older than `staleThresholdDays` (default **30**) → `PATCH accountEnabled=false`.
3. **Delete long-disabled devices** — `accountEnabled=false` AND `approximateLastSignInDateTime` older than `staleThresholdDays + disabledDeletionThresholdDays` (default **30 + 30 = 60**) → `DELETE`.
4. **Skip** Autopilot devices (`[ZTDID]` in `physicalIds`) and hybrid-joined devices (`trustType = ServerAd`) by default.
5. **Email an HTML report** to the configured recipients via Graph `sendMail`, including: total devices, count disabled, count deleted, full table of each, and any errors.

`dryRun = true` (the default) sends the report **without making changes**.

## Required Graph application permissions

Both paths need the same two permissions granted to whichever principal the workflow authenticates as:

| Permission             | Why |
|------------------------|-----|
| `Device.ReadWrite.All` | List + disable + delete device objects |
| `Mail.Send`            | Send the HTML report via `/users/{from}/sendMail` |

> Tip: scope `Mail.Send` to just the sender mailbox with `New-ApplicationAccessPolicy` in Exchange Online so the principal can only send as that one identity.

## Layout

```
arm/
  azuredeploy.bicep                     # Path A: source of truth (managed identity)
  azuredeploy.json                      # Path A: compiled — Deploy to Azure button target
  azuredeploy-appreg.bicep              # Path B: source of truth (app registration)
  azuredeploy-appreg.json               # Path B: compiled — Deploy to Azure button target
  workflow-definition.json              # Path A workflow (MI auth on every HTTP action)
  workflow-definition-appreg.json       # Path B workflow (ActiveDirectoryOAuth auth on every HTTP action)
  azuredeploy.parameters.json
scripts/
  Test-Prerequisites.ps1                # PS version, az CLI, required modules
  Deploy.ps1                            # CLI wrapper — supports -AuthMode ManagedIdentity|AppRegistration
  Grant-GraphPermissions.ps1            # Path A only: grant Graph roles to the Logic App MI
  Test-GraphPermissions.ps1             # Path A only: confirm the grant landed
```

If you edit any `.bicep` or `workflow-definition*.json`, recompile:

```bash
az bicep build --file arm/azuredeploy.bicep
az bicep build --file arm/azuredeploy-appreg.bicep
```

## Parameters (shared by both paths unless noted)

| Name                                     | Default        | Notes |
|------------------------------------------|----------------|-------|
| `staleThresholdDays`                     | 30             | Inactivity threshold to **disable** a device. |
| `disabledDeletionThresholdDays`          | 30             | Extra inactivity beyond `staleThresholdDays` after which a disabled device is **deleted**. |
| `scheduleFrequency` / `scheduleInterval` | Day / 1        | Recurrence. |
| `emailFromUpn`                           | — (required)   | Sender mailbox UPN. Principal needs `Mail.Send` (optionally scoped via an ApplicationAccessPolicy). |
| `emailToRecipients`                      | — (required)   | Semicolon-separated recipient list. |
| `excludeAutopilot`                       | true           | Skip ZTDID devices. |
| `excludeHybridJoined`                    | true           | Skip `trustType = ServerAd` (clean up via on-prem AD instead). |
| `dryRun`                                 | true           | When true: no PATCH / DELETE, only the report is sent. |
| `graphTenantId` *(Path B only)*          | current tenant | Tenant that hosts the app registration. |
| `graphClientId` *(Path B only)*          | — (required)   | Application (client) ID of the app registration. |
| `graphClientSecret` *(Path B only)*      | — (required)   | Client secret; stored as securestring on the workflow. |

---

## Path A — Managed Identity (recommended)

### Step A1 — Deploy the Logic App

**Option 1: Portal one-click.** Click Path A's **Deploy to Azure** button above. Fill in `emailFromUpn` and `emailToRecipients`, leave other defaults, click **Review + create**. When the deployment finishes, open the deployment **Outputs** and copy `managedIdentityPrincipalId` — you need it if you use the Graph Explorer route in Step A2.

**Option 2: PowerShell / CLI.**
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
Optional: `-StaleThresholdDays 60`, `-DisabledDeletionThresholdDays 60`, `-DryRun $false`.

### Step A2 — Grant Graph app roles to the Managed Identity

> Must run as **Global Administrator** or **Privileged Role Administrator**. There is **no Azure Portal UI** for granting Graph application permissions to a managed identity — this is a long-standing Microsoft gap. Pick one of the three methods below.

**Method 1: repo script (fastest).**
```powershell
./scripts/Grant-GraphPermissions.ps1 -LogicAppName la-entra-device-hygiene -ResourceGroupName rg-entra-hygiene
./scripts/Test-GraphPermissions.ps1  -LogicAppName la-entra-device-hygiene -ResourceGroupName rg-entra-hygiene
```

**Method 2: Microsoft Graph Explorer (no local tooling, GUI-driven form).**
1. Open <https://developer.microsoft.com/graph/graph-explorer>, sign in as GA/PRA.
2. Click the profile icon → **Consent to permissions** → tick `AppRoleAssignment.ReadWrite.All` and `Application.Read.All` → Consent.
3. `GET https://graph.microsoft.com/v1.0/servicePrincipals(appId='00000003-0000-0000-c000-000000000000')?$select=id` → copy `id` value → call it `GRAPH_SP_ID`.
4. `POST https://graph.microsoft.com/v1.0/servicePrincipals/<managedIdentityPrincipalId>/appRoleAssignments` body:
   ```json
   { "principalId": "<managedIdentityPrincipalId>", "resourceId": "<GRAPH_SP_ID>", "appRoleId": "1138cb37-bd11-4084-a2b7-9f71582aeddb" }
   ```
5. Same URL again, body with `appRoleId` = `b633e1c5-b582-4048-a93e-9f11b44c7e96` (Mail.Send).
6. Both calls return `201 Created`.

**Method 3: Azure CLI one-liners** (needs `az` + GA/PRA):
```powershell
$mi        = az ad sp show --id $managedIdentityPrincipalId --query id -o tsv
$graphSpId = az ad sp show --id 00000003-0000-0000-c000-000000000000 --query id -o tsv
foreach ($rid in @('1138cb37-bd11-4084-a2b7-9f71582aeddb','b633e1c5-b582-4048-a93e-9f11b44c7e96')) {
    az rest --method POST `
        --uri "https://graph.microsoft.com/v1.0/servicePrincipals/$mi/appRoleAssignments" `
        --body "{`"principalId`":`"$mi`",`"resourceId`":`"$graphSpId`",`"appRoleId`":`"$rid`"}"
}
```

### Step A3 — Force a managed-identity token refresh

MI tokens cache up to ~24 hours. After granting the new Graph roles, cycle the workflow so the MI re-fetches its token:
```powershell
az logic workflow update -g rg-entra-hygiene -n la-entra-device-hygiene --state Disabled
az logic workflow update -g rg-entra-hygiene -n la-entra-device-hygiene --state Enabled
```

### Step A4 — Validate, then go live
- Trigger the workflow once on demand (**Portal → Logic App → Run Trigger → Recurrence**).
- Confirm the dry-run report arrives in the inbox.
- When it looks right, redeploy with `-DryRun $false` (or edit `dryRun` in the portal Logic App parameters).

---

## Path B — App Registration

> ⚠️ **You are now responsible for the client secret.** Store it securely, rotate on your org schedule (typically 6–24 months), redeploy the Logic App when you rotate. If you lose the secret, the workflow's Graph calls will 401 until you rotate + redeploy. If Key Vault-based secret rotation is required, prefer **Path A** — this repo does not currently include a Key Vault reference variant.

### Step B1 — Create the Entra app registration

1. Entra admin center → **App registrations** → **New registration**.
2. Name: `sp-entra-device-hygiene` (or your convention). Supported account types: **Single tenant**. No redirect URI needed. Register.
3. On the **Overview** blade, copy **Application (client) ID** and **Directory (tenant) ID**.

### Step B2 — Grant Graph app permissions (GUI, one click)

1. Same app reg → **API permissions** → **Add a permission** → **Microsoft Graph** → **Application permissions** → tick `Device.ReadWrite.All` and `Mail.Send` → **Add permissions**.
2. Click **Grant admin consent for \<tenant\>** at the top. Status must go green for both rows. **This requires Global Administrator or Privileged Role Administrator.**

### Step B3 — Create a client secret

1. Same app reg → **Certificates & secrets** → **Client secrets** → **New client secret**.
2. Description: `entra-device-hygiene`. Expires: pick per your org policy (max 24 months). Add.
3. **Copy the Value immediately** — Entra shows it exactly once. Also note the expiry date; set a calendar reminder to rotate + redeploy before then.

### Step B4 — Deploy the Logic App

**Option 1: Portal one-click.** Click Path B's **Deploy to Azure** button above. Fill in `emailFromUpn`, `emailToRecipients`, `graphClientId` (from step B1), `graphClientSecret` (from step B3). `graphTenantId` defaults to the deployment subscription's tenant — override only if the app reg lives in a different tenant. **Review + create**.

**Option 2: PowerShell / CLI.**
```powershell
$secret = Read-Host -AsSecureString "Client secret"

./scripts/Deploy.ps1 `
    -AuthMode            AppRegistration `
    -ResourceGroupName   rg-entra-hygiene `
    -SubscriptionId      <subscription-id> `
    -EmailFromUpn        reports@yourtenant.onmicrosoft.com `
    -EmailToRecipients   'admin@yourtenant.com;security@yourtenant.com' `
    -GraphClientId       <app-registration-client-id> `
    -GraphClientSecret   $secret
```

### Step B5 — Validate, then go live
- Trigger the workflow once on demand.
- Confirm the dry-run report arrives.
- Redeploy with `-DryRun $false` when ready.

### Rotating the client secret (Path B only)

1. Create a new secret in the app registration (repeat Step B3).
2. Redeploy the Logic App with the new secret (repeat Step B4). Both secrets are valid until the old one's expiry, so this is zero-downtime.
3. Delete the old secret.

---


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
