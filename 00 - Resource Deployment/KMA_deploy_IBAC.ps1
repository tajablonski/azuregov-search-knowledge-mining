# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the MIT License.

Write-Host "Ensuring Azure dependencies are installed."
if (!(Get-Module -Name Az)) {
    Write-Host "Installing Az PowerShell..."
    Install-Module -Name Az
    Import-Module -Name Az
}
if (!(Get-Module -Name Az.Search)) {
    Write-Host "Installing Az.Search PowerShell..."
    Install-Module -Name Az.Search
    Import-Module -Name Az.Search
}

Write-Host @"

------------------------------------------------------------
Guidance for choosing parameters for resource deployment:
 uniqueName: Choose a name that is globally unique and less than 12 characters. This name will be used as a prefix for the resources created and the resultant name must not conflict with any other Azure resource. 
   Ex: FabrikamTestPilot1
 
 resourceGroup: Please create a resource group in your Azure account and retrieve its resource group name.
   Ex: testpilotresourcegroup

 subscriptionId: Your subscription id.
   Ex: 123456-7890-1234-5678-9012345678
------------------------------------------------------------

"@

function Deploy
{
    # Read parameters from user.
    Write-Host "Press enter to use [default] value."
    Write-Host "For uniqueName, please enter a string with 10 or less characters."
    while (!($uniqueName = Read-Host "uniqueName")) { Write-Host "You must provide a uniqueName."; }
    while (!($resourceGroupName = Read-Host "resourceGroupName")) { Write-Host "You must provide a resourceGroupName."; }
    while (!($subscriptionId = Read-Host "subscriptionId")) { Write-Host "You must provide a subscriptionId."; }

    $defaultLocation = "usgovvirginia"
    if (!($location = Read-Host "location [$defaultLocation]")) { $location = $defaultLocation }
    $defaultSearchSku = "basic"
    if (!($searchSku = Read-Host "searchSku [$defaultSearchSku]")) { $searchSku = $defaultSearchSku }
        
    # Generate derivative parameters.
    $searchServiceName = $uniqueName + "search";
    $webappname = $uniqueName + "app";
    $cogServicesName = $uniqueName + "cog";
    $appInsightsName = $uniqueName + "insights";
    $storageAccountName = $uniqueName + "str";
    $storageContainerName = "documents";
        
    $dataSourceName = $uniqueName + "-datasource";
    $skillsetName = $uniqueName + "-skillset";
    $indexName = $uniqueName + "-index";
    $indexerName = $uniqueName + "-indexer";
 
    # These values are extracted by this process automatically. Do not set values here.
    $global:storageConnectionString = "";
    $global:searchServiceKey = "";
    $global:cogServicesKey = "";
 
    function ValidateParameters
    {
        Write-Host "------------------------------------------------------------";
        Write-Host "Here are the values of all parameters:";
        Write-Host "uniqueName: '$uniqueName'";
        Write-Host "resourceGroupName: '$resourceGroupName'";
        Write-Host "subscriptionId: '$subscriptionId'";
        Write-Host "location: '$location'";
        Write-Host "searchSku: '$searchSku'";
        Write-Host "searchServiceName: '$searchServiceName'";
        Write-Host "webappname: '$webappname'";
        Write-Host "cogServicesName: '$cogServicesName'";
        Write-Host "appInsightsName: '$appInsightsName'";
        Write-Host "storageAccountName: '$storageAccountName'";
        Write-Host "storageContainerName: '$storageContainerName'";
        Write-Host "dataSourceName: '$dataSourceName'";
        Write-Host "skillsetName: '$skillsetName'";
        Write-Host "indexName: '$indexName'";
        Write-Host "indexerName: '$indexerName'";
        Write-Host "------------------------------------------------------------";
    }

    ValidateParameters;
 
    function Signin
    {
        # Sign in
        Write-Host "Logging in for '$subscriptionId'";
        Connect-AzAccount -EnvironmentName AzureUSGovernment;

        # Select subscription
        Write-Host "Selecting subscription '$subscriptionId'";
        Select-AzSubscription -SubscriptionID $subscriptionId;
    }

    Signin;
 
    function PrepareSubscription
    {
        # Register RPs
        $resourceProviders = @("microsoft.cognitiveservices", "microsoft.insights", "microsoft.search", "microsoft.storage");
        if ($resourceProviders.length) {
            Write-Host "Registering resource providers"
            foreach ($resourceProvider in $resourceProviders) {
                Register-AzResourceProvider -ProviderNamespace $resourceProvider;
            }
        }
    }

    PrepareSubscription;
    
    function FindOrCreateResourceGroup
    {
        # Create or check for existing resource group
        $resourceGroup = Get-AzResourceGroup -Name $resourceGroupName -ErrorAction SilentlyContinue
        if (!$resourceGroup) {
            Write-Host "Resource group '$resourceGroupName' does not exist.";
            if (!$location) {
                $location = Read-Host "please enter a location:";
            }
            Write-Host "Creating resource group '$resourceGroupName' in location '$location'";
            New-AzResourceGroup -Name $resourceGroupName -Location $location
        }
        else {
            Write-Host "Using existing resource group '$resourceGroupName'";
        }
    }

    FindOrCreateResourceGroup;
    
    function CreateStorageAccountAndContainer
    {
        # Create a new storage account
        Write-Host "Creating Storage Account";

        # Create the resource using the API
        $storageAccount = New-AzStorageAccount 
            -ResourceGroupName $resourceGroupName 
            -Name $storageAccountName 
            -Location $location 
            -SkuName Standard_LRS 
            -Kind StorageV2 
            -AllowSharedKeyAccess $false
        
        # Disable Shared Key access for the storage account
        Write-Host "Disabling Shared Key access";
        Update-AzStorageAccount 
            -ResourceGroupName $resourceGroupName 
            -Name $storageAccountName 
            -AllowSharedKeyAccess $false

        $global:storageConnectionString = 'DefaultEndpointsProtocol=https;AccountName=' + $storageAccountName + ';EndpointSuffix=core.usgovcloudapi.net' 

        $storageContext = New-AzStorageContext 
            -StorageAccountName $storageAccountName 
            -UseManagedIdentity $true
        
        Write-Host "Creating Storage Container";
        $storageContainer = New-AzStorageContainer 
            -Name $storageContainerName 
            -Context $storageContext 
            -Permission Off

        Write-Host "Uploading sample documents directory";		
        $filepath= "../sample_documents"
        foreach($file in Get-ChildItem $filepath)
        {
            Set-AzStorageBlobContent -File $file.FullName -Container $storageContainerName -Properties @{"ContentType" = [System.Web.MimeMapping]::GetMimeMapping($file.FullName);} -Context $storageContext -Force 
        }
    }

    CreateStorageAccountAndContainer;
    
    function CreateSearchServices
    {
        # Create a cognitive services resource
        Write-Host "Creating Cognitive Services";
        $cogServices = New-AzCognitiveServicesAccount 
            -ResourceGroupName $resourceGroupName 
            -Name $cogServicesName 
            -Location $location 
            -SkuName S0 
            -Type CognitiveServices
        $global:cogServicesKey = (Get-AzCognitiveServicesAccountKey -ResourceGroupName $resourceGroupName -name $cogServicesName).Key1   
        Write-Host "Cognitive Services Key: '$global:cogServicesKey'";
            
        # Create a new search service
        # Alternatively, you can now use the Az.Search module: https://docs.microsoft.com/en-us/azure/search/search-manage-powershell 
        Write-Host "Creating Search Service";
        $searchService = New-AzSearchService  
            -ResourceGroupName $resourceGroupName 
            -Name $searchServiceName 
            -Sku $searchSku -Location $location 
            -PartitionCount 1 
            -ReplicaCount 1

        $global:searchServiceKey = (Get-AzSearchAdminKeyPair -ResourceGroupName $resourceGroupName -ServiceName $searchServiceName).Primary         
        Write-Host "Search Service Key: '$global:searchServiceKey'";
    }

    CreateSearchServices;
    
    function CreateSearchIndex
    {
        Write-Host "Creating Search Index"; 
        
        function CallSearchAPI
        {
            param (
                [string]$url,
                [string]$body
            )

            $headers = @{
                'api-key' = $global:searchServiceKey
                'Content-Type' = 'application/json' 
                'Accept' = 'application/json' 
            }
            $baseSearchUrl = "https://"+$searchServiceName+".search.azure.us"
            $fullUrl = $baseSearchUrl + $url
        
            Write-Host "Calling api: '"$fullUrl"'";
            Invoke-RestMethod -Uri $fullUrl -Headers $headers -Method Put -Body $body | ConvertTo-Json
        }; 

        # Create the datasource
        $dataSourceBody = Get-Content -Path .\templates\base-datasource.json  
        $dataSourceBody = $dataSourceBody.Replace("YOUR-STORAGE-NAME", $storageAccountName)  
        $dataSourceBody = $dataSourceBody.Replace("YOUR-STORAGE-CONTAINER-NAME", $storageContainerName)  
        $dataSourceBody = $dataSourceBody.Replace("YOUR-STORAGE-KEY", $global:storageConnectionString)  
        $dataSourceBody = $dataSourceBody.Replace("YOUR-SEARCH-SERVICE-NAME", $searchServiceName)
        $dataSourceBody = $dataSourceBody.Replace("YOUR-RESOURCE-GROUP-NAME", $resourceGroupName)
        $dataSourceBody = $dataSourceBody.Replace("YOUR-SUBSCRIPTION-ID", $subscriptionId)  
        
        CallSearchAPI -url "/datasources/$dataSourceName" -body $dataSourceBody
        
        # Create the skillset
        $skillsetBody = Get-Content -Path .\templates\base-skillset.json  
        $skillsetBody = $skillsetBody.Replace("YOUR-COG-SERVICES-KEY", $global:cogServicesKey)  
        CallSearchAPI -url "/skillsets/$skillsetName" -body $skillsetBody 
        
        # Create the index
        $indexBody = Get-Content -Path .\templates\base-index.json  
        CallSearchAPI -url "/indexes/$indexName" -body $indexBody 
        
        # Create the indexer
        $indexerBody = Get-Content -Path .\templates\base-indexer.json  
        $indexerBody = $indexerBody.Replace("YOUR-INDEX-NAME", $indexName)  
        $indexerBody = $indexerBody.Replace("YOUR-DATASOURCE-NAME", $dataSourceName)  
        $indexerBody = $indexerBody.Replace("YOUR-SKILLSET-NAME", $skillsetName)  
        CallSearchAPI -url "/indexers/$indexerName" -body $indexerBody 
    }

    CreateSearchIndex;
 
    function CreateWebApp
    {
        # Create a new app service plan
        Write-Host "Creating App Service Plan";
        $servicePlan = New-AzAppServicePlan 
            -ResourceGroupName $resourceGroupName 
            -Name $webappname 
            -Location $location 
            -Tier "Basic" 
            -NumberofWorkers 1;

        # Create a new webapp
        Write-Host "Creating Web App";
        $webapp = New-AzWebApp 
            -ResourceGroupName $resourceGroupName 
            -Name $webappname 
            -Location $location 
            -AppServicePlan $servicePlan;
                
        # Configure app settings
        Write-Host "Updating App Settings";
        $newSettings = @{}
        $newSettings["AZURE_COGNITIVE_SEARCH_API_KEY"] = $global:searchServiceKey
        $newSettings["AZURE_COGNITIVE_SEARCH_NAME"] = $searchServiceName
        $newSettings["AZURE_STORAGE_NAME"] = $storageAccountName
        $newSettings["AZURE_STORAGE_CONTAINER_NAME"] = $storageContainerName
        $newSettings["AZURE_STORAGE_KEY"] = $global:storageConnectionString
        $newSettings["AZURE_COGNITIVE_SERVICES_KEY"] = $global:cogServicesKey

        Set-AzWebApp -ResourceGroupName $resourceGroupName -Name $webappname -AppSettings $newSettings
    }

    CreateWebApp;

    Write-Host "To see your app in action, please visit: http://"$webappname".azurewebsites.us"; 
    
    function PrintAppsettings {
        Write-Host "Copy and paste the following values to update the appsettings.json file described in the next folder:"
        Write-Host "------------------------------------------------------------"
        Write-Host "SearchServiceName: '$searchServiceName'"
        Write-Host "SearchApiKey: '$global:searchServiceKey'"
        Write-Host "SearchIndexName: '$indexName'"
        Write-Host "SearchIndexerName: '$indexerName'"
        Write-Host "StorageAccountName: '$storageAccountName'"
        Write-Host "StorageAccountKey: 'UseManagedIdentity'"
        $StorageContainerAddress = ("https://"+$storageAccountName+".blob.core.usgovcloudapi.net/"+$storageContainerName)
        Write-Host "StorageContainerAddress: '$StorageContainerAddress'"
        Write-Host "StorageContainerAddress2: '$StorageContainerAddress2'"
        Write-Host "StorageContainerAddress3: '$StorageContainerAddress3'"
        Write-Host "KeyField: '$KeyField'"
        Write-Host "IsPathBase64Encoded: '$IsPathBase64Encoded'"
        Write-Host "SearchApiVersion: '$SearchApiVersion'"
        Write-Host "InstrumentationKey: '$InstrumentationKey'"
        Write-Host "AzureMapsSubscriptionKey: '$AzureMapsSubscriptionKey'"
        Write-Host "GraphFacet: '$GraphFacet'"
        Write-Host "Customizable: '$Customizable'"
        Write-Host "OrganizationName: '$OrganizationName'"
        Write-Host "OrganizationLogo: '$OrganizationLogo'"
        Write-Host "OrganizationWebSiteUrl: '$OrganizationWebSiteUrl'"
        Write-Host "------------------------------------------------------------"
    }
    PrintAppsettings
    

    function DeployWebUICode {
        Set-Location "..\02 - Web UI Template\CognitiveSearch.UI"
        dotnet publish
        Set-Location ".\bin\Debug\netcoreapp3.1\publish\"
    
        $json = Get-Content .\appsettings.json | ConvertFrom-Json
        $json.SearchServiceName = "$searchServiceName"
        $json.SearchApiKey = "$global:searchServiceKey"
        $json.SearchIndexName = "$indexName"
        $json.SearchIndexerName = "$indexerName"
        $json.StorageAccountName = "$storageAccountName"
        $json.StorageAccountKey = "UseManagedIdentity"
        $StorageContainerAddress = ("https://"+$storageAccountName+".blob.core.usgovcloudapi.net/"+$storageContainerName)
        $json.StorageContainerAddress = "$StorageContainerAddress"
        $json.StorageContainerAddress2 = "https://{storage-account-name}.blob.core.usgovcloudapi.net/{container-name}"
        $json.StorageContainerAddress3 = "https://{storage-account-name}.blob.core.usgovcloudapi.net/{container-name}"
        $json.KeyField = "metadata_storage_path"
        $json.SearchApiVersion = "2020-06-30"
        $json.InstrumentationKey = "$InstrumentationKey"
        $json.AzureMapsSubscriptionKey = "$AzureMapsSubscriptionKey"
        $json.GraphFacet = "$GraphFacet"
        $json.Customizable = "true"
        $json.OrganizationName = "Microsoft"
        $json.OrganizationLogo = "~/images/logo.png"
        $json.OrganizationWebSiteUrl = "https://www.microsoft.com"
        $json | ConvertTo-Json | Set-Content .\appsettings.json
    
        Compress-Archive * ..\..\CognitiveSearchUI.zip -Force
        Set-location "..\.."
        Publish-AzWebApp -ResourceGroupName $resourceGroupName -Name $webappname -ArchivePath $pwd\CognativeSearchUI.zip
    }
    DeployWebUICode
    


}

Deploy;
