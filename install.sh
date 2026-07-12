#!/data/data/com.termux/files/usr/bin/bash
# ============================================================================
#  install.sh — create ONE Minecraft VM (Termux + proot-distro Debian).
#
#  This installer is intentionally MINIMAL. It asks only for:
#     - (optional) host packages
#     - container name
#     - VM SSH port, VM Minecraft port
#     - RAM for the server
#
#  Everything else — SSH keys / password, Cloudflare exposure, playit.gg,
#  changing RAM or ports later — is done from:   bash commands.sh
# ============================================================================
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$DIR/lib/config.sh"
source "$DIR/lib/ui.sh"
source "$DIR/lib/vm_helpers.sh"
source "$DIR/lib/cloudflare.sh"
source "$DIR/lib/ssh.sh"
source "$DIR/lib/launcher.sh"

# Absolute paths baked into the shell-command wrappers.
export PROJECT_DIR="$DIR"
export COMMANDS_SH="$DIR/commands.sh"
export INSTALL_SH="$DIR/install.sh"

title "1. Host System Setup"
if ask_yes_no "Install/Update required host packages?"; then
    pkg update -y && pkg install -y x11-repo tur-repo && \
        pkg install -y proot-distro tmux openssh wget cloudflared nano jq iproute2
    c_ok "Host packages installed."
fi

title "2. Container Name"
while true; do
    NAME=$(ask "Container Name (a-z, 0-9, '-'; e.g. mc3)")
    if ! valid_name "$NAME"; then
        c_warn "Invalid name. Use lowercase letters, digits and '-' only (max 20 chars)."
        continue
    fi
    if vm_exists "$NAME" || proot-distro list 2>/dev/null | grep -qiw "$NAME"; then
        c_warn "Container '$NAME' already exists. Choose another."
        continue
    fi
    if ! name_is_free_for_wrapper "$NAME"; then
        c_warn "'$NAME' is already a command on your phone (or reserved)."
        c_warn "Pick a different name so it can become the '$NAME' shell command."
        continue
    fi
    break
done

title "3. Ports & RAM"
while true; do
    SSH_PORT=$(ask "VM SSH Port" "$SSH_PORT_BASE")
    if ! valid_port "$SSH_PORT"; then c_warn "Port must be a number 1024-65535."; continue; fi
    if who=$(port_in_use "$SSH_PORT"); then c_warn "Port $SSH_PORT is already used by $who."; continue; fi
    break
done
while true; do
    MC_PORT=$(ask "VM Minecraft Port" "$MC_PORT_BASE")
    if ! valid_port "$MC_PORT"; then c_warn "Port must be a number 1024-65535."; continue; fi
    if [ "$MC_PORT" = "$SSH_PORT" ]; then c_warn "Minecraft port must differ from the SSH port."; continue; fi
    if who=$(port_in_use "$MC_PORT"); then c_warn "Port $MC_PORT is already used by $who."; continue; fi
    break
done
RAM=$(ask_ram "2")

title "4. Installing Debian"
proot-distro install --override-alias "$NAME" "$DISTRO_BASE"
proot-distro login "$NAME" -- bash -c 'touch /root/ROOTFS_FOUND'
REAL_PATH=$(find "$PREFIX/var/lib/proot-distro" -name ROOTFS_FOUND 2>/dev/null | head -n1 | sed 's|/root/ROOTFS_FOUND||' || true)
[ -z "$REAL_PATH" ] && c_err "Rootfs path not found."
rm -f "$REAL_PATH/root/ROOTFS_FOUND"
c_ok "Rootfs: $REAL_PATH"

title "5. Writing Configuration"
mkdir -p "$REAL_PATH/root/.ssh" \
         "$REAL_PATH/root/server/mods" "$REAL_PATH/root/server/plugins" \
         "$REAL_PATH/etc/ssh/sshd_config.d"
# Empty authorized_keys so key auth is consistent from the first boot.
touch "$REAL_PATH/root/.ssh/authorized_keys"
chmod 700 "$REAL_PATH/root/.ssh"; chmod 600 "$REAL_PATH/root/.ssh/authorized_keys"

# Runtime env consumed by boot-container.sh and both installers.
cat > "$REAL_PATH/root/vm.env" <<ENV
RAM=$RAM
MC_PORT=$MC_PORT
SSH_PORT=$SSH_PORT
MC_VERSION=$MC_VERSION
ENV

# sshd drop-in (only the port is templated; auth stays key-only by default).
cp "$DIR/templates/sshd_container.conf" "$REAL_PATH/etc/ssh/sshd_config.d/container.conf"
sed -i "s|__SSH_PORT__|$SSH_PORT|g" "$REAL_PATH/etc/ssh/sshd_config.d/container.conf"

# Placeholder-free scripts.
cp "$DIR/templates/boot-container.sh"   "$REAL_PATH/root/boot-container.sh"
cp "$DIR/templates/fabric-installer.sh" "$REAL_PATH/root/fabric-installer.sh"
cp "$DIR/templates/paper-installer.sh"  "$REAL_PATH/root/paper-installer.sh"
cp "$DIR/templates/README.txt"          "$REAL_PATH/root/README.txt"
chmod +x "$REAL_PATH/root/boot-container.sh" \
         "$REAL_PATH/root/fabric-installer.sh" \
         "$REAL_PATH/root/paper-installer.sh"

printf 'set -g mouse on\n' > "$REAL_PATH/root/.tmux.conf"

# Login reminder (without clobbering an existing .bashrc).
if ! grep -q 'README.txt' "$REAL_PATH/root/.bashrc" 2>/dev/null; then
    printf '\n[ -f ~/README.txt ] && echo "  >> Read ~/README.txt, then run: bash ~/fabric-installer.sh  (or paper-installer.sh)"\n' \
        >> "$REAL_PATH/root/.bashrc"
fi

title "6. Installing Software inside VM"
proot-distro login "$NAME" -- bash -c "export DEBIAN_FRONTEND=noninteractive; apt-get update && apt-get install -y openssh-server wget curl tmux jq ca-certificates && ssh-keygen -A && wget -q -O /usr/local/bin/playit '$PLAYIT_URL' && chmod +x /usr/local/bin/playit"

title "7. Registering the VM"
mkdir -p "$CONTAINERS_DIR/$NAME"
NANNY="$CONTAINERS_DIR/$NAME/nanny.sh"
cp "$DIR/templates/nanny.sh" "$NANNY"
chmod +x "$NANNY"
# vm.conf is the host-side source of truth for this VM.
cat > "$(vm_conf "$NAME")" <<CONF
NAME=$NAME
ROOTFS=$REAL_PATH
SSH_PORT=$SSH_PORT
MC_PORT=$MC_PORT
RAM=$RAM
CONF
c_ok "VM '$NAME' registered in $CONTAINERS_DIR/$NAME"

title "8. Installing Shell Commands"
wrapper_install_launcher
wrapper_install_vm "$NAME"

title "SETUP COMPLETE!"
cat <<EOF

  VM name      : $NAME
  VM SSH port  : $SSH_PORT     (localhost, exposed via Cloudflare/LAN later)
  Minecraft    : $MC_PORT
  RAM          : $RAM

  NEXT STEPS
  ----------
  0) OPEN THE MENU anytime:  Termuxcraft   (or: termuxcraft)
     Manage this VM directly with its own command:  $NAME

  1) START THE VM (on the phone):
       $NAME            ->  Power  ->  Start
     …or from the phone:  Termuxcraft  ->  Start a VM

  2) INSTALL A SERVER (inside the VM, once):
       proot-distro login $NAME
       bash ~/fabric-installer.sh      # Fabric + mods
         (or)  bash ~/paper-installer.sh   # Paper + plugins
       nano ~/server/eula.txt          # eula=false -> eula=true

  3) SET UP REMOTE ACCESS (from the phone, anytime):
       $NAME   ->  SSH auth / Cloudflare
     This is where you add your PC's SSH key (or a password), expose the
     VM through a Cloudflare hostname, and print the ready ~/.ssh/config
     block for your PC.

  Tip: 'Termuxcraft' is the phone-admin control center; '$NAME' is the
       focused menu for just this VM.
EOF
