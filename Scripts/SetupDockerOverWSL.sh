#!/usr/bin/env bash
# Installs Docker Engine natively inside a WSL2 Ubuntu/Debian distro, using Docker's
# official apt repository. No desktop product is required.
#
# This is a generic starting point: if your organisation has its own standard Docker setup,
# use that instead (the other scripts only need a working `docker` CLI), or adapt this script.
#
# Usage: ./Scripts/SetupDockerOverWSL.sh [-y]
set -euo pipefail

assume_yes=false
[[ "${1:-}" == "-y" || "${1:-}" == "--yes" ]] && assume_yes=true

if docker info >/dev/null 2>&1; then
    echo "Docker is already installed and working ($(docker --version)). Nothing to do."
    exit 0
fi

if ! grep -qi microsoft /proc/version 2>/dev/null; then
    echo "Note: this doesn't look like WSL. The steps below should still work on Ubuntu/Debian." >&2
fi

# shellcheck disable=SC1091
. /etc/os-release
case "${ID:-}" in
    ubuntu|debian) ;;
    *)
        echo "ERROR: this script supports Ubuntu and Debian only (found '${ID:-unknown}')." >&2
        echo "See https://docs.docker.com/engine/install/ for other distributions." >&2
        exit 1
        ;;
esac

if [[ $EUID -eq 0 ]]; then sudo=""; else sudo="sudo"; fi
target_user="${SUDO_USER:-${USER:-$(id -un)}}"

cat <<EOF
This will install Docker Engine inside this WSL distro ($PRETTY_NAME). It will:
  1. Add Docker's official apt repository and signing key
  2. Install docker-ce, docker-ce-cli, containerd.io, buildx and compose plugins
  3. Add user '$target_user' to the 'docker' group (so you don't need sudo for docker)
  4. Start the Docker service
You may be asked for your sudo password.

EOF

if [[ "$assume_yes" != true ]]; then
    if [[ ! -t 0 ]]; then
        echo "Not running interactively; re-run with -y to confirm." >&2
        exit 1
    fi
    read -r -p "Continue? [y/N] " answer
    [[ "$answer" =~ ^[Yy]$ ]] || { echo "Cancelled."; exit 1; }
fi

echo "==> Installing prerequisites"
$sudo apt-get update
$sudo apt-get install -y ca-certificates curl

echo "==> Adding Docker's apt repository"
$sudo install -m 0755 -d /etc/apt/keyrings
$sudo curl -fsSL "https://download.docker.com/linux/$ID/gpg" -o /etc/apt/keyrings/docker.asc
$sudo chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/$ID ${VERSION_CODENAME} stable" \
    | $sudo tee /etc/apt/sources.list.d/docker.list >/dev/null

echo "==> Installing Docker Engine"
$sudo apt-get update
$sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

echo "==> Adding '$target_user' to the docker group"
$sudo usermod -aG docker "$target_user"

echo "==> Starting Docker"
if [[ -d /run/systemd/system ]]; then
    $sudo systemctl enable --now docker
else
    $sudo service docker start
    systemd_note=true
fi

echo "==> Verifying"
if $sudo docker info >/dev/null 2>&1; then
    echo "Docker Engine is installed and running: $($sudo docker --version)"
else
    echo "ERROR: Docker was installed but the engine isn't responding. Try: sudo service docker start" >&2
    exit 1
fi

cat <<EOF

Done. Two things to know:
  * Group membership only applies to new shells. Open a new terminal, or run: newgrp docker
EOF
if [[ "${systemd_note:-false}" == true ]]; then
    cat <<'EOF'
  * This WSL distro isn't running systemd, so Docker won't start automatically after WSL restarts.
    Either run 'sudo service docker start' when needed, or enable systemd (recommended) by adding
        [boot]
        systemd=true
    to /etc/wsl.conf and running 'wsl --shutdown' from Windows.
EOF
fi
