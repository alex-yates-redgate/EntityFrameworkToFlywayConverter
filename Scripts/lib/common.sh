#!/usr/bin/env bash
# Shared helpers for every script in Scripts/. Source this file; don't execute it.
#
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
#
# CONTENTS (in order)
#   1. Configuration       Every setting is an environment variable with a default. Override, don't edit.
#   2. Database naming     ONE rule shared with Flyway (Flyway/flyway.toml). See AGENTS.md before changing it.
#   3. Preflight checks    require_docker, require_dotnet_ef, require_sql_password, require_flyway_auth.
#                          Each fails with a message saying exactly what to do next.
#   4. SQL Server          ensure_sql_container, sqlcmd_exec, database_exists, ensure_database.
#   5. Flyway              ensure_flyway_image, run_flyway.
#
# DESIGN RULES
#   - Only the plain `docker` CLI is used, so any Docker-compatible engine works (Docker Engine, Docker
#     Desktop, Rancher Desktop, Podman with a docker alias...). Set DOCKER to use another CLI name.
#   - Secrets (SQL password, Redgate token) are never put on a command line: they are passed to
#     containers by variable NAME (`-e NAME`) or through a temporary file that is deleted on exit.
#   - Scripts are non-interactive: configuration comes from environment variables, results from exit codes,
#     so they behave the same when run by a developer, a git hook or a CI pipeline.

# ------------------------------------------------------------------------------------------------
# 1. Configuration
# ------------------------------------------------------------------------------------------------
_lib_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
_scripts_dir="$(dirname "$_lib_dir")"
REPO_DIR="$(dirname "$_scripts_dir")"

DOCKER="${DOCKER:-docker}"
export PATH="$PATH:$HOME/.dotnet/tools"

DEFAULT_CONTAINER_NAME="entityframework-flyway-sample"
SQL_CONTAINER="${MSSQL_CONTAINER_NAME:-$DEFAULT_CONTAINER_NAME}"
SQL_PORT="${MSSQL_PORT:-1433}"
# Override MSSQL_IMAGE to pull SQL Server from an internal registry or mirror.
MSSQL_IMAGE="${MSSQL_IMAGE:-mcr.microsoft.com/mssql/server:2022-latest}"

# The Flyway version is pinned HERE, in one place. It must be the commercial redgate/flyway image
# (NOT flyway/flyway, which is the free Community edition and lacks diff/model/generate).
# Override FLYWAY_BASE_IMAGE to use an internal mirror of it.
FLYWAY_BASE_IMAGE="${FLYWAY_BASE_IMAGE:-redgate/flyway:13.12.2}"
_flyway_tag="${FLYWAY_BASE_IMAGE##*/}"; _flyway_tag="${_flyway_tag#*:}"
# Locally built image = FLYWAY_BASE_IMAGE + git. See Scripts/docker/flyway/Dockerfile for why.
FLYWAY_IMAGE="${FLYWAY_IMAGE:-efflyway/flyway-git:${_flyway_tag}}"
FLYWAY_PROJECT_DIR="Flyway"      # folder (relative to the repo root) that contains flyway.toml

# ------------------------------------------------------------------------------------------------
# 2. Database naming  (shared with Flyway: see Flyway/flyway.toml, and AGENTS.md)
# ------------------------------------------------------------------------------------------------
#   <base>_<branch>          EF deployment target AND Flyway "development" database (the same database)
#   <base>_<branch>_shadow   Flyway "shadow" database: a scratch database Flyway rebuilds from the migrations
# <branch> is the git branch name with everything except ASCII letters and digits removed. That is exactly
# what Flyway's ${git.branch:ad} resolver filter does, so Flyway and these scripts always agree on the name
# for a branch. Case is preserved, as Flyway does; SQL Server database names are normally case-insensitive,
# so comparisons elsewhere ignore case.
DB_BASE_NAME="${MSSQL_DATABASE_BASE:-EntityFrameworkDemo}"
DB_NAME_MAX_LENGTH=128
DB_SUFFIX_RESERVE=7              # room for the "_shadow" suffix

# Turns a git branch name into the <branch> part of a database name, e.g. feature/add-widgets -> featureaddwidgets.
sanitize_branch_name() {
    LC_ALL=C sed -E 's/[^A-Za-z0-9]+//g' <<<"$1"
}

# Prints the development database name. An explicit MSSQL_DATABASE_NAME always wins; otherwise it's
# <base>_<sanitised current branch>, or just <base> when not on a branch (detached HEAD, no git).
resolve_database_name() {
    if [[ -n "${MSSQL_DATABASE_NAME:-}" ]]; then
        echo "$MSSQL_DATABASE_NAME"
        return
    fi
    local branch
    branch="$(git -C "$_scripts_dir" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
    if [[ -z "$branch" || "$branch" == "HEAD" ]]; then
        echo "$DB_BASE_NAME"
    else
        echo "${DB_BASE_NAME}_$(sanitize_branch_name "$branch")"
    fi
}

# Prints the development database name for the FLYWAY scripts. Flyway always derives the name from the git
# branch (Flyway/flyway.toml), so an MSSQL_DATABASE_NAME override can't be honoured there: refuse it loudly
# rather than silently working on a different database from the one Flyway uses.
resolve_flyway_database_name() {
    local branch_name override="${MSSQL_DATABASE_NAME:-}"
    branch_name="$(MSSQL_DATABASE_NAME='' resolve_database_name)"
    if [[ -n "$override" && "$override" != "$branch_name" ]]; then
        _fail "MSSQL_DATABASE_NAME='$override' can't be used with the Flyway scripts." \
            "Flyway always uses the branch-derived name ('$branch_name', from the git resolver in Flyway/flyway.toml)." \
            "Unset MSSQL_DATABASE_NAME, or deploy and run everything on the same git branch."
    fi
    echo "$branch_name"
}

# Fails unless $1 is a safe database name (it is interpolated into SQL) with room for Flyway's suffix.
validate_database_name() {
    local name="$1"
    if [[ ! "$name" =~ ^[A-Za-z0-9_]+$ ]]; then
        _fail "Database name '$name' is not valid." "It may contain only letters, numbers and underscores."
    fi
    if (( ${#name} + DB_SUFFIX_RESERVE > DB_NAME_MAX_LENGTH )); then
        _fail "Database name '$name' is too long." \
            "SQL Server's limit is $DB_NAME_MAX_LENGTH characters and Flyway adds a suffix." \
            "Use a shorter branch name, or set MSSQL_DATABASE_NAME."
    fi
}

# ------------------------------------------------------------------------------------------------
# 3. Preflight checks
# ------------------------------------------------------------------------------------------------
_fail() {
    {
        echo
        echo "ERROR: $1"
        shift
        for line in "$@"; do echo "  $line"; done
        echo
    } >&2
    exit 2
}

_info() { echo "==> $*"; }

# Fails (with guidance) unless a container engine is installed, running and usable.
require_docker() {
    local setup_hint="To install Docker Engine inside WSL, run: $_scripts_dir/SetupDockerOverWSL.sh
Then open a new terminal (or run 'newgrp docker') and re-run this script.
If your organisation has its own standard Docker setup, any Docker-compatible engine will do."

    if ! command -v "$DOCKER" >/dev/null 2>&1; then
        _fail "'$DOCKER' was not found." "$setup_hint"
    fi

    local output
    if output="$("$DOCKER" info 2>&1)"; then
        return 0
    fi

    if grep -qi "permission denied" <<<"$output"; then
        _fail "'$DOCKER' is installed but your user isn't allowed to use it." \
            "Add yourself to the docker group, then open a new terminal:" \
            "  sudo usermod -aG docker \$USER" \
            "(or run 'newgrp docker' if you've just been added)."
    elif grep -qiE "could not be found in this WSL|WSL integration" <<<"$output"; then
        _fail "'$DOCKER' is a stub that isn't connected to an engine in this WSL distro." \
            "Either enable WSL integration for this distro in your Docker/Rancher Desktop settings," \
            "or install a native engine: $_scripts_dir/SetupDockerOverWSL.sh"
    elif grep -qiE "cannot connect|daemon running|connection refused|no such file" <<<"$output"; then
        _fail "'$DOCKER' is installed but the container engine isn't running." \
            "If you installed Docker Engine in WSL, start it with: sudo service docker start" \
            "(or start your Docker/Rancher Desktop app)." \
            "Not installed yet? $_scripts_dir/SetupDockerOverWSL.sh"
    else
        _fail "'$DOCKER info' failed:" "$output" "$setup_hint"
    fi
}

# Fails (with guidance) unless the .NET 8 SDK and the dotnet-ef tool are available.
require_dotnet_ef() {
    local setup_hint="To install them, run: $_scripts_dir/SetupDotnetPrerequisites.sh"

    if ! command -v dotnet >/dev/null 2>&1; then
        _fail "The .NET SDK ('dotnet') was not found." "$setup_hint"
    fi
    if ! dotnet --list-sdks 2>/dev/null | grep -q '^8\.'; then
        _fail "The .NET 8 SDK is not installed (found: $(dotnet --list-sdks 2>/dev/null | tr '\n' ' ')). This project targets net8.0." "$setup_hint"
    fi
    if ! dotnet ef --version >/dev/null 2>&1; then
        _fail "The 'dotnet-ef' tool was not found." "$setup_hint"
    fi
    # `dotnet ef` builds the project, which leaves a Roslyn compiler server running in the background. That
    # server inherits this script's stdout, so a pipe reading it (a CI log, `| tee`, `| grep`) never sees
    # end-of-file and hangs. Compile in-process instead (MSBuild reads this environment variable).
    export UseSharedCompilation=false
}

# Under WSL, if the named variable is not set, copies it from the Windows environment (user scope, then
# machine scope) so it only has to be set in one place. Needs no WSLENV. Does nothing outside WSL, or
# when powershell.exe is unreachable, so the same scripts behave identically on Linux and in CI.
# The value is read into a shell variable, never placed on a command line.
import_windows_env() {
    local name="$1" value scope
    [[ -z "${!name:-}" ]] || return 0
    [[ -n "${WSL_DISTRO_NAME:-}" ]] && command -v powershell.exe >/dev/null 2>&1 || return 0
    for scope in User Machine; do
        value="$(powershell.exe -NoProfile -NonInteractive -Command \
            "[Environment]::GetEnvironmentVariable('$name','$scope')" 2>/dev/null | tr -d '\r')" || value=""
        if [[ -n "$value" ]]; then
            printf -v "$name" '%s' "$value"
            export "${name?}"
            return 0
        fi
    done
}

# Fails unless the SQL Server SA password is set. It is exported so containers can receive it by name.
require_sql_password() {
    import_windows_env MSSQL_SA_PASSWORD
    if [[ -z "${MSSQL_SA_PASSWORD:-}" ]]; then
        _fail "MSSQL_SA_PASSWORD is not set." \
            "Set it to the SA password of the local SQL Server container (any strong password for a new one):" \
            "  export MSSQL_SA_PASSWORD='Use-A-Strong-Local-Password1!'"
    fi
    export MSSQL_SA_PASSWORD
}

# Fails unless Redgate credentials are available (the Flyway features we use need the Enterprise edition,
# which the container activates from a Redgate email + personal access token).
#
# CURRENT APPROACH: environment variables REDGATE_EMAIL and REDGATE_TOKEN (a personal access token).
# FUTURE: replace the body of this function to fetch them from a secrets manager (Azure Key Vault, etc.).
# Nothing else needs to change, as long as FLYWAY_EMAIL and FLYWAY_TOKEN end up exported.
require_flyway_auth() {
    import_windows_env REDGATE_EMAIL
    import_windows_env REDGATE_TOKEN
    FLYWAY_EMAIL="${FLYWAY_EMAIL:-${REDGATE_EMAIL:-}}"
    FLYWAY_TOKEN="${FLYWAY_TOKEN:-${REDGATE_TOKEN:-}}"
    if [[ -z "$FLYWAY_EMAIL" || -z "$FLYWAY_TOKEN" ]]; then
        _fail "Redgate credentials for Flyway Enterprise were not found." \
            "Set REDGATE_EMAIL (your Redgate account email) and REDGATE_TOKEN (a Redgate personal access token)." \
            "Set them as Windows environment variables (WSL scripts read them automatically)," \
            "or export them in your shell (e.g. ~/.bashrc), which is what Linux and CI use." \
            "See README.md, section 'Flyway credentials'."
    fi
    export FLYWAY_EMAIL FLYWAY_TOKEN
}

# ------------------------------------------------------------------------------------------------
# 4. SQL Server container
# ------------------------------------------------------------------------------------------------
# Starts (or creates) the SQL Server container and waits until it accepts connections.
# One container is shared by every branch; each branch gets its own databases inside it.
ensure_sql_container() {
    require_sql_password
    if "$DOCKER" container inspect "$SQL_CONTAINER" >/dev/null 2>&1; then
        "$DOCKER" start "$SQL_CONTAINER" >/dev/null
    else
        _info "Creating SQL Server container '$SQL_CONTAINER' from $MSSQL_IMAGE (first run pulls the image)"
        "$DOCKER" run --detach \
            --name "$SQL_CONTAINER" \
            --restart unless-stopped \
            --publish "$SQL_PORT:1433" \
            --env ACCEPT_EULA=Y \
            --env MSSQL_SA_PASSWORD \
            "$MSSQL_IMAGE" >/dev/null
    fi

    local attempt
    for ((attempt = 1; attempt <= 60; attempt++)); do
        if sqlcmd_exec master -Q "SELECT 1" >/dev/null 2>&1; then
            return 0
        fi
        sleep 2
    done
    _fail "SQL Server did not become ready in container '$SQL_CONTAINER'." \
        "Check the container's logs: $DOCKER logs $SQL_CONTAINER"
}

# Runs sqlcmd inside the SQL Server container.
#   sqlcmd_exec <database> [sqlcmd args...]       e.g. sqlcmd_exec master -Q "SELECT 1"
# SQL can also be piped in on stdin. The password is passed by variable name, not on the command line.
sqlcmd_exec() {
    local database="$1"; shift
    SQLCMDPASSWORD="$MSSQL_SA_PASSWORD" "$DOCKER" exec -i -e SQLCMDPASSWORD "$SQL_CONTAINER" \
        /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -C -b -d "$database" "$@"
}

# Succeeds if database $1 exists in the container.
database_exists() {
    local count
    count="$(sqlcmd_exec master -h -1 -W -Q "SET NOCOUNT ON; SELECT COUNT(*) FROM sys.databases WHERE name = N'$1'" | tr -d '[:space:]')"
    [[ "$count" == "1" ]]
}

ensure_database() {
    sqlcmd_exec master -Q "IF DB_ID(N'$1') IS NULL CREATE DATABASE [$1];"
}

# ------------------------------------------------------------------------------------------------
# 5. Flyway (runs in a container: nothing to install except Docker)
# ------------------------------------------------------------------------------------------------
# Builds the Flyway image (official redgate/flyway + git) the first time it is needed.
ensure_flyway_image() {
    if "$DOCKER" image inspect "$FLYWAY_IMAGE" >/dev/null 2>&1; then
        return 0
    fi
    _info "Building $FLYWAY_IMAGE from $FLYWAY_BASE_IMAGE (first run only; pulls ~750 MB)"
    "$DOCKER" build --quiet \
        --build-arg "BASE_IMAGE=$FLYWAY_BASE_IMAGE" \
        --tag "$FLYWAY_IMAGE" \
        "$_scripts_dir/docker/flyway" >/dev/null
}

# Runs a Flyway command in a container against the project in Flyway/.
#   run_flyway diff model -diff.source=development -diff.target=schemaModel
#   run_flyway check -code
# Arguments go straight to Flyway. Returns Flyway's exit code. Important details:
#   --network container:<sql>   shares the SQL Server container's network, so the 127.0.0.1:1433 in
#                               flyway.toml works unchanged inside this container. No Docker network needed.
#   -v <repo>:/repo             mounts the WHOLE repo (not just Flyway/) because the git resolver needs .git.
#   credentials overlay         a temporary file with only the SQL user/password is mounted OVER
#                               Flyway/flyway.user.toml, inside the container only. The developer's real
#                               flyway.user.toml holds Flyway Desktop secrets the container can't read, and this
#                               keeps the password off the command line. (If Flyway/flyway.user.toml doesn't
#                               exist yet the engine creates an empty one as the mount point; it is git-ignored.)
#   --user <you>                files Flyway writes (schema model, migrations) belong to you, not root.
#   Chained commands           use the PREFIXED options: `diff model -diff.source=...`, not `-source=...`.
run_flyway() {
    require_sql_password
    local creds rc=0
    creds="$(mktemp)"
    cat >"$creds" <<EOF
[environments.development]
user = "sa"
password = "$MSSQL_SA_PASSWORD"

[environments.shadow]
user = "sa"
password = "$MSSQL_SA_PASSWORD"
EOF
    "$DOCKER" run --rm \
        --user "$(id -u):$(id -g)" -e HOME=/tmp \
        --network "container:$SQL_CONTAINER" \
        -v "$REPO_DIR:/repo" \
        -v "$creds:/repo/$FLYWAY_PROJECT_DIR/flyway.user.toml:ro" \
        -w "/repo/$FLYWAY_PROJECT_DIR" \
        -e FLYWAY_EMAIL -e FLYWAY_TOKEN \
        "$FLYWAY_IMAGE" "$@" || rc=$?
    rm -f "$creds"
    return "$rc"
}
