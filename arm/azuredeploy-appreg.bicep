// Entra Device Hygiene - APP REGISTRATION variant
//
// Same Logic App as azuredeploy.bicep, but the workflow calls Microsoft Graph as an
// Entra app registration (client_credentials) instead of the Logic App's managed
// identity. Use this path when your tenant admin prefers granting Graph app
// permissions through the app-registration GUI ("API permissions" -> "Grant admin
// consent") instead of running a post-deploy script against a managed identity.
//
// SECURITY: this stores the app registration's client secret as a securestring
// parameter on the workflow. Rotate the secret on a schedule and redeploy when it
// changes. If secret rotation via Key Vault is required, use the managed-identity
// variant (azuredeploy.bicep) instead.

@description('Logic App name.')
param logicAppName string = 'la-entra-device-hygiene'

param location string = resourceGroup().location

@description('A device is considered stale (and will be disabled) when approximateLastSignInDateTime is older than this many days.')
@minValue(1)
@maxValue(3650)
param staleThresholdDays int = 30

@description('A disabled device is deleted when it has been inactive for staleThresholdDays + this many additional days.')
@minValue(1)
@maxValue(3650)
param disabledDeletionThresholdDays int = 30

@allowed([ 'Hour', 'Day', 'Week', 'Month' ])
param scheduleFrequency string = 'Day'

@minValue(1)
param scheduleInterval int = 1

@description('User Principal Name of the mailbox that sends the report. The app registration must have Mail.Send permission scoped to (or unrestricted over) this mailbox.')
param emailFromUpn string

@description('Semicolon-separated list of recipient email addresses for the report.')
param emailToRecipients string

param excludeAutopilot bool = true
param excludeHybridJoined bool = true

@description('When true, no PATCH/DELETE is performed - only the report is sent so you can preview impact.')
param dryRun bool = true

@description('Entra tenant ID (GUID) that hosts the app registration.')
param graphTenantId string = subscription().tenantId

@description('Application (client) ID of the Entra app registration whose Graph app roles the Logic App will use.')
param graphClientId string

@description('Client secret for the app registration. Stored as a securestring on the workflow. Rotate + redeploy on the schedule your org requires.')
@secure()
param graphClientSecret string

var graphBaseUri = 'https://graph.microsoft.com/v1.0'

var workflowDefinitionRaw = loadJsonContent('workflow-definition-appreg.json')

// The workflow JSON keeps Recurrence as outer-ARM parameter references for readability,
// but loadJsonContent() ships those strings verbatim to Logic Apps validation which
// rejects them - substitute here in Bicep.
var workflowDefinition = union(workflowDefinitionRaw, {
  triggers: union(workflowDefinitionRaw.triggers, {
    Recurrence: union(workflowDefinitionRaw.triggers.Recurrence, {
      recurrence: {
        frequency: scheduleFrequency
        interval:  scheduleInterval
      }
    })
  })
})

resource workflow 'Microsoft.Logic/workflows@2019-05-01' = {
  name:     logicAppName
  location: location
  // No managed identity in this variant - workflow authenticates as the app registration
  properties: {
    state: 'Enabled'
    definition: workflowDefinition
    parameters: {
      staleThresholdDays:            { value: staleThresholdDays }
      disabledDeletionThresholdDays: { value: disabledDeletionThresholdDays }
      graphBaseUri:                  { value: graphBaseUri }
      emailFromUpn:                  { value: emailFromUpn }
      emailToRecipients:             { value: emailToRecipients }
      excludeAutopilot:              { value: excludeAutopilot }
      excludeHybridJoined:           { value: excludeHybridJoined }
      dryRun:                        { value: dryRun }
      graphTenantId:                 { value: graphTenantId }
      graphClientId:                 { value: graphClientId }
      graphClientSecret:             { value: graphClientSecret }
    }
  }
}

output logicAppName string = logicAppName
output nextSteps    string = 'Grant Graph app permissions (Device.ReadWrite.All, Mail.Send) to the app registration via Entra portal, then click Grant admin consent. Rotate the client secret on your org schedule and redeploy when it changes.'
