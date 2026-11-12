#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $PublishPath,
    [Parameter(Mandatory)] [securestring] $ServicePassword,
    [string] $ServiceName         = 'StatusMonitor',
    [string] $UserName            = 'svc_statusmonitor',
    [string] $InstallPath         = 'C:\Services\StatusMonitor',
    [int]    $RestartDelaySeconds = 300
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$account = "$env:COMPUTERNAME\$UserName"

# A service account needs the "Log on as a service" right, otherwise the service fails with error 1069
function Grant-LogOnAsService([string] $Account, [string] $UserName) {
    $sid = ([System.Security.Principal.NTAccount]$Account).Translate(
        [System.Security.Principal.SecurityIdentifier]).Value
    $export = Join-Path $env:TEMP 'secpol-export.inf'
    $import = Join-Path $env:TEMP 'secpol-import.inf'
    $db     = Join-Path $env:TEMP 'secpol.sdb'

    # Returns the accounts that have the right; they can be listed by SID (*S-1-5-...) or by name
    function Get-Members {
        secedit /export /cfg $export /areas USER_RIGHTS | Out-Null
        $line = Select-String -Path $export -Pattern '^SeServiceLogonRight\s*=' | Select-Object -First 1
        if (-not $line) { return @() }
        ($line.Line -split '=', 2)[1].Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    }
    function Test-Granted($members) {
        ($members -contains "*$sid") -or ($members -contains $UserName) -or ($members -contains $Account)
    }

    $members = @(Get-Members)
    if (Test-Granted $members) {
        Write-Host "$Account already has 'Log on as a service'"
    } else {
        $newValue = (@($members) + "*$sid") -join ','
        @('[Unicode]', 'Unicode=yes', '[Version]', 'signature="$CHICAGO$"', 'Revision=1',
          '[Privilege Rights]', "SeServiceLogonRight = $newValue") |
            Set-Content -Path $import -Encoding Unicode
        secedit /configure /db $db /cfg $import /areas USER_RIGHTS | Out-Null
        # secedit may return 1 only because another existing entry has a name it cannot resolve
        # (seen with localized Windows), so we check the real result instead of the exit code
        if (-not (Test-Granted @(Get-Members))) { throw "Could not grant 'Log on as a service' to $Account" }
        Write-Host "Granted 'Log on as a service' to $Account"
    }
    Remove-Item $export, $import, $db -ErrorAction SilentlyContinue
}

# --- 1. Service account ----------------------------------------------------
if (-not (Get-LocalUser -Name $UserName -ErrorAction SilentlyContinue)) {
    New-LocalUser -Name $UserName -Password $ServicePassword -PasswordNeverExpires `
        -UserMayNotChangePassword -Description 'Identity of the StatusMonitor service' | Out-Null
    Write-Host "Created local user $UserName"
} else {
    Set-LocalUser -Name $UserName -Password $ServicePassword
    Write-Host "Local user $UserName already exists (password kept in sync)"
}
Grant-LogOnAsService -Account $account -UserName $UserName

# --- 2. Files (stop the service first on a redeploy) --------------------------
$service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($service -and $service.Status -ne 'Stopped') {
    Stop-Service -Name $ServiceName -Force
    $service.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(30))
    Write-Host "Stopped service $ServiceName"
}
if (-not (Test-Path $InstallPath)) {
    New-Item -ItemType Directory -Path $InstallPath | Out-Null
}
Copy-Item -Path (Join-Path $PublishPath '*') -Destination $InstallPath -Recurse -Force
Write-Host "Copied $PublishPath to $InstallPath"

# The service writes status.log next to the exe, so its account needs Modify on this folder
icacls $InstallPath /grant "${account}:(OI)(CI)M" | Out-Null
if ($LASTEXITCODE -ne 0) { throw "icacls failed to grant $account on $InstallPath" }

# --- 3. Windows Service: specific user, automatic start ------------------------
$exePath = Join-Path $InstallPath 'StatusMonitor.exe'
if (-not $service) {
    $credential = [PSCredential]::new($account, $ServicePassword)
    New-Service -Name $ServiceName -BinaryPathName "`"$exePath`"" -Credential $credential `
        -StartupType Automatic -DisplayName 'HelloWorld Status Monitor' `
        -Description 'Checks the HelloWorld site every 60 s and stops if it is not 200 OK' | Out-Null
    Write-Host "Created service $ServiceName (runs as $account, automatic start)"
} else {
    $plainPassword = [System.Net.NetworkCredential]::new('', $ServicePassword).Password
    $cimService = Get-CimInstance Win32_Service -Filter "Name='$ServiceName'"
    $result = Invoke-CimMethod -InputObject $cimService -MethodName Change -Arguments @{
        PathName = "`"$exePath`""; StartName = $account; StartPassword = $plainPassword }
    Remove-Variable plainPassword
    if ($result.ReturnValue -ne 0) { throw "Failed to update service $ServiceName (code $($result.ReturnValue))" }
    Set-Service -Name $ServiceName -StartupType Automatic
    Write-Host "Service $ServiceName already exists (path, account and startup type updated)"
}

# --- 4. Recovery: restart after N seconds on every failure ---------------------
$delayMs = $RestartDelaySeconds * 1000
sc.exe failure $ServiceName reset= 86400 actions= "restart/$delayMs/restart/$delayMs/restart/$delayMs" | Out-Null
if ($LASTEXITCODE -ne 0) { throw "sc.exe failure returned $LASTEXITCODE" }
# Also count a stop with a non-zero exit code as a failure
sc.exe failureflag $ServiceName 1 | Out-Null
if ($LASTEXITCODE -ne 0) { throw "sc.exe failureflag returned $LASTEXITCODE" }
Write-Host "Recovery: restart after $RestartDelaySeconds s on failure"

# --- 5. Start and smoke test ----------------------------------------------------
Start-Service -Name $ServiceName
(Get-Service -Name $ServiceName).WaitForStatus('Running', [TimeSpan]::FromSeconds(30))
Write-Host "Service $ServiceName is running"
Start-Sleep -Seconds 10
$logFile = Join-Path $InstallPath 'status.log'
if (Test-Path $logFile) { Get-Content $logFile -Tail 1 } else { Write-Warning "No status.log yet in $InstallPath" }
