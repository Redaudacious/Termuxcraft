#!/bin/bash
set -uo pipefail

# Runtime values come from /root/vm.env (written by install.sh / commands.sh).
MC_VERSION="1.21.11"; MC_PORT="25565"
# shellcheck disable=SC1091
[ -f /root/vm.env ] && . /root/vm.env
SERVER_PORT="$MC_PORT"

SERVER_DIR="/root/server"
PLUGINS_DIR="$SERVER_DIR/plugins"
JDK_DIR="$SERVER_DIR/jdk"
API="https://api.papermc.io/v2/projects/paper"

# Paper already bundles most of Fabric's performance mods (it's a highly
# optimized server). We only add what Paper does NOT: a pre-generator (Chunky)
# and a profiler (spark). Alternate-current redstone is enabled via config.
PLUGINS="chunky spark"

msg(){ printf "\033[36m==>\033[0m %s\n" "$*"; }
err(){ printf "\033[31m[ERROR]\033[0m %s\n" "$*" >&2; exit 1; }

if [ -f "$SERVER_DIR/fabric-server-launch.jar" ] || ls -1 "$SERVER_DIR"/mods/*.jar >/dev/null 2>&1; then
    printf "\033[33m[!]\033[0m This folder looks like a Fabric server (jar/mods present).\n"
    printf "    Paper uses plugins, not mods, and must not share the folder with Fabric.\n"
    printf "    Remove fabric-server-launch.jar and mods/ first, or use a fresh VM.\n"
    read -r -p "  Continue anyway? (y/N): " a; case "$a" in [yY]*) ;; *) exit 1;; esac
fi

if ! command -v jq >/dev/null 2>&1; then apt-get update -y && apt-get install -y jq ca-certificates; fi

mkdir -p "$SERVER_DIR" "$PLUGINS_DIR" "$SERVER_DIR/config"
cd "$SERVER_DIR" || err "Cannot enter $SERVER_DIR"

if [ ! -x "$JDK_DIR/bin/java" ]; then
    msg "Downloading JDK 21..."
    wget -O /tmp/jdk.tar.gz "https://api.adoptium.net/v3/binary/latest/21/ga/linux/aarch64/jdk/hotspot/normal/eclipse" || err "JDK fail"
    rm -rf "$JDK_DIR"; mkdir -p "$JDK_DIR"
    tar -xzf /tmp/jdk.tar.gz -C "$JDK_DIR" --strip-components=1 || err "Extract fail"
    rm -f /tmp/jdk.tar.gz
fi

msg "Resolving Paper build for $MC_VERSION..."
BUILDS_JSON=$(wget -qO- "$API/versions/$MC_VERSION/builds") || err "Paper API unreachable"
BUILD=$(printf '%s' "$BUILDS_JSON" | jq -r '[.builds[] | select(.channel=="default")] | last | .build // empty')
[ -z "$BUILD" ] && BUILD=$(printf '%s' "$BUILDS_JSON" | jq -r '.builds | last | .build // empty')
[ -z "$BUILD" ] || [ "$BUILD" = "null" ] && err "No Paper build found for $MC_VERSION"
JARNAME=$(printf '%s' "$BUILDS_JSON" | jq -r --argjson b "$BUILD" '.builds[] | select(.build==$b) | .downloads.application.name')
[ -z "$JARNAME" ] || [ "$JARNAME" = "null" ] && JARNAME="paper-$MC_VERSION-$BUILD.jar"

msg "Downloading Paper $MC_VERSION build $BUILD ($JARNAME)..."
rm -f "$SERVER_DIR"/paper*.jar        # drop older builds so autodetect is unambiguous
wget -O "$SERVER_DIR/$JARNAME" "$API/versions/$MC_VERSION/builds/$BUILD/downloads/$JARNAME" || err "Paper download failed"

msg "Downloading plugins..."
dl_plugin(){
    local slug="$1" api url fname
    api="https://api.modrinth.com/v2/project/$slug/version?loaders=%5B%22paper%22%2C%22bukkit%22%2C%22spigot%22%5D&game_versions=%5B%22$MC_VERSION%22%5D"
    url=$(wget -qO- "$api" | jq -r '.[0].files | sort_by(.primary != true) | .[0].url // empty')
    if [ -z "$url" ] || [ "$url" = "null" ]; then
        api="https://api.modrinth.com/v2/project/$slug/version?loaders=%5B%22paper%22%2C%22bukkit%22%2C%22spigot%22%5D"
        url=$(wget -qO- "$api" | jq -r '.[0].files | sort_by(.primary != true) | .[0].url // empty')
    fi
    if [ -n "$url" ] && [ "$url" != "null" ]; then
        fname=$(basename "${url%%\?*}")
        wget -q -O "$PLUGINS_DIR/$fname" "$url" && printf "   \033[32m[OK]\033[0m %s\n" "$slug" || printf "   \033[31m[FAIL]\033[0m %s\n" "$slug"
    else
        printf "   \033[33m[SKIP]\033[0m %s (no Paper build for $MC_VERSION)\n" "$slug"
    fi
}
for slug in $PLUGINS; do dl_plugin "$slug"; done

# Enable the Alternate Current redstone implementation (faster redstone).
PG="$SERVER_DIR/config/paper-global.yml"
if [ ! -f "$PG" ]; then
    cat > "$PG" <<'YML'
misc:
  redstone-implementation: ALTERNATE_CURRENT
YML
    msg "Seeded config/paper-global.yml (redstone-implementation: ALTERNATE_CURRENT)"
elif grep -q 'redstone-implementation' "$PG"; then
    sed -i 's/\(redstone-implementation:\).*/\1 ALTERNATE_CURRENT/' "$PG"
    msg "Set redstone-implementation: ALTERNATE_CURRENT"
else
    printf "\033[33m[!]\033[0m Add under 'misc:' in config/paper-global.yml -> redstone-implementation: ALTERNATE_CURRENT\n"
fi

[ -f "$SERVER_DIR/eula.txt" ] || echo "eula=false" > "$SERVER_DIR/eula.txt"
if [ ! -f "$SERVER_DIR/server.properties" ]; then
    cat > "$SERVER_DIR/server.properties" <<PROP
server-port=$SERVER_PORT
motd=Paper Server $MC_VERSION
online-mode=true
max-players=20
view-distance=10
simulation-distance=8
PROP
fi
msg "DONE! Next step: nano ~/server/eula.txt   (set eula=true)"
