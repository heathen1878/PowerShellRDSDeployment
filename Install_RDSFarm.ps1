<#
DESCRIPTION   This script will create a configured Remote Desktop Session Farm.
Author:         Julian Mooren
Creation Date:  12.05.17
#>
 

#Requires -version 4.0
#Requires -RunAsAdministrator

#Functions
#http://www.leeholmes.com/blog/2009/11/20/testing-for-powershell-remoting-test-psremoting/
function Test-PsRemoting
{
    param(
        [Parameter(Mandatory = $true)]
        $computername
    )
   
    try
    {
        $errorActionPreference = "Stop"
        $result = Invoke-Command -ComputerName $computername { 1 }
    }
    catch
    {
        Write-Verbose $_
        return $false
    }
   
    ## I've never seen this happen, but if you want to be
    ## thorough....
    if($result -ne 1)
    {
        Write-Verbose "Remoting to $computerName returned an unexpected result."
        return $false
    }
   
    $true   
} 


# Thanks @xenappblog.com for the Transcript Log idea
$configpath= "C:\rds\config.json"
$StartDate = (Get-Date) 
$Vendor = "Microsoft"
$Product = "Remote Desktop Farm"
$Version = "2016"
$LogPath = "${env:SystemRoot}" + "\Temp\$Vendor $Product $Version.log"

Start-Transcript $LogPath

Write-Verbose "Check Prerequisites" -Verbose

if (Get-WindowsFeature -Name RSAT-AD-Tools, RSAT-DNS-Server)
{
   Write-Verbose "Needed PowerShell Modules available." -Verbose
}

else 
{    
    Write-Verbose "Needed PowerShell Modules will be installed." -Verbose
    Install-WindowsFeature RSAT-AD-Tools, RSAT-DNS-Server
    Write-Verbose "Needed PowerShell Modules have been installed." -Verbose
}



if (Test-Path $configpath) 
{
Write-Verbose "JSON File was found." -Verbose
$config = Get-Content -Path $configpath -Raw | ConvertFrom-Json
Write-Verbose "JSON File was imported." -Verbose
}

Else 
{
Write-Warning "Failed to find the JSON File."
break
}

if (Test-Path $config.CertPath) 
{
Write-Verbose "SSL Certificate was found." -Verbose
}

Else 
{
Write-Warning "Failed to find the SSL Certificate."
break
}



Write-Verbose "Starting Installation of $Vendor $Product $Version" -Verbose

# Import the RemoteDesktop Module
Import-Module RemoteDesktop

##### MultiDeployment Configuration Parameters ##### 


if($config.MultiDeployment -like "Yes")
{

if(Test-PsRemoting -computername $config.RDSHost01, $config.RDSHost02, $config.ConnectionBroker01, $config.WebAccessServer01, $config.RDGatewayServer01)
{
Write-Verbose "PSRemoting is enabled on all Hosts." -Verbose
}

Else 
{
Write-Warning "PSRemoting is not enabled on all Hosts." 
break
}


# Create RDS deployment
New-RDSessionDeployment -ConnectionBroker $config.ConnectionBroker01 -WebAccessServer $config.WebAccessServer01 -SessionHost @($config.RDSHost01, $config.RDSHost02)

Write-Verbose "Created new RDS deployment" -Verbose

# Create Desktop Collection
New-RDSessionCollection  -CollectionName $config.DesktopCollectionName -SessionHost @($config.RDSHost01, $config.RDSHost02)  -CollectionDescription $config.DesktopDiscription  -ConnectionBroker $config.ConnectionBroker01 
Write-Verbose "Created new Desktop Collection"  -Verbose

#Install Gateway
Add-WindowsFeature -Name RDS-Gateway -IncludeManagementTools -ComputerName $config.RDGatewayServer01
Write-Verbose "Installed RDS Gateway"  -Verbose

#Join Gateway to Broker
Add-RDServer -Server $config.RDGatewayServer01 -Role "RDS-GATEWAY" -ConnectionBroker $config.ConnectionBroker01 -GatewayExternalFqdn $config.GatewayExternalFqdn
Write-Verbose "Joined RDS Gateway to Broker"  -Verbose

# Configure GW Policies on RDGatewayServer01
Invoke-Command -ComputerName $config.RDGatewayServer01 -ArgumentList $config.GatewayAccessGroup, $config.RDBrokerDNSInternalName, $config.RDBrokerDNSInternalZone, $config.RDSHost01, $config.RDSHost02 -ScriptBlock {
$GatewayAccessGroup = $args[0]
$RDBrokerDNSInternalName = $args[1]
$RDBrokerDNSInternalZone = $args[2]
$RDSHost01 = $args[3]
$RDSHost02 = $args[4]
Import-Module RemoteDesktopServices
Remove-Item -Path "RDS:\GatewayServer\CAP\RDG_CAP_AllUsers" -Force -recurse
Remove-Item -Path "RDS:\GatewayServer\RAP\RDG_RDConnectionBrokers" -Force -recurse
Remove-Item -Path "RDS:\GatewayServer\RAP\RDG_AllDomainComputers" -Force -recurse
Remove-Item  -Path "RDS:\GatewayServer\GatewayManagedComputerGroups\RDG_RDCBComputers"-Force -recurse
New-Item -Path "RDS:\GatewayServer\GatewayManagedComputerGroups" -Name "RDSFarm1" -Description "RDSFarm1" -Computers "$RDBrokerDNSInternalName.$RDBrokerDNSInternalZone" -ItemType "String"
New-Item -Path "RDS:\GatewayServer\GatewayManagedComputerGroups\RDSFarm1\Computers" -Name $RDSHost01 -ItemType "String"
New-Item -Path "RDS:\GatewayServer\GatewayManagedComputerGroups\RDSFarm1\Computers" -Name $RDSHost02 -ItemType "String"

New-Item -Path "RDS:\GatewayServer\RAP" -Name "RDG_RAP_RDSFarm1" -UserGroups $GatewayAccessGroup -ComputerGroupType 0 -ComputerGroup "RDSFarm1"
New-Item -Path "RDS:\GatewayServer\CAP" -Name "RDG_CAP_RDSFarm1" -UserGroups $GatewayAccessGroup -AuthMethod 1

}
Write-Verbose "Configured CAP & RAP Policies on: $($config.RDGatewayServer01)"  -Verbose


# Create WebAccess DNS-Record
Import-Module DNSServer
$IPWebAccess01 = [System.Net.Dns]::GetHostAddresses("$($config.WebAccessServer01)")[0].IPAddressToString
Add-DnsServerResourceRecordA -ComputerName $config.DomainController  -Name $config.RDWebAccessDNSInternalName -ZoneName $config.RDWebAccessDNSInternalZone -AllowUpdateAny -IPv4Address $IPWebAccess01
Write-Verbose "Configured WebAccess DNS-Record"  -Verbose

# Redirect to RDWeb (IIS)
Invoke-Command -ComputerName $config.WebAccessServer01 -ArgumentList $config.RDWebAccessDNSInternalName, $config.RDWebAccessDNSInternalZone  -ScriptBlock {
$RDWebAccessDNSInternalName = $args[0]
$RDWebAccessDNSInternalZone = $args[1]
$siteName = "Default Web Site"
Import-Module webAdministration
Set-WebConfiguration system.webServer/httpRedirect "IIS:\sites\$siteName" -Value @{enabled="true";destination="https://$RDWebAccessDNSInternalName.$RDWebAccessDNSInternalZone/RDWeb";exactDestination="true";httpResponseStatus="Found"} }
Write-Verbose "Configured RDWeb Redirect"  -Verbose

}


##### Default Configuration Parameters ##### 

# Set Access Group for RDS Farm
Set-RDSessionCollectionConfiguration -CollectionName $config.DesktopCollectionName -UserGroup $config.$RDSAccessGroup -ConnectionBroker $config.ConnectionBroker01
Write-Verbose "Configured Access for $($config.RDSAccessGroup)"  -Verbose

# Set Profile Disk 
Set-RDSessionCollectionConfiguration -CollectionName $config.DesktopCollectionName -EnableUserProfileDisk -MaxUserProfileDiskSizeGB "20" -DiskPath $config.ProfileDiskPath -ConnectionBroker $config.ConnectionBroker01
Write-Verbose "Configured ProfileDisk"  -Verbose

# RDS Licencing
Add-RDServer -Server $config.LICserver -Role "RDS-LICENSING" -ConnectionBroker $config.ConnectionBroker01
Write-Verbose "Installed RDS Licence Server: $($config.LICserver)"  -Verbose
Set-RDLicenseConfiguration -LicenseServer $config.LICserver -Mode $config.LICmode -ConnectionBroker $config.ConnectionBroker01 -Force
Write-Verbose "Configured RDS Licening"  -Verbose

# Set Certificates
$Password = ConvertTo-SecureString -String $config.CertPassword -AsPlainText -Force 
Set-RDCertificate -Role RDPublishing -ImportPath $config.CertPath  -Password $Password -ConnectionBroker $config.ConnectionBroker01 -Force
Set-RDCertificate -Role RDRedirector -ImportPath $config.CertPath -Password $Password -ConnectionBroker $config.ConnectionBroker01 -Force
Set-RDCertificate -Role RDWebAccess -ImportPath $config.CertPath -Password $Password -ConnectionBroker $config.ConnectionBroker01 -Force
Set-RDCertificate -Role RDGateway -ImportPath $config.CertPath  -Password $Password -ConnectionBroker $config.ConnectionBroker01 -Force
Write-Verbose "Configured SSL Certificates"  -Verbose


# Configure WebAccess (when RDBroker is available, no Gateway will be used)
Set-RDDeploymentGatewayConfiguration -GatewayMode Custom -GatewayExternalFqdn $config.GatewayExternalFqdn -LogonMethod Password -UseCachedCredentials $True -BypassLocal $True -ConnectionBroker $config.ConnectionBroker01 -Force
Write-Verbose "Configured Gateway Mapping"  -Verbose

# Create TXT WebFeed DNS Record - Create RemoteAccess connection via e-Mail address
Add-DnsServerResourceRecord -ZoneName $config.RDWebAccessDNSInternalZone -Name "_msradc" -Txt -DescriptiveText "https://$($config.RDWebAccessDNSInternalName).$($config.RDWebAccessDNSInternalZone)/RDWeb/Feed"
Write-Verbose "Created TXT WebFeed DNS Record"  -Verbose

# Create RDS Broker DNS-Record
Import-Module DNSServer
$IPBroker01 = [System.Net.Dns]::GetHostAddresses("$($config.ConnectionBroker01)")[0].IPAddressToString
Add-DnsServerResourceRecordA -ComputerName $config.DomainController  -Name $config.RDBrokerDNSInternalName -ZoneName $config.RDBrokerDNSInternalZone -AllowUpdateAny -IPv4Address $IPBroker01
Write-Verbose "Configured RDSBroker DNS-Record"  -Verbose

#Change RDPublishedName
#https://gallery.technet.microsoft.com/Change-published-FQDN-for-2a029b80
Invoke-WebRequest -Uri "https://gallery.technet.microsoft.com/Change-published-FQDN-for-2a029b80/file/103829/2/Set-RDPublishedName.ps1" -OutFile "C:\rds\Set-RDPublishedName.ps1"
Copy-Item "C:\rds\Set-RDPublishedName.ps1" -Destination "\\$($config.ConnectionBroker01)\c$"
Invoke-Command -ComputerName $config.ConnectionBroker01 -ArgumentList $config.RDBrokerDNSInternalName, $config.RDBrokerDNSInternalZone -ScriptBlock {
$RDBrokerDNSInternalName = $args[0]
$RDBrokerDNSInternalZone = $args[1]
Set-Location C:\
.\Set-RDPublishedName.ps1 -ClientAccessName "$RDBrokerDNSInternalName.$RDBrokerDNSInternalZone"
Remove-Item "C:\Set-RDPublishedName.ps1"
}
Write-Verbose "Configured RDPublisher Name"  -Verbose


##### HA Configuration Configuration Parameters ##### 


if($config.HADeployment -like "Yes")
{

if(Test-PsRemoting -computername $config.RDSHost01, $config.RDSHost02, $config.ConnectionBroker01, $config.ConnectionBroker02, $config.WebAccessServer01, $config.WebAccessServer02, $config.RDGatewayServer01, $config.RDGatewayServer02 )
{
Write-Verbose "PSRemoting is enabled on all Hosts." -Verbose
}

Else 
{
Write-Warning "PSRemoting is not enabled on all Hosts." -Verbose
break
}


#Create HA Broker Security Group for SQL Database Access
Import-Module ActiveDirectory 
New-ADGroup  -Name "RDS_Connection_Brokers" -GroupCategory Security -GroupScope Global  -Server $config.DomainController
Add-ADGroupMember -Identity "RDS_Connection_Brokers" -Members "$($config.RDSHost01.Split(".")[0])$" -Server $config.DomainController
Add-ADGroupMember -Identity "RDS_Connection_Brokers" -Members "$($config.RDSHost02.Split(".")[0])$" -Server $config.DomainController
Write-Verbose "Created RDSBroker Security Group in ActiveDirectory" -Verbose

# Restart Broker Server (that Broker Security Group is being applied)
Write-Verbose "$($config.ConnectionBroker01) will reboot"  -Verbose
Restart-Computer -ComputerName $config.ConnectionBroker01 -Wait -For PowerShell -Timeout 300 -Delay 2
Write-Verbose "$($config.ConnectionBroker01) online again"  -Verbose

Write-Verbose "$($config.ConnectionBroker02) will reboot"  -Verbose
Restart-Computer -ComputerName $config.ConnectionBroker02 -Wait -For PowerShell -Timeout 300 -Delay 2
Write-Verbose "$($config.ConnectionBroker02) online again"  -Verbose



# Create HA RDS Broker DNS-Record
Import-Module DNSServer
$IPBroker02 = [System.Net.Dns]::GetHostAddresses("$($config.ConnectionBroker02)")[0].IPAddressToString
Add-DnsServerResourceRecordA -ComputerName $config.DomainController  -Name $config.RDBrokerDNSInternalName -ZoneName $config.RDBrokerDNSInternalZone -AllowUpdateAny -IPv4Address $IPBroker02
Write-Verbose "Configured RDSBroker DNS-Record"  -Verbose

# Create HA WebAccess DNS-Record
Import-Module DNSServer
$IPWebAccess02 = [System.Net.Dns]::GetHostAddresses("$($config.WebAccessServer02)")[0].IPAddressToString
Add-DnsServerResourceRecordA -ComputerName $config.DomainController  -Name $config.RDWebAccessDNSInternalName -ZoneName $config.RDWebAccessDNSInternalZone -AllowUpdateAny -IPv4Address $IPWebAccess02
Write-Verbose "Configured WebAccess DNS-Record"  -Verbose


# Download SQL Native Client
Invoke-WebRequest -Uri "https://download.microsoft.com/download/B/E/D/BED73AAC-3C8A-43F5-AF4F-EB4FEA6C8F3A/1033/amd64/sqlncli.msi" -OutFile "C:\rds\sqlncli.msi"
if (Test-Path C:\rds\sqlncli.msi) 
{
Write-Verbose "Downloaded SQL Native Client" -Verbose
}

Else 
{
Write-Warning "Couldnt Download SQL Native Client"
break
}


#Install SQLNativeClient on ConnectionBroker01
Copy-Item "C:\rds\sqlncli.msi" -Destination "\\$($config.ConnectionBroker01)\c$"
Invoke-Command -ComputerName $config.ConnectionBroker01 -ArgumentList $config.ConnectionBroker01 -ScriptBlock {
$ConnectionBroker01 = $args[0]
$install = Start-Process "msiexec.exe" -ArgumentList "/i C:\sqlncli.msi", "/qn", "IACCEPTSQLNCLILICENSETERMS=YES", "/log C:\sql.log" -PassThru -Wait 

if ($install.ExitCode -ne 0) 
{
    Write-Warning "SQL Client failed to install with $($install.ExitCode) on $ConnectionBroker01"
    break
}

else
{
    Write-Verbose "SQL Client installed succesfull on $ConnectionBroker01" -Verbose
}
Remove-Item "C:\sqlncli.msi"}


#Install SQLNativeClient on ConnectionBroker02
Copy-Item "C:\rds\sqlncli.msi" -Destination "\\$($config.ConnectionBroker02)\c$"
Invoke-Command -ComputerName $config.ConnectionBroker02 -ArgumentList $config.ConnectionBroker02 -ScriptBlock {
$ConnectionBroker02 = $args[0]
$install = Start-Process "msiexec.exe" -ArgumentList "/i C:\sqlncli.msi", "/qn", "IACCEPTSQLNCLILICENSETERMS=YES", "/log C:\sql.log" -PassThru -Wait 

if ($install.ExitCode -ne 0) 
{
    Write-Warning "SQL Client failed to install with $($install.ExitCode) on $ConnectionBroker02"
    break
}

else
{
    Write-Verbose "SQL Client installed succesfull on $ConnectionBroker02" -Verbose
}
Remove-Item "C:\sqlncli.msi"}



#Configure RDSBrokerHighAvailability

(Read-Host 'Please give the "RDS_Connection_Brokers" Security Group the right "sysadmin" to create the databases on the SQL Server. Press Enter when finished')

Set-RDConnectionBrokerHighAvailability -ConnectionBroker $config.ConnectionBroker01`
-DatabaseConnectionString "DRIVER=SQL Server Native Client 11.0;SERVER=$($config.SQLServer);Trusted_Connection=Yes;APP=Remote Desktop Services Connection Broker;DATABASE=$($config.SQLDatabase)"`
-ClientAccessName "$($config.RDBrokerDNSInternalName).$($config.RDBrokerDNSInternalZone)"`
-DatabaseFilePath  $config.SQLFilePath
Write-Verbose "Configured RDSBroker High Availablilty"  -Verbose


#Join ConnectionBroker02
Add-RDServer -Server $config.ConnectionBroker02 -Role "RDS-CONNECTION-BROKER" -ConnectionBroker $config.ConnectionBroker01
Write-Verbose "Joined Broker Server: $($config.ConnectionBroker02)"  -Verbose

#Reboot ConnectionBroker02 (without Reboot, there can occur errors with the next commands)
Write-Verbose "$($config.ConnectionBroker02) will reboot"  -Verbose
Restart-Computer -ComputerName $config.ConnectionBroker02 -Wait -For PowerShell -Timeout 300 -Delay 2
Write-Verbose "$($config.ConnectionBroker02) online again"  -Verbose

#Determine ActiveBroker
$primaryBroker = (Get-RDConnectionBrokerHighAvailability -ConnectionBroker $config.ConnectionBroker01).ActiveManagementServer

#Join WebAccess02
Add-RDServer -Server $config.WebAccessServer02 -Role "RDS-WEB-ACCESS" -ConnectionBroker $primaryBroker
Write-Verbose "Joined WebAccess Server:  $($config.ConnectionBroker02)"  -Verbose

# WebAccess02 - Redirect to RDWeb (IIS)
Invoke-Command -ComputerName $config.WebAccessServer02 -ArgumentList $config.RDWebAccessDNSInternalName, $config.RDWebAccessDNSInternalZone  -ScriptBlock {
$RDWebAccessDNSInternalName = $args[0]
$RDWebAccessDNSInternalZone = $args[1]
$siteName = "Default Web Site"
Import-Module webAdministration
Set-WebConfiguration system.webServer/httpRedirect "IIS:\sites\$siteName" -Value @{enabled="true";destination="https://$RDWebAccessDNSInternalName.$RDWebAccessDNSInternalZone/RDWeb";exactDestination="true";httpResponseStatus="Found"} }
Write-Verbose "Configured RDWeb Redirect"  -Verbose

# Create same Machine Key for RDWeb Services
# https://docs.microsoft.com/en-us/windows-server/remote/remote-desktop-services/rds-rdweb-gateway-ha
# https://gallery.technet.microsoft.com/Get-and-Set-the-machineKeys-9a1e7b77
Invoke-WebRequest -Uri "https://gallery.technet.microsoft.com/Get-and-Set-the-machineKeys-9a1e7b77/file/122500/1/Configure-MachineKeys.ps1" -OutFile "C:\rds\Configure-MachineKeys.ps1"
if (Test-Path C:\rds\Configure-MachineKeys.ps1) 
{
Write-Verbose "Downloaded Configure-MachineKeys Script" -Verbose
C:\rds\Configure-MachineKeys.ps1 -ComputerName $config.WebAccessServer01, $config.WebAccessServer02 -Mode Write
Write-Verbose "Configured same Machine Key for RDWeb Servers"
}

Else 
{
Write-Warning "Couldnt download Configure-MachineKeys Script"
break
}



#Join RDGatewayServer02
Add-RDServer -Server $config.RDGatewayServer02 -Role "RDS-GATEWAY" -ConnectionBroker $primaryBroker -GatewayExternalFqdn $config.GatewayExternalFqdn
Write-Verbose "Joined Gateway Server:  $($config.ConnectionBroker02)"  -Verbose

# Configure GW Policies on RDGatewayServer02
Invoke-Command -ComputerName $config.RDGatewayServer02 -ArgumentList $config.GatewayAccessGroup, $config.RDBrokerDNSInternalName, $config.RDBrokerDNSInternalZone, $config.RDSHost01, $config.RDSHost02, $config.RDGatewayServer01, $config.RDGatewayServer02 -ScriptBlock {
$GatewayAccessGroup = $args[0]
$RDBrokerDNSInternalName = $args[1]
$RDBrokerDNSInternalZone = $args[2]
$RDSHost01 = $args[3]
$RDSHost02 = $args[4]
$RDGatewayServer01 = $args[5]
$RDGatewayServer02 = $args[6]
Import-Module RemoteDesktopServices
Remove-Item -Path "RDS:\GatewayServer\CAP\RDG_CAP_AllUsers" -Force -recurse
Remove-Item -Path "RDS:\GatewayServer\RAP\RDG_RDConnectionBrokers" -Force -recurse
Remove-Item -Path "RDS:\GatewayServer\RAP\RDG_AllDomainComputers" -Force -recurse
Remove-Item -Path "RDS:\GatewayServer\RAP\RDG_HighAvailabilityBroker_DNS_RR" -Force -recurse
Remove-Item  -Path "RDS:\GatewayServer\GatewayManagedComputerGroups\RDG_RDCBComputers"-Force -recurse
Remove-Item  -Path "RDS:\GatewayServer\GatewayManagedComputerGroups\RDG_DNSRoundRobin"-Force -recurse
New-Item -Path "RDS:\GatewayServer\GatewayManagedComputerGroups" -Name "RDSFarm1" -Description "RDSFarm1" -Computers "$RDBrokerDNSInternalName.$RDBrokerDNSInternalZone" -ItemType "String"
New-Item -Path "RDS:\GatewayServer\GatewayManagedComputerGroups\RDSFarm1\Computers" -Name $RDSHost01 -ItemType "String"
New-Item -Path "RDS:\GatewayServer\GatewayManagedComputerGroups\RDSFarm1\Computers" -Name $RDSHost02 -ItemType "String"

New-Item -Path "RDS:\GatewayServer\RAP" -Name "RDG_RAP_RDSFarm1" -UserGroups $GatewayAccessGroup -ComputerGroupType 0 -ComputerGroup "RDSFarm1"
New-Item -Path "RDS:\GatewayServer\CAP" -Name "RDG_CAP_RDSFarm1" -UserGroups $GatewayAccessGroup -AuthMethod 1


New-Item -Path "RDS:\GatewayServer\GatewayFarm\Servers" -Name $RDGatewayServer01 -ItemType "String"
New-Item -Path "RDS:\GatewayServer\GatewayFarm\Servers" -Name $RDGatewayServer02 -ItemType "String"

}
Write-Verbose "Configured CAP & RAP Policies on: $($config.RDGatewayServer02)"  -Verbose

#Cleanup Gateway Policies on RDGatewayServer01
Invoke-Command -ComputerName $config.RDGatewayServer01 -ScriptBlock {
Import-Module RemoteDesktopServices
Remove-Item -Path "RDS:\GatewayServer\RAP\RDG_HighAvailabilityBroker_DNS_RR" -Force -recurse
Remove-Item  -Path "RDS:\GatewayServer\GatewayManagedComputerGroups\RDG_DNSRoundRobin"-Force -recurse
}
Write-Verbose "Cleanup RAP Policy on: $($config.RDGatewayServer01)"  -Verbose

#Create Gateway Farm on RDGatewayServer01
Invoke-Command -ComputerName $config.RDGatewayServer01 -ArgumentList $config.RDGatewayServer01, $config.RDGatewayServer02 -ScriptBlock {
$RDGatewayServer01 = $args[0]
$RDGatewayServer02 = $args[1]
Import-Module RemoteDesktopServices
New-Item -Path "RDS:\GatewayServer\GatewayFarm\Servers" -Name $RDGatewayServer01 -ItemType "String"
New-Item -Path "RDS:\GatewayServer\GatewayFarm\Servers" -Name $RDGatewayServer02 -ItemType "String"
}
Write-Verbose "Created Gateway Server Farm on: $($config.RDGatewayServer01)"  -Verbose


#Set Certificates (need to be applied again, that ConnectioBroker02 is getting the certificates)
$Password = ConvertTo-SecureString -String $config.CertPassword -AsPlainText -Force 
Set-RDCertificate -Role RDPublishing -ImportPath $config.CertPath  -Password $Password -ConnectionBroker $primaryBroker -Force
Set-RDCertificate -Role RDRedirector -ImportPath $config.CertPath -Password $Password -ConnectionBroker $primaryBroker -Force
Set-RDCertificate -Role RDWebAccess -ImportPath $config.CertPath -Password $Password -ConnectionBroker $primaryBroker -Force
Set-RDCertificate -Role RDGateway -ImportPath $config.CertPath  -Password $Password -ConnectionBroker $primaryBroker -Force
Write-Verbose "Configured SSL Certificates"  -Verbose

}


Write-Verbose "Stop logging" -Verbose
$EndDate = (Get-Date)
Write-Verbose "Elapsed Time: $(($EndDate-$StartDate).TotalSeconds) Seconds" -Verbose
Write-Verbose "Elapsed Time: $(($EndDate-$StartDate).TotalMinutes) Minutes" -Verbose

