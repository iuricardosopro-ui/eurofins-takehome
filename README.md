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

_Coming in each step._

## Repository conventions

| File | Why it exists |
|---|---|
| `global.json` | Pins the .NET 10 SDK (LTS) so local builds and CI use the same version |
| `.gitattributes` | Normalizes line endings (Windows CRLF vs Linux LF runners) |
| `.editorconfig` | Consistent code style for any editor and the compiler |
| `Directory.Build.props` | Shared build rules for all projects: nullable checks, warnings as errors |
| `EurofinsTakeHome.sln` | Groups all projects; classic `.sln` format for compatibility with older Visual Studio |

Workflow: GitHub Flow (short-lived branches, pull requests, squash merge) and Conventional Commits.