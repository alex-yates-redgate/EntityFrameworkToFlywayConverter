# End-to-end demo

A walkthrough that proves the whole workflow works: change an Entity Framework (EF) model, then watch Flyway's schema model and migrations catch up, and the sync checks go green. It uses a scratch branch and disposable databases, so nothing real is touched.

> This walkthrough uses the sample `Product` model in `EntityFramework/Models/`. If you have replaced the sample with your own EF project (see [Adapting this template](README.md#adapting-this-template)), pick any model class of yours and add a nullable column instead, then update or delete this file.

## Prerequisites

### A Windows machine with WSL

This demo is written for a **Windows machine with WSL (Windows Subsystem for Linux) enabled** and a Linux distribution installed (for example Ubuntu). Enable it from an administrator PowerShell with `wsl --install`, then restart. Check with `wsl --status`.

Clone the repo on Windows, then run **every command below from the repo root inside a WSL terminal** (the repo is under `/mnt/c/...`). The scripts are bash scripts and don't run in PowerShell or cmd.

### Install the tools inside WSL

Inside WSL you need Docker Engine, the .NET 8 SDK and `dotnet-ef`. Two setup scripts install them. They need an Ubuntu or Debian distro and ask for your `sudo` password. Skip a script if its tool is already installed: both detect that and do nothing.

Run them once, from the repo root in a WSL terminal:
```bash
./Scripts/SetupDockerOverWSL.sh        # add -y to skip the confirmation prompt
./Scripts/SetupDotnetPrerequisites.sh
```
Then open a **new** WSL terminal (the `docker` group membership only applies to new shells).

**`SetupDockerOverWSL.sh`** installs Docker Engine natively inside WSL, with no Docker Desktop. It:
1. Adds Docker's official apt repository and signing key.
2. Installs `docker-ce`, `docker-ce-cli`, `containerd.io` and the buildx and compose plugins.
3. Adds your user to the `docker` group, so you don't need `sudo` for `docker`.
4. Starts the Docker service and checks that the engine responds.

It shows this list and asks you to confirm before changing anything. If your WSL distro isn't running systemd, Docker won't start automatically after a WSL restart: run `sudo service docker start`, or enable systemd as the script's closing message explains. If your organisation has its own standard Docker setup, use that instead. The demo scripts only need a working `docker` CLI.

**`SetupDotnetPrerequisites.sh`** installs what the EF commands need. It:
1. Installs the .NET 8 SDK (`dotnet-sdk-8.0`) with apt.
2. Installs the `dotnet-ef` tool (version 8.0.x) as a global .NET tool.
3. Adds `~/.dotnet/tools` to your `PATH` in `~/.bashrc`.

Both are safe to re-run. On native Linux or in CI the demo scripts also work, with the secrets set as ordinary environment variables instead.

### Windows environment variables

Set these three **on the Windows machine**, as user environment variables:

| Variable | Value |
|---|---|
| `MSSQL_SA_PASSWORD` | Any strong password for the local SQL Server container: at least 8 characters with upper case, lower case, a digit and a symbol. It is used when the container is first created. |
| `REDGATE_EMAIL` | Your Redgate account email, used to activate Flyway Enterprise. |
| `REDGATE_TOKEN` | A Redgate personal access token for that account. |

Set them in PowerShell (this persists), then **open a new WSL terminal** so it picks them up:
```powershell
[Environment]::SetEnvironmentVariable('MSSQL_SA_PASSWORD','Use-A-Strong-Local-Password1!','User')
[Environment]::SetEnvironmentVariable('REDGATE_EMAIL','you@your-company.com','User')
[Environment]::SetEnvironmentVariable('REDGATE_TOKEN','<your personal access token>','User')

# Make the SA password visible inside WSL, for plain `dotnet ef` commands (appends to any existing WSLENV)
$wslenv = [Environment]::GetEnvironmentVariable('WSLENV','User')
if ($wslenv -notmatch 'MSSQL_SA_PASSWORD') {
    [Environment]::SetEnvironmentVariable('WSLENV', (($wslenv, 'MSSQL_SA_PASSWORD/u') | Where-Object { $_ }) -join ':', 'User')
}
```
`WSLENV` is the standard Windows setting that lists which Windows variables are passed into WSL. Only `MSSQL_SA_PASSWORD` needs it: the Redgate variables are only used by our scripts, which read them from Windows themselves. Close **all** terminal windows (including Windows Terminal and VS Code) and open a new WSL terminal, because already-running programs keep the old environment. Check it worked with `echo ${MSSQL_SA_PASSWORD:+set}` in WSL, which should print `set`.
Alternatively use *Edit environment variables for your account* in the Windows Start menu. The `Scripts/*.sh` scripts read any of the three from the Windows user or machine environment themselves if it isn't set in the WSL shell. `WSLENV` (below) additionally lets other tools you run in WSL, such as `dotnet ef`, see the password.
> **PoC only: don't ship this.** Plain environment variables are fine for a throwaway demo but not for real use: other processes can read them, and anyone who can run `docker inspect` on a running container can see them. **Before this is used in anger, change the code to fetch these secrets from a proper secrets manager** (Azure Key Vault, etc.). Only `require_sql_password` and `require_flyway_auth` in `Scripts/lib/common.sh` need to change. The scripts print a warning about this on every run, which is expected. See [Credentials](README.md#credentials).

## Steps

### 0. Set up a scratch branch
In a WSL terminal, from the repo root:
```bash
git checkout -b scratch-test   # databases are named per branch
```

### 1. Make an example change
In `EntityFramework/Models/Product.cs`, add a property under `Price`:
```csharp
public string? Description { get; set; }
```
`string?` becomes a nullable `nvarchar(max)` column.

### 2. Generate the EF migration
```bash
cd EntityFramework
dotnet ef migrations add AddProductDescription
cd ..
```
A new file appears in `EntityFramework/Migrations/`. Generate it however you like, this is plain EF. If it fails with `Set MSSQL_SA_PASSWORD before using EF tooling.`, the password isn't visible in WSL: check the `WSLENV` setting above and that you opened a new terminal.

### 3. Deploy to this branch's dev database
```bash
Scripts/DockerDeployFromEntityFrameworkIdempotentScript.sh
```
This starts the SQL Server container (the first run pulls the image, so it is slow) and applies the EF migrations to `EntityFrameworkDemo_scratchtest`.

### 4. Check that the layers are out of sync
```bash
Scripts/CheckSync.sh; echo "exit=$?"
```
Expect exit code **1**, with the `model` and `end-to-end` checks out of sync.

### 5. Update the Flyway schema model
```bash
Scripts/UpdateFlywaySchemaModel.sh
```
`flyway diff model` runs from the dev database into `Flyway/schema-model`. The `Description` column should now appear for `Product`. The first Flyway run builds the local Flyway image, which is slow once.

### 6. Generate the Flyway migration
```bash
Scripts/GenerateFlywayMigrations.sh "AddProductDescription"
```
New `V…` and `U…` files appear in `Flyway/migrations`.

### 7. Check that everything is in sync
```bash
Scripts/CheckSync.sh; echo "exit=$?"
```
Expect exit code **0** and all four checks passing. This is the pass condition for the demo.

### 8. Optional: lint the migrations
```bash
Scripts/CheckFlyway.sh
```

## Clean up

```bash
git clean -fdn EntityFramework Flyway        # dry run: check what it would delete
git checkout -- . && git clean -fd EntityFramework Flyway
git checkout main && git branch -D scratch-test
Scripts/CleanupDatabases.sh --branch scratchtest --yes
git ls-files | grep user.toml                # must print nothing
```
The database name uses the branch name with the hyphen removed, which is why the cleanup uses `scratchtest`.

## If something goes wrong

- **Exit code 2** means a prerequisite is missing. The `ERROR:` message says which one: Docker, `dotnet ef`, the SA password or the Redgate credentials.
- **Step 7 fails only on `end-to-end`:** see the troubleshooting notes in [AGENTS.md](AGENTS.md) (a phantom difference on a system-named constraint is the usual cause).
- **`git status` in WSL shows every file modified:** that's CRLF noise from a repo checked out by Windows git. Ignore it.
- More in [Troubleshooting](README.md#troubleshooting).
