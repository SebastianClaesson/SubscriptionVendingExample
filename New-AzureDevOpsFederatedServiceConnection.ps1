## Requires the module ADOPS
function New-ADOServiceConnection {
    [CmdletBinding()]
    param (
        # SubscriptionId
        [Parameter(Mandatory)]
        [string]
        $SubscriptionId,

        # SubscriptionName
        [Parameter(Mandatory)]
        [string]
        $SubscriptionName,

        # Environment
        [Parameter(Mandatory)]
        [string]
        $Environment,

        # Identifier - This can be a project name, Service name or such to identify the Azure Landing Zone
        [Parameter(Mandatory)]
        [string]
        $Identifier,

        # Azure DevOps Organization
        [Parameter(Mandatory)]
        [string]
        $ADOOrganization,

        # Azure DevOps Project Name
        [Parameter(Mandatory)]
        [string]
        $ADOProjectName,

        # Role Defintion Name in Azure to be assigned to our Service Connection over the entire Landing Zone
        [Parameter(Mandatory)]
        [string]
        $RoleDefinitionName
    )
}

## Naming convention
$AppRegistrationName = "sc-azdo-$ProjectName-$Identifier-$Environment"
$ServiceConnectionName = "sc-$Identifier-$Environment"

# The script requires the Az PowerShell Module
if (! (Get-Module 'Az' -ListAvailable)) {
    Throw 'Please install the Az PowerShell Module "https://www.powershellgallery.com/packages/Az"'
}

# The script requires the ADOPS PowerShell Module
if (! (Get-Module 'ADOPS' -ListAvailable)) {
    Throw 'Please install the ADOPS PowerShell Module "https://www.powershellgallery.com/packages/ADOPS"'
}

# Check if the user is already logged in to the Az PowerShell Module.
$AzureContext = Get-AzContext
if (!$AzureContext) {
    # User is not logged into Az PowerShell Module
    Write-verbose "Please login to the Az PowerShell Module, this is used for confirming the existance of the Application Id and obtain an Azure Access Token" -Verbose
    Connect-AzAccount
}

$Description = "Federated Identity connection for Azure Subscription '$($AzureLandingZone.SubscriptionId)' as '$RoleDefinitionName'"

## Azure
$TenantId = $AzureContext.Tenant.Id

if ((Get-Module Az.Accounts).Version -lt '4.0.0') {
    $AccessToken = $(Get-AzAccessToken).Token
}
else {
    $AccessToken = $(Get-AzAccessToken).Token | ConvertFrom-SecureString -AsPlainText
}

# Verify that the Azure Landing zone exists.
$AzureLandingZone = Get-AzSubscription -SubscriptionId $SubscriptionId

# Connects to Azure DevOps
Connect-ADOPS -Organization $Organization -OAuthToken $AccessToken

# Gets the Azure DevOps project
$AzdoProject = Get-ADOPSProject -Name $ProjectName
if (!($AzdoProject)) {
    Get-ADOPSProject | Select-Object name, id | Sort-Object Name
    Throw "Unable to find $ProjectName"
}

# Gets the Azure DevOps Service Conection, if it already exists.
$AdopsSC = Get-ADOPSServiceConnection -Name $ServiceConnectionName -Project $ProjectName -IncludeFailed -ErrorAction SilentlyContinue
if (!($AdopsSC)) {
    $Params = @{
        TenantId = $TenantId 
        SubscriptionName = $SubscriptionName 
        SubscriptionId = $SubscriptionId 
        WorkloadIdentityFederation = $true
        Project = $ProjectName 
        ConnectionName = $ServiceConnectionName.ToLower()
        CreationMode = 'Manual'
        Description = $Description
    }
    $AdopsSC = New-ADOPSServiceConnection @Params
} else {
    Write-Verbose "Found '$ServiceConnectionName' in the Project $ProjectName" -Verbose
}

# Creates the Workload identity (Application Registration) using Az Module
$EntraIdAppParams = @{
    DisplayName = "$AppRegistrationName".tolower()
    Description = "Azure DevOps Service Connection used in '$ProjectName' for credential federation."
    Confirm = $false
}
$App = Get-AzADServicePrincipal -DisplayName $EntraIdAppParams.DisplayName
if (!($App)) {
    $App = New-AzADServicePrincipal -AccountEnabled @EntraIdAppParams
} else {
    Write-Verbose "The Entra ID Service Principal '$($App.DisplayName)' already exists." -Verbose
}
$AppDetails = Get-AzADApplication -ApplicationId $App.AppId

# Creates Entra Id Federated Credentials for authentication between Azure DevOps and Entra id using our Workload identity

$FederatedCreds = Get-AzADAppFederatedCredential -ApplicationObjectId $AppDetails.Id

if ($AdopsSC.authorization.parameters.workloadIdentityFederationSubject -in $FederatedCreds.Subject) {
    Write-Verbose "Azure DevOps Federated Credentials have already been configured." -Verbose
} else {
    $FederatedCredentialsParams = @{
        ApplicationObjectId = $AppDetails.Id
        Issuer = $AdopsSC.authorization.parameters.workloadIdentityFederationIssuer
        Subject = $AdopsSC.authorization.parameters.workloadIdentityFederationSubject
        Name = 'AzureDevOpsAuthentication'
        Description = "Azure DevOps Federated Credentials"
        Audience = 'api://AzureADTokenExchange'
    }
    New-AzADAppFederatedCredential @FederatedCredentialsParams
}

# Removes the default client secret
$Secret = Get-AzADAppCredential -ObjectId $AppDetails.Id
if ($Secret) {
    Remove-AzADAppCredential -KeyId $Secret.KeyId -ApplicationId $AppDetails.AppId
}

# Assigning correct permissions to Azure Landing Zone.
if (!(Get-AzRoleAssignment -Scope "/subscriptions/$($AzureLandingZone.SubscriptionId)" -RoleDefinitionName $RoleDefinitionName -ObjectId $App.Id)) {
    New-AzRoleAssignment -Scope "/subscriptions/$($AzureLandingZone.SubscriptionId)" -RoleDefinitionName $RoleDefinitionName -ObjectId $App.Id
} else {
    Write-Verbose "'$($App.Id)' already has access as '$RoleDefinitionName' over subscription '$($AzureLandingZone.SubscriptionId)'" -Verbose
}

# Completes the Service connection authentication details in Azure DevOps
$Params = @{
    TenantId = $TenantId
    SubscriptionName = $subscriptionName
    SubscriptionId = $subscriptionId
    Project = $ProjectName
    ServiceEndpointId = $AdopsSC.Id
    ConnectionName = $AdopsSC.name
    ServicePrincipalId = $App.AppId
    WorkloadIdentityFederationIssuer = $AdopsSC.authorization.parameters.workloadIdentityFederationIssuer
    WorkloadIdentityFederationSubject = $AdopsSC.authorization.parameters.workloadIdentityFederationSubject
    Description = $Description
}
Set-ADOPSServiceConnection @Params