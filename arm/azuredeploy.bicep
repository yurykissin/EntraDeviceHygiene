// Entra Device Hygiene - scheduled Logic App that disables stale devices and deletes devices
// that have been disabled long enough, then emails an HTML report. Uses a system-assigned
// managed identity calling Microsoft Graph.
//
// The Deploy to Azure button deploys the Logic App with its system-assigned managed identity.
// A brief post-deploy step is required to grant the two Microsoft Graph application roles
// (Device.ReadWrite.All + Mail.Send) to the managed identity - see README section "Grant
// Graph permissions after deployment". This split is unavoidable: Azure Portal-triggered
// deployments cannot grant Graph app roles from ARM.

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
#disable-next-line no-unused-params
param scheduleFrequency string = 'Day'

@minValue(1)
#disable-next-line no-unused-params
param scheduleInterval int = 1

@description('User Principal Name of the mailbox that sends the report. The Logic App\'s managed identity must have Mail.Send permission scoped to (or unrestricted over) this mailbox.')
param emailFromUpn string

@description('Semicolon-separated list of recipient email addresses for the report.')
param emailToRecipients string

param excludeAutopilot bool = true
param excludeHybridJoined bool = true

@description('When true, no PATCH/DELETE is performed - only the report is sent so you can preview impact.')
param dryRun bool = true

var graphBaseUri = 'https://graph.microsoft.com/v1.0'

var workflowDefinitionRaw = loadJsonContent('workflow-definition.json')

// loadJsonContent() ships the raw JSON to Logic Apps validation before ARM evaluates it,
// so the outer-ARM "[parameters('scheduleFrequency')]" strings baked into the file get
// rejected as invalid FlowRecurrenceFrequency values. Overwrite the recurrence in Bicep.
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
  identity: { type: 'SystemAssigned' }
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
    }
  }
}

output logicAppName               string = logicAppName
output managedIdentityPrincipalId string = workflow.identity.principalId
output nextSteps                  string = 'IMPORTANT: Grant Graph roles (Device.ReadWrite.All, Mail.Send) to managedIdentityPrincipalId - see README. Then cycle the workflow Disabled -> Enabled to refresh the MI token.'
