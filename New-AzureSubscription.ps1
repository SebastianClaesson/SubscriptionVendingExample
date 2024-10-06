[CmdletBinding()]
param (

    # BillingScope
    [Parameter(Mandatory)]
    [string]
    $BillingScope,

    # Workload
    [Parameter(Mandatory)]
    [string]
    $Workload,

    # ManagementGroupId
    [Parameter(Mandatory)]
    [string]
    $ManagementGroupId,

    # Identifier
    [Parameter(Mandatory)]
    [string]
    $Identifier,

    # Environment
    [Parameter(Mandatory)]
    [string]
    $EnvironmentShortName,

    # DisplayName
    [Parameter(Mandatory)]
    [string]
    $DisplayName
)

# The script requires the Az PowerShell Module
if (! (Get-Module 'Az.Subscription' -ListAvailable)) {
    Throw 'Please install the Az PowerShell Module "https://www.powershellgallery.com/packages/Az.Subscription"'
}

Import-Module .\Az.Subscription

$params = @{
    AliasName = "$Identifier-$EnvironmentShortName".toLower()
    SubscriptionName = "$DisplayName-$EnvironmentShortName".toLower()
    BillingScope = $BillingScope
    Workload = $Workload
    ManagementGroupId = $ManagementGroupId
}

Write-Verbose "Attempting to list any Azure Subscription" -Verbose
$SubAliases = Get-AzSubscriptionAlias
Write-verbose "Found a total of $($SubAliases.Count) Subscription Aliases." -Verbose
$SubAliases | Select-Object AliasName, SubscriptionId

if ($SubAliases.AliasName -Contains "$($params.AliasName)") {
    $SubscriptionInfo = $SubAliases | Where-Object {$_.AliasName -eq "$($params.AliasName)"}
    Write-Verbose "The subscription ""$($SubscriptionInfo.AliasName)"" already exists with id: '$($SubscriptionInfo.SubscriptionId)', Skipping creation." -Verbose
} else {
    try {
        $SubscriptionInfo = New-AzSubscriptionAlias @params
    
        Write-Output $SubscriptionInfo
    
        Write-verbose "Successfully created the subscription '$($SubscriptionInfo.AliasName)' with id: '$($SubscriptionInfo.SubscriptionId)'" -Verbose
    } catch {
        throw
    }
}
