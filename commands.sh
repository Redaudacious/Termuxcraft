#!/data/data/com.termux/files/usr/bin/bash
# ============================================================================
#  commands.sh — control center for the Minecraft VMs (run on the phone/Termux)
# ----------------------------------------------------------------------------
#  Interactive menu:   bash commands.sh            (or just: commands)
#
#  One-shot commands:
#     commands list                 show VMs + status
#     commands start   <name>       start one VM
#     commands stop    <name>       stop one VM cleanly
#     commands restart <name>       restart one VM
#     commands delete  <name>       permanently delete a VM
#     commands start-all|stop-all   every VM at once
#     commands vm      [name]       per-VM settings (auth, CF, playit, RAM, ports)
#     commands phone                phone (Termux host) SSH menu
#     commands cf                   start the Cloudflare tunnel
#     commands cf-stop              stop the Cloudflare tunnel
#     commands cloudflare           Cloudflare account & tunnel menu
#     commands login                link this phone to Cloudflare
#     commands new-tunnel           create a new named tunnel
#     commands select-tunnel        choose the active tunnel
#     commands ssh-config           print the PC ~/.ssh/config (phone + VMs)
#     commands routes               list tunnels + SSH routes
#     commands dns                  (re)create DNS records (+ overwrite)
# ============================================================================

# NO 'set -e' — the menu must survive individual command failures.
set -uo pipefail

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

# Empty CF_TUNNEL => resolve the active tunnel from config.yml so DNS/route ops
# and the ssh-config snippet know the exact tunnel to use.
CF_TUNNEL="${CF_TUNNEL:-$(cfg_tunnel_name)}"
PICKED=""
EXPOSED_HOST=""

# Admin tier for the per-VM menu:
#   1 = phone admin (full control)   2 = VM admin (scoped to one VM)
# Tier 2 may only expose its own SSH port on an ALREADY-configured tunnel, and
# never restarts the shared tunnel (that stays a phone-admin action).
VM_ADMIN_TIER=1

# ============================ VIEW: LIST ====================================
cmd_list(){
    c_head "Virtual machines"
    local any=0 name ssh mc sub state h
    while read -r name; do
        [ -z "$name" ] && continue
        any=1
        ssh=$(vm_get "$name" SSH_PORT); mc=$(vm_get "$name" MC_PORT)
        h=$(cf_host_for_port "$ssh"); sub="${h:--}"
        if running "$name"; then state="$(c_on "● RUNNING")"; else state="$(c_off "○ stopped")"; fi
        printf "   %-10s %b   ssh:%-5s mc:%-6s  %s\n" \
            "$name" "$state" "${ssh:--}" "${mc:--}" "$sub"
    done < <(list_vm_names)
    [ "$any" = 0 ] && c_warn "No VMs yet (create one with: bash install.sh)."

    if running "$CF_SESSION"; then
        printf "\n   Cloudflare tunnel: %b\n" "$(c_on "● up")"
    else
        printf "\n   Cloudflare tunnel: %b  (needed for remote SSH)\n" "$(c_off "○ down")"
    fi
}

# ============================ PICK A VM =====================================
pick_vm(){
    local names=() name i choice
    while read -r name; do [ -n "$name" ] && names+=("$name"); done < <(list_vm_names)
    if [ "${#names[@]}" -eq 0 ]; then c_warn "No VMs to choose from."; return 1; fi

    i=1
    for name in "${names[@]}"; do
        if running "$name"; then printf "   %d) %-10s %b\n" "$i" "$name" "$(c_on "running")"
        else                     printf "   %d) %-10s %b\n" "$i" "$name" "$(c_off "stopped")"; fi
        i=$((i+1))
    done
    printf "   0) back\n"
    read -r -p "  Choose a number: " choice
    [ "$choice" = "0" ] && return 1
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#names[@]}" ]; then
        c_warn "Invalid choice."; return 1
    fi
    PICKED="${names[$((choice-1))]}"
    return 0
}

# ============================ START / STOP ==================================
start_vm(){
    local name="$1" nanny="$CONTAINERS_DIR/$1/nanny.sh"
    vm_exists "$name" || { c_warn "No such VM: $name"; return 1; }
    [ -f "$nanny" ] || { c_warn "$name has no nanny.sh — is the name correct?"; return 1; }
    if running "$name"; then c_warn "$name is already running."; return 0; fi
    if tmux new -d -s "$name" "$nanny"; then
        c_ok "$name started.  Watch boot:  tmux attach -t $name"
    else
        c_warn "Could not start $name (is tmux available?)."
    fi
}

# stop_vm — clean shutdown WITHOUT killall java (which, under proot's shared PID
# namespace, would kill EVERY VM's java). We (1) send 'stop' to the server, (2)
# kill the host-side nanny session so it stops relaunching, (3) kill the
# CONTAINER's own tmux server — proot-distro gives each container a separate
# tmux server (no shared /tmp), so this only ends THIS VM's java.
stop_vm(){
    local name="$1"
    if ! running "$name"; then c_warn "$name is not running."; return 0; fi
    c_info "Asking $name to save the world and stop cleanly..."
    proot-distro login "$name" -- tmux send-keys -t mc-server "stop" Enter 2>/dev/null || true
    sleep "$SAVE_WAIT"
    tmux kill-session -t "=$name" 2>/dev/null || true
    proot-distro login "$name" -- tmux kill-server 2>/dev/null || true
    c_ok "$name stopped."
}

restart_vm(){ local name="$1"; stop_vm "$name"; sleep 2; start_vm "$name"; }

start_all(){
    local name n=0
    while read -r name; do
        [ -z "$name" ] && continue
        running "$name" || { start_vm "$name"; n=$((n+1)); }
    done < <(list_vm_names)
    [ "$n" = 0 ] && c_info "Nothing to start (all VMs already running or none exist)."
}

stop_all(){
    local name n=0
    while read -r name; do
        [ -z "$name" ] && continue
        if running "$name"; then stop_vm "$name"; n=$((n+1)); fi
    done < <(list_vm_names)
    [ "$n" = 0 ] && c_info "Nothing to stop (no VMs running)."
}

vm_power_menu(){
    local name="$1" choice
    c_head "Power — $name"
    if running "$name"; then c_ok "Currently running."; else c_warn "Currently stopped."; fi
    echo "   1) Start"
    echo "   2) Stop"
    echo "   3) Restart"
    echo "   0) Back"
    read -r -p "  > " choice
    case "$choice" in
        1) start_vm "$name" ;;
        2) stop_vm "$name" ;;
        3) restart_vm "$name" ;;
        *) : ;;
    esac
}

# delete_vm <name> — PERMANENTLY remove a VM: stop it, drop the Debian rootfs,
# strip its Cloudflare ingress, and remove its container dir. The DNS record
# can't be deleted via cloudflared, so we point the user to the dashboard.
delete_vm(){
    local name="$1" sshp host
    vm_exists "$name" || { c_warn "No such VM: $name"; return 1; }
    sshp=$(vm_get "$name" SSH_PORT); host=$(cf_host_for_port "$sshp")

    c_warn "This PERMANENTLY deletes VM '$name':"
    echo "     - its Debian rootfs and Minecraft world (proot-distro remove)"
    echo "     - its nanny + container dir ($CONTAINERS_DIR/$name)"
    echo "     - its Cloudflare ingress (if any)"
    ask_yes_no "Type y to confirm DELETION of '$name'" || { c_info "Cancelled."; return 1; }

    running "$name" && stop_vm "$name"

    if command -v proot-distro >/dev/null 2>&1; then
        proot-distro remove "$name" 2>/dev/null || c_warn "proot-distro remove failed (maybe already gone)."
    fi

    [ -n "$host" ] && cf_remove_route "$host"
    wrapper_remove "$name"
    rm -rf "$CONTAINERS_DIR/$name"
    c_ok "VM '$name' deleted."

    if [ -n "$host" ]; then
        c_warn "DNS record '$host' may still exist in the Cloudflare dashboard — delete it there if unused."
        if [ "${VM_ADMIN_TIER:-1}" = "2" ]; then
            c_info "The removed ingress clears after the tunnel reloads (ask the phone admin to restart it)."
        else
            ask_yes_no "Restart the tunnel now so it drops the removed ingress?" && cf_tunnel_restart "${CF_TUNNEL:-$(cfg_tunnel_name)}"
        fi
    fi
}

# ============================ SHARED CLOUDFLARE EXPOSE ======================
# expose_port <local-port> <default-label> — add (or change) a Cloudflare
# hostname pointing at a local port, create its DNS record, and (tier-1 only)
# offer a tunnel restart. Sets EXPOSED_HOST on success.
#   Tier 1 (phone admin): may link/create a tunnel and restart it.
#   Tier 2 (VM admin): only works if a tunnel already exists; never logs in,
#                      never creates/selects a tunnel, never restarts it.
expose_port(){
    local port="$1" deflabel="$2" zone host old
    EXPOSED_HOST=""
    if [ "${VM_ADMIN_TIER:-1}" = "2" ]; then
        cf_tier2_gate || return 1
    else
        cf_require_ready || return 1
    fi
    zone=$(cf_require_zone) || return 1
    old=$(cf_host_for_port "$port")
    host=$(ask_cf_hostname "Hostname for this endpoint" "$zone" "$deflabel")
    [ -z "$host" ] && { c_warn "No hostname given."; return 1; }
    if [ -n "$old" ] && [ "$old" != "$host" ]; then
        c_info "Replacing the existing route ($old)."
        cf_remove_route "$old"
        c_warn "The old DNS record ($old) may linger in the dashboard — delete it there if unused."
    fi
    cf_add_route "$host" "$port"
    cf_route_dns "$host"
    if [ "${VM_ADMIN_TIER:-1}" = "2" ]; then
        c_info "Route saved. It becomes active after the tunnel reloads."
        c_info "Ask the phone admin to restart the tunnel (Termuxcraft -> Cloudflare -> Start),"
        c_info "or it will apply automatically the next time the tunnel restarts."
    else
        ask_yes_no "Restart the tunnel now to apply?" && cf_tunnel_restart "$CF_TUNNEL"
    fi
    EXPOSED_HOST="$host"
    return 0
}

# cf_tier2_gate — VM-admin Cloudflare precondition: an account must be linked
# AND a tunnel already selected in config.yml. Sets CF_TUNNEL. No prompts that
# would create global state.
cf_tier2_gate(){
    if ! cf_logged_in; then
        c_warn "Cloudflare isn't set up on this phone yet."
        c_info "Ask the phone admin to link Cloudflare and pick a tunnel first."
        return 1
    fi
    local t; t=$(cfg_tunnel_name)
    if [ -z "$t" ]; then
        c_warn "No Cloudflare tunnel is selected on this phone yet."
        c_info "Ask the phone admin to select a tunnel first."
        return 1
    fi
    export CF_TUNNEL="$t"
    return 0
}

# unexpose_port <local-port> — remove the Cloudflare route for a local port.
unexpose_port(){
    local port="$1" host
    host=$(cf_host_for_port "$port")
    if [ -z "$host" ]; then c_info "Nothing is exposed for port $port."; return 0; fi
    ask_yes_no "Remove the Cloudflare route $host?" || { c_info "Cancelled."; return 0; }
    cf_remove_route "$host"
    c_warn "The DNS record ($host) may linger in the dashboard — delete it there if unused."
    if [ "${VM_ADMIN_TIER:-1}" = "2" ]; then
        c_info "Removal takes effect after the tunnel reloads (ask the phone admin to restart it)."
    else
        ask_yes_no "Restart the tunnel now?" && cf_tunnel_restart "${CF_TUNNEL:-$(cfg_tunnel_name)}"
    fi
}

# ============================ PER-VM: AUTH ==================================
vm_auth_apply(){
    local name="$1"
    if running "$name"; then
        ask_yes_no "Apply now by reloading $name's sshd (keeps live sessions)?" && vm_sshd_restart "$name"
    else
        c_info "Changes apply next time $name starts."
    fi
}

vm_auth_menu(){
    local name="$1" choice
    while true; do
        c_head "SSH auth — VM $name"
        c_info "Current mode: $(vm_auth_summary "$name")"
        echo "   1) Key only (recommended)"
        echo "   2) Password only"
        echo "   3) Key + password"
        echo "   4) Manage keys (add / remove / replace)"
        echo "   5) Set root password"
        echo "   0) Back"
        read -r -p "  > " choice
        case "$choice" in
            1) vm_set_auth_mode "$name" key
               c_info "Key-only needs at least one authorized key:"
               keys_add "$(vm_authkeys "$name")"
               vm_auth_apply "$name" ;;
            2) vm_set_auth_mode "$name" password
               c_info "Password login needs a root password:"
               vm_set_root_password "$name"
               vm_auth_apply "$name" ;;
            3) vm_set_auth_mode "$name" both
               keys_add "$(vm_authkeys "$name")"
               vm_set_root_password "$name"
               vm_auth_apply "$name" ;;
            4) keys_menu "$(vm_authkeys "$name")" "VM $name"
               vm_auth_apply "$name" ;;
            5) vm_set_root_password "$name" ;;
            0|"") return ;;
            *) c_warn "Invalid choice." ;;
        esac
    done
}

# ============================ PER-VM: CLOUDFLARE ============================
vm_cf_menu(){
    local name="$1" sshp host choice
    if [ "${VM_ADMIN_TIER:-1}" = "2" ] && ! cf_tier2_gate >/dev/null 2>&1; then
        c_head "Cloudflare — VM $name"
        c_warn "No Cloudflare tunnel is set up on this phone yet."
        c_info "The phone admin must link Cloudflare and select a tunnel before this"
        c_info "VM can get its own SSH hostname. (You can still use LAN — see PC config.)"
        read -r -p "  Press Enter to go back..." _ || true
        return
    fi
    while true; do
        sshp=$(vm_get "$name" SSH_PORT); host=$(cf_host_for_port "$sshp")
        c_head "Cloudflare — VM $name (SSH port $sshp)"
        if [ -n "$host" ]; then c_ok "Exposed as: $host"; else c_warn "Not exposed via Cloudflare (LAN only)."; fi
        echo "   1) Expose / change hostname"
        echo "   2) Remove Cloudflare exposure"
        echo "   3) Print PC ~/.ssh/config block for this VM"
        echo "   0) Back"
        read -r -p "  > " choice
        case "$choice" in
            1) expose_port "$sshp" "$name" && print_vm_connect_info "$name" ;;
            2) unexpose_port "$sshp" ;;
            3) print_vm_connect_info "$name" ;;
            0|"") return ;;
            *) c_warn "Invalid choice." ;;
        esac
    done
}

# ============================ PER-VM: PLAYIT ================================
vm_playit_menu(){
    local name="$1" rootfs secret choice key
    rootfs=$(vm_rootfs "$name"); secret="$rootfs/root/.playit-secret"
    while true; do
        c_head "Playit.gg — VM $name"
        if [ -s "$secret" ]; then c_ok "A playit secret is set."; else c_warn "No playit secret set."; fi
        echo "   1) Set / change secret key"
        echo "   2) Remove secret key"
        echo "   0) Back"
        read -r -p "  > " choice
        case "$choice" in
            1) key=$(ask "Playit.gg secret key")
               if [ -n "$key" ]; then
                   printf '%s' "$key" > "$secret"; chmod 600 "$secret"
                   c_ok "Secret saved."
                   running "$name" && ask_yes_no "Restart $name so playit picks it up?" && restart_vm "$name"
               else c_warn "No key entered."; fi ;;
            2) if [ -f "$secret" ]; then
                   rm -f "$secret"; c_ok "Secret removed."
                   running "$name" && ask_yes_no "Restart $name to stop the playit agent?" && restart_vm "$name"
               else c_info "There was no secret to remove."; fi ;;
            0|"") return ;;
            *) c_warn "Invalid choice." ;;
        esac
    done
}

# ============================ PER-VM: RAM ===================================
vm_change_ram(){
    local name="$1" cur new
    cur=$(vm_get "$name" RAM); [ -z "$cur" ] && cur="2G"
    c_info "Current RAM: $cur"
    new=$(ask_ram "$cur")
    vm_set "$name" RAM "$new"; vm_env_set "$name" RAM "$new"
    c_ok "RAM set to $new (vm.conf + vm.env)."
    running "$name" && ask_yes_no "Restart $name now to apply the new heap?" && restart_vm "$name"
}

# ============================ PER-VM: PORTS =================================
vm_change_ssh_port(){
    local name="$1" old new who host cfg
    old=$(vm_get "$name" SSH_PORT)
    while true; do
        new=$(ask "New SSH port for $name" "$old")
        if ! valid_port "$new"; then c_warn "Port must be a number 1024-65535."; continue; fi
        if [ "$new" = "$old" ]; then c_info "Unchanged."; return 0; fi
        if who=$(port_in_use "$new" "$name"); then c_warn "Port $new is already used by $who."; continue; fi
        break
    done
    vm_set "$name" SSH_PORT "$new"; vm_env_set "$name" SSH_PORT "$new"
    cfg=$(vm_container_conf "$name"); sshd_set_directive "$cfg" Port "$new"
    c_ok "SSH port -> $new (vm.conf, vm.env, container.conf)."
    host=$(cf_host_for_port "$old")
    if [ -n "$host" ]; then
        cf_update_route_port "$host" "$new"
        if [ "${VM_ADMIN_TIER:-1}" = "2" ]; then
            c_info "Re-pointed. It takes effect after the tunnel reloads (ask the phone admin)."
        else
            ask_yes_no "Restart the tunnel to apply the new port?" && cf_tunnel_restart "${CF_TUNNEL:-$(cfg_tunnel_name)}"
        fi
    fi
    vm_sshd_restart "$name"
    c_info "Regenerate the PC config afterwards:  commands ssh-config"
}

vm_change_mc_port(){
    local name="$1" old new who rootfs props
    old=$(vm_get "$name" MC_PORT)
    while true; do
        new=$(ask "New Minecraft port for $name" "$old")
        if ! valid_port "$new"; then c_warn "Port must be a number 1024-65535."; continue; fi
        if [ "$new" = "$old" ]; then c_info "Unchanged."; return 0; fi
        if [ "$new" = "$(vm_get "$name" SSH_PORT)" ]; then c_warn "Must differ from the SSH port."; continue; fi
        if who=$(port_in_use "$new" "$name"); then c_warn "Port $new is already used by $who."; continue; fi
        break
    done
    vm_set "$name" MC_PORT "$new"; vm_env_set "$name" MC_PORT "$new"
    rootfs=$(vm_rootfs "$name"); props="$rootfs/root/server/server.properties"
    if [ -f "$props" ]; then
        sed -i "s/^server-port=.*/server-port=$new/" "$props"
        c_ok "server.properties updated (server-port=$new)."
    else
        c_info "server.properties not created yet — the installer will use vm.env."
    fi
    c_ok "Minecraft port -> $new (vm.conf + vm.env)."
    [ -s "$rootfs/root/.playit-secret" ] && c_warn "Update the port mapping in your playit.gg dashboard to $new."
    running "$name" && ask_yes_no "Restart $name now to apply?" && restart_vm "$name"
}

vm_ports_menu(){
    local name="$1" choice
    while true; do
        c_head "Ports — VM $name"
        c_info "SSH: $(vm_get "$name" SSH_PORT)    Minecraft: $(vm_get "$name" MC_PORT)"
        echo "   1) Change SSH port"
        echo "   2) Change Minecraft port"
        echo "   0) Back"
        read -r -p "  > " choice
        case "$choice" in
            1) vm_change_ssh_port "$name" ;;
            2) vm_change_mc_port "$name" ;;
            0|"") return ;;
            *) c_warn "Invalid choice." ;;
        esac
    done
}

# ============================ PER-VM: CONSOLE ==============================
# vm_console <name> — attach to the live Minecraft server console (the
# 'mc-server' tmux session inside the container).
vm_console(){
    local name="$1"
    if ! running "$name"; then
        c_warn "$name is not running. Start it first (Power -> Start)."
        return 1
    fi
    if ! proot-distro login "$name" -- tmux has-session -t mc-server 2>/dev/null; then
        c_warn "No live server console yet (the server may still be starting, or has stopped)."
        c_info "Watch the boot log instead:  tmux attach -t $name"
        return 1
    fi
    c_info "Attaching to the server console."
    c_info "  Detach (leave it running):  Ctrl+B  then  D"
    c_info "  Stop the server cleanly:    type 'stop' then Enter"
    read -r -p "  Press Enter to attach..." _ || true
    proot-distro login "$name" -- tmux attach -t mc-server
}

# ============================ PER-VM: TOP MENU =============================
# vm_menu <name> — the per-VM menu, shared by both admin tiers. Set
# VM_ADMIN_TIER before calling (1 = phone admin, 2 = VM admin). The actions are
# identical; only the header and the Cloudflare behaviour differ by tier.
vm_menu(){
    local name="$1" choice h title
    if ! vm_exists "$name"; then c_warn "No such VM: $name"; return 1; fi
    if [ "${VM_ADMIN_TIER:-1}" = "2" ]; then title="VM console & settings — $name (VM admin)"
    else                                    title="VM settings — $name"; fi
    while true; do
        c_head "$title"
        if running "$name"; then printf "   State     : %b\n" "$(c_on "● running")"
        else                     printf "   State     : %b\n" "$(c_off "○ stopped")"; fi
        printf "   SSH port  : %s\n" "$(vm_get "$name" SSH_PORT)"
        printf "   Minecraft : %s\n" "$(vm_get "$name" MC_PORT)"
        printf "   RAM       : %s\n" "$(vm_get "$name" RAM)"
        printf "   SSH auth  : %s\n" "$(vm_auth_summary "$name")"
        h=$(cf_host_for_port "$(vm_get "$name" SSH_PORT)")
        printf "   Cloudflare: %s\n" "${h:-<LAN only>}"
        echo ""
        echo "   1) Server console (attach)"
        echo "   2) Power (start / stop / restart)"
        echo "   3) SSH auth (key / password / keys / root pw)"
        echo "   4) Cloudflare exposure & PC ~/.ssh/config"
        echo "   5) Playit.gg secret"
        echo "   6) Change RAM"
        echo "   7) Change ports (SSH / Minecraft)"
        echo "   8) Delete this VM"
        echo "   0) Back"
        read -r -p "  > " choice
        case "$choice" in
            1) vm_console "$name" ;;
            2) vm_power_menu "$name" ;;
            3) vm_auth_menu "$name" ;;
            4) vm_cf_menu "$name" ;;
            5) vm_playit_menu "$name" ;;
            6) vm_change_ram "$name" ;;
            7) vm_ports_menu "$name" ;;
            8) delete_vm "$name"; vm_exists "$name" || return ;;
            0|"") return ;;
            *) c_warn "Invalid choice." ;;
        esac
    done
}

# ============================ PHONE (HOST) SSH =============================
host_apply(){
    if host_sshd_running; then
        ask_yes_no "Restart the phone sshd now to apply?" && host_sshd_restart
    else
        c_info "Will apply when you start the phone sshd."
    fi
}

phone_cf_menu(){
    local host choice
    while true; do
        host=$(cf_host_for_port "$HOST_SSH_PORT")
        c_head "Cloudflare — Phone host SSH (port $HOST_SSH_PORT)"
        if [ -n "$host" ]; then c_ok "Exposed as: $host"; else c_warn "Not exposed (LAN only)."; fi
        echo "   1) Expose / change hostname"
        echo "   2) Remove exposure"
        echo "   3) Print PC ~/.ssh/config (phone + all VMs)"
        echo "   0) Back"
        read -r -p "  > " choice
        case "$choice" in
            1) expose_port "$HOST_SSH_PORT" "phone" && gen_ssh_config ;;
            2) unexpose_port "$HOST_SSH_PORT" ;;
            3) gen_ssh_config ;;
            0|"") return ;;
            *) c_warn "Invalid choice." ;;
        esac
    done
}

phone_menu(){
    local choice
    while true; do
        c_head "Phone (Termux host) SSH"
        if host_sshd_running; then c_ok "sshd listening on port $HOST_SSH_PORT."; else c_warn "sshd is NOT running."; fi
        c_info "Auth mode: $(host_auth_summary)"
        if [ ! -s "$(host_authkeys)" ]; then c_info "No authorized keys yet (~/.ssh/authorized_keys)."; fi
        echo "   1) Start sshd"
        echo "   2) Stop sshd"
        echo "   3) Auth: key only"
        echo "   4) Auth: password only"
        echo "   5) Auth: key + password"
        echo "   6) Manage keys (add / remove / replace)"
        echo "   7) Set Termux password (passwd)"
        echo "   8) Cloudflare exposure & PC config"
        echo "   0) Back"
        read -r -p "  > " choice
        case "$choice" in
            1) host_sshd_start ;;
            2) host_sshd_stop ;;
            3) host_set_auth_mode key
               c_info "Key-only needs at least one authorized key:"
               keys_add "$(host_authkeys)"; host_apply ;;
            4) host_set_auth_mode password
               c_info "Password login needs a Termux password:"; passwd; host_apply ;;
            5) host_set_auth_mode both
               keys_add "$(host_authkeys)"; passwd; host_apply ;;
            6) keys_menu "$(host_authkeys)" "Phone (host)"; host_apply ;;
            7) passwd ;;
            8) phone_cf_menu ;;
            0|"") return ;;
            *) c_warn "Invalid choice." ;;
        esac
    done
}

# ============================ CLOUDFLARE TUNNEL ============================
cf_start(){
    cf_require_ready || return 1
    if ! host_sshd_running; then host_sshd_start; fi
    if running "$CF_SESSION"; then c_info "Cloudflare tunnel already running."; return 0; fi
    if tmux new -d -s "$CF_SESSION" "cloudflared tunnel run $CF_TUNNEL"; then
        c_ok "Cloudflare tunnel starting (session '$CF_SESSION')."
        c_info "You can now connect from your PC:  ssh <vm-name>"
    else
        c_warn "Could not start the tunnel (is tmux/cloudflared available?)."
    fi
}

cf_stop(){
    running "$CF_SESSION" || { c_warn "Cloudflare tunnel is not running."; return 0; }
    tmux kill-session -t "=$CF_SESSION" 2>/dev/null || true
    c_ok "Cloudflare tunnel stopped."
}

list_routes(){
    c_head "Cloudflare tunnels"
    if cf_logged_in; then c_ok "Account linked (cert.pem present)."; else c_warn "Account NOT linked on this phone."; fi
    local zone; zone=$(cf_detect_zone); [ -n "$zone" ] && c_info "Root domain: $zone"
    if command -v cloudflared >/dev/null 2>&1; then
        cloudflared tunnel list 2>/dev/null | sed 's/^/   /' || c_warn "Could not run 'cloudflared tunnel list'."
    else
        c_warn "cloudflared is not installed."
    fi
    local active; active=$(cfg_tunnel_name)
    echo ""
    c_info "Tunnel used by config.yml: ${active:-<none>}"

    c_head "Current SSH routes (from config.yml)"
    local host port label name found=0
    while IFS=$'\t' read -r host port; do
        [ -z "$host" ] && continue
        found=1
        if [ "$port" = "$HOST_SSH_PORT" ]; then label="PHONE"; else name=$(vm_for_ssh_port "$port"); label="VM ${name:-?}"; fi
        printf "   %-8s %-34s -> localhost:%s\n" "$label" "$host" "$port"
    done < <(cfg_routes)
    [ "$found" = 0 ] && c_warn "No routes found in $CF_CONFIG."
}

cf_tunnel_create_i(){
    command -v cloudflared >/dev/null 2>&1 || { c_warn "cloudflared is not installed."; return 1; }
    if ! cf_logged_in; then
        c_warn "No Cloudflare account is linked yet."
        ask_yes_no "Link it now?" && cf_login_flow || return 1
    fi
    local name; name=$(ask "New tunnel name" "phone-ssh")
    [ -z "$name" ] && { c_warn "No name given."; return 1; }
    if cloudflared tunnel create "$name"; then
        c_ok "Tunnel '$name' created (its <uuid>.json is now in ~/.cloudflared/)."
        ask_yes_no "Make it the active tunnel now?" && cf_set_active_tunnel "$name"
    else
        c_warn "Create failed (a tunnel with that name may already exist)."
    fi
}

cf_select_tunnel_i(){
    command -v cloudflared >/dev/null 2>&1 || { c_warn "cloudflared is not installed."; return 1; }
    if ! cf_logged_in; then c_warn "Link a Cloudflare account first (Cloudflare menu -> Link)."; return 1; fi
    c_info "Tunnels on this account:"
    cloudflared tunnel list 2>/dev/null | sed 's/^/     /' || echo "     (none)"
    local name; name=$(ask "Tunnel name to activate")
    [ -z "$name" ] && { c_warn "No name given."; return 1; }
    cf_set_active_tunnel "$name"
}

# create_dns_routes — (re)create DNS records for EVERY hostname in config.yml.
# THE fix for "record with that host already exists" (code 1003): can pass
# --overwrite-dns so leftover/stale records are repointed at this tunnel.
create_dns_routes(){
    [ -f "$CF_CONFIG" ] || { c_warn "No $CF_CONFIG found."; return 1; }
    command -v cloudflared >/dev/null 2>&1 || { c_warn "cloudflared is not installed."; return 1; }
    local tun; tun="${CF_TUNNEL:-$(cfg_tunnel_name)}"
    [ -z "$tun" ] && { c_warn "No active tunnel found in config.yml (select one first)."; return 1; }

    local flag=""
    ask_yes_no "Overwrite existing DNS records (repoint them at THIS tunnel)?" && flag="--overwrite-dns"

    c_head "Creating DNS records (tunnel: $tun)"
    local host port out any=0
    while IFS=$'\t' read -r host port; do
        [ -z "$host" ] && continue
        any=1
        if out=$(cloudflared tunnel route dns $flag "$tun" "$host" 2>&1); then
            c_ok "DNS route set: $host"
        else
            c_warn "$host — not created:"
            printf '%s\n' "$out" | sed 's/^/       /'
        fi
    done < <(cfg_routes)
    [ "$any" = 0 ] && { c_warn "No routes in $CF_CONFIG to create."; return 1; }
    c_info "If a hostname still won't connect, give DNS a minute and make sure the tunnel is running."
}

cf_menu(){
    local choice z t
    while true; do
        c_head "Cloudflare tunnel & account"
        if cf_logged_in; then c_ok "Account linked."; else c_warn "Not linked on this phone."; fi
        z=$(cf_detect_zone); [ -n "$z" ] && c_info "Root domain: $z"
        t=$(cfg_tunnel_name); c_info "Active tunnel: ${t:-<none>}"
        if running "$CF_SESSION"; then c_ok "Tunnel process: up"; else c_warn "Tunnel process: down"; fi
        echo ""
        echo "   1) Link / re-login this phone to Cloudflare"
        echo "   2) List tunnels + current SSH routes"
        echo "   3) Create a new tunnel"
        echo "   4) Select the active tunnel"
        echo "   5) Start tunnel"
        echo "   6) Stop tunnel"
        echo "   7) Create/refresh DNS records (fix 'already exists')"
        echo "   0) Back"
        read -r -p "  > " choice
        case "$choice" in
            1) cf_login_flow ;;
            2) list_routes ;;
            3) cf_tunnel_create_i ;;
            4) cf_select_tunnel_i ;;
            5) cf_start ;;
            6) cf_stop ;;
            7) create_dns_routes ;;
            0|"") return ;;
            *) c_warn "Invalid choice." ;;
        esac
    done
}

# ============================ CREATE / COMMANDS / RESET ====================
create_vm(){
    [ -f "$INSTALL_SH" ] || { c_warn "install.sh not found next to commands.sh."; return 1; }
    bash "$INSTALL_SH"
}

commands_install(){
    c_head "Install / repair shell commands"
    wrappers_relink_all
    c_ok "Done. Launcher: $LAUNCHER_NAME / $LAUNCHER_ALIAS, plus one command per VM."
}

# full_reset — undo EVERYTHING this project created. Guarded by a typed word,
# with the truly account-/phone-wide wipes offered individually.
full_reset(){
    c_head "FULL RESET — delete everything this project created"
    c_warn "This will PERMANENTLY:"
    echo "     - stop and REMOVE every VM (Debian rootfs + Minecraft world)"
    echo "     - delete $CONTAINERS_DIR (all VM state and nannies)"
    echo "     - remove the $LAUNCHER_NAME / $LAUNCHER_ALIAS and per-VM commands"
    echo "     - remove this project's ingress from Cloudflare config.yml"
    echo ""
    local ans
    read -r -p "  Type EXACTLY 'RESET' to continue (anything else cancels): " ans
    [ "$ans" = "RESET" ] || { c_info "Cancelled — nothing was changed."; return 1; }

    # 1) Stop everything fast (worlds are about to be deleted; no graceful save).
    c_info "Stopping VMs and the tunnel..."
    local name
    while read -r name; do
        [ -z "$name" ] && continue
        if running "$name"; then
            tmux kill-session -t "=$name" 2>/dev/null || true
            proot-distro login "$name" -- tmux kill-server 2>/dev/null || true
        fi
    done < <(list_vm_names)
    running "$CF_SESSION" && tmux kill-session -t "=$CF_SESSION" 2>/dev/null || true

    # 2) Remove each VM's rootfs (collect names BEFORE deleting the dir).
    while read -r name; do
        [ -z "$name" ] && continue
        c_info "Removing VM: $name"
        proot-distro remove "$name" 2>/dev/null || c_warn "  proot-distro remove $name failed (maybe already gone)."
    done < <(list_vm_names)

    # 3) Remove all our shell-command wrappers.
    wrappers_remove_all
    c_ok "Shell commands removed."

    # 4) Strip our ingress routes from config.yml (account/tunnel kept for now).
    if [ -f "$CF_CONFIG" ]; then
        local h p
        while IFS=$'\t' read -r h p; do [ -n "$h" ] && cf_remove_route "$h" >/dev/null; done < <(cfg_routes)
        c_ok "Removed our ingress routes from config.yml."
    fi

    # 5) Delete the containers directory.
    rm -rf "$CONTAINERS_DIR"
    c_ok "Deleted $CONTAINERS_DIR."

    # 6) Defensively drop any legacy launcher line from the host .bashrc.
    if [ -f "$HOME/.bashrc" ] && grep -q 'TERMUXCRAFT' "$HOME/.bashrc" 2>/dev/null; then
        sed -i '/TERMUXCRAFT/d' "$HOME/.bashrc"
    fi

    c_ok "Core reset complete."
    echo ""

    # ---- optional, individually-confirmed wider wipes ----
    if ask_yes_no "Also LOG OUT of Cloudflare (delete ~/.cloudflared: cert + tunnel creds)?"; then
        c_warn "Any tunnels and DNS records will REMAIN in the Cloudflare dashboard — remove them there."
        rm -rf "$HOME/.cloudflared" && c_ok "~/.cloudflared removed."
    fi

    if ask_yes_no "Also reset the PHONE's SSH (clear ~/.ssh/authorized_keys + re-allow passwords)?"; then
        : > "$HOME/.ssh/authorized_keys" 2>/dev/null || true
        sshd_set_directive "$HOST_SSHD_CONFIG" PasswordAuthentication yes
        sshd_set_directive "$HOST_SSHD_CONFIG" PubkeyAuthentication  yes
        c_ok "Phone SSH reset (authorized keys cleared, password login re-enabled)."
        c_info "It applies after the phone sshd restarts."
    fi

    if ask_yes_no "FINALLY, delete this project folder too ($PROJECT_DIR) so you can re-clone fresh?"; then
        c_warn "This removes the scripts themselves; this menu will now exit."
        cd "$HOME" 2>/dev/null || true
        rm -rf "$PROJECT_DIR"
        echo "  Project folder deleted. Re-clone with your git command when ready. Bye."
        exit 0
    fi

    c_info "All done. To set things up again later:  bash bootstrap.sh"
}

# ============================ MAIN MENU =====================================
main_menu(){
    local choice
    VM_ADMIN_TIER=1
    while true; do
        cmd_list
        echo ""
        echo "   1) Start a VM"
        echo "   2) Stop a VM"
        echo "   3) Restart a VM"
        echo "   4) Start ALL VMs"
        echo "   5) Stop ALL VMs"
        echo "   6) VM settings (console, auth, Cloudflare, playit, RAM, ports)"
        echo "   7) Phone (Termux host) SSH"
        echo "   8) Cloudflare tunnel & account"
        echo "   9) Generate PC ~/.ssh/config (phone + all VMs)"
        echo "  10) Create a NEW VM"
        echo "  11) Install / repair shell commands (Termuxcraft + per-VM)"
        echo "  12) Delete a VM (rootfs + world + config)"
        echo "  13) FULL RESET — delete everything this project made"
        echo "   0) Exit"
        read -r -p "  > " choice
        case "$choice" in
            1) pick_vm && start_vm   "$PICKED" ;;
            2) pick_vm && stop_vm    "$PICKED" ;;
            3) pick_vm && restart_vm "$PICKED" ;;
            4) start_all ;;
            5) stop_all ;;
            6) VM_ADMIN_TIER=1; pick_vm && vm_menu "$PICKED" ;;
            7) phone_menu ;;
            8) cf_menu ;;
            9) gen_ssh_config ;;
            10) create_vm ;;
            11) commands_install ;;
            12) pick_vm && delete_vm "$PICKED" ;;
            13) full_reset ;;
            0|"") echo "  Bye."; return 0 ;;
            *) c_warn "Invalid choice." ;;
        esac
    done
}

# ============================ CLI DISPATCH ==================================
case "${1:-}" in
    ""|menu)   main_menu ;;
    list|ls)   cmd_list ;;
    start)     if [ -n "${2:-}" ]; then start_vm   "$2"; else echo "usage: commands start <name>"; fi ;;
    stop)      if [ -n "${2:-}" ]; then stop_vm    "$2"; else echo "usage: commands stop <name>"; fi ;;
    restart)   if [ -n "${2:-}" ]; then restart_vm "$2"; else echo "usage: commands restart <name>"; fi ;;
    delete|rm) if [ -n "${2:-}" ]; then delete_vm  "$2"; else echo "usage: commands delete <name>"; fi ;;
    start-all) start_all ;;
    stop-all)  stop_all ;;
    vm|settings) VM_ADMIN_TIER=1; if [ -n "${2:-}" ]; then vm_menu "$2"; else pick_vm && vm_menu "$PICKED"; fi ;;
    vmadmin)   VM_ADMIN_TIER=2; if [ -n "${2:-}" ]; then vm_menu "$2"; else echo "usage: commands vmadmin <name>"; fi ;;
    console)   if [ -n "${2:-}" ]; then vm_console "$2"; else echo "usage: commands console <name>"; fi ;;
    phone)     phone_menu ;;
    cf|tunnel) cf_start ;;
    cf-stop)   cf_stop ;;
    cloudflare|account) cf_menu ;;
    login|cf-login)     cf_login_flow ;;
    new-tunnel|cf-create) cf_tunnel_create_i ;;
    select-tunnel)      cf_select_tunnel_i ;;
    ssh-config)         gen_ssh_config ;;
    routes|tunnels)     list_routes ;;
    dns|route-dns)      create_dns_routes ;;
    create|new)         create_vm ;;
    link|commands-install|install-commands) commands_install ;;
    reset|nuke)         full_reset ;;
    *) echo "unknown command: $1"
       echo "usage: commands [ menu | list | start <name> | stop <name> | restart <name> | delete <name>"
       echo "                 | start-all | stop-all | vm [name] | vmadmin <name> | console <name> | phone"
       echo "                 | cf | cf-stop | cloudflare | login | new-tunnel | select-tunnel"
       echo "                 | ssh-config | routes | dns | create | link | reset ]" ;;
esac
