#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$script_dir/lib/common.sh"

require_docker
require_dotnet_ef

if [[ -z "${MSSQL_SA_PASSWORD:-}" ]]; then
    echo "Set MSSQL_SA_PASSWORD to a strong SQL Server SA password before running this script." >&2
    exit 1
fi

database_name="$(resolve_database_name)"
if [[ ! "$database_name" =~ ^[A-Za-z0-9_]+$ ]]; then
    echo "Database name '$database_name' may contain only letters, numbers, and underscores." >&2
    exit 1
fi

# Leave room for the _flyway / _shadow suffixes Flyway adds to the same name.
if (( ${#database_name} + 7 > DB_NAME_MAX_LENGTH )); then
    echo "Database name '$database_name' is too long (SQL Server's limit is $DB_NAME_MAX_LENGTH characters, and Flyway adds a suffix)." >&2
    echo "Use a shorter branch name, or set MSSQL_DATABASE_NAME." >&2
    exit 1
fi

repo_dir="$(cd -- "$script_dir/.." && pwd)"
project_dir="$repo_dir/EntityFramework"
container_name="${MSSQL_CONTAINER_NAME:-$DEFAULT_CONTAINER_NAME}"
port="${MSSQL_PORT:-1433}"
sql_script="$(mktemp)"
trap 'rm -f "$sql_script"' EXIT

if "$DOCKER" container inspect "$container_name" >/dev/null 2>&1; then
    "$DOCKER" start "$container_name" >/dev/null
else
    "$DOCKER" run --detach \
        --name "$container_name" \
        --publish "$port:1433" \
        --env ACCEPT_EULA=Y \
        --env "MSSQL_SA_PASSWORD=$MSSQL_SA_PASSWORD" \
        mcr.microsoft.com/mssql/server:2022-latest >/dev/null
fi

sqlcmd=(/opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -b)
ready=false
for ((attempt = 1; attempt <= 60; attempt++)); do
    if "$DOCKER" exec "$container_name" "${sqlcmd[@]}" -Q "SELECT 1" >/dev/null 2>&1; then
        ready=true
        break
    fi
    sleep 2
done

if [[ "$ready" != true ]]; then
    echo "SQL Server did not become ready in container '$container_name'." >&2
    exit 1
fi

"$DOCKER" exec "$container_name" "${sqlcmd[@]}" -d master \
    -Q "IF DB_ID(N'$database_name') IS NULL CREATE DATABASE [$database_name];"

export MSSQL_PORT="$port"
export MSSQL_DATABASE_NAME="$database_name"
dotnet ef migrations script --idempotent --output "$sql_script" --project "$project_dir"
sed -i '1s/^\xEF\xBB\xBF//' "$sql_script"
"$DOCKER" exec -i "$container_name" "${sqlcmd[@]}" -d "$database_name" < "$sql_script"

echo "Deployed Entity Framework idempotent migration script to database '$database_name'."
