# EntityFrameworkToFlywayConverter

A template for teams whose developers use **Entity Framework (EF)** while the Ops/DBA team deploys to senior environments with **Flyway**. Developers keep working in EF. A set of scripts keeps a Flyway project in step with the EF migrations, so Ops get ordinary Flyway migrations to deploy, and checks prove the two agree.

Everything runs in Docker (a SQL Server container for the databases, and a Flyway container), so there is nothing to install except Docker, plus the .NET SDK for the EF commands.

> **Status: proof of concept.** The developer workflow and the sync checks work end to end. Git hooks, CI/CD pipelines and the Ops deployment pipelines are still to do. See [Progress](#progress) and [Pending tasks](#pending-tasks).
>
> **AI agents:** read [AGENTS.md](AGENTS.md) first. It lists the rules that must not be broken when changing this repo.

## How it fits together

```text
EF model ──▶ EF migrations ──deploy──▶ dev database ──▶ Flyway schema model ──▶ Flyway migrations ──▶ Ops pipelines
(C#)         (C#, dotnet ef)           (SQL Server       (Flyway/schema-model)    (Flyway/migrations)    (senior environments)
                                        in a container)
```

- `EntityFramework/` is an EF Core 8 project that developers change using EF migrations. The sample model in it is a placeholder: see [Adapting this template](#adapting-this-template).
- `Flyway/` is the Flyway project that Ops use. Its **schema model** is a snapshot of the database as files; its **migrations** are versioned SQL scripts with undo scripts.
- `Scripts/` holds the bash scripts that connect them. They run in WSL (or any Linux shell) and use only the plain `docker` CLI.

For readers who know Flyway but not EF:

| Entity Framework | Flyway equivalent |
|---|---|
| `Models/` and `Data/AppDbContext.cs` | The desired schema, written as C# |
| `Migrations/*.cs` | `V__*.sql` versioned migrations, written as C# `Up()`/`Down()` code |
| `AppDbContextModelSnapshot.cs` | The model as of the latest migration. EF diffs the model against it to generate the next migration. |
| `__EFMigrationsHistory` table | `flyway_schema_history` |
| `dotnet ef migrations add <Name>` | Generates the next migration from your model changes |
| `dotnet ef migrations script --idempotent` | One SQL script, guarded by history checks, that works from any starting state |

## Prerequisites

1. **A Docker-compatible container engine** reachable as `docker` in your shell. Docker Engine, Docker Desktop, Rancher Desktop or Podman (with a `docker` alias) all work: the scripts don't depend on any one of them. Set `DOCKER=<cli>` to use a differently named CLI.
2. **The .NET 8 SDK and the `dotnet-ef` tool**, for the EF commands.
3. **Redgate credentials**, because the Flyway features used here (`diff`, `model`, `generate`) need Flyway Enterprise. See [Credentials](#credentials).

Every script checks these first and, if something is missing, stops with a message saying what to do. If you don't have Docker or .NET in WSL (Ubuntu or Debian), these scripts install them:

```bash
./Scripts/SetupDockerOverWSL.sh        # installs Docker Engine natively inside WSL
./Scripts/SetupDotnetPrerequisites.sh  # installs the .NET 8 SDK and dotnet-ef
newgrp docker                          # or open a new terminal, to pick up the docker group
```

The Docker script is a generic starting point. If your organisation has its own standard Docker setup, use that: nothing else in this repo depends on the setup script.

If you check this repo out on Windows with `core.autocrlf=true`, `.gitattributes` keeps LF line endings on the `.sh` files and the Dockerfile so they still run in Linux.

### Credentials

> **PoC only.** For this proof of concept, all three secrets are plain environment variables. **Before this is used in anger, change the code to fetch them from a proper secrets manager** (Azure Key Vault, etc.). Only `require_sql_password` and `require_flyway_auth` in `Scripts/lib/common.sh` need to change. The scripts print a warning on every run as a reminder (to stderr; silence it with `SUPPRESS_SECRETS_WARNING=true`).

Three variables are needed:

```bash
export REDGATE_EMAIL='you@your-company.com'                 # Redgate account email (Flyway Enterprise)
export REDGATE_TOKEN='<your Redgate personal access token>'  # activates Flyway Enterprise in the container
export MSSQL_SA_PASSWORD='Use-A-Strong-Local-Password1!'     # SA password for the local SQL Server container
```

`MSSQL_SA_PASSWORD` can be any strong password. It is used when the SQL Server container is first created.

**Set them once, as Windows environment variables, or export them in your shell.** Under WSL the scripts look in the Windows user and machine environment automatically when a variable isn't already set (via `powershell.exe`), so you don't need a second copy in `~/.bashrc`. To let plain `dotnet ef` commands (which are not our scripts) see the SA password too, also add `MSSQL_SA_PASSWORD/u` to the Windows `WSLENV` variable. [EndToEndDemoInstructions.md](EndToEndDemoInstructions.md) has the exact PowerShell. On plain Linux, or in CI, set them as ordinary environment variables.

The scripts pass secrets to containers by variable *name*, so they never appear on a command line. Anyone who can run `docker inspect` on a running container can still read its environment, which is acceptable on a developer's own machine for short-lived containers, but is one more reason to move to a secrets manager.

## Developer workflow

Run these from the repo root, in WSL. To try the whole flow on a scratch branch with an example change, follow [EndToEndDemoInstructions.md](EndToEndDemoInstructions.md).

| Step | Do this | What happens |
|---|---|---|
| 1 | Change the model in `EntityFramework/Models/`, then `dotnet ef migrations add <Name> --project EntityFramework` | EF generates the migration |
| 2 | `./Scripts/DockerDeployFromEntityFrameworkIdempotentScript.sh` | The EF migrations are applied to your branch's dev database in a local SQL Server container |
| 3 | `./Scripts/UpdateFlywaySchemaModel.sh` | `Flyway/schema-model` is updated from the dev database (`flyway diff model`) |
| 4 | `./Scripts/GenerateFlywayMigrations.sh "<describe the change>"` | The next Flyway migration and its undo script are written to `Flyway/migrations` (`flyway diff generate`, via the shadow database) |
| 5 | `./Scripts/CheckSync.sh` | Verifies that all the layers agree |
| 6 | Commit the EF migration, the schema model and the Flyway migrations **together** | |

### One database per git branch

The databases are disposable, and each git branch gets its own, in one shared container. One naming rule covers the EF scripts and Flyway:

| Database | Name | Example for `feature/my-change` |
|---|---|---|
| **Dev**: EF deploy target *and* Flyway's development database | `<base>_<branch>` | `<base>_featuremychange` |
| **Shadow**: Flyway's scratch database, rebuilt from the migrations when comparing or generating | `<base>_<branch>_shadow` | `<base>_featuremychange_shadow` |

`<base>` is `MSSQL_DATABASE_BASE` (see [Settings](#settings)).

`<branch>` is the branch name with everything except ASCII letters and digits removed. That is exactly what Flyway's git resolver does with `${git.branch:ad}` in `Flyway/flyway.toml`, so Flyway and the scripts always agree on the name for a branch. (Two branches that differ only in punctuation, such as `feature/x-y` and `feature/xy`, would share databases.)

Remove old databases with:

```bash
./Scripts/CleanupDatabases.sh                    # dry run: lists databases whose branch no longer exists
./Scripts/CleanupDatabases.sh --merged --yes     # drops them
./Scripts/CleanupDatabases.sh --branch feature/old --yes
./Scripts/CleanupDatabases.sh --all --yes        # drops every database these scripts created
```

It never drops anything without `--yes`, and only considers databases starting with the base name, so `master` and your own databases are safe. The container is left running. To remove it entirely: `docker rm -f entityframework-flyway-sample`.

## Checks

`./Scripts/CheckSync.sh` verifies that every layer agrees with the next. It is non-interactive, so it works by hand, in a git hook or in CI.

| Check | Compares | If it fails, run |
|---|---|---|
| `ef` | EF model, EF migrations, and what's applied to the dev database | `dotnet ef migrations add`, or the deploy script |
| `model` | Dev database and Flyway schema model | `UpdateFlywaySchemaModel.sh` |
| `migrations` | Schema model and Flyway migrations (shadow database rebuilt from them) | `GenerateFlywayMigrations.sh` |
| `end-to-end` | Flyway migrations and the EF-deployed dev database | bring the earlier checks into sync first |

```bash
./Scripts/CheckSync.sh                        # all four, readable output
./Scripts/CheckSync.sh --check model          # just one (repeat --check to run several)
./Scripts/CheckSync.sh --output json          # unattended: stdout is one JSON document (see below)
```

Exit codes: `0` in sync, `1` something is out of sync (the output says how to fix it), `2` a check couldn't run. The exit code is the pass/fail signal in both output modes.

With `--output json`, stdout contains one JSON document and nothing else (progress goes to stderr), for pipelines and tools to consume:

```json
{ "inSync": false, "exitCode": 1, "database": "<base>_<branch>",
  "checks": [ { "name": "model", "status": "out-of-sync",
                "differences": [ { "type": "Edit", "objectType": "Table", "name": "dbo.Orders" } ],
                "fix": "./Scripts/UpdateFlywaySchemaModel.sh" } ] }
```

`status` is `in-sync`, `out-of-sync` or `error`. The Flyway checks get their differences from `flyway diff -outputType=json`.

`./Scripts/CheckFlyway.sh` runs Flyway's code review (`flyway check -code`) on the migrations, with the T-SQL dialect and all of Flyway's default rules. It needs no database. It reports violations by default; add `--fail-on-error` to fail on them in a hook or pipeline. Expect some rules to fire on undo scripts (for example RG01, "Usage of DROP TABLE is discouraged", on the undo of an initial creation), so refine the rule set before enabling `--fail-on-error`.

## Settings

Every setting is an environment variable with a default. Override them, don't edit the scripts.

| Variable | Default | Purpose |
|---|---|---|
| `MSSQL_SA_PASSWORD` | (required) | SA password for the SQL Server container |
| `REDGATE_EMAIL`, `REDGATE_TOKEN` | (required for Flyway) | Redgate account email and personal access token (PoC: environment variables, to be replaced by a secrets manager) |
| `SUPPRESS_SECRETS_WARNING` | (unset) | Set to `true` to silence the PoC warning about secrets coming from environment variables |
| `MSSQL_DATABASE_NAME` | derived from the branch | Exact dev database name (EF deploy script only; the Flyway scripts always use the branch name) |
| `MSSQL_DATABASE_BASE` | `EntityFrameworkDemo` | Prefix for the branch-named databases. Must match the database names in `Flyway/flyway.toml`. |
| `MSSQL_CONTAINER_NAME` | `entityframework-flyway-sample` | The SQL Server container to start or reuse |
| `MSSQL_PORT` | `1433` | Host port (applies when the container is first created) |
| `MSSQL_IMAGE` | `mcr.microsoft.com/mssql/server:2022-latest` | SQL Server image. Point at an internal registry or mirror if needed. |
| `FLYWAY_BASE_IMAGE` | `redgate/flyway:13.12.2` | The commercial Flyway image. **Flyway's version is pinned here.** Must be `redgate/flyway`, not `flyway/flyway` (the free Community edition). |
| `DOCKER` | `docker` | Container CLI to use |

### The Flyway container

Flyway runs from `redgate/flyway`, plus git: Flyway's git resolver (`${git.branch}`) runs the `git` command, which the official image doesn't contain. [Scripts/docker/flyway/Dockerfile](Scripts/docker/flyway/Dockerfile) adds it, and the scripts build that image automatically the first time. Behind a corporate registry or proxy, change `FLYWAY_BASE_IMAGE` and the Dockerfile.

The container shares the SQL Server container's network, so the `127.0.0.1:1433` URLs in `Flyway/flyway.toml` work unchanged. It never reads your `flyway.user.toml` (which holds Flyway Desktop secrets it couldn't decrypt): the scripts mount a temporary credentials file over it, inside the container only.

## Adapting this template

The sample EF model and database name are placeholders. To use your own:

1. Replace the contents of `EntityFramework/` with your EF project (keep a design-time factory that reads `MSSQL_SA_PASSWORD`, `MSSQL_PORT` and `MSSQL_DATABASE_NAME`, as `Data/AppDbContextFactory.cs` does), and delete the sample `Flyway/migrations` and `Flyway/schema-model` so they are regenerated from your model. Update or delete `EndToEndDemoInstructions.md`, which refers to the sample model.
2. Choose your database base name: set the default of `MSSQL_DATABASE_BASE` in `Scripts/lib/common.sh` **and** the two `databaseName=` values in `Flyway/flyway.toml` (they must agree, see [One database per git branch](#one-database-per-git-branch)). Optionally rename the container (`MSSQL_CONTAINER_NAME`).
3. Run the [developer workflow](#developer-workflow) once, then `./Scripts/CheckSync.sh`.

## Troubleshooting

- **`localhost,1433` fails from a Windows tool such as SSMS, but `127.0.0.1,1433` works.** A quirk of how some Windows SQL clients resolve `localhost` through WSL's port forwarding. Use `127.0.0.1,1433`.
- **A script says it can't find Docker.** Follow the message: it distinguishes "not installed", "not running", "no permission" and "Docker Desktop stub without WSL integration".
- **Flyway reports Community Edition.** The Redgate credentials didn't reach the container. See [Credentials](#credentials).
- **`git status` shows every file modified when run in WSL.** Files checked out by Windows git have CRLF line endings, which Linux git sees as changes. Use Windows git for `git status`, or clone the repo inside WSL.

## Progress

Done and verified in WSL (Ubuntu 22.04) with Flyway 13.12.2 Enterprise:

- A sample EF Core 8 project with migrations.
- Container-engine-agnostic scripts with preflight checks, and setup scripts for Docker Engine and .NET inside WSL.
- Idempotent EF deployment to a SQL Server container; one dev database and one shadow database per git branch, with cleanup.
- The Flyway project, with branch-aware environments, run from a container.
- Developer scripts that update the schema model and generate Flyway migrations from it, tested end to end by adding a column and walking through the whole workflow.
- `CheckSync.sh` (four sync checks) and `CheckFlyway.sh` (code review).

## Pending tasks

1. **Git hooks**, kept fast and non-blocking: for example pre-commit (`CheckFlyway.sh`, `CheckSync.sh --check ef`) and pre-push (`CheckSync.sh`), shipped via a committed `core.hooksPath` folder.
2. **CI/CD checks and when to run them**: on pull request, on merge, on a schedule. They need a throwaway SQL Server container and the Redgate credentials from a secret store.
3. **Ops deployment pipelines** (Azure DevOps): outside this repo's developer scripts. They would use `flyway migrate`, plus `check -changes`, `check -drift` and `check -dryrun` against real environments.
4. **Code-review policy** for `check -code` (see above): refine the rule set, then enable `--fail-on-error`.
5. **Secrets manager (required before real use):** replace the environment variables for the Redgate credentials and SA password (see [Credentials](#credentials); only `require_flyway_auth` and `require_sql_password` in `Scripts/lib/common.sh` need to change), then remove the PoC warning.
6. **More realistic test migrations** (index, foreign key, data changes) and **baselining** existing databases (`baselineOnMigrate`).
7. **Customer adaptation:** confirm their container engine and registry policy (Docker Desktop is untested here: only a native Docker Engine in WSL has been run), and re-check that Flyway Desktop doesn't write the removed `majorTolerance` setting back into `flyway.toml`.
