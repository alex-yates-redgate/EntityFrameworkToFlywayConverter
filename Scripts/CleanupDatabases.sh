#!/usr/bin/env bash
# PURPOSE   Drop the disposable per-branch databases from the SQL Server container. The container itself is
#           left running. Every database can be rebuilt at any time (EF deploy script, Flyway scripts), so
#           dropping them is safe.
#
# USAGE     ./Scripts/CleanupDatabases.sh [--merged | --all | --branch <name>] [--yes]
#             --merged         (default) databases whose git branch no longer exists locally
#             --all            every database created by these scripts
#             --branch <name>  the databases for one specific branch
#             --yes            actually drop them. Without it this is a DRY RUN that only lists them.
#
# SAFETY    Only databases named <base> or <base>_* are ever considered (base defaults to EntityFrameworkDemo),
#           so master, msdb and anything else on the server is never touched. A branch's databases are
#           <base>_<branch> and <base>_<branch>_shadow (see lib/common.sh, database naming).
# NEEDS     Docker, MSSQL_SA_PASSWORD.
# EXIT      0 done (or nothing to do).  2 couldn't run.
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
        *) _fail "Unknown option: $1" "Try --help." ;;
    esac
    shift
done

require_docker
require_sql_password

if [[ "$("$DOCKER" container inspect -f '{{.State.Running}}' "$SQL_CONTAINER" 2>/dev/null || true)" != "true" ]]; then
    echo "Container '$SQL_CONTAINER' isn't running, so there are no databases to clean up."
    exit 0
fi

# Every database created by these scripts: <base> or <base>_<something>.
mapfile -t all_dbs < <(sqlcmd_exec master -h -1 -W \
    -Q "SET NOCOUNT ON; SELECT name FROM sys.databases WHERE name = N'$DB_BASE_NAME' OR name LIKE N'${DB_BASE_NAME}[_]%' ORDER BY name;" \
    | tr -d '\r' | grep -v '^$' || true)

# Sanitised, lower-cased names of branches that still exist locally (database names are compared case-insensitively).
existing_branches=()
if git -C "$script_dir" rev-parse --git-dir >/dev/null 2>&1; then
    while IFS= read -r branch; do
        sanitized="$(sanitize_branch_name "$branch")"
        existing_branches+=("${sanitized,,}")
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
            [[ "$db_lc" == "$want_lc" || "$db_lc" == "${want_lc}_shadow" ]] && targets+=("$db")
            ;;
        merged)
            [[ "$db" == "$DB_BASE_NAME" ]] && continue      # the un-suffixed database: only --all drops it
            suffix="${db#"${DB_BASE_NAME}_"}"
            suffix="${suffix,,}"
            suffix="${suffix%_shadow}"                      # a shadow database follows its branch
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
    echo "Dry run. These databases would be dropped from '$SQL_CONTAINER' (mode: $mode):"
    printf '  %s\n' "${targets[@]}"
    echo "Re-run with --yes to drop them."
    exit 0
fi

for db in "${targets[@]}"; do
    sqlcmd_exec master -Q "ALTER DATABASE [$db] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$db];"
    echo "Dropped $db"
done
