<#
.SYNOPSIS
    This cmdlet processes AzOpsState changes and takes appropriate action by invoking ARM deployment and limited set of imperative operations required by platform that is currently not supported in ARM.
.DESCRIPTION
    This cmdlet invokes ARM deployment by calling New-AzDeployment* command at appropriate scope mapped to tenant, Management Group, Subscription or resource group in AzOpsState folder.
        1) Filename must end with <template-name>.parameters.json
        2) This cmdlet will look for <template-name>.json in same directory and use that template if found.
        3) If no template file is found, it will use default template\template.json for supported resource types.

    This cmdlet invokes following imperative operations that are not supported in ARM.
        1) Subscription Creation with Enterprise Enrollment - Subscription will be created if not found in Azure where service principle have access. Subscription will also be moved to the Management Group.

        2) Resource providers registration until ARM support is available.  Following format is used for *.providerfeatures.json 
            [
                {
                    "ProviderNamespace":  "Microsoft.Security",
                    "RegistrationState":  "Registered"
                }
            ]
        3) Resource provider features registration until ARM support is available.  Following format is used for *.resourceproviders.json
            [
                {
                    "FeatureName":  "",
                    "ProviderName":  "",
                    "RegistrationState":  ""
                }
            ]
.EXAMPLE
    # Invoke ARM Template Deployment
    New-AzOpsStateDeployment -filename 'C:\Git\CET-NorthStar\azops\3fc1081d-6105-4e19-b60c-1ec1252cf560\contoso\.AzState\Microsoft.Management-managementGroups_contoso.parameters.json'
.EXAMPLE
    # Invoke Subscription Creation
    New-AzOpsStateDeployment -filename 'C:\Git\CET-NorthStar\azops\3fc1081d-6105-4e19-b60c-1ec1252cf560\contoso\platform\connectivity\subscription.json'
.EXAMPLE
    # Invoke provider features registration
    New-AzOpsStateDeployment -filename 'C:\Git\CET-NorthStar\azops\3fc1081d-6105-4e19-b60c-1ec1252cf560\contoso\platform\connectivity\providerfeatures.json'
.EXAMPLE
    # Invoke resource providers registration
    New-AzOpsStateDeployment -filename 'C:\Git\CET-NorthStar\azops\3fc1081d-6105-4e19-b60c-1ec1252cf560\contoso\platform\connectivity\resourceproviders.json'
.INPUTS
    Filename
.OUTPUTS
    None
#>
function New-AzOpsStateDeployment {

    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [ValidateScript( { Test-Path $_ })]
        $filename
    )

    begin {}

    process {
        Write-AzOpsLog -Level Verbose -Topic "pwsh" -Message ("Initiating function " + $MyInvocation.MyCommand + " process")

        Write-AzOpsLog -Level Verbose -Topic "pwsh" -Message "New-AzOpsStateDeployment for $filename"
        $Item = Get-Item -Path $filename
        $scope = New-AzOpsScope -path $Item

        if ($scope.type) {
            $templateParametersJson = Get-Content $filename | ConvertFrom-json

            if ($scope.type -eq 'subscriptions' -and $filename -match '/*.subscription.json$') {

                Write-AzOpsLog -Level Verbose -Topic "pwsh" -Message "Upsert subscriptions for $filename"
                $subscription = Get-AzSubscription -SubscriptionName $scope.subscriptionDisplayName -ErrorAction SilentlyContinue

                if ($null -eq $subscription) {
                    Write-AzOpsLog -Level Verbose -Topic "pwsh" -Message "Creating new Subscription"

                    if ((Get-AzEnrollmentAccount)) {
                        if ($global:AzOpsEnrollmentAccountPrincipalName) {
                            Write-AzOpsLog -Level Verbose -Topic "pwsh" -Message "Querying EnrollmentAccountObjectId for $($global:AzOpsEnrollmentAccountPrincipalName)"
                            $EnrollmentAccountObjectId = (Get-AzEnrollmentAccount | Where-Object -FilterScript { $_.PrincipalName -eq $Global:AzOpsEnrollmentAccountPrincipalName }).ObjectId
                        }
                        else {
                            Write-AzOpsLog -Level Verbose -Topic "pwsh" -Message "Using first enrollement account"
                            $EnrollmentAccountObjectId = (Get-AzEnrollmentAccount)[0].ObjectId
                        }

                        Write-AzOpsLog -Level Verbose -Topic "pwsh" -Message "EnrollmentAccountObjectId: $EnrollmentAccountObjectId"

                        $subscription = New-AzSubscription -Name $scope.Name -OfferType $global:AzOpsOfferType -EnrollmentAccountObjectId $EnrollmentAccountObjectId
                        Write-AzOpsLog -Level Verbose -Topic "pwsh" -Message "Creating new Subscription Success!"

                        $ManagementGroupName = $scope.managementgroup
                        Write-AzOpsLog -Level Verbose -Topic "pwsh" -Message "Assigning Subscription to Management Group $ManagementGroupName"
                        New-AzManagementGroupSubscription -GroupName $ManagementGroupName -SubscriptionId $subscription.SubscriptionId
                    }
                    else {
                        Write-AzOpsLog -Level Error -Topic "pwsh" -Message "No Azure Enrollment account found for current Azure context"
                        Write-AzOpsLog -Level Error -Topic "pwsh" -Message "Create new Azure role assignment for service principle used for pipeline: New-AzRoleAssignment -ObjectId <application-Id> -RoleDefinitionName Owner -Scope /providers/Microsoft.Billing/enrollmentAccounts/<object-Id>"
                    }
                }
                else {
                    Write-AzOpsLog -Level Verbose -Topic "pwsh" -Message "Existing Subscription found with ID: $($subscription.Id) Name: $($subscription.Name)"
                    Write-AzOpsLog -Level Verbose -Topic "pwsh" -Message "Checking if it is in desired Management Group"
                    $ManagementGroupName = $scope.managementgroup
                    Write-AzOpsLog -Level Verbose -Topic "pwsh" -Message "Assigning Subscription to Management Group $ManagementGroupName"
                    New-AzManagementGroupSubscription -GroupName $ManagementGroupName -SubscriptionId $subscription.SubscriptionId

                }
            }
            if ($scope.type -eq 'subscriptions' -and $filename -match '/*.providerfeatures.json$') {
                Register-AzOpsProviderFeature -filename $filename -scope $scope
            }
            if ($scope.type -eq 'subscriptions' -and $filename -match '/*.resourceproviders.json$') {

                Register-AzOpsResourceProvider -filename $filename -scope $scope
            }
            if ($filename -match '/*.parameters.json$') {
                Write-AzOpsLog -Level Verbose -Topic "pwsh" -Message "Template deployment"

                $MainTemplateSupportedTypes = @(
                    "Microsoft.Resources/resourceGroups",
                    "Microsoft.Authorization/policyAssignments",
                    "Microsoft.Authorization/policyDefinitions",
                    "Microsoft.Authorization/PolicySetDefinitions",
                    "Microsoft.Authorization/roleDefinitions",
                    "Microsoft.Authorization/roleAssignments",
                    "Microsoft.PolicyInsights/remediations",
                    "Microsoft.ContainerService/ManagedClusters",
                    "Microsoft.KeyVault/vaults",
                    "Microsoft.Network/virtualWans",
                    "Microsoft.Network/virtualHubs",
                    "Microsoft.Network/virtualNetworks",
                    "Microsoft.Network/azureFirewalls",
                    "/providers/Microsoft.Management/managementGroups",
                    "/subscriptions"
                )

                if (($scope.subscription) -and (Get-AzContext).Subscription.Id -ne $scope.subscription) {
                    Write-AzOpsLog -Level Verbose -Topic "pwsh" -Message "Switching Subscription context from $($(Get-AzContext).Subscription.Name) to $scope.subscription "
                    Set-AzContext -SubscriptionId $scope.subscription
                }

                $templatename = (Get-Item $filename).BaseName.Replace('.parameters', '.json')
                $templatePath = (Join-Path (Get-Item $filename).Directory.FullName -ChildPath $templatename )
                if (Test-Path $templatePath) {
                    $templatePath = (Join-Path (Get-Item $filename).Directory.FullName -ChildPath $templatename )
                }
                else {

                    $effectiveResourceType = ''
                    # Check if generic template is supporting the resource type for the deployment.
                    if ((Get-Member -InputObject $templateParametersJson.parameters.input.value -Name ResourceType)) {
                        $effectiveResourceType = $templateParametersJson.parameters.input.value.ResourceType
                    }
                    elseif ((Get-Member -InputObject $templateParametersJson.parameters.input.value -Name Type)) {
                        $effectiveResourceType = $templateParametersJson.parameters.input.value.Type
                    }
                    else {
                        $effectiveResourceType = ''
                    }
                    if ($effectiveResourceType -and ($MainTemplateSupportedTypes -Contains $effectiveResourceType)) {
                        $templatePath = $env:AzOpsMainTemplate
                    }
                }

                if (Test-Path $templatePath) {
                    $deploymentName = (Get-Item $filename).BaseName.replace('.parameters', '').Replace(' ', '_')

                    if ($deploymentName.Length -gt 64) {
                        $deploymentName = $deploymentName.SubString($deploymentName.IndexOf('-') + 1)
                    }
                    Write-AzOpsLog -Level Verbose -Topic "pwsh" -Message "Template is $templatename / $templatepath and Deployment Name is $deploymentName"
                    if ($scope.resourcegroup) {
                        Write-AzOpsLog -Level Verbose -Topic "pwsh" -Message "Validating at template at resource group scope"
                        Test-AzResourceGroupDeployment -ResourceGroupName $scope.resourcegroup -TemplateFile $templatePath -TemplateParameterFile $filename -OutVariable templateErrors
                        if (-not $templateErrors) {
                            New-AzResourceGroupDeployment -ResourceGroupName $scope.resourcegroup -TemplateFile $templatePath -TemplateParameterFile $filename -Name $deploymentName
                        }
                    }
                    elseif ($scope.subscription) {
                        Write-AzOpsLog -Level Verbose -Topic "pwsh" -Message "Attempting at template at Subscription scope with default region $($Global:AzOpsDefaultDeploymentRegion)"
                        New-AzSubscriptionDeployment -Location $Global:AzOpsDefaultDeploymentRegion -TemplateFile $templatePath -TemplateParameterFile $filename -Name $deploymentName
                    }
                    elseif ($scope.managementgroup) {
                        Write-AzOpsLog -Level Verbose -Topic "pwsh" -Message "Attempting at template at Management Group scope with default region $($Global:AzOpsDefaultDeploymentRegion)"
                        New-AzManagementGroupDeployment -ManagementGroupId $scope.managementgroup -Name $deploymentName  -Location  $Global:AzOpsDefaultDeploymentRegion -TemplateFile $templatePath -TemplateParameterFile $filename
                    }
                    elseif ($scope.type -eq 'root') {
                        Write-AzOpsLog -Level Verbose -Topic "pwsh" -Message "Attempting at template at Tenant Deployment Group scope with default region $($Global:AzOpsDefaultDeploymentRegion)"
                        New-AzTenantDeployment -Name $deploymentName  -Location  $Global:AzOpsDefaultDeploymentRegion -TemplateFile $templatePath -TemplateParameterFile $filename
                    }
                }
            }
            else {
                Write-AzOpsLog -Level Verbose -Topic "pwsh" -Message "Template Path for $templatePath for $filename not found"
            }
        }
        else {
            Write-AzOpsLog -Level Warning -Topic "pwsh" -Message "Unable to determine scope type for $filename"
        }

    }

    end {}

}