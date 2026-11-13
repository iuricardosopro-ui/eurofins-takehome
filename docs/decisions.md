# Design decisions

Notes on why the repo and scripts look the way they do, plus a few corners I cut on purpose.

## Platform & repo setup

I went with **.NET 10 (LTS)** instead of .NET Core 3.1. The brief says "at least .NET Core 3.1", which has been EOL since December 2022, so using it today makes little sense. `global.json` locks the SDK to `10.0.404` with `rollForward: latestFeature`—it'll pick up newer `10.0.x` patches automatically without ever jumping to 11.

For the app itself, I used the empty **Minimal API** template (`dotnet new web`) rather than Razor Pages. The acceptance criteria only ask for a "Hello World" endpoint, and keeping it barebones means you can read the whole thing line by line without boilerplate getting in the way. Because of that, the customer form/grid from the brief isn't there (out of scope; I focused on the six DevOps steps).

A couple of repo-level choices to save headaches later:

* **Classic `.sln` over `.slnx`:** .NET 10 defaults to `.slnx` now, which breaks older Visual Studio installs. Since the brief specifies it has to open cleanly in Visual Studio or VS Code, I stuck with the classic format.
* **`Directory.Build.props`:** Centralizes nullable checks, implicit usings, and `TreatWarningsAsErrors` so I don't have to copy-paste them across `.csproj` files—and CI catches warnings immediately.
* **No automated tests:** Kept the scope strictly to what was asked. A clean build with warnings treated as errors acts as the main quality gate here.

Git workflow is standard GitHub Flow with squash merges and Conventional Commits—short-lived branches, one PR per step, one clean commit landing on `main`. Because this is a private repo on GitHub Free, branch protection isn't available, so "no direct pushes to `main`" is just an honor-system convention here. On a paid plan, I'd lock `main` behind PRs and passing checks.

## CI pipeline (Steps 1 & 5)

The workflow triggers on PRs targeting `main` and pushes to `main`. PRs run the full build and validate the Dockerfile (GitHub tests the merge commit), while pushes to `main` produce the official zip and push the container image. No redundant double runs.

The **zip packaging job** runs on `windows-latest`. Technically the app is portable and builds fine on Linux, but building and zipping on Windows keeps the entire pipeline in PowerShell—matching the target servers (IIS and Windows Service) and the deployment scripts. It's slightly slower to spin up and burns more private-repo minutes, which is negligible at this scale.

A few small details baked into the workflow:

* Permissions default to `contents: read`, elevating to `packages: write` only in the Docker job. `concurrency` cancels stale runs if I push twice quickly, and `--no-restore` / `--no-build` skip duplicate work.
* Both the zip and the container image share the `1.0.<run_number>` version plus the short commit SHA.
* `actions/upload-artifact@v7` uses `archive: false` so GitHub doesn't wrap the `.zip` inside another `.zip`.

In parallel, the **Docker job** runs on `ubuntu-latest` (GitHub's Windows runners can't build Linux containers) without touching the zip job. It builds on every PR to catch broken Dockerfiles early, then pushes to `ghcr.io` on `main` using the ephemeral `GITHUB_TOKEN` instead of hardcoded registry secrets. Images get tagged with the version, `sha-<commit>`, and `latest`, alongside standard OCI labels pointing back to the commit and repo.

I made the **container package public** even though the repo is private. It only holds the compiled Hello World binaries—nothing from the assignment brief—so anyone can pull and run it on any box without wrestling with GHCR auth tokens.

## IIS deployment (Step 2)

The site runs as `HelloWorldSite` on HTTP `8080` and HTTPS `8443` (leaving port 80 free for the Default Web Site), with the app mounted under `/helloworld` as requested. HTTPS uses a self-signed cert since this is strictly a local lab setup.

The app pool is set to **"No Managed Code"** and runs under a dedicated local account, `svc_helloworld`. ASP.NET Core apps are hosted by the ASP.NET Core Module rather than the legacy .NET Framework CLR, and since it runs in-process, the worker inherits that pool identity directly. File permissions are handled via a local `HelloWorldUsers` group with read/execute on the site folder—easier to audit in one place, and it doesn't need write access to logs because IIS writes those itself.

I wrote the deploy script to be **idempotent**: it checks existing state before creating resources and enforces target properties, meaning re-running it handles redeploys cleanly. Redeploying had two annoying edge cases worth calling out:

1. IIS locks the app DLLs while running in-process, and its management API sometimes keeps reporting a dead `w3wp.exe` as "Stopping". After stopping the app pool, the script polls the actual OS process list until the worker process is truly gone.
2. `Expand-Archive` ignores the script-level `$ErrorActionPreference` because it's a module function, so I had to pass `-ErrorAction Stop` explicitly to avoid silent extraction failures.

At the very end, a quick smoke test hits `http://localhost:8080/helloworld` and fails the script if it doesn't get a `200`.

## Status monitor & Windows Service (Steps 3 & 4)

The monitor is a **.NET Worker Service** (`AddWindowsService`) that runs equally well from an IDE or as a background Windows Service. Target URL and polling interval live in `appsettings.json` (defaulting to 60s), and both can be overridden via CLI flags during local testing.

Any connection error or timeout is treated the same as a non-200 response and logged with status code `0`—if IIS goes down completely, the monitor still catches it and bails out. Logs go to `status.log` right next to the binary (`AppContext.BaseDirectory`), per the brief.

When a check fails, the process calls `Environment.Exit(1)` instead of a graceful shutdown. Stopping cleanly tells the Windows Service Control Manager everything exited normally, which skips recovery actions. Following Microsoft's guidance for Worker Services, a non-zero exit forces Windows to treat it as a crash. I verified this in Event Viewer: Event `7031` fires (*"terminated unexpectedly... restart in 300000 ms"*), and SCM brings it back up five minutes later.

To run it safely, the setup script creates `svc_statusmonitor`, grants "Log on as a service" via `secedit`, and installs the binaries under `C:\Services\StatusMonitor` (not `Program Files`, where the service account wouldn't have write permissions for `status.log`). One quirk with `secedit`: it returns a non-zero exit code if *any* unrelated policy entry on the machine has a localized name it can't resolve, so the script verifies the exported security policy directly instead of trusting `secedit`'s exit code.

Service recovery is configured to restart after 300 seconds on the first, second, and subsequent failures, resetting the failure counter after 24 hours, with `failureflag` enabled so non-zero exit codes always trigger recovery.

## Docker (Steps 5 & 6)

The **Dockerfile uses a multi-stage build** (SDK image to compile, the ASP.NET runtime image to run), drops privileges to the non-root `app` user, exposes `8080`, and builds with `-p:UseAppHost=false` so the container executes `dotnet HelloWorld.dll` directly. I deliberately left `global.json` out of the Docker build context—inside the container, the base image tag already pins the SDK version.

Speaking of tags: I used the floating **:10.0** tag rather than an exact patch version or digest. That way rebuilds automatically pick up upstream security patches, even if it means two builds a week apart aren't bit-for-bit identical. For strict reproducibility in production, I'd lock the exact patch version or SHA digest.

Finally, the **container deploy script is written in PowerShell** (the preferred scripting language in the brief). It pulls the new image, swaps out the old container, starts the new one with `--restart unless-stopped`, and polls the endpoint from the host until it gets a `200`—partly because the runtime image doesn't include `curl`, and partly because Docker reporting a container as "running" doesn't mean Kestrel is actually ready to serve traffic yet.
