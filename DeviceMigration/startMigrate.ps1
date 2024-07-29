<# INTUNE TENANT-TO-TENANT DEVICE MIGRATION V7.0
Synopsis
This solution will automate the migration of devices from one Intune tenant to another Intune tenant.  Devices can be Hybrid Entra Joined, Active Directory Domain Joined, or Entra Joined.
DESCRIPTION
Intune Device Migration Solution leverages the Microsoft Graph API to automate the migration of devices from one Intune tenant to another Intune tenant.  Devices can be hybrid AD Joined or Azure AD Joined.  The solution will also migrate the device's primary user profile data and files.  The solution leverages Windows Configuration Designer to create a provisioning package containing a Bulk Primary Refresh Token (BPRT).  Tasks are set to run after the user signs into the PC with destination tenant credentials to update Intune attributes including primary user, Entra ID device group tag, and device category.  In the last step, the device is registered to the destination tenant Autopilot service.  
USE
This script is packaged along with the other files into an intunewin file.  The intunewin file is then uploaded to Intune and assigned to a group of devices.  The script is then run on the device to start the migration process.

NOTES
When deploying with Microsoft Intune, the install command must be "%WinDir%\Sysnative\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File startMigrate.ps1" to ensure the script runs in 64-bit mode.
.OWNER
Steve Weiner
.CONTRIBUTORS
Logan Lautt
Jesse Weimer
#>

$ErrorActionPreference = "SilentlyContinue"

# Import module from same directory
Import-Module "$($PSScriptRoot)\DeviceMigration.psm1" -Force

# Import config settings from JSON file
$config = Get-Content "$($PSScriptRoot)\config.json" | ConvertFrom-Json

# Start Transcript
Start-Transcript -Path "$($config.logPath)\DeviceMigration.log" -Append -Verbose
log "Starting Device Migration V-7..."

# Initialize script
log "Initializing startMigrate.ps1..."
try
{
    initializeScript -installTag $true
    log "Script initialized successfully."
}
catch
{
    $message = $_.Exception.Message
    log "Failed to initialize script. Error: $message"
    log "Exiting script."
    exitScript -exitCode 4 -functionName "initializeScript"
}

# Copy package files to local machine
$destination = $config.localPath
log "Copying package files to $($destination)..."
Copy-Item -Path "$($PSScriptRoot)\*" -Destination $destination -Recurse -Force
log "Package files copied successfully."

# Authenticate to source tenant if exists
log "Checking for source tenant in JSON settings..."
if([string]::IsNullOrEmpty($config.sourceTenant.tenantName))
{
    log "Source tenant not found in JSON settings."
    exitScript -exitCode 4 -functionName "sourceTenant"
}
else
{
    log "Source tenant found in JSON settings."
    try
    {
        log "Authenticating to source tenant..."
        $sourceHeaders = msGraphAuthenticate -tenantName $config.sourceTenant.tenantname -clientId $config.sourceTenant.clientId -clientSecret $config.sourceTenant.clientSecret
        log "Authenticated to $($config.sourceTenant.tenantName) source tenant successfully."
    }
    catch
    {
        $message = $_.Exception.Message
        log "Failed to authenticate to $($config.sourceTenant.tenantName) source tenant. Error: $message"
        log "Exiting script."
        exitScript -exitCode 4 -functionName "msGraphAuthenticate"
    }
}


# Authenticate to target tenant if exists
log "Checking for target tenant in JSON settings..."
if([string]::IsNullOrEmpty($config.targetTenant.tenantName))
{
    log "Target tenant not found in JSON settings."
    exitScript -exitCode 4 -functionName "targetTenant"
}
else
{
    log "Target tenant found in JSON settings."
    try
    {
        log "Authenticating to target tenant..."
        $targetHeaders = msGraphAuthenticate -tenantName $config.targetTenant.tenantname -clientId $config.targetTenant.clientId -clientSecret $config.targetTenant.clientSecret
        log "Authenticated to $($config.targetTenant.tenantName) target tenant successfully."
    }
    catch
    {
        $message = $_.Exception.Message
        log "Failed to authenticate to $($config.targetTenant.tenantName) target tenant. Error: $message"
        log "Exiting script."
        exitScript -exitCode 4 -functionName "msGraphAuthenticate"
    }
}


# Check Microsoft account connection registry policy
log "Checking Microsoft account connection registry policy..."
$accountConnectionPath = "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Accounts"
$accountConnectionName = "AllowMicrosoftAccountConnection"
$accountConnectionValue = Get-ItemPropertyValue -Path $accountConnectionPath -Name $accountConnectionName -ErrorAction SilentlyContinue
if($accountConnectionValue -ne 1)
{
    log "Microsoft account connection registry policy is not set. Setting policy..."
    Set-ItemProperty -Path $accountConnectionPath -Name $accountConnectionName -Value 1
    log "Microsoft account connection registry policy set successfully."
}
else
{
    log "Microsoft account connection registry policy is set."
}

# FUNCTION: deviceObject
# DESCRIPTION: Creates a device object and writes values to registry.
# PARAMETERS: $hostname - The hostname of the device, $serialNumber - The serial number of the device, $azureAdJoined - Whether the device is Azure AD joined, $domainJoined - Whether the device is domain joined, $certPath - The path to the certificate store, $intuneIssuer - The Intune certificate issuer, $azureIssuer - The Azure certificate issuer, $groupTag - The group tag, $mdm - Whether the device is MDM enrolled.
function deviceObject()
{
    [CmdletBinding()]
    Param(
        [object]$headers,
        [string]$hostname = $env:COMPUTERNAME,
        [string]$serialNumber = (Get-CimInstance -ClassName Win32_BIOS).SerialNumber,
        [string]$azureAdJoined = (dsregcmd.exe /status | Select-String "AzureAdJoined").ToString().Split(":")[1].Trim(),
        [string]$domainjoined = (dsregcmd.exe /status | Select-String "DomainJoined").ToString().Split(":")[1].Trim(),
        [string]$certPath = "Cert:\LocalMachine\My",
        [string]$intuneIssuer = "Microsoft Intune MDM Device CA",
        [string]$azureIssuer = "MS-Organization-Access",
        [string]$groupTag = $config.groupTag,
        [string]$regPath = $config.regPath,
        [bool]$mdm = $false
    )
    # Get Intune device certificate
    $cert = Get-ChildItem -Path $certPath | Where-Object {$_.Issuer -match $intuneIssuer}
    # Get Intune and Entra device IDs if certificate exists
    if($cert)
    {
        $mdm = $true
        $intuneId = ((Get-ChildItem $cert | Select-Object Subject).Subject).TrimStart("CN=")
        $entraDeviceId = ((Get-ChildItem $certPath | Where-Object {$_.Issuer -match $azureIssuer} | Select-Object Subject).Subject).TrimStart("CN=")
        # Get Autopilot object if headers provided
        if($headers)
        {
            log "Headers provided.  Checking for Autopilot object..."
            $autopilotObject = (Invoke-RestMethod -Method Get -Uri "https://graph.microsoft.com/beta/deviceManagement/windowsAutopilotDeviceIdentities?`$filter=contains(serialNumber,'$($serialNumber)')" -Headers $headers)
            if(($autopilotObject.'@odata.count') -eq 1)
            {
                $autopilotId = $autopilotObject.value.id
                if([string]::IsNullOrEmpty($groupTag))
                {
                    $groupTag = $autopilotObject.value.groupTag
                }
                else
                {
                    $groupTag = $groupTag
                }
            }
        }
        else
        {
            log "Headers not provided.  Skipping Autopilot object check."            
            $autopilotObject = $null
        }
    }
    else
    {
        $intuneId = $null
        $entraDeviceId = $null
        $autopilotId = $null
    }
    if([string]::IsNullOrEmpty($groupTag))
    {
        $groupTag = $null
    }
    else
    {
        $groupTag = $groupTag
    }
    if($domainjoined -eq "YES")
    {
        $localDomain = Get-ItemPropertyValue -Path "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters" -Name "Domain"
    }
    else
    {
        $localDomain = $null
    }
    $pc = @{
        hostname = $hostname
        serialNumber = $serialNumber
        azureAdJoined = $azureAdJoined
        domainJoined = $domainJoined
        intuneId = $intuneId
        entraDeviceId = $entraDeviceId
        autopilotId = $autopilotId
        groupTag = $groupTag
        mdm = $mdm
        localDomain = $localDomain
    }
    # Write device object to registry
    log "Writing device object to registry..."
    foreach($x in $pc.Keys)
    {
        $name = "OLD_$($x)"
        $value = $($pc[$x])
        # Check if value is null or empty
        if(![string]::IsNullOrEmpty($value))
        {
            log "Writing $($name) with value $($value)."
            try
            {
                reg.exe add $regPath /v $name /t REG_SZ /d $value /f | Out-Host
                log "Successfully wrote $($name) with value $($value)."
            }
            catch
            {
                $message = $_.Exception.Message
                log "Failed to write $($name) with value $($value).  Error: $($message)."
            }
        }
        else
        {
            log "Value for $($name) is null.  Not writing to registry."
        }
    }
    return $pc
}

# Create OLD device object
log "Creating current (OLD) device object record..."
try
{
    $pc = deviceObject -headers $sourceHeaders
    log "Current (OLD) device object record created successfully."
}
catch
{
    $message = $_.Exception.Message
    log "Failed to create current (OLD) device object record. Error: $message"
    log "Exiting script."
    exitScript -exitCode 4 -functionName "deviceObject"
}

# FUNCTION: userObject
# DESCRIPTION: Creates a user object and writes values to registry.
# PARAMETERS: $domainJoined - Whether the user is domain joined, $azureAdJoined - Whether the user is Azure AD joined, $headers - The headers for the REST API call.
function userObject()
{
    [CmdletBinding()]
    Param(
        [string]$domainJoined = $pc.domainJoined,
        [string]$azureAdJoined = $pc.azureAdJoined,
        [object]$headers,
        [string]$regPath = $config.regPath,
        [string]$user = (Get-CimInstance -ClassName Win32_ComputerSystem | Select-Object UserName).UserName,
        [string]$SID = (New-Object System.Security.Principal.NTAccount($user)).Translate([System.Security.Principal.SecurityIdentifier]).Value,
        [string]$profilePath = (Get-ItemPropertyValue -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$($SID)" -Name "ProfileImagePath"),
        [string]$SAMName = ($user).Split("\")[1]
    )
    # If PC is NOT domain joined, get UPN from cache
    if($domainJoined -eq "NO")
    {
        $upn = (Get-ItemPropertyValue -Path "HKLM:\SOFTWARE\Microsoft\IdentityStore\Cache\$($SID)\IdentityCache\$($SID)" -Name "UserName")
        # If PC is Azure AD joined, get user ID from Graph
        if($azureAdJoined -eq "YES")
        {
            $entraUserId = (Invoke-RestMethod -Method Get -Uri "https://graph.microsoft.com/beta/users/$($upn)" -Headers $headers).id
        }
        else
        {
            $entraUserId = $null
        }
    }
    else
    {
        $upn = $null
        $entraUserId = $null
    }
    $user = @{
        user = $user
        upn = $upn
        entraUserId = $entraUserId
        profilePath = $profilePath
        SAMName = $SAMName
        SID = $SID
    }
    # Write user object to registry
    foreach($x in $user.Keys)
    {
        $name = "OLD_$($x)"
        $value = $($user[$x])
        # Check if value is null or empty
        if(![string]::IsNullOrEmpty($value))
        {
            log "Writing $($name) with value $($value)."
            try
            {
                reg.exe add $regPath /v $name /t REG_SZ /d $value /f | Out-Host
                log "Successfully wrote $($name) with value $($value)."
            }
            catch
            {
                $message = $_.Exception.Message
                log "Failed to write $($name) with value $($value).  Error: $($message)."
            }
        }
    }
    return $user
}


# Create OLD user object
log "Creating current (OLD) user object record..."
try
{
    $currentUser = userObject -headers $sourceHeaders
    log "Current (OLD) user object record created successfully."
}
catch
{
    $message = $_.Exception.Message
    log "Failed to create current (OLD) user object record. Error: $message"
    log "Exiting script."
    exitScript -exitCode 4 -functionName "userObject"
}

# Attempt to get new user info based on current SAMName
$sam = $currentUser.SAMName
$newUser = $null
# If target tenant headers exist, get new user object
if($targetHeaders)
{
    $newUserObject = Invoke-WebRequest -Method GET -Uri "https://graph.microsoft.com/beta/users?`$filter=startsWith(userPrincipalName,'$sam')" -Headers $targetHeaders
    # if new user graph request is successful, set new user object
    if($newUserObject.StatusCode -eq 200)
    {
        log "New user found in $($config.targetTenant.tenantName) tenant."
        $newUser = @{
            user = $newUserObject.value.userPrincipalName
            entraUserId = $newUserObject.value.id
            SAMName = $newUserObject.value.userPrincipalName.Split("@")[0]
            SID = $newUserObject.value.securityIdentifier
        }
    }
    else
    {
        # Make sure nuget package is installed
        $installedNuget = Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue
        if(-not($installedNuget))
        {
            log "NuGet package provider not installed.  Installing..."
            Install-PackageProvider -Name NuGet -Force
            log "NuGet package provider installed successfully."
        }
        else
        {
            log "NuGet package provider already installed."
        }
        # Check for Az.Accounts module
        $installedAzAccounts = Get-Module -Name Az.Accounts -ErrorAction SilentlyContinue
        if(-not($installedAzAccounts))
        {
            log "Az.Accounts module not installed.  Installing..."
            Install-Module -Name Az.Accounts -Force
            Import-Module Az.Accounts
            log "Az.Accounts module installed successfully."
        }
        else
        {
            log "Az.Accounts module already installed."
            Import-Module Az.Accounts
        }
        try
        {
            Connect-AzAccount
            $token = Get-AzAccessToken -ResourceUrl "https://graph.microsoft.com/"
            #Get Token form OAuth
            $token = -join("Bearer ", $token.Token)

            #Reinstantiate headers
            $headers = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
            $headers.Add("Authorization", $token)
            $headers.Add("Content-Type", "application/json")

            $output = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/me" -Headers $headers -Method "GET"
            $newUPN = $output.userPrincipalName
            if([string]::IsNullOrEmpty($newUPN))
            {
                Log "New user not found in $($config.targetTenant.tenantName) tenant."
            }
            else
            {
                $newUserObject = Invoke-WebRequest -Method GET -Uri "https://graph.microsoft.com/beta/users/$newUPN" -Headers $targetHeaders
                if($newUserObject.StatusCode -eq 200)
                {
                    log "New user found in $($config.targetTenant.tenantName) tenant."
                    $newUser = @{
                        user = $newUserObject.userPrincipalName
                        entraUserId = $newUserObject.id
                        SAMName = $newUserObject.userPrincipalName.Split("@")[0]
                        SID = $newUserObject.securityIdentifier
                    }
                }
                else
                {
                    log "New user not found in $($config.targetTenant.tenantName) tenant."
                }
            }
        }
        catch
        {
            $message = $_.Exception.Message
            log "Failed to get new user object. Error: $message"
            log "Exiting script."
            exitScript -exitCode 4 -functionName "newUserObject"
        }
    }
    # Write new user object to registry
    foreach($x in $newUser)
    {
        $name = "NEW_$($x)"
        $value = $($newUser[$x])
        if(![string]::IsNullOrEmpty($value))
        {
            log "Writing $($name) with value $($value)."
            try
            {
                reg.exe add $config.regPath /v $name /t REG_SZ /d $value /f | Out-Host
                log "Successfully wrote $($name) with value $($value)."
            }
            catch
            {
                $message = $_.Exception.Message
                log "Failed to write $($name) with value $($value).  Error: $($message)."
            }
        }
    }
}
else
{
    log "Target tenant headers not provided.  Skipping new user object creation."
}



# Remove MDM certificate if present
if($pc.mdm -eq $true)
{
    log "Removing MDM certificate..."
    Get-ChildItem -Path "Cert:\LocalMachine\My" | Where-Object {$_.Issuer -match "Microsoft Intune MDM Device CA"} | Remove-Item -Force
    log "MDM certificate removed successfully."
}
else
{
    log "MDM certificate not present."
}

# Remove MDM enrollment
if($pc.mdm -eq $true)
{
    log "Removing MDM enrollment..."
    $enrollmentPath = "HKLM:\SOFTWARE\Microsoft\Enrollments"
    $enrollments = Get-ChildItem -Path $enrollmentPath
    foreach($enrollment in $enrollments)
    {
        $object = Get-ItemProperty Registry::$enrollment
        $enrollPath = $enrollmentPath + $object.PSChildName
        $key = Get-ItemProperty -Path $enrollPath -Name "DiscoveryServiceFullURL"
        if($key)
        {
            log "Removing MDM enrollment $($enrollPath)..."
            Remove-Item -Path $enrollPath -Recure
            log "MDM enrollment removed successfully."
        }
        else
        {
            log "MDM enrollment not present."
        }
    }
    $enrollId = $enrollPath.Split("\")[-1]
    $additionalPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Enrollments\Status\$($enrollID)",
        "HKLM:\SOFTWARE\Microsoft\EnterpriseResourceManager\Tracked\$($enrollID)",
        "HKLM:\SOFTWARE\Microsoft\PolicyManager\AdmxInstalled\$($enrollID)",
        "HKLM:\SOFTWARE\Microsoft\PolicyManager\Providers\$($enrollID)",
        "HKLM:\SOFTWARE\Microsoft\Provinsioning\OMADM\Accounts\$($enrollID)",
        "HKLM:\SOFTWARE\Microsoft\Provisioning\OMADM\Logger\$($enrollID)",
        "HKLM:\SOFTWARE\Microsoft\Provisioning\OMADM\Sessions\$($enrollID)"
    )
    foreach($path in $additionalPaths)
    {
        if(Test-Path $path)
        {
            log "Removing $($path)..."
            Remove-Item -Path $path -Recurse
            log "$($path) removed successfully."
        }
        else
        {
            log "$($path) not present."
        }
    }
}
else
{
    log "MDM enrollment not present."
}


# Set migration tasks
$tasks = @("reboot","postMigrate")
foreach($task in $tasks)
{
    $taskPath = "$($config.localPath)\$($task).xml"
    if([string]::IsNullOrEmpty($taskPath))
    {
        log "$($task) task not found."
    }
    else
    {
        log "Setting $($task) task..."
        try
        {
            schtasks.exe /create /xml $taskPath /tn $task /f | Out-Host
            log "$($task) task set successfully."
        }
        catch
        {
            $message = $_.Exception.Message
            log "Failed to set $($task) task. Error: $message"
            log "Exiting script."
            exitScript -exitCode 4 -functionName "schtasks"
        }
    }
}


# Leave Azure AD / Entra Join
if($pc.azureAdJoined -eq "YES")
{
    log "PC is Azure AD Joined.  Leaving Azure AD..."
    try
    {
        Start-Process -FilePath "C:\Windows\System32\dsregcmd.exe" -ArgumentList "/leave"
        log "PC left Azure AD successfully."
    }
    catch
    {
        $message = $_.Exception.Message
        log "Failed to leave Azure AD. Error: $message"
        log "Exiting script."
        exitScript -exitCode 4 -functionName "dsregcmd"
    }
}
else
{
    log "PC is not Azure AD Joined."
}

# FUNCTION: unjoinDomain
# DESCRIPTION: Unjoins the device from the domain.
# PARAMETERS: $unjoinAccount - The account to unjoin the device with, $hostname - The hostname of the device.

function unjoinDomain()
{
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$true)]
        [string]$unjoinAccount,
        [string]$hostname = $pc.hostname,
        [string]$localDomain = $pc.localDomain
    )
    # Check for line of sight to domain controller
    $pingCount = 4
    $pingResult = Test-Connection -ComputerName $localDomain -Count $pingCount
    if($pingResult.StatusCode -eq 0)
    {
        log "$($hostname) has line of sight to domain controller.  Attempting to break..."
        $adapter = Get-NetAdapter | Where-Object {$_.Status -eq 'Up'} | Select-Object -ExpandProperty InterfaceAlias
        Set-DnsClientServerAddress -InterfaceAlias $adapter -ServerAddresses ("8.8.8.8","8.8.4.4")
        log "Successfully broke line of sight to domain controller."
    }
    else
    {
        log "$($hostname) has no line of sight to domain controller."
    }
    $password = generatePassword
    log "Generated password for $unjoinAccount."
    log "Checking $unjoinAccount status..."
    [bool]$acctStatus = (Get-LocalUser -Name $unjoinAccount).Enabled
    if($acctStatus -eq $false)
    {
        log "$unjoinAccount is disabled; setting password and enabling..."
        Set-LocalUser -Name $unjoinAccount -Password $password -PasswordNeverExpires $true
        Get-LocalUser -Name $unjoinAccount | Enable-LocalUser
        log "Successfully set password and enabled $unjoinAccount."
    }
    else
    {
        log "$unjoinAccount is enabled; setting password..."
        Set-LocalUser -Name $unjoinAccount -Password $password -PasswordNeverExpires $true
        log "Successfully set password for $unjoinAccount."
    }
    $cred = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList ("$hostname\$unjoinAccount", $password)
    log "Unjoining $hostname from domain..."
    Remove-Computer -UnjoinDomainCredential $cred -PassThru -Force -Verbose
    log "Successfully unjoined $hostname from domain."
}

# Leave Domain/Hybrid Join
if($pc.domainJoined -eq "YES")
{
    log "PC is Domain/Hybrid Joined.  Leaving Domain..."
    try
    {
        unjoinDomain -unjoinAccount "Administrator"
        log "PC left Domain successfully."
    }
    catch
    {
        $message = $_.Exception.Message
        log "Failed to leave Domain. Error: $message"
        log "Exiting script."
        exitScript -exitCode 4 -functionName "unjoinDomain"
    }
}
else
{
    log "PC is not Domain/Hybrid Joined."
}


################### SCCM SECTION ###################
# FUNCTION: removeSCCM
# DESCRIPTION: Removes the SCCM client from the device.
function removeSCCM()
{
    [CmdletBinding()]
    Param(
        [string]$CCMpath = "C:\Windows\ccmsetup\ccmsetup.exe",
        [array]$services = @("CcmExec","smstsmgr","CmRcService","ccmsetup"),
        [string]$CCMProcess = "ccmsetup",
        [string]$servicesRegPath = "HKLM:\SYSTEM\CurrentControlSet\Services\",
        [string]$ccmRegPath = "HKLM:\SOFTWARE\Microsoft\CCM",
        [array]$sccmKeys = @("CCM","SMS","CCMSetup"),
        [string]$CSPPath = "HKLM:\SOFTWARE\Microsoft\DeviceManageabilityCSP",
        [array]$sccmFolders = @("C:\Windows\ccm","C:\Windows\ccmsetup","C:\Windows\ccmcache","C:\Windows\ccmcache2","C:\Windows\SMSCFG.ini",
        "C:\Windows\SMS*.mif"),
        [array]$sccmNamespaces = @("ccm","sms")
    )
    
    # Remove SCCM client
    log "Removing SCCM client..."
    if(Test-Path $CCMpath)
    {
        log "Uninstalling SCCM client..."
        Start-Process -FilePath $CCMpath -ArgumentList "/uninstall" -Wait
        if($CCMProcess)
        {
            log "SCCM client still running; killing..."
            Stop-Process -Name $CCMProcess -Force -ErrorAction SilentlyContinue
            log "Killed SCCM client."
        }
        else
        {
            log "SCCM client uninstalled successfully."
        }
        # Stop SCCM services
        foreach($service in $services)
        {
            $serviceStatus = Get-Service -Name $service -ErrorAction SilentlyContinue
            if($serviceStatus)
            {
                log "Stopping $service..."
                Stop-Service -Name $service -Force -ErrorAction SilentlyContinue
                log "Stopped $service."
            }
            else
            {
                log "$service not found."
            }
        }
        # Remove WMI Namespaces
        foreach($namespace in $sccmNamespaces)
        {
            Get-WmiObject -Query "SELECT * FROM __Namespace WHERE Name = '$namespace'" -Namespace "root" | Remove-WmiObject
        }
        # Remove SCCM registry keys
        foreach($service in $services)
        {
            $serviceKey = $servicesRegPath + $service
            if(Test-Path $serviceKey)
            {
                log "Removing $serviceKey registry key..."
                Remove-Item -Path $serviceKey -Recurse -Force -ErrorAction SilentlyContinue
                log "Removed $serviceKey registry key."
            }
            else
            {
                log "$serviceKey registry key not found."
            }
        }
        foreach($key in $sccmKeys)
        {
            $keyPath = $ccmRegPath + "\" + $key
            if(Test-Path $keyPath)
            {
                log "Removing $keyPath registry key..."
                Remove-Item -Path $keyPath -Recurse -Force -ErrorAction SilentlyContinue
                log "Removed $keyPath registry key."
            }
            else
            {
                log "$keyPath registry key not found."
            }
        }
        # Remove CSP
        Remove-Item -Path $CSPPath -Recurse -Force -ErrorAction SilentlyContinue
        # Remove SCCM folders
        foreach($folder in $sccmFolders)
        {
            if(Test-Path $folder)
            {
                log "Removing $folder..."
                Remove-Item -Path $folder -Recurse -Force -ErrorAction SilentlyContinue
                log "Removed $folder."
            }
            else
            {
                log "$folder not found."
            }
        }
    }
    else
    {
        log "SCCM client not found."
    }
}


# Remove SCCM client if required
log "Checking for SCCM client..."
if($config.SCCM -eq $true)
{
    log "SCCM enabled.  Removing SCCM client..."
    try
    {
        removeSCCM
        log "SCCM client removed successfully."
    }
    catch
    {
        $message = $_.Exception.Message
        log "Failed to remove SCCM client. Error: $message"
        log "Exiting script."
        exitScript -exitCode 4 -functionName "removeSCCM"
    }
}
else
{
    log "SCCM not enabled."
}

# Install provisioning package
$ppkg = (Get-ChildItem -Path $config.localPath -Filter "*.ppkg" -Recurse).FullName
if($ppkg)
{
    log "Provisioning package found. Installing..."
    try
    {
        Install-ProvisioningPackage -PackagePath $ppkg -QuietInstall -Force
        log "Provisioning package installed successfully."
    }
    catch
    {
        $message = $_.Exception.Message
        log "Failed to install provisioning package. Error: $message"
        log "Exiting script."
        exitScript -exitCode 4 -functionName "Install-ProvisioningPackage"
    }
}
else
{
    log "Provisioning package not found."
    exitScript -exitCode 4 -functionName "Install-ProvisioningPackage"
}

# Delete Intune and Autopilot object if exist
if($pc.mdm -eq $true)
{
    if([string]::IsNullOrEmpty($pc.intuneId))
    {
        log "Intune object not found."
    }
    else
    {
        log "Deleting Intune object..."
        try
        {
            Invoke-RestMethod -Method Delete -Uri "https://graph.microsoft.com/beta/deviceManagement/managedDevices/$($pc.intuneId)" -Headers $sourceHeaders
            Start-Sleep -Seconds 2
            log "Intune object deleted successfully."
        }
        catch
        {
            $message = $_.Exception.Message
            log "Failed to delete Intune object. Error: $message"
            log "Exiting script."
            exitScript -exitCode 4 -functionName "Intune object delete"
        }
    }
    if([string]::IsNullOrEmpty($pc.autopilotId))
    {
        log "Autopilot object not found."
    }
    else
    {
        log "Deleting Autopilot object..."
        try
        {
            Invoke-RestMethod -Method Delete -Uri "https://graph.microsoft.com/beta/deviceManagement/importedWindowsAutopilotDeviceIdentities/$($pc.autopilotId)" -Headers $sourceHeaders
            Start-Sleep -Seconds 2
            log "Autopilot object deleted successfully."
        }
        catch
        {
            $message = $_.Exception.Message
            log "Failed to delete Autopilot object. Error: $message"
            log "Exiting script."
            exitScript -exitCode 4 -functionName "Autopilot object delete"
        }
    }
}
else
{
    log "PC is not MDM enrolled."
}
# FUNCTION: setAutoLogonAdmin
# DESCRIPTION: Sets the auto logon account for the administrator 
# PARAMETERS: $username - The username to set auto logon for, $password - The password to set auto logon for.
function setAutoLogonAdmin()
{
    Param(
        [string]$regPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon",
        [string]$regName = "AutoAdminLogon",
        [string]$migrateAdmin = "MigrationInProgress"
    )
    log "Creating local admin account..."
    $adminPW = generatePassword
    $adminGroup = Get-CimInstance -Query "Select * From Win32_Group Where LocalAccount = True And SID = 'S-1-5-32-544'"
    $adminGroupName = $adminGroup.Name
    New-LocalUser -Name $migrateAdmin -Password $adminPW
    Add-LocalGroupMember -Group $adminGroupName -Member $migrateAdmin
    log "Successfully created local admin account."
    reg.exe add $regPath /v "AutoAdminLogon" /t REG_SZ /d 0 /f | Out-Host
    reg.exe add $regPath /v "DefaultUserName" /t REG_SZ /d $migrateAdmin /f | Out-Host
    reg.exe add $regPath /v "DefaultPassword" /t REG_SZ /d "@Password*123" | Out-Host
    log "Successfully set auto logon to $migrateAdmin."
}

# Set Auto logon Admin account
log "Setting Auto logon Admin account..."
try
{
    setAutoLogonAdmin
    log "Auto logon Admin account set successfully."
}
catch
{
    $message = $_.Exception.Message
    log "Failed to set Auto logon Admin account. Error: $message"
    log "Exiting script."
    exitScript -exitCode 4 -functionName "setAutoLogonAdmin"
}

# Enable auto logon
log "Enabling auto logon..."
try
{
    toggleAutoLogon -enable $true
    log "Auto logon enabled successfully."
}
catch
{
    $message = $_.Exception.Message
    log "Failed to enable auto logon. Error: $message"
    log "Exiting script."
    exitScript -exitCode 4 -functionName "toggleAutoLogon"
}

# Disable logon provider
log "Disabling logon provider..."
try
{
    toggleLogonProvider -enable $false
    log "Logon provider disabled successfully."
}
catch
{
    $message = $_.Exception.Message
    log "Failed to disable logon provider. Error: $message"
    log "Exiting script."
    exitScript -exitCode 4 -functionName "disableLogonProvider"
}

# Disable DisplayLastUser
log "Disabling DisplayLastUser..."
try
{
    toggleDisplayLastUser -enable $false
    log "DisplayLastUser disabled successfully."
}
catch
{
    $message = $_.Exception.Message
    log "Failed to disable DisplayLastUser. Error: $message"
    log "Exiting script."
    exitScript -exitCode 4 -functionName "disableDisplayLastUser"
}

# Set lock screen caption
log "Setting lock screen caption..."
try 
{
    setLockScreenCaption -caption "Device Migration in Progress..." -text "Your PC is being migrated to the $($config.targetTenant.tenantName) tenant and will automatically reboot in 30 seconds.  Please do not power off."
    log "Lock screen caption set successfully."
}
catch 
{
    $message = $_.Exception.Message
    log "Failed to set lock screen caption. Error: $message"
    log "Exiting script."
    exitScript -exitCode 4 -functionName "setLockScreenCaption"
}

# Stop transcript and restart
log "$pc.hostname will reboot in 30 seconds..."
Stop-Transcript
shutdown -r -t 30

