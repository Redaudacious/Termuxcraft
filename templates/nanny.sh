#!/data/data/com.termux/files/usr/bin/bash
# nanny.sh — keep one VM's server alive. This file is placeholder-free: it reads
# the vm.conf that lives right next to it (written by install.sh / commands.sh).
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$DIR/vm.conf"

EULA="$ROOTFS/root/server/eula.txt"
while true; do
    if [ ! -f "$EULA" ] || ! grep -Eqi '^[[:space:]]*eula[[:space:]]*=[[:space:]]*true' "$EULA"; then
        echo "[nanny] EULA NOT ACCEPTED. Inside the VM run ~/fabric-installer.sh (or"
        echo "        ~/paper-installer.sh), then set eula=true in ~/server/eula.txt."
    fi
    proot-distro login "$NAME" -- /root/boot-container.sh
    sleep 5
done
