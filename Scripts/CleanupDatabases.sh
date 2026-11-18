#!/usr/bin/env bash
# Drops the disposable per-branch databases from the SQL Server container. The container itself is
# left running; every database can be rebuilt from the migrations at any time.
#
# Usage: ./Scripts/CleanupDatabases.sh [--merged | --all | --branch <name>] [--yes]
#
#   --merged         (default) databases whose git branch no longer exists locally
#   --all            every database created by these scripts
#   --branch <name>  the database for one specific branch
#   --yes            actually drop them. Without it this is a dry run that only lists them.
#
# Only databases named <base> or <base>_* are ever considered (base defaults to EntityFrameworkDemo),
# so master, msdb, and anything else on the server is never touched.
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$script_dir/lib/common.sh"

mode="merged"
branch_arg=""
confirmed=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --merged) mode="merged" ;;
        --all) mode="all" ;;
        --branch) mode="branch"; branch_arg="${2:?--branch needs a branch name}"; shift ;;
        --yes|-y) confirmed=true ;;
        -h|--help) sed -n '2,/^set -/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option: $1 (try --help)" >&2; exit 1 ;;
    esac
    shift
done

require_docker

if [[ -z "${MSSQL_SA_PASSWORD:-}" ]]; then
    echo "Set MSSQL_SA_PASSWORD to the SQL Server SA password before running this script." >&2
    exit 1
fi

container_name="${MSSQL_CONTAINER_NAME:-$DEFAULT_CONTAINER_NAME}"
if [[ "$("$DOCKER" container inspect -f '{{.State.Running}}' "$container_name" 2>/dev/null || true)" != "true" ]]; then
    echo "Container '$container_name' isn't running, so there are no databases to clean up."
    exit 0
fi

sqlcmd=(/opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -b)

# Every database created by these scripts: <base> or <base>_<something>.
mapfile -t all_dbs < <("$DOCKER" exec "$container_name" "${sqlcmd[@]}" -d master -h -1 -W \
    -Q "SET NOCOUNT ON; SELECT name FROM sys.databases WHERE name = N'$DB_BASE_NAME' OR name LIKE N'${DB_BASE_NAME}[_]%' ORDER BY name;" \
    | tr -d '\r' | grep -v '^$' || true)

# Sanitised names of branches that still exist locally.
existing_branches=()
if git -C "$script_dir" rev-parse --git-dir >/dev/null 2>&1; then
    while IFS= read -r branch; do
        sanitized="$(sanitize_branch_name "$branch")"
        existing_branches+=("${sanitized,,}")   # lower-cased: database names are compared case-insensitively
    done < <(git -C "$script_dir" for-each-ref --format='%(refname:short)' refs/heads)
fi

targets=()
for db in "${all_dbs[@]}"; do
    [[ "$db" =~ ^[A-Za-z0-9_]+$ ]] || continue   # never interpolate odd names into SQL
    case "$mode" in
        all)
            targets+=("$db")
            ;;
        branch)
            want="${DB_BASE_NAME}_$(sanitize_branch_name "$branch_arg")"
            db_lc="${db,,}"; want_lc="${want,,}"
            [[ "$db_lc" == "$want_lc" || "$db_lc" == "${want_lc}_flyway" || "$db_lc" == "${want_lc}_shadow" ]] && targets+=("$db")
            ;;
        merged)
            [[ "$db" == "$DB_BASE_NAME" ]] && continue              # un-suffixed legacy DB: only --all drops it
            suffix="${db#"${DB_BASE_NAME}_"}"
            suffix="${suffix,,}"
            suffix="${suffix%_flyway}"                              # the Flyway development and shadow databases
            suffix="${suffix%_shadow}"                              # follow their branch
            keep=false
            for b in "${existing_branches[@]}"; do
                [[ "$b" == "$suffix" ]] && keep=true && break
            done
            [[ "$keep" == true ]] || targets+=("$db")
            ;;
    esac
done

if [[ ${#targets[@]} -eq 0 ]]; then
    echo "Nothing to clean up (mode: $mode)."
    exit 0
fi

if [[ "$confirmed" != true ]]; then
    echo "Dry run. These databases would be dropped from '$container_name' (mode: $mode):"
    printf '  %s\n' "${targets[@]}"
    echo "Re-run with --yes to drop them."
    exit 0
fi

for db in "${targets[@]}"; do
    "$DOCKER" exec "$container_name" "${sqlcmd[@]}" -d master \
        -Q "ALTER DATABASE [$db] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$db];"
    echo "Dropped $db"
done
