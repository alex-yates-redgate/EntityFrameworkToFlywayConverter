# EntityFrameworkToFlywayConverter
An Entity Framework development project, with a sidecar Flyway deployment project, that enables developers to use EF, while also providing all the files for the Ops/DBA team to centrally manage deployments to senior environments using Flyway. Uses MSSQL docker containers over WSL.

## Entity Framework sample

The `EntityFramework` folder contains a minimal EF Core project for a SQL Server
database with an initial `Products` migration. The `Flyway` folder is reserved
for the future Flyway project.

To deploy the EF migrations to a local SQL Server container from WSL, install
Docker, the .NET 8 SDK, and the `dotnet-ef` tool, then run this from the
repository root:

```bash
export MSSQL_SA_PASSWORD='Use-A-Strong-Local-Password1!'
./Scripts/DockerDeployFromEntityFrameworkIdempotentScript.sh
```

The script starts or reuses the `entityframework-flyway-sample` container,
creates the `EntityFrameworkDemo` database if needed, generates an idempotent
EF migration script, and applies it with `sqlcmd` inside the container. The
container remains running after deployment. Set `MSSQL_CONTAINER_NAME`,
`MSSQL_DATABASE_NAME`, or `MSSQL_PORT` to override the defaults.

The other scripts in `Scripts` are placeholders for future Flyway workflows.
