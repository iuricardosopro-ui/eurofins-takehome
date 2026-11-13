# Eurofins DevOps Take-Home – HelloWorld

.NET 10 web app with a CI pipeline (zip package and Docker image), an IIS deployment script, a Windows Service to monitor the site, and a Docker deployment script.

## Assignment coverage

| Step | Description | Status | Location |
| --- | --- | --- | --- |
| 1 | Build + CI pipeline (zip package) | Done | `src/HelloWorld`, `.github/workflows/ci.yml` |
| 2 | IIS deployment script | Done | `deploy/iis/Deploy-IIS.ps1` |
| 3 | Status monitor (Windows Service) | Done | `src/StatusMonitor` |
| 4 | Windows Service deployment script | Done | `deploy/service/Install-StatusMonitor.ps1` |
| 5 | Docker image (optional) | Done | `Dockerfile`, `ci.yml` (`docker` job) |
| 6 | Docker deployment (optional) | Done | `deploy/docker/Deploy-Docker.ps1` |
| — | Customer form + grid (brief) | Not implemented | Out of scope (focused on the 6 DevOps steps) |

## Architecture

```
PR / push to main ──► GitHub Actions (ci.yml)
                        ├─ windows-latest: restore → build → publish → HelloWorld-1.0.<run>-<sha>.zip (artifact)
                        └─ ubuntu-latest:  docker build → push ghcr.io/iuricardosopro-ui/helloworld (main only)

zip ──► Deploy-IIS.ps1 ──► IIS  HelloWorldSite (http :8080, https :8443)
                                 └─ /helloworld → app pool HelloWorldPool (No Managed Code, user svc_helloworld)
                                        ▲
                                        │ GET every 60 s
StatusMonitor (Windows Service, user svc_statusmonitor) ──► status.log next to the exe
        status ≠ 200 → exits with code 1 → Windows recovery restarts it after 300 s

image ──► Deploy-Docker.ps1 ──► Docker Engine  container helloworld (:8081 → 8080)

```

## Stack and prerequisites

* **Runtime and SDK:** C# on .NET 10 (LTS) — SDK `10.0.404`, runtime `10.0.15` (Minimal API and Worker Service).
* **Web server:** IIS 10 with the ASP.NET Core Hosting Bundle `10.0.15`.
* **Automation and CI:** PowerShell 5.1, GitHub Actions, Docker, and GitHub Container Registry.

Before running the scripts locally, you need:

* Windows 10/11 or Windows Server with IIS enabled (including *IIS Management Scripting Tools*), and the ASP.NET Core Hosting Bundle installed **after** IIS.
* .NET 10 SDK to build locally.
* PowerShell running **as Administrator** for Steps 2 and 4.
* Docker (Desktop or Engine, Linux containers) for Steps 5 and 6.

## Running and deploying

### Local app (Step 1)

```powershell
dotnet run --project src/HelloWorld --launch-profile http
curl.exe http://localhost:5176/   # Hello World!

```

### CI pipeline (Steps 1 and 5)

`.github/workflows/ci.yml` runs on every PR and push to `main`:

* **Zip job (`windows-latest`):** runs restore, Release build, publish, and zip, saving `HelloWorld-1.0.<run>-<short sha>.zip` as an artifact for 7 days.
* **Docker job (`ubuntu-latest`):** builds the image on every run to validate the Dockerfile. On pushes to `main`, it logs in with `GITHUB_TOKEN` and pushes `ghcr.io/iuricardosopro-ui/helloworld` with the tags `1.0.<run>`, `sha-<commit>`, and `latest`.

### Deploy to IIS (Step 2)

Download the `.zip` artifact from the latest `main` workflow run and run this in PowerShell as Administrator:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
$appPoolPwd = Read-Host -AsSecureString "Password for svc_helloworld"
.\deploy\iis\Deploy-IIS.ps1 -ZipPath C:\temp\HelloWorld-<version>.zip -AppPoolPassword $appPoolPwd

```

The script is idempotent, so you can run it again to redeploy. It creates the local user `svc_helloworld` in the `HelloWorldUsers` group, sets up `HelloWorldPool` and `HelloWorldSite` (HTTP `8080`, HTTPS `8443`, logs in `C:\inetpub\logs\HelloWorldSite`), and adds the `/helloworld` application. At the end, it checks `http://localhost:8080/helloworld` and fails if it does not return `200 Hello World!`.

### Status monitor (Step 3)

```powershell
dotnet run --project src/StatusMonitor

```

By default, it checks `http://localhost:8080/helloworld` every 60 seconds (`StatusMonitor:Url` and `StatusMonitor:IntervalSeconds` in `appsettings.json`) and writes `<timestamp> <url> <code> <message>` to `status.log` next to the executable. Any status other than `200`—including connection errors, logged as code `0`—makes the process exit with `Environment.Exit(1)`. To test faster locally: `dotnet run --project src/StatusMonitor -- --StatusMonitor:IntervalSeconds=5`.

### Install as a Windows Service (Step 4)

In PowerShell as Administrator:

```powershell
dotnet publish src/StatusMonitor -c Release -o C:\temp\StatusMonitor-publish
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
$svcPwd = Read-Host -AsSecureString "Password for svc_statusmonitor"
.\deploy\service\Install-StatusMonitor.ps1 -PublishPath C:\temp\StatusMonitor-publish -ServicePassword $svcPwd

```

Also idempotent: it creates the `svc_statusmonitor` account with the *Log on as a service* permission, copies the files to `C:\Services\StatusMonitor`, creates the `StatusMonitor` service with automatic start, and configures Windows recovery to restart it 300 seconds after a failure.

Tested cycle: stop the IIS site → the monitor logs `503` and exits with code `1` → Windows logs System Event `7031` (*"terminated unexpectedly... restart in 300000 ms"*) → the service starts again 300 seconds later and logs `200 OK`.

### Deploy the Docker image (Step 6)

```powershell
.\deploy\docker\Deploy-Docker.ps1                 # pulls latest
.\deploy\docker\Deploy-Docker.ps1 -Tag 1.0.12     # specific tag (rollback)

```

Also idempotent: pulls the image, replaces the old container, starts the new one with `--restart unless-stopped` on port `8081` (`8081 -> 8080`), and waits until `http://localhost:8081/` returns `200`.

## Repository layout and conventions

```
.
├── .github/
│   ├── workflows/ci.yml                     # CI: zip package (Windows job) + Docker image (Linux job)
│   └── pull_request_template.md
├── docs/                                    # Design decisions and evidence screenshots
├── src/
│   ├── HelloWorld/                          # ASP.NET Core web app (Step 1)
│   └── StatusMonitor/                       # Worker Service, runs as a Windows Service (Step 3)
├── deploy/
│   ├── iis/Deploy-IIS.ps1                   # IIS deployment (Step 2)
│   ├── service/Install-StatusMonitor.ps1    # Windows Service installation + recovery (Step 4)
│   └── docker/Deploy-Docker.ps1             # Docker deployment (Step 6)
├── Dockerfile                               # Multi-stage image (Step 5)
├── .dockerignore
├── EurofinsTakeHome.sln                     # Opens both projects in Visual Studio / VS Code
├── global.json, Directory.Build.props       # Pinned SDK, shared build rules
└── .editorconfig, .gitattributes, .gitignore

```

| File | Purpose |
| --- | --- |
| `global.json` | Pins the .NET 10 SDK (LTS) so local builds and CI use the same version |
| `.gitattributes` | Keeps line endings consistent across Windows (CRLF) and Linux runners (LF) |
| `.editorconfig` | Keeps code formatting consistent across editors and the compiler |
| `Directory.Build.props` | Centralizes nullable checks and `TreatWarningsAsErrors` across projects |
| `EurofinsTakeHome.sln` | Classic `.sln` format so older Visual Studio versions can open it |

Git workflow: GitHub Flow (short-lived branches, pull requests, squash merges) and Conventional Commits.

## Further docs and evidence

* [docs/decisions.md](docs/decisions.md) — technical choices and trade-offs.
* [docs/images](docs/images) — screenshots: the green CI run on `main` with the zip artifact (Step 1), the IIS site with its http/https bindings (Step 2), and the Windows Service recovery with System event `7031` and `status.log` showing `200 → 503 → 200` (Step 4).

## Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| `sc` does nothing useful in PowerShell | `sc` is an alias for `Set-Content` in PowerShell; use `sc.exe` |
| `curl` behaves differently | `curl` is an alias for `Invoke-WebRequest`; use `curl.exe` |
| IIS returns `500.19` | ASP.NET Core Hosting Bundle is missing, or was installed before IIS (repair it and run `iisreset`) |
| IIS returns `503` | App pool stopped or failed to log on due to a wrong password |
| Service fails with error `1069` | Account does not have *Log on as a service* permission or password is wrong |
| Recovery does not restart the service | Process exited with `0`; the monitor must exit with a non-zero code |
| Redeploy fails with "access denied" on `HelloWorld.dll` | The `w3wp.exe` worker process still holds the file; the script stops the pool and waits for the process to exit |

## About this submission

My daily work is focused on cloud (AWS, Terraform, Docker), so I had not worked with .NET, IIS, or Windows Services before this assignment. Since I was balancing this with my full-time job, I treated it as a hands-on learning exercise and used an AI assistant as a tutor: building and studying step by step, typing, running, and testing every part myself.
Testing locally brought up real issues that I had to debug and fix: redeploys failing because the IIS worker process (w3wp.exe) kept the DLL locked, Windows Service recovery not triggering on a graceful stop (fixed by exiting with a non-zero code), and secedit returning an error on a localized Windows installation. 
