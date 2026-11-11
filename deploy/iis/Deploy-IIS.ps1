#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Deploys the HelloWorld app to IIS (Step 2 of the assignment).
.EXAMPLE
    $appPoolPwd = Read-Host -AsSecureString "Password for svc_helloworld"
    .\Deploy-IIS.ps1 -ZipPath C:\temp\HelloWorld-1.0.5-fd319a2.zip -AppPoolPassword $appPoolPwd
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $ZipPath,
    [Parameter(Mandatory)] [securestring] $AppPoolPassword,
    [string] $SiteName    = 'HelloWorldSite',
    [string] $AppName     = 'helloworld',
    [string] $AppPoolName = 'HelloWorldPool',
    [string] $UserName    = 'svc_helloworld',
    [string] $GroupName   = 'HelloWorldUsers',
    [int]    $HttpPort    = 8080,
    [int]    $HttpsPort   = 8443,
    [string] $SitePath    = 'C:\inetpub\HelloWorldSite',
    [string] $LogPath     = 'C:\inetpub\logs\HelloWorldSite'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- 1. Local user and group -----------------------------------------------
if (-not (Get-LocalUser -Name $UserName -ErrorAction SilentlyContinue)) {
    New-LocalUser -Name $UserName -Password $AppPoolPassword -PasswordNeverExpires `
        -UserMayNotChangePassword -Description 'Identity of the HelloWorld app pool' | Out-Null
    Write-Host "Created local user $UserName"
} else {
    Set-LocalUser -Name $UserName -Password $AppPoolPassword
    Write-Host "Local user $UserName already exists (password kept in sync)"
}

if (-not (Get-LocalGroup -Name $GroupName -ErrorAction SilentlyContinue)) {
    New-LocalGroup -Name $GroupName -Description 'Accounts that run the HelloWorld app' | Out-Null
    Write-Host "Created local group $GroupName"
} else {
    Write-Host "Local group $GroupName already exists"
}

$isMember = Get-LocalGroupMember -Group $GroupName |
    Where-Object { $_.Name -like "*\$UserName" }
if (-not $isMember) {
    Add-LocalGroupMember -Group $GroupName -Member $UserName
    Write-Host "Added $UserName to $GroupName"
} else {
    Write-Host "$UserName is already a member of $GroupName"
}

# --- 2. Folders, permissions and app files ---------------------------------
Import-Module WebAdministration
$appPath = Join-Path $SitePath $AppName

foreach ($folder in @($SitePath, $appPath, $LogPath)) {
    if (-not (Test-Path $folder)) {
        New-Item -ItemType Directory -Path $folder | Out-Null
        Write-Host "Created folder $folder"
    }
}

# The group (and so the app pool user) can only read and execute the site files
icacls $SitePath /grant "${GroupName}:(OI)(CI)RX" | Out-Null
if ($LASTEXITCODE -ne 0) { throw "icacls failed to grant $GroupName on $SitePath" }
Write-Host "Granted $GroupName read/execute on $SitePath"

# On a redeploy, stop the app pool and wait until its worker process is gone,
# otherwise HelloWorld.dll is still locked by w3wp.exe (in-process hosting)
if (Test-Path "IIS:\AppPools\$AppPoolName") {
    if ((Get-WebAppPoolState -Name $AppPoolName).Value -ne 'Stopped') {
        Stop-WebAppPool -Name $AppPoolName
    }
    $deadline = (Get-Date).AddSeconds(30)
        # Ask the OS (source of truth): is any w3wp.exe of this pool still alive?
    while (Get-CimInstance Win32_Process -Filter "Name='w3wp.exe'" |
           Where-Object { $_.CommandLine -like ('*-ap "' + $AppPoolName + '"*') }) {
        if ((Get-Date) -gt $deadline) { throw "App pool $AppPoolName did not stop within 30 seconds" }
        Start-Sleep -Seconds 1
    }
    Write-Host "App pool $AppPoolName stopped"
}

Expand-Archive -Path $ZipPath -DestinationPath $appPath -Force -ErrorAction Stop
Write-Host "Extracted $ZipPath to $appPath"

# --- 3. Application pool -----------------------------------------------------
$poolPath = "IIS:\AppPools\$AppPoolName"
if (-not (Test-Path $poolPath)) {
    New-WebAppPool -Name $AppPoolName | Out-Null
    Write-Host "Created app pool $AppPoolName"
} else {
    Write-Host "App pool $AppPoolName already exists"
}

# .NET (Core) apps are loaded by the ASP.NET Core Module, not by the old CLR
Set-ItemProperty $poolPath -Name managedRuntimeVersion -Value ''

# Run the pool as the dedicated local user (identityType 3 = SpecificUser)
$plainPassword = [System.Net.NetworkCredential]::new('', $AppPoolPassword).Password
Set-ItemProperty $poolPath -Name processModel -Value @{
    userName     = "$env:COMPUTERNAME\$UserName"
    password     = $plainPassword
    identityType = 3
}
Remove-Variable plainPassword
Write-Host "App pool $AppPoolName runs as $env:COMPUTERNAME\$UserName (No Managed Code)"

# --- 4. Site, bindings, log folder and application ---------------------------
$siteIisPath = "IIS:\Sites\$SiteName"
if (-not (Test-Path $siteIisPath)) {
    New-Website -Name $SiteName -PhysicalPath $SitePath -Port $HttpPort `
        -ApplicationPool $AppPoolName | Out-Null
    Write-Host "Created site $SiteName (http port $HttpPort)"
} else {
    Write-Host "Site $SiteName already exists"
}

# HTTPS binding with a self-signed certificate (lab only; production uses a CA-issued certificate)
$certName = "$SiteName (self-signed)"
$cert = Get-ChildItem Cert:\LocalMachine\My |
    Where-Object { $_.FriendlyName -eq $certName } | Select-Object -First 1
if (-not $cert) {
    $cert = New-SelfSignedCertificate -DnsName 'localhost' `
        -CertStoreLocation Cert:\LocalMachine\My -FriendlyName $certName
    Write-Host "Created self-signed certificate $($cert.Thumbprint)"
}
if (-not (Get-WebBinding -Name $SiteName -Protocol https -Port $HttpsPort)) {
    New-WebBinding -Name $SiteName -Protocol https -Port $HttpsPort
    (Get-WebBinding -Name $SiteName -Protocol https -Port $HttpsPort).AddSslCertificate($cert.Thumbprint, 'My')
    Write-Host "Added https binding on port $HttpsPort"
}

# Site log files go to a custom folder (assignment requirement)
Set-ItemProperty $siteIisPath -Name logFile.directory -Value $LogPath

# Application under the site, running in the dedicated app pool
if (-not (Get-WebApplication -Site $SiteName -Name $AppName)) {
    New-WebApplication -Site $SiteName -Name $AppName -PhysicalPath $appPath `
        -ApplicationPool $AppPoolName | Out-Null
    Write-Host "Created application /$AppName"
}

Start-WebAppPool -Name $AppPoolName -ErrorAction SilentlyContinue
Start-Website -Name $SiteName

# --- 5. Smoke test -----------------------------------------------------------
$url = "http://localhost:$HttpPort/$AppName"
$response = Invoke-WebRequest -Uri $url -UseBasicParsing
Write-Host "GET $url -> $($response.StatusCode) $($response.Content)"
