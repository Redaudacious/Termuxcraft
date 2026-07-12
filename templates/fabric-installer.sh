#!/bin/bash
set -uo pipefail

# Runtime values come from /root/vm.env (written by install.sh / commands.sh).
MC_VERSION="1.21.11"; MC_PORT="25565"
# shellcheck disable=SC1091
[ -f /root/vm.env ] && . /root/vm.env
SERVER_PORT="$MC_PORT"

SERVER_DIR="/root/server"
MODS_DIR="$SERVER_DIR/mods"
JDK_DIR="$SERVER_DIR/jdk"
MODS="fabric-api lithium ferrite-core krypton c2me-fabric chunky servercore \
      spark noisium scalablelux modernfix clumps alternate-current"

msg(){ printf "\033[36m==>\033[0m %s\n" "$*"; }
err(){ printf "\033[31m[ERROR]\033[0m %s\n" "$*" >&2; exit 1; }

if ls -1 "$SERVER_DIR"/paper*.jar >/dev/null 2>&1; then
    printf "\033[33m[!]\033[0m A Paper jar exists in %s.\n" "$SERVER_DIR"
    printf "    Fabric and Paper must not share a server folder. Remove the paper*.jar\n"
    printf "    (and its plugins/) first, or install into a fresh VM.\n"
    read -r -p "  Continue anyway? (y/N): " a; case "$a" in [yY]*) ;; *) exit 1;; esac
fi

if ! command -v jq >/dev/null 2>&1; then apt-get update -y && apt-get install -y jq ca-certificates; fi

mkdir -p "$SERVER_DIR" "$MODS_DIR"
cd "$SERVER_DIR" || err "Cannot enter $SERVER_DIR"

if [ ! -x "$JDK_DIR/bin/java" ]; then
    msg "Downloading JDK 21..."
    wget -O /tmp/jdk.tar.gz "https://api.adoptium.net/v3/binary/latest/21/ga/linux/aarch64/jdk/hotspot/normal/eclipse" || err "JDK fail"
    rm -rf "$JDK_DIR"; mkdir -p "$JDK_DIR"
    tar -xzf /tmp/jdk.tar.gz -C "$JDK_DIR" --strip-components=1 || err "Extract fail"
    rm -f /tmp/jdk.tar.gz
fi

msg "Resolving Fabric..."
LOADER=$(wget -qO- "https://meta.fabricmc.net/v2/versions/loader/$MC_VERSION" | jq -r '.[0].loader.version')
INSTALLER=$(wget -qO- "https://meta.fabricmc.net/v2/versions/installer"       | jq -r '.[0].version')
[ -z "${LOADER:-}" ] || [ "$LOADER" = "null" ] && err "No fabric loader for $MC_VERSION"

msg "Downloading Fabric server..."
wget -O "$SERVER_DIR/fabric-server-launch.jar" "https://meta.fabricmc.net/v2/versions/loader/$MC_VERSION/$LOADER/$INSTALLER/server/jar" || err "Fabric fail"

msg "Downloading mods..."
for slug in $MODS; do
    api="https://api.modrinth.com/v2/project/$slug/version?loaders=%5B%22fabric%22%5D&game_versions=%5B%22$MC_VERSION%22%5D"
    url=$(wget -qO- "$api" | jq -r '.[0].files | sort_by(.primary != true) | .[0].url // empty')
    if [ -n "$url" ] && [ "$url" != "null" ]; then
        fname=$(basename "${url%%\?*}")
        wget -q -O "$MODS_DIR/$fname" "$url" && printf "   \033[32m[OK]\033[0m %s\n" "$slug" || printf "   \033[31m[FAIL]\033[0m %s\n" "$slug"
    else
        printf "   \033[33m[SKIP]\033[0m %s\n" "$slug"
    fi
done

[ -f "$SERVER_DIR/eula.txt" ] || echo "eula=false" > "$SERVER_DIR/eula.txt"
if [ ! -f "$SERVER_DIR/server.properties" ]; then
    cat > "$SERVER_DIR/server.properties" <<PROP
server-port=$SERVER_PORT
motd=Fabric Server $MC_VERSION
online-mode=true
max-players=20
view-distance=10
simulation-distance=8
PROP
fi
msg "DONE! Next step: nano ~/server/eula.txt   (set eula=true)"
