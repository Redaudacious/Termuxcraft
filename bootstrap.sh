#!/data/data/com.termux/files/usr/bin/bash
# ============================================================================
#  bootstrap.sh — run ONCE after 'git clone' to wire up the shell commands.
#
#  It (optionally) installs the host packages, then installs the 'Termuxcraft'
#  command (and 'termuxcraft'), and re-links a command for every VM that
#  already exists. After this you never call the scripts by path again — just
#  type:  Termuxcraft
# ============================================================================
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$DIR/lib/config.sh"
source "$DIR/lib/ui.sh"
source "$DIR/lib/vm_helpers.sh"
source "$DIR/lib/launcher.sh"

export PROJECT_DIR="$DIR"
export COMMANDS_SH="$DIR/commands.sh"
export INSTALL_SH="$DIR/install.sh"

title "Termuxcraft bootstrap"

if ask_yes_no "Install/Update required host packages now?"; then
    pkg update -y && pkg install -y x11-repo tur-repo && \
        pkg install -y proot-distro tmux openssh wget cloudflared nano jq iproute2
    c_ok "Host packages installed."
fi

title "Installing shell commands"
wrappers_relink_all

title "DONE"
cat <<EOF

  The command center is installed. From now on just type:

      Termuxcraft        (or: termuxcraft)

  In that menu choose "Create a new VM" to build your first server.
  Each VM you create also gets its own command (e.g. 'mc1') that opens a
  focused menu for just that VM.

  If you ever move this folder, re-run:  bash bootstrap.sh
EOF
