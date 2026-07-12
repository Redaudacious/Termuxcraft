#!/bin/bash
export HOME=/root

# ---- runtime config (written to /root/vm.env by installer/commands) ---------
RAM="2G"; MC_PORT="25565"; SSH_PORT="8023"; MC_VERSION="1.21.11"
# shellcheck disable=SC1091
[ -f /root/vm.env ] && . /root/vm.env
SERVER_DIR=/root/server

echo "nameserver 1.1.1.1" > /etc/resolv.conf
echo "nameserver 8.8.8.8" >> /etc/resolv.conf

mkdir -p /run/sshd
/usr/sbin/sshd && echo "[boot] SSHD running on port $SSH_PORT"

if [ -s /root/.playit-secret ]; then
    nohup /usr/local/bin/playit --secret "$(cat /root/.playit-secret)" > /root/playit.log 2>&1 &
    echo "[boot] Playit agent started"
fi

cd "$SERVER_DIR" 2>/dev/null || { echo "[boot] $SERVER_DIR does not exist"; sleep 30; exit 0; }

find_java(){
    if [ -x "$SERVER_DIR/jdk/bin/java" ]; then echo "$SERVER_DIR/jdk/bin/java"
    else command -v java 2>/dev/null || true; fi
}
# Prefer Fabric's launch jar, then a Paper jar, then any jar in the folder.
find_jar(){
    if [ -f "$SERVER_DIR/fabric-server-launch.jar" ]; then echo "$SERVER_DIR/fabric-server-launch.jar"
    elif ls -1 "$SERVER_DIR"/paper*.jar >/dev/null 2>&1; then ls -1 "$SERVER_DIR"/paper*.jar | head -n1
    else ls -1 "$SERVER_DIR"/*.jar 2>/dev/null | head -n1; fi
}
eula_ok(){
    [ -f "$SERVER_DIR/eula.txt" ] && grep -Eqi '^[[:space:]]*eula[[:space:]]*=[[:space:]]*true' "$SERVER_DIR/eula.txt"
}

# ---- Aikar's JVM flags (tuned G1GC) -----------------------------------------
# Xms == Xmx (Aikar recommends a fixed heap). The "large" G1 sub-set kicks in at
# >= 12 GB, otherwise the standard set. RAM keeps its suffix (e.g. 2048M / 2G).
ram_mb(){
    local r="${1^^}"
    case "$r" in
        *G) echo $(( ${r%G} * 1024 )) ;;
        *M) echo "${r%M}" ;;
        *)  echo "$r" ;;
    esac
}
RAM_MB=$(ram_mb "$RAM"); case "$RAM_MB" in ''|*[!0-9]*) RAM_MB=0;; esac
if [ "$RAM_MB" -ge 12288 ]; then
    G1_FLAGS="-XX:G1NewSizePercent=40 -XX:G1MaxNewSizePercent=50 -XX:G1HeapRegionSize=16M -XX:G1ReservePercent=15 -XX:InitiatingHeapOccupancyPercent=20"
else
    G1_FLAGS="-XX:G1NewSizePercent=30 -XX:G1MaxNewSizePercent=40 -XX:G1HeapRegionSize=8M -XX:G1ReservePercent=20 -XX:InitiatingHeapOccupancyPercent=15"
fi
AIKAR_FLAGS="-XX:+UseG1GC -XX:+ParallelRefProcEnabled -XX:MaxGCPauseMillis=200 \
-XX:+UnlockExperimentalVMOptions -XX:+DisableExplicitGC \
$G1_FLAGS -XX:G1HeapWastePercent=5 -XX:G1MixedGCCountTarget=4 \
-XX:G1MixedGCLiveThresholdPercent=90 -XX:G1RSetUpdatingPauseTimePercent=5 \
-XX:SurvivorRatio=32 -XX:+PerfDisableSharedMem -XX:MaxTenuringThreshold=1 \
-Dusing.aikars.flags=https://mcflags.emc.gs -Daikars.new.flags=true"
JVM_FLAGS="-Xms$RAM -Xmx$RAM $AIKAR_FLAGS"

while true; do
    JAVA_BIN=$(find_java); JAR=$(find_jar)
    if [ -z "$JAVA_BIN" ] || [ -z "$JAR" ]; then
        echo "[boot] Server incomplete. Run ~/fabric-installer.sh or ~/paper-installer.sh. Retrying in 20s..."; sleep 20; continue
    fi
    if ! eula_ok; then
        echo "[boot] EULA NOT ACCEPTED. Edit $SERVER_DIR/eula.txt. Waiting 20s..."; sleep 20; continue
    fi
    break
done

echo "[boot] Starting $JAR in TMUX (heap $RAM, Aikar flags)..."
tmux kill-session -t mc-server 2>/dev/null
tmux new -d -s mc-server "$JAVA_BIN $JVM_FLAGS -jar $JAR nogui"

while tmux has-session -t mc-server 2>/dev/null; do sleep 5; done
echo "[boot] TMUX session ended. Shutting down."
