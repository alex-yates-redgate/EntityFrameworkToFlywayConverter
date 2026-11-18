#!/usr/bin/env bash
# PURPOSE   Step 3 of the developer workflow: update the Flyway schema model (Flyway/schema-model) so it
#           matches the development database, i.e. the database the EF project was just deployed to.
#           Runs `flyway diff model`. Flyway runs in a container; nothing to install but Docker.
#
# WORKFLOW  1. change the EF model and run `dotnet ef migrations add <Name>`
#           2. ./Scripts/DockerDeployFromEntityFrameworkIdempotentScript.sh     (creates/updates the dev database)
#           3. ./Scripts/UpdateFlywaySchemaModel.sh                              <- this script
#           4. ./Scripts/GenerateFlywayMigrations.sh "<description>"             (writes the Flyway migration)
#           5. ./Scripts/CheckSync.sh                                            (verify everything agrees)
#
# USAGE     ./Scripts/UpdateFlywaySchemaModel.sh
# NEEDS     Docker, MSSQL_SA_PASSWORD, REDGATE_EMAIL + REDGATE_TOKEN (Flyway Enterprise), and the EF project
#           already deployed on this git branch.
# CHANGES   Files under Flyway/schema-model/. Review with `git diff Flyway/schema-model`.
# EXIT      0 done.  2 couldn't run.
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$script_dir/lib/common.sh"

require_docker
require_sql_password
require_flyway_auth

dev_db="$(resolve_flyway_database_name)"
validate_database_name "$dev_db"

ensure_sql_container
if ! database_exists "$dev_db"; then
    _fail "The development database '$dev_db' doesn't exist yet." \
        "Deploy the EF project to it first: ./Scripts/DockerDeployFromEntityFrameworkIdempotentScript.sh"
fi
ensure_flyway_image

_info "Updating the Flyway schema model from database '$dev_db'"
run_flyway diff model -diff.source=development -diff.target=schemaModel
_info "Done. Review the change with: git diff Flyway/schema-model"
