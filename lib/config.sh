#!/bin/bash
# lib/config.sh - Global constants shared by install.sh and commands.sh
#
# Per-VM state now lives in $CONTAINERS_DIR/<name>/vm.conf (host side) and in
# /root/vm.env inside each container (read by boot-container.sh + installers).

export PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"

export CONTAINERS_DIR="$HOME/.containers"
export DISTRO_BASE="debian"
export SSH_PORT_BASE=8023
export MC_PORT_BASE=25565
export HOST_SSH_PORT=8022
export MC_VERSION="1.21.11"
export PLAYIT_URL="https://github.com/playit-cloud/playit-agent/releases/latest/download/playit-linux-aarch64"
export CF_CONFIG="$HOME/.cloudflared/config.yml"
export TERMUX_USER="$(whoami)"
export CF_SESSION="cf"
export SAVE_WAIT=6

export CF_CERT="$HOME/.cloudflared/cert.pem"
export CF_ZONE_CACHE="$HOME/.cloudflared/zone.txt"
export HOST_SSHD_CONFIG="$PREFIX/etc/ssh/sshd_config"

# Shell-command wrappers (Termuxcraft launcher + one per VM) live in $BIN_DIR,
# which is on PATH. Each wrapper carries $WRAPPER_MARKER so we can find/remove
# exactly our files and never touch a real command.
export BIN_DIR="$PREFIX/bin"
export LAUNCHER_NAME="Termuxcraft"
export LAUNCHER_ALIAS="termuxcraft"
export WRAPPER_MARKER="# TERMUXCRAFT-WRAPPER"

mkdir -p "$CONTAINERS_DIR"
