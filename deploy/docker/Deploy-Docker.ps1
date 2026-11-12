
[CmdletBinding()]
param(
    [string] $Image          = 'ghcr.io/iuricardosopro-ui/helloworld',
    [string] $Tag            = 'latest',
    [string] $ContainerName  = 'helloworld',
    [int]    $HostPort       = 8081,
    [int]    $TimeoutSeconds = 30
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# docker is an external program: check its exit code ourselves
function Invoke-Docker {
    docker @args
    if ($LASTEXITCODE -ne 0) { throw "docker $($args -join ' ') failed with exit code $LASTEXITCODE" }
}

$imageRef = "${Image}:${Tag}"

# 1. Pull the image
Invoke-Docker pull $imageRef

# 2. Remove the old container, if any (idempotent redeploy)
$existing = docker ps -a --filter "name=^${ContainerName}$" --format '{{.Names}}'
if ($existing) {
    Invoke-Docker rm -f $ContainerName | Out-Null
    Write-Host "Removed old container $ContainerName"
}

# 3. Run the new container; Docker restarts it after a crash or a reboot
Invoke-Docker run -d --name $ContainerName --restart unless-stopped -p "${HostPort}:8080" $imageRef | Out-Null
Write-Host "Started $ContainerName from $imageRef on port $HostPort"

# 4. Health check from outside the container (the aspnet image has no curl),
#    with retries: "container running" does not mean "app ready"
$url = "http://localhost:$HostPort/"
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
while ($true) {
    try {
        $response = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 5
        if ($response.StatusCode -eq 200) {
            Write-Host "GET $url -> 200 $($response.Content)"
            break
        }
    } catch {
        # App not ready yet; try again until the deadline
    }
    if ((Get-Date) -gt $deadline) {
        docker logs --tail 20 $ContainerName
        throw "$ContainerName did not answer 200 on $url within $TimeoutSeconds seconds"
    }
    Start-Sleep -Seconds 2
}
