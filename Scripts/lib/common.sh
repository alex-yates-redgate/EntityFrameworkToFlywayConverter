#!/usr/bin/env bash
# Shared helpers for the scripts in this folder. Source this file; don't execute it.
#
# The scripts only use the plain `docker` CLI, so they work with any Docker-compatible
# engine (Docker Engine, Docker Desktop, Rancher Desktop, Podman with a docker alias...).
# Set DOCKER to use a different CLI name, e.g. DOCKER=podman.

DOCKER="${DOCKER:-docker}"
export PATH="$PATH:$HOME/.dotnet/tools"

DEFAULT_CONTAINER_NAME="entityframework-flyway-sample"
# Database naming rule, shared with Flyway (see Flyway/flyway.toml):
#   EF database:        <base>_<branch>
#   Flyway development: <base>_<branch>_flyway
#   Flyway shadow:      <base>_<branch>_shadow
# where <branch> is the git branch name with everything except ASCII letters and digits removed.
# That is exactly what Flyway's ${git.branch:ad} resolver filter does, so Flyway and these scripts
# always agree on the name for a branch. Case is preserved, as Flyway does; SQL Server database
# names are normally case-insensitive, so comparisons below ignore case.
DB_BASE_NAME="${MSSQL_DATABASE_BASE:-EntityFrameworkDemo}"
DB_NAME_MAX_LENGTH=128

# Turns a git branch name into the <branch> part of a database name, e.g. feature/Add-Price -> featureAddPrice.
sanitize_branch_name() {
    LC_ALL=C sed -E 's/[^A-Za-z0-9]+//g' <<<"$1"
}

# Prints the database name to use. An explicit MSSQL_DATABASE_NAME always wins; otherwise it's
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

_lib_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
_scripts_dir="$(dirname "$_lib_dir")"

_fail() {
    {
        echo
        echo "ERROR: $1"
        shift
        for line in "$@"; do echo "  $line"; done
        echo
    } >&2
    exit 1
}

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
}
