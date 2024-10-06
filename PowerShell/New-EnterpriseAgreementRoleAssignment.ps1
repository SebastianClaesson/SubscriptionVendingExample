function New-EnterpriseAgreementRoleAssignment {

    [CmdletBinding()]
    param (

        #Workload Identity in Entra ID, This is the Application (Client) Id
        [Parameter(Mandatory)]
        [string]
        $WorkloadId,

        # Roles available as per defined at https://learn.microsoft.com/en-us/azure/cost-management-billing/manage/assign-roles-azure-service-principals#permissions-that-can-be-assigned-to-the-service-principal
        [Parameter(Mandatory)]
        [ValidateSet('SubscriptionCreator', 'DepartmentReader', 'EA purchaser', 'EnrollmentReader')]
        [string]
        $RoleDefinitionName,

        # Billing Account Id
        [Parameter()]
        [int]
        $BillingAccountId,
    
        # Enrollment Account Id
        [Parameter()]
        [int]
        $EnrollmentAccountId
    )

    $RoleDefinitionIds = @{
        'SubscriptionCreator' = 'a0bcee42-bf30-4d1b-926a-48d21664ef71'
        'DepartmentReader'    = 'db609904-a47f-4794-9be8-9bd86fbffd8a'
        'EA purchaser'        = 'da6647fb-7651-49ee-be91-c43c4877f0c4'
        'EnrollmentReader'    = '24f8edb6-1668-4659-b5e2-40bb5f3a7d7e'
    }

    $RoleAssignmentId = $RoleDefinitionIds[$RoleDefinitionName]

    # The script requires the Az PowerShell Module
    if (! (Get-Module 'Az' -ListAvailable)) {
        Throw 'Please install the Az PowerShell Module "https://www.powershellgallery.com/packages/Az"'
    }

    # Check if the user is already logged in to the Az PowerShell Module.
    if (! (Get-AzContext -ListAvailable)) {
        # User is not logged into Az PowerShell Module
        Write-verbose "Please login to the Az PowerShell Module, this is used for confirming the existance of the Application Id and obtain an Azure Access Token" -Verbose
        Connect-AzAccount
    }

    # Use the Access Token provided by Az PowerShell Module and create a header containing it.
    # Handle the breaking change upcoming in Az.Accounts 4.0.0 - https://learn.microsoft.com/en-us/powershell/azure/upcoming-breaking-changes?view=azps-12.3.0
    if ((Get-Module Az.Accounts).Version -lt '4.0.0') {
        $Token = $(Get-AzAccessToken).Token
    }
    else {
        $Token = $(Get-AzAccessToken).Token | ConvertFrom-SecureString -AsPlainText
    }
    $Headers = @{'Authorization' = "Bearer $Token"; 'Content-Type' = 'application/json' }

    # Get Tenant Id
    $TenantId = (get-azcontext).tenant.id

    # Get the Workload Identity to confirm that it exists. This requires reader access in Entra Id.
    $WorkloadIdentity = Get-AzADServicePrincipal -ApplicationId $WorkloadId

    if (!$WorkloadIdentity) {
        throw "Unable to find the workload identity with Application Id '$WorkloadId' in the Tenant Id '$TenantId'"
    }

    # Get Billing Account
    $BillingAccountUrl = "https://management.azure.com/providers/Microsoft.Billing/billingAccounts?api-version=2019-10-01-preview"
    Write-verbose "Fetching all billing accounts." -Verbose
    $BillingAccounts = (Invoke-RestMethod -Method Get -Uri $BillingAccountUrl -Headers $Headers).value
    if (!$BillingAccountId) {
        $BillingAccount = $BillingAccounts | 
        Select-Object Id, @{'N' = 'DisplayName'; E = { $_.properties.displayName } }, @{'N' = 'AccountStatus'; E = { $_.properties.accountStatus } }, @{'N' = 'AccountType'; E = { $_.properties.accountType } }, @{'N' = 'AgreementType'; E = { $_.properties.agreementType } }, Name |
        Out-GridView -OutputMode Single -Title "Select the correct billing account."  | Select-Object -ExpandProperty Name
    }
    else {
        $BillingAccount = $BillingAccounts | Where-Object { $_.name -eq $BillingAccountId } | Select-Object -ExpandProperty Name
        Write-Verbose "Successfully found the Billing Account with id '$BillingAccountId'" -Verbose
    }
    if (!$BillingAccount) {
        throw "Billing Account Id '$BillingAccountId' cannot be found"
    } 

    # Get Enrollment Account
    $EnrollmentUrl = "https://management.azure.com/providers/Microsoft.Billing/billingAccounts/$BillingAccount/enrollmentAccounts?api-version=2019-10-01-preview"
    $EnrollmentAccounts = (Invoke-RestMethod -Method Get -Uri $EnrollmentUrl -Headers $Headers).value
    if (!$EnrollmentAccountId) {
        $EnrollmentAccount = $EnrollmentAccounts | 
        Select-Object Id, @{'N' = 'DisplayName'; E = { $_.properties.displayName } }, @{'N' = 'Status'; E = { $_.properties.Status } }, @{'N' = 'StartDate'; E = { $_.properties.startDate } }, @{'N' = 'EndDate'; E = { $_.properties.endDate } }, Name |
        Out-GridView -OutputMode Single -Title "Select the Enrollment account."  | Select-Object -ExpandProperty Name
    }
    else {
        $EnrollmentAccount = (Invoke-RestMethod -Method Get -Uri $EnrollmentUrl -Headers $Headers).value | Where-Object { $_.name -eq $EnrollmentAccountId }
    }
    if (!$EnrollmentAccount) {
        throw "Enrollment Account Id '$EnrollmentAccountId' cannot be found"
    } 
    Write-Verbose "Successfully found the Enrollment Account with id '$EnrollmentAccountId'" -Verbose

    # Generate a unique role assignment id.
    # https://learn.microsoft.com/en-us/azure/cost-management-billing/manage/assign-roles-azure-service-principals#assign-enrollment-account-role-permission-to-the-service-principal
    $UniqueRoleAssignmentId = (New-guid).Guid

    # Create a Role Assignment for our Workload Identity.
    $RoleAssignmentUrl = "https://management.azure.com/providers/Microsoft.Billing/billingAccounts/$BillingAccount/enrollmentAccounts/$EnrollmentAccount/billingRoleAssignments/$UniqueRoleAssignmentId`?api-version=2019-10-01-preview"
    $Body = @{
        "properties" = @{
            "principalId"       = "$($WorkloadIdentity.id)"
            "principalTenantId" = "$TenantId"
            "roleDefinitionId"  = "/providers/Microsoft.Billing/billingAccounts/$BillingAccount/enrollmentAccounts/$EnrollmentAccount/billingRoleDefinitions/$RoleAssignmentId"
        }
    } | ConvertTo-Json -depth 100

    try {
        Invoke-RestMethod -Method Put -Uri $RoleAssignmentUrl -Headers $Headers -Body $Body
        Write-verbose "Successfully create the role assignment." -Verbose
    } catch {
        throw
    }
}