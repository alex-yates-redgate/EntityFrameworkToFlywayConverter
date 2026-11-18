#!/usr/bin/env bash
# Installs the .NET 8 SDK and the dotnet-ef tool inside WSL (Ubuntu), which the EF scripts need.
# Safe to re-run.
set -euo pipefail

if [[ $EUID -eq 0 ]]; then sudo=""; else sudo="sudo"; fi

if dotnet --list-sdks 2>/dev/null | grep -q '^8\.'; then
    echo ".NET 8 SDK already installed."
else
    echo "==> Installing the .NET 8 SDK (you may be asked for your sudo password)"
    $sudo apt-get update
    $sudo apt-get install -y dotnet-sdk-8.0
fi

export PATH="$PATH:$HOME/.dotnet/tools"

if dotnet ef --version >/dev/null 2>&1; then
    echo "dotnet-ef already installed: $(dotnet ef --version | tail -n1)"
else
    echo "==> Installing dotnet-ef"
    dotnet tool install --global dotnet-ef --version '8.0.*'
fi

if ! grep -q '\.dotnet/tools' "$HOME/.bashrc" 2>/dev/null; then
    echo 'export PATH="$PATH:$HOME/.dotnet/tools"' >> "$HOME/.bashrc"
    echo "Added ~/.dotnet/tools to PATH in ~/.bashrc (applies to new terminals)."
fi

echo "Done: $(dotnet --version), dotnet-ef $(dotnet ef --version | tail -n1)"
