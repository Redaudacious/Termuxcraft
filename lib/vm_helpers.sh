#!/bin/bash
# lib/vm_helpers.sh - Working with the per-VM state.
#
# Each VM is a directory $CONTAINERS_DIR/<name>/ that contains:
#   vm.conf   -> host-side state:  NAME, ROOTFS, SSH_PORT, MC_PORT, RAM
#   nanny.sh  -> the boot loop launched via tmux
# Inside the container, /root/vm.env mirrors the runtime bits (RAM, ports,
# MC_VERSION) so boot-container.sh and the installers read them at runtime.

# running <session> — is a tmux session with this EXACT name alive?
running(){ tmux has-session -t "=$1" 2>/dev/null; }

vm_conf(){ printf '%s/%s/vm.conf' "$CONTAINERS_DIR" "$1"; }
vm_exists(){ [ -f "$(vm_conf "$1")" ]; }

# list_vm_names — every dir under $CONTAINERS_DIR that has a vm.conf.
list_vm_names(){
    [ -d "$CONTAINERS_DIR" ] || return 0
    local d
    for d in "$CONTAINERS_DIR"/*/; do
        [ -f "${d}vm.conf" ] || continue
        basename "$d"
    done
}

# vm_get <name> <KEY> — print the value of KEY from vm.conf (empty if absent).
vm_get(){
    local f; f=$(vm_conf "$1")
    [ -f "$f" ] || return 0
    awk -F= -v k="$2" '$1==k{sub(/^[^=]*=/,"");print;exit}' "$f"
}

# vm_set <name> <KEY> <VALUE> — update KEY in vm.conf, or append if missing.
vm_set(){
    local name="$1" key="$2" val="$3" f tmp
    f=$(vm_conf "$name"); mkdir -p "$(dirname "$f")"; touch "$f"
    tmp="$f.tmp.$$"
    awk -F= -v k="$key" -v v="$val" '
        $1==k { print k"="v; found=1; next }
        { print }
        END { if(!found) print k"="v }
    ' "$f" > "$tmp" && mv "$tmp" "$f"
}

vm_rootfs(){ vm_get "$1" ROOTFS; }

# vm_env_set <name> <KEY> <VALUE> — same update-or-append, but on the
# container's /root/vm.env (so a running boot picks it up next start).
vm_env_set(){
    local name="$1" key="$2" val="$3" rootfs envf tmp
    rootfs=$(vm_rootfs "$name"); [ -n "$rootfs" ] || return 0
    envf="$rootfs/root/vm.env"
    mkdir -p "$(dirname "$envf")"; touch "$envf"
    tmp="$envf.tmp.$$"
    awk -F= -v k="$key" -v v="$val" '
        $1==k { print k"="v; found=1; next }
        { print }
        END { if(!found) print k"="v }
    ' "$envf" > "$tmp" && mv "$tmp" "$envf"
}

# vm_for_ssh_port <port> — name of the VM whose SSH_PORT matches (if any).
vm_for_ssh_port(){
    local port="$1" name
    while read -r name; do
        [ -z "$name" ] && continue
        if [ "$(vm_get "$name" SSH_PORT)" = "$port" ]; then printf '%s' "$name"; return 0; fi
    done < <(list_vm_names)
    return 0
}

# port_in_use <port> [ignore-name] — prints WHO uses the port and returns 0,
# or returns 1 if the port is free. Checks the phone's host SSH port plus every
# VM's SSH and Minecraft port (skipping <ignore-name> so a VM can keep its own).
port_in_use(){
    local port="$1" ignore="${2:-}" name s m
    if [ "$port" = "$HOST_SSH_PORT" ]; then printf 'the phone (host SSH)'; return 0; fi
    while read -r name; do
        [ -z "$name" ] && continue
        [ "$name" = "$ignore" ] && continue
        s=$(vm_get "$name" SSH_PORT); m=$(vm_get "$name" MC_PORT)
        if [ "$port" = "$s" ]; then printf 'VM %s (SSH)' "$name"; return 0; fi
        if [ "$port" = "$m" ]; then printf 'VM %s (Minecraft)' "$name"; return 0; fi
    done < <(list_vm_names)
    return 1
}
