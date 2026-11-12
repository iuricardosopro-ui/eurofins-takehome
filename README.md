# Eurofins DevOps Take-Home – HelloWorld

Spike of a customer management web app on .NET 10, with a CI pipeline,
an IIS deployment script and a Windows Service that monitors the site.

## Assignment coverage

| Step | Description | Status | Location |
|---|---|---|---|
| 1 | Build + CI pipeline (zip package) | Planned | `.github/workflows/` |
| 2 | IIS deployment script | Planned | `deploy/iis/` |
| 3 | Status monitor (Windows Service) | Planned | `src/StatusMonitor/` |
| 4 | Windows Service deployment script | Planned | `deploy/service/` |
| 5 | Docker image (optional) | Planned | `Dockerfile` |
| 6 | Docker deployment (optional) | Planned | `deploy/docker/` |

## How to run

### Run locally

```powershell
dotnet run --project src/HelloWorld --launch-profile http
curl.exe http://localhost:5176/   # Hello World!
```

### CI pipeline

GitHub Actions (`.github/workflows/ci.yml`) runs on every pull request to `main` and on every push to `main`:
restore → build (Release) → publish → zip → upload artifact.

The artifact is named `HelloWorld-1.0.<run number>-<short sha>.zip` and is available for 7 days in the run's **Artifacts** section.
The runner is `windows-latest`, the same OS as the IIS target.

## Repository conventions

| File | Why it exists |
|---|---|
| `global.json` | Pins the .NET 10 SDK (LTS) so local builds and CI use the same version |
| `.gitattributes` | Normalizes line endings (Windows CRLF vs Linux LF runners) |
| `.editorconfig` | Consistent code style for any editor and the compiler |
| `Directory.Build.props` | Shared build rules for all projects: nullable checks, warnings as errors |
| `EurofinsTakeHome.sln` | Groups all projects; classic `.sln` format for compatibility with older Visual Studio |

Workflow: GitHub Flow (short-lived branches, pull requests, squash merge) and Conventional Commits.

### Deploy to IIS (Step 2)

Run in an **elevated** PowerShell (Run as Administrator), with IIS and the ASP.NET Core Hosting Bundle installed:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
$appPoolPwd = Read-Host -AsSecureString "Password for svc_helloworld"
.\deploy\iis\Deploy-IIS.ps1 -ZipPath C:\temp\HelloWorld-<version>.zip -AppPoolPassword $appPoolPwd
```

The script is idempotent (safe to run again; it also redeploys the zip) and creates:
local user `svc_helloworld` in group `HelloWorldUsers` (read/execute on the site folder),
app pool `HelloWorldPool` (No Managed Code, runs as that user),
site `HelloWorldSite` on http `8080` and https `8443` (self-signed certificate, lab only),
site logs in `C:\inetpub\logs\HelloWorldSite`, and the application `/helloworld`.
It ends with a smoke test: `http://localhost:8080/helloworld` must return `200 Hello World!`.

### Status monitor (Step 3)

`src/StatusMonitor` is a .NET Worker Service that can run from the IDE (F5) or from the terminal:

```powershell
dotnet run --project src/StatusMonitor
```

Every `StatusMonitor:IntervalSeconds` (60, in `appsettings.json`) it calls `StatusMonitor:Url`
(`http://localhost:8080/helloworld`) and appends `<timestamp> <url> <code> <message>` to `status.log`,
next to the executable. If the status is not 200 (a connection error is logged as code `0`),
it stops with exit code 1, so Windows service recovery can restart it (Step 4).

For a quick test, override the interval: `dotnet run --project src/StatusMonitor -- --StatusMonitor:IntervalSeconds=5`

### Install the status monitor as a Windows Service (Step 4)

Run in an **elevated** PowerShell:

```powershell
dotnet publish src/StatusMonitor -c Release -o C:\temp\StatusMonitor-publish
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
$svcPwd = Read-Host -AsSecureString "Password for svc_statusmonitor"
.\deploy\service\Install-StatusMonitor.ps1 -PublishPath C:\temp\StatusMonitor-publish -ServicePassword $svcPwd
```

The script is idempotent. It creates the local account `svc_statusmonitor` with the "Log on as a service" right,
copies the files to `C:\Services\StatusMonitor` (the account can write `status.log` there),
creates the service `StatusMonitor` running as that account with automatic start,
and sets recovery to restart the service 300 seconds after each failure.

Verified cycle: site stopped → `503` logged and the service exits with code 1 →
Windows event 7031 ("terminated unexpectedly... restart in 300000 ms") → service restarted 300 s later → `200 OK`.
