#!/usr/bin/env bash
# PURPOSE   Step 4 of the developer workflow: write the Flyway migration scripts (Flyway/migrations) for
#           whatever changed in the schema model since the last migration. Runs `flyway diff generate`:
#           Flyway rebuilds the SHADOW database from the existing migrations, compares it with the schema
#           model, and writes the difference as the next versioned migration (V...) plus an undo script (U...).
#
# USAGE     ./Scripts/GenerateFlywayMigrations.sh "<description>" [--no-undo]
#             e.g. ./Scripts/GenerateFlywayMigrations.sh "Add product price"
#           The description becomes part of the file name: V002_<timestamp>__Add_product_price.sql
#
# RUN FIRST ./Scripts/UpdateFlywaySchemaModel.sh. Migrations are generated from the schema MODEL, so a stale
#           model gives incomplete migrations. ./Scripts/CheckSync.sh will catch it if you forget.
# NEEDS     Docker, MSSQL_SA_PASSWORD, REDGATE_EMAIL + REDGATE_TOKEN (Flyway Enterprise).
# CHANGES   New files under Flyway/migrations/. Existing migrations are never rewritten. Review with
#           `git status Flyway/migrations`, and commit them together with the EF migration and schema model.
# EXIT      0 done (including "nothing to generate").  2 couldn't run.
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$script_dir/lib/common.sh"

description=""
types="versioned,undo"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-undo) types="versioned" ;;
        -h|--help) sed -n '2,/^set -/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
        -*) _fail "Unknown option: $1" "Try --help." ;;
        *) description="$1" ;;
    esac
    shift
done
if [[ -z "$description" ]]; then
    _fail "A description is required." "Usage: ./Scripts/GenerateFlywayMigrations.sh \"Add product price\""
fi
description="${description// /_}"      # file names look better, and are safer, without spaces

require_docker
require_sql_password
require_flyway_auth

ensure_sql_container                    # the shadow database lives in this container
ensure_flyway_image

marker="$(mktemp)"
trap 'rm -f "$marker"' EXIT
sleep 1; touch "$marker"; sleep 1       # whole seconds, so files written by Flyway are clearly newer

_info "Generating Flyway migrations from the schema model (types: $types)"
run_flyway diff generate \
    -diff.source=schemaModel \
    -diff.target=migrations \
    -diff.buildEnvironment=shadow \
    -diff.rebuild=true \
    -generate.types="$types" \
    -generate.description="$description"

new_files="$(find "$REPO_DIR/$FLYWAY_PROJECT_DIR/migrations" -type f -newer "$marker" 2>/dev/null | sort || true)"
if [[ -z "$new_files" ]]; then
    _info "Nothing to generate: the migrations already match the schema model."
else
    _info "New migration files:"
    sed "s#^$REPO_DIR/#  #" <<<"$new_files"
fi
