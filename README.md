# EntityFrameworkToFlywayConverter

An Entity Framework development project, with a sidecar Flyway deployment project, that enables developers to use EF, while also providing all the files for the Ops/DBA team to centrally manage deployments to senior environments using Flyway. Uses MSSQL docker containers over WSL.

> **Status: proof of concept, work in progress.** The EF side works end to end. The Flyway side is not built yet. See [Progress](#progress) and [Pending tasks](#pending-tasks).

## How it fits together

- `EntityFramework/` is a minimal EF Core 8 project (one `Products` table) that developers change using EF migrations.
- `Flyway/` will hold the Flyway project that Ops/DBAs use to deploy to senior environments. It is currently a placeholder.
- `Scripts/` holds the bash scripts that tie them together. They run in WSL (or any Linux shell) and use only the plain `docker` CLI.

For readers who know Flyway but not EF:

| Entity Framework | Flyway equivalent |
|---|---|
| `Models/` and `Data/AppDbContext.cs` | The desired schema, written as C# |
| `Migrations/*.cs` | `V__*.sql` versioned migrations, written as C# `Up()`/`Down()` code |
| `AppDbContextModelSnapshot.cs` | The model as of the latest migration. EF diffs the model against it to generate the next migration. |
| `__EFMigrationsHistory` table | `flyway_schema_history` |
| `dotnet ef migrations add <Name>` | Generates the next migration from your model changes |
| `dotnet ef migrations script --idempotent` | Generates one SQL script, guarded by history checks, that works from any starting state |

## Prerequisites

You need:

1. **A Docker-compatible container engine** reachable via the `docker` command in your shell. Docker Engine, Docker Desktop, Rancher Desktop, or Podman with a `docker` alias all work, because the scripts don't depend on any one of them. Set `DOCKER=<cli>` to use a differently named CLI.
2. **The .NET 8 SDK and the `dotnet-ef` tool**, to run EF commands.

Every script checks for these first and, if something is missing, stops with a message explaining what to do. If you don't already have them in WSL (Ubuntu or Debian), these scripts install them:

```bash
./Scripts/SetupDockerOverWSL.sh        # installs Docker Engine natively inside WSL
./Scripts/SetupDotnetPrerequisites.sh  # installs the .NET 8 SDK and dotnet-ef
newgrp docker                          # or open a new terminal, to pick up the docker group
```

The Docker script is a generic starting point. If your organisation has its own standard Docker setup, use that instead; nothing else in this repo depends on the setup script.

If you check this repo out on Windows with `core.autocrlf=true`, `.gitattributes` makes sure the `.sh` files keep LF line endings so they still run in WSL.

## Deploying the EF migrations to a local container

From the repo root, in WSL:

```bash
export MSSQL_SA_PASSWORD='Use-A-Strong-Local-Password1!'
./Scripts/DockerDeployFromEntityFrameworkIdempotentScript.sh
```

The script starts or reuses a SQL Server 2022 container named `entityframework-flyway-sample`, creates a database if needed, generates an idempotent EF migration script, and applies it with `sqlcmd` inside the container. The container keeps running afterwards.

### One database per git branch

Each git branch gets its own disposable databases in the same container. One naming rule covers the EF scripts and Flyway:

| Database | Name | Example for `feature/Add-Price` |
|---|---|---|
| EF deployment | `EntityFrameworkDemo_<branch>` | `EntityFrameworkDemo_featureAddPrice` |
| Flyway development | `EntityFrameworkDemo_<branch>_flyway` | `EntityFrameworkDemo_featureAddPrice_flyway` |
| Flyway shadow | `EntityFrameworkDemo_<branch>_shadow` | `EntityFrameworkDemo_featureAddPrice_shadow` |

`<branch>` is the branch name with everything except ASCII letters and digits removed. That is exactly what Flyway's git resolver does with `${git.branch:ad}` in `Flyway/flyway.toml`, so Flyway and the scripts always agree on the name for a branch. (Two branches that differ only in punctuation, such as `feature/x-y` and `feature/xy`, would share databases.) This stops migrations from different branches getting mixed up in one database. It's safe because every database can be rebuilt from the migrations at any time.

Environment variables you can set:

| Variable | Default | Purpose |
|---|---|---|
| `MSSQL_SA_PASSWORD` | (required) | SA password for the container |
| `MSSQL_DATABASE_NAME` | derived from the branch | Use an exact database name instead |
| `MSSQL_DATABASE_BASE` | `EntityFrameworkDemo` | Prefix for the branch-named databases |
| `MSSQL_CONTAINER_NAME` | `entityframework-flyway-sample` | Container to start or reuse |
| `MSSQL_PORT` | `1433` | Host port for the container |
| `DOCKER` | `docker` | Container CLI to use |

### Cleaning up

```bash
./Scripts/CleanupDatabases.sh              # dry run: lists databases whose branch no longer exists
./Scripts/CleanupDatabases.sh --merged --yes   # drops them
./Scripts/CleanupDatabases.sh --branch feature/old --yes
./Scripts/CleanupDatabases.sh --all --yes  # drops every database these scripts created
```

It never drops anything unless you pass `--yes`, and it only considers databases starting with the base name, so `master` and your own databases are safe. The container itself is left running. To remove it entirely, run `docker rm -f entityframework-flyway-sample`.

## Changing the database with EF

1. Edit the model in `EntityFramework/Models/` (and `Data/AppDbContext.cs` if you need extra configuration).
2. Generate a migration:
   ```bash
   export MSSQL_SA_PASSWORD='Use-A-Strong-Local-Password1!'
   dotnet ef migrations add <MigrationName> --project EntityFramework
   ```
3. Re-run the deploy script. Only the new migration is applied.
4. Commit the model change, the new migration files and the updated snapshot together.

To check you haven't forgotten step 2:

```bash
dotnet ef migrations has-pending-model-changes --project EntityFramework
```

## Progress

Done and verified in WSL (Ubuntu 22.04):

- EF Core 8 project with a `Products` table and two migrations (`InitialCreate`, `AddProductPrice`). The migrations and model agree: no pending model changes.
- Container-engine-agnostic scripts, with preflight checks that fail with guidance when Docker or .NET is missing.
- Setup scripts for Docker Engine and for .NET 8 plus `dotnet-ef` inside WSL.
- Idempotent EF deployment to a local SQL Server container.
- A database per git branch, with a cleanup script (dry run by default).

## Pending tasks

The scripts below exist but only print "To do: write this script".

1. **Create the Flyway project** in `Flyway/`: `flyway.toml`, a `migrations/` folder with `V<n>__name.sql` naming, and an environment for the local container.
2. **`SyncFlywayFromEntityFramework.sh`**: generate versioned Flyway migrations from the EF migrations (`dotnet ef migrations script <from> <to>`). This is the core of the project. Open design questions:
   - how EF migration IDs map to Flyway version numbers;
   - how to keep `__EFMigrationsHistory` out of Flyway's way;
   - making the sync incremental, so migrations that have already been released are never rewritten.
3. **`DockerDeployFromFlywayMigrations.sh`**: deploy the Flyway migrations to a database in the same container, running Flyway as a throwaway container on a shared Docker network (no `host.docker.internal`, no `docker compose`, to stay runtime-agnostic).
4. **`GetEntityFrameworkFlywayDiff.sh`**: compare the EF-deployed database with the Flyway-deployed one (`<db>` and `<db>_flyway`) and fail if they differ. Note that EF created a default constraint when adding the non-nullable `Price` column, which the Flyway migration must reproduce.
5. **Automation**:
   - git hooks, kept fast and non-blocking: for example a `post-checkout` hook to prepare the branch database, and a `pre-push` check for pending model changes, shipped via a committed `core.hooksPath` folder;
   - CI/CD pipeline: a throwaway container per run, the SA password from a secret store, and the diff as a gate.
6. **Container lifecycle options**: a throwaway mode (unique container name, `--rm`) for CI, and a script to remove the container entirely.
7. **Realistic test cases**: a further EF migration with an index, a foreign key and data changes, to exercise the sync and diff.
8. **Baselining**: decide how existing databases are brought under Flyway (`baselineOnMigrate`).
9. **Customer adaptation**: confirm the customer's container engine and organisation policy, and adapt the setup scripts if they have a standard.
