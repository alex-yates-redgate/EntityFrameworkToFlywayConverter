#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${MSSQL_SA_PASSWORD:-}" ]]; then
    echo "Set MSSQL_SA_PASSWORD to a strong SQL Server SA password before running this script." >&2
    exit 1
fi

if [[ ! "${MSSQL_DATABASE_NAME:-EntityFrameworkDemo}" =~ ^[A-Za-z0-9_]+$ ]]; then
    echo "MSSQL_DATABASE_NAME may contain only letters, numbers, and underscores." >&2
    exit 1
fi

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd -- "$script_dir/.." && pwd)"
project_dir="$repo_dir/EntityFramework"
container_name="${MSSQL_CONTAINER_NAME:-entityframework-flyway-sample}"
database_name="${MSSQL_DATABASE_NAME:-EntityFrameworkDemo}"
port="${MSSQL_PORT:-1433}"
sql_script="$(mktemp)"
trap 'rm -f "$sql_script"' EXIT

if ! command -v docker >/dev/null 2>&1 || ! command -v dotnet >/dev/null 2>&1; then
    echo "Install Docker and the .NET 8 SDK in WSL before running this script." >&2
    exit 1
fi

if docker container inspect "$container_name" >/dev/null 2>&1; then
    docker start "$container_name" >/dev/null
else
    docker run --detach \
        --name "$container_name" \
        --publish "$port:1433" \
        --env ACCEPT_EULA=Y \
        --env "MSSQL_SA_PASSWORD=$MSSQL_SA_PASSWORD" \
        mcr.microsoft.com/mssql/server:2022-latest >/dev/null
fi

sqlcmd=(/opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -b)
ready=false
for ((attempt = 1; attempt <= 60; attempt++)); do
    if docker exec "$container_name" "${sqlcmd[@]}" -Q "SELECT 1" >/dev/null 2>&1; then
        ready=true
        break
    fi
    sleep 2
done

if [[ "$ready" != true ]]; then
    echo "SQL Server did not become ready in container '$container_name'." >&2
    exit 1
fi

docker exec "$container_name" "${sqlcmd[@]}" -d master \
    -Q "IF DB_ID(N'$database_name') IS NULL CREATE DATABASE [$database_name];"

export MSSQL_PORT="$port"
export MSSQL_DATABASE_NAME="$database_name"
dotnet ef migrations script --idempotent --output "$sql_script" --project "$project_dir"
sed -i '1s/^\xEF\xBB\xBF//' "$sql_script"
docker exec -i "$container_name" "${sqlcmd[@]}" -d "$database_name" < "$sql_script"

echo "Deployed Entity Framework idempotent migration script to database '$database_name'."
