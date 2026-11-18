#!/usr/bin/env bash
# PURPOSE   Run Flyway's own checks on the migrations. For now: `flyway check -code`, a code review (linting) of
#           the SQL in Flyway/migrations. It reads the migration files only: no database is needed, so it is
#           fast enough for a git hook, and works on a branch whose databases don't exist yet.
#
# USAGE     ./Scripts/CheckFlyway.sh [--fail-on-error]
#             (default)         report violations, exit 0. Use this while you decide your code-review policy.
#             --fail-on-error   exit 1 if any violation has severity Error. Use this in CI or a hook.
#
# NEEDS     Docker, MSSQL_SA_PASSWORD (the container is shared with the other scripts), REDGATE_EMAIL + REDGATE_TOKEN.
# OUTPUT    A summary on screen, plus Flyway/report.html and Flyway/report-code-review.sarif (git-ignored).
# EXIT      0 no violations (or violations tolerated, without --fail-on-error).  1 Error violations with
#           --fail-on-error.  2 couldn't run.
#
# RULES     All of Flyway's default code-review rules are applied, with the T-SQL dialect. Refine the rule set
#           later. Expect some to fire on undo scripts: RG01 ("Usage of DROP TABLE is discouraged") fires on the
#           undo of an initial creation, which has to drop the tables. Decide your policy before enabling
#           --fail-on-error: exclude undo scripts, change a rule's severity, or accept those drops.
#
# LATER     `check -changes`, `check -drift` and `check -dryrun` compare against a real target environment
#           (test, production...). They belong to the Ops pipelines, not to the developer scripts.
#
# DIALECT   -rulesDialect=TSQL is set explicitly because there is no database URL to detect it from. Without it
#           Flyway falls back to generic ANSI SQL, which parses T-SQL wrongly and MISSES violations.
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$script_dir/lib/common.sh"

fail_on_error=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --fail-on-error) fail_on_error=true ;;
        -h|--help) sed -n '2,/^set -/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
        *) _fail "Unknown option: $1" "Try --help." ;;
    esac
    shift
done

require_docker
require_sql_password
require_flyway_auth
ensure_sql_container
ensure_flyway_image

_info "Reviewing the Flyway migrations (flyway check -code, T-SQL dialect)"
rc=0
run_flyway check -code -rulesDialect=TSQL -check.code.failOnError="$fail_on_error" || rc=$?
if (( rc == 0 )); then
    _info "Code review finished: no failing violations."
else
    echo "Code review failed (exit code $rc)." >&2
fi
exit "$rc"
