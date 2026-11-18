#!/usr/bin/env bash
# PURPOSE   Verify that every layer of the project agrees with the next. Run it by hand, from a git hook,
#           or in CI: it is non-interactive and reports through its exit code.
#
#           EF project ──1──▶ EF target (dev database) ──2──▶ Flyway schema model ──3──▶ Flyway migrations
#                                         ▲                                                    │
#                                         └─────────────────────────4 (end to end)─────────────┘
#
#           ef          1  Is the EF model fully captured in EF migrations, and are they all applied to the
#                          dev database?                          (dotnet ef; fix: migrations add / deploy)
#           model       2  Does the Flyway schema model match the dev database?
#                                                                (flyway diff; fix: UpdateFlywaySchemaModel.sh)
#           migrations  3  Do the Flyway migrations produce the schema model? (shadow database is rebuilt)
#                                                                (flyway diff; fix: GenerateFlywayMigrations.sh)
#           end-to-end  4  Do the Flyway migrations produce the same schema as the EF-deployed dev database?
#                          The ultimate test: it catches anything checks 1-3 miss, such as a filter hiding a
#                          difference.                            (flyway diff)
#
# USAGE     ./Scripts/CheckSync.sh [--check ef|model|migrations|end-to-end]... [--output text|json] [--list]
#             no --check        run all four checks
#             --check NAME      run only that check; repeat the option to run several
#             --output text     (default) human-readable progress and summary
#             --output json     unattended mode: stdout is ONE JSON document and nothing else (progress goes to
#                               stderr). The exit code is still the pass/fail signal. Shape:
#                                 { "inSync": false, "exitCode": 1, "database": "...",
#                                   "checks": [ { "name": "model", "status": "out-of-sync",
#                                                 "differences": [ { "type": "Edit", "objectType": "Table",
#                                                                    "name": "dbo.Orders" } ],
#                                                 "message": "...", "fix": "..." } ] }
#                               status is "in-sync", "out-of-sync" or "error". "differences" is only filled for
#                               the Flyway checks; "message" carries the detail for the EF check and for errors.
#             --list            print the checks and exit
#
# NEEDS     Docker, MSSQL_SA_PASSWORD, REDGATE_EMAIL + REDGATE_TOKEN (checks 2-4), and for check 1 the .NET 8
#           SDK + dotnet-ef. The EF project must already be deployed to this branch's dev database.
# EXIT      0 everything checked is in sync
#           1 at least one check found a difference (the output says how to fix it)
#           2 a check could not run (missing prerequisite, SQL/Docker error). Takes priority over 1.
#
# NOTE      `flyway diff` exits 0 whether or not it finds differences, so the Flyway checks run it with
#           `-outputType=json` and count the entries in its "differences" array.
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$script_dir/lib/common.sh"

ALL_CHECKS=(ef model migrations end-to-end)
selected=()
output_format=text
while [[ $# -gt 0 ]]; do
    case "$1" in
        --check)
            [[ -n "${2:-}" ]] || _fail "--check needs a name." "One of: ${ALL_CHECKS[*]}"
            selected+=("$2"); shift ;;
        --output)
            [[ "${2:-}" == text || "${2:-}" == json ]] || _fail "--output must be 'text' or 'json'."
            output_format="$2"; shift ;;
        --list) sed -n '/^#           ef /,/^#                          difference/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -h|--help) sed -n '2,/^set -/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
        *) _fail "Unknown option: $1" "Try --help." ;;
    esac
    shift
done
[[ ${#selected[@]} -gt 0 ]] || selected=("${ALL_CHECKS[@]}")
for name in "${selected[@]}"; do
    [[ " ${ALL_CHECKS[*]} " == *" $name "* ]] || _fail "Unknown check '$name'." "One of: ${ALL_CHECKS[*]}"
done

# fd 3 is the real stdout. In json mode everything else (progress, docker output) is sent to stderr,
# so that stdout carries the JSON document and nothing else.
exec 3>&1
if [[ "$output_format" == json ]]; then exec 1>&2; fi

needs_flyway=false; needs_ef=false
for name in "${selected[@]}"; do
    [[ "$name" == "ef" ]] && needs_ef=true || needs_flyway=true
done

require_docker
require_sql_password
if [[ "$needs_ef" == true ]]; then require_dotnet_ef; fi
if [[ "$needs_flyway" == true ]]; then require_flyway_auth; fi

dev_db="$(resolve_flyway_database_name)"
validate_database_name "$dev_db"

ensure_sql_container
if [[ "$needs_flyway" == true ]]; then ensure_flyway_image; fi
if ! database_exists "$dev_db"; then
    _fail "The development database '$dev_db' doesn't exist yet." \
        "Deploy the EF project to it first: ./Scripts/DockerDeployFromEntityFrameworkIdempotentScript.sh"
fi

# ---- helpers -----------------------------------------------------------------------------------------
# Each check function returns 0 (in sync), 1 (differences) or 2 (couldn't run), and sets three globals
# (they are reset before every check): `detail` (free text), `fix` (what to run), and `diffs` (one
# "<type>|<objectType>|<name>" line per difference found by Flyway).
detail=""; fix=""; diffs=""

# Reads the JSON that `flyway diff -outputType=json` prints and writes one "<type>|<objectType>|<name>" line
# per entry of its "differences" array. (Plain awk, so there is no jq dependency.)
summarise_differences() {
    awk '
        function value(line) { sub(/^[^:]*: *"/, "", line); sub(/".*$/, "", line); return line }
        function flush(   n) {
            if (kind == "") return
            n = (nm["to"] != "") ? (sc["to"] != "" ? sc["to"] "." nm["to"] : nm["to"]) \
                                 : (sc["from"] != "" ? sc["from"] "." nm["from"] : nm["from"])
            print kind "|" obj "|" n
            kind = ""; obj = ""; delete nm; delete sc; side = ""
        }
        /"differenceType"/ { flush(); kind = value($0) }
        /"objectType"/     { obj = value($0) }
        /"from" :/         { side = ($0 ~ /null/) ? "" : "from" }
        /"to" :/           { side = ($0 ~ /null/) ? "" : "to" }
        /"schema" :/       { if (side != "") sc[side] = value($0) }
        /"name" :/         { if (side != "") nm[side] = value($0) }
        END                { flush() }
    '
}

# Runs a `flyway diff` (arguments = everything after `flyway`) and classifies the result.
diff_in_sync() {
    local output rc=0 errfile
    errfile="$(mktemp)"
    output="$(run_flyway "$@" -outputType=json 2>"$errfile")" || rc=$?
    if (( rc != 0 )) || ! grep -q '"differences"' <<<"$output"; then
        detail="$(cat "$errfile")"$'\n'"$output"      # unrecognised or failed: show everything
        rm -f "$errfile"
        return 2
    fi
    rm -f "$errfile"
    diffs="$(summarise_differences <<<"$output")"
    [[ -z "$diffs" ]]                                   # 0 if no differences, 1 otherwise
}

check_ef() {
    local output rc=0
    export MSSQL_PORT="$SQL_PORT" MSSQL_DATABASE_NAME="$dev_db"   # read by EntityFramework/Data/AppDbContextFactory.cs
    output="$(dotnet ef migrations has-pending-model-changes --project "$REPO_DIR/EntityFramework" 2>&1)" || rc=$?
    if grep -q "No changes have been made" <<<"$output"; then
        :
    elif grep -q "Changes have been made" <<<"$output"; then
        detail="The EF model has changes that no EF migration captures."
        fix="dotnet ef migrations add <Name> --project EntityFramework"
        return 1
    else
        detail="$output"; return 2
    fi

    rc=0
    output="$(dotnet ef migrations list --project "$REPO_DIR/EntityFramework" --no-build 2>&1)" || rc=$?
    if (( rc != 0 )); then detail="$output"; return 2; fi
    if grep -q "(Pending)" <<<"$output"; then
        detail="EF migrations not yet applied to '$dev_db': $(grep '(Pending)' <<<"$output" | tr -s ' \n' ' ')"
        fix="./Scripts/DockerDeployFromEntityFrameworkIdempotentScript.sh"
        return 1
    fi
}

check_model() {
    local rc=0
    diff_in_sync diff -source=development -target=schemaModel || rc=$?
    fix="./Scripts/UpdateFlywaySchemaModel.sh"
    return "$rc"
}

check_migrations() {
    local rc=0
    diff_in_sync diff -source=schemaModel -target=migrations -buildEnvironment=shadow -rebuild=true || rc=$?
    fix="./Scripts/GenerateFlywayMigrations.sh \"<description>\""
    return "$rc"
}

check_end_to_end() {
    local rc=0
    diff_in_sync diff -source=migrations -target=development -buildEnvironment=shadow -rebuild=true || rc=$?
    (( rc == 1 )) && detail="The Flyway migrations don't produce the schema that the EF migrations produce."
    fix="bring the earlier checks into sync first; if they all pass, see AGENTS.md ('Troubleshooting')."
    return "$rc"
}

json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\n'/\\n}"; s="${s//$'\r'/}"; s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

# ---- run ---------------------------------------------------------------------------------------------
declare -A label=(
    [ef]="1 ef          EF project  <> EF target (dev database)"
    [model]="2 model       EF target   <> Flyway schema model"
    [migrations]="3 migrations  Schema model <> Flyway migrations"
    [end-to-end]="4 end-to-end  Flyway migrations <> EF target"
)
worst=0
declare -A result r_detail r_fix r_diffs
for name in "${selected[@]}"; do
    _info "Check ${label[$name]}"
    detail=""; fix=""; diffs=""
    rc=0
    "check_${name//-/_}" || rc=$?
    result[$name]=$rc
    # only keep a fix / detail that applies to the outcome
    (( rc == 0 )) && { detail=""; fix=""; }
    (( rc == 2 )) && fix=""
    r_detail[$name]="$detail"; r_fix[$name]="$fix"; r_diffs[$name]="$diffs"
    case $rc in
        0) echo "    in sync" ;;
        1) echo "    OUT OF SYNC" ;;
        *) echo "    COULD NOT RUN" ;;
    esac
    if (( rc != 0 )); then
        while IFS='|' read -r t o n; do [[ -n "$t" ]] && echo "      $t $o $n"; done <<<"$diffs"
        [[ -n "$detail" ]] && sed 's/^/      /' <<<"$detail"
        [[ -n "$fix" ]] && echo "    Fix: $fix"
    fi
    # exit-code priority: 2 (couldn't run) beats 1 (differences) beats 0
    if (( rc == 2 )) || { (( rc == 1 )) && (( worst == 0 )); }; then worst=$rc; fi
done

echo
echo "Summary (dev database: $dev_db)"
for name in "${selected[@]}"; do
    case ${result[$name]} in 0) s="in sync" ;; 1) s="OUT OF SYNC" ;; *) s="could not run" ;; esac
    printf '  %-12s %s\n' "$name" "$s"
done

if [[ "$output_format" == json ]]; then
    {
        printf '{\n  "inSync": %s,\n  "exitCode": %s,\n  "database": "%s",\n  "checks": [' \
            "$([[ $worst == 0 ]] && echo true || echo false)" "$worst" "$(json_escape "$dev_db")"
        first=true
        for name in "${selected[@]}"; do
            [[ $first == true ]] && first=false || printf ','
            case ${result[$name]} in 0) s="in-sync" ;; 1) s="out-of-sync" ;; *) s="error" ;; esac
            printf '\n    {\n      "name": "%s",\n      "status": "%s",\n      "differences": [' "$name" "$s"
            dfirst=true
            while IFS='|' read -r t o n; do
                [[ -n "$t" ]] || continue
                [[ $dfirst == true ]] && dfirst=false || printf ','
                printf '\n        { "type": "%s", "objectType": "%s", "name": "%s" }' \
                    "$(json_escape "$t")" "$(json_escape "$o")" "$(json_escape "$n")"
            done <<<"${r_diffs[$name]}"
            printf ']'
            [[ -n "${r_detail[$name]}" ]] && printf ',\n      "message": "%s"' "$(json_escape "${r_detail[$name]}")"
            [[ -n "${r_fix[$name]}" ]] && printf ',\n      "fix": "%s"' "$(json_escape "${r_fix[$name]}")"
            printf '\n    }'
        done
        printf '\n  ]\n}\n'
    } >&3
fi
exit "$worst"
