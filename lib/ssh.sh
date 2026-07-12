#!/bin/bash
# lib/ssh.sh - SSH auth, keys, and PC ~/.ssh/config generation.
#
# Two SSH endpoints exist:
#   * the phone itself (Termux sshd, port $HOST_SSH_PORT), configured in
#     $HOST_SSHD_CONFIG, keys in ~/.ssh/authorized_keys.
#   * each VM (sshd inside the container), configured in
#     <rootfs>/etc/ssh/sshd_config.d/container.conf, keys in
#     <rootfs>/root/.ssh/authorized_keys.
#
# proot-distro shares the host PID namespace, so we NEVER kill sshd by name.
# The phone sshd is stopped via its pidfile; a VM's sshd is reloaded by HUPing
# the pid it wrote inside the container (keeps live sessions, rebinds the port).

HOST_SSHD_PID="${HOST_SSHD_PID:-$PREFIX/var/run/sshd.pid}"

# ---- generic sshd_config directive editing ---------------------------------
# sshd_set_directive <file> <Directive> <value>
#   OpenSSH honors the FIRST occurrence, so we replace in place if the line
#   exists (even commented), otherwise append.
sshd_set_directive(){
    local file="$1" key="$2" val="$3"
    [ -f "$file" ] || { mkdir -p "$(dirname "$file")"; touch "$file"; }
    if grep -qiE "^[[:space:]]*#?[[:space:]]*${key}[[:space:]]" "$file"; then
        sed -i -E "s|^[[:space:]]*#?[[:space:]]*${key}[[:space:]].*|${key} ${val}|I" "$file"
    else
        printf '%s %s\n' "$key" "$val" >> "$file"
    fi
}

# sshd_get_directive <file> <Directive> <default> — print the active value.
sshd_get_directive(){
    local file="$1" key="$2" def="$3" v=""
    [ -f "$file" ] && v=$(grep -iE "^[[:space:]]*${key}[[:space:]]" "$file" 2>/dev/null | head -n1 | awk '{print $2}')
    printf '%s' "${v:-$def}"
}

# _auth_label <pubkey yes/no> <password yes/no> <has-keys 0/1>
_auth_label(){
    local pub="$1" pass="$2" haskeys="$3" key_ok=0 pass_ok=0
    [ "${pub,,}" = "yes" ] && [ "$haskeys" = "1" ] && key_ok=1
    [ "${pass,,}" = "yes" ] && pass_ok=1
    if   [ "$key_ok" = 1 ] && [ "$pass_ok" = 1 ]; then printf 'key+password'
    elif [ "$key_ok" = 1 ];                       then printf 'key'
    elif [ "$pass_ok" = 1 ];                      then printf 'password'
    else                                               printf 'none'; fi
}

# ---- LAN IP detection (for VMs/phone without Cloudflare) -------------------
lan_ip(){
    local ip=""
    if command -v ip >/dev/null 2>&1; then
        ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
    fi
    if [ -z "$ip" ] && command -v ifconfig >/dev/null 2>&1; then
        ip=$(ifconfig 2>/dev/null | awk '/inet /{print $2}' | grep -vE '^127\.' | head -n1)
    fi
    if [ -z "$ip" ] && command -v termux-wifi-connectioninfo >/dev/null 2>&1; then
        ip=$(termux-wifi-connectioninfo 2>/dev/null | awk -F'"' '/"ip"/{print $4; exit}')
    fi
    if [ -n "$ip" ]; then printf '%s' "$ip"; else printf '<PHONE_LAN_IP>'; fi
}

# ---- key management (generic over an authorized_keys path) -----------------
_key_short(){
    local ln="$1" type blob comment
    type=$(printf '%s' "$ln" | awk '{print $1}')
    blob=$(printf '%s' "$ln" | awk '{print $2}')
    comment=$(printf '%s' "$ln" | awk '{$1="";$2="";sub(/^  */,"");print}')
    printf '%s ...%s %s' "$type" "${blob: -16}" "$comment"
}

keys_list(){
    local f="$1" n=0 line
    if [ ! -s "$f" ]; then c_info "No authorized keys yet."; return 0; fi
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        n=$((n+1)); printf "   %d) %s\n" "$n" "$(_key_short "$line")"
    done < "$f"
    [ "$n" = 0 ] && c_info "No authorized keys yet."
}

keys_add(){
    local f="$1" key
    key=$(ask_ssh_key "Paste the PC public key")
    mkdir -p "$(dirname "$f")"; touch "$f"
    chmod 700 "$(dirname "$f")" 2>/dev/null || true; chmod 600 "$f" 2>/dev/null || true
    if grep -qxF "$key" "$f" 2>/dev/null; then c_info "That key is already authorized."; return 0; fi
    printf '%s\n' "$key" >> "$f"
    c_ok "Key added."
}

keys_remove(){
    local f="$1" choice n
    [ -s "$f" ] || { c_info "No keys to remove."; return 0; }
    sed -i '/^[[:space:]]*$/d' "$f"        # drop blank lines so numbering == line numbers
    keys_list "$f"
    read -r -p "  Number to remove (0 = cancel): " choice
    [ "$choice" = "0" ] && return 0
    n=$(grep -c '' "$f")
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "$n" ]; then c_warn "Invalid choice."; return 1; fi
    sed -i "${choice}d" "$f"
    c_ok "Key removed."
}

keys_replace(){
    local f="$1"
    c_warn "This REMOVES all existing keys and adds a single new one."
    ask_yes_no "Continue?" || return 0
    : > "$f"; chmod 600 "$f" 2>/dev/null || true
    keys_add "$f"
}

keys_menu(){
    local f="$1" label="$2" choice
    while true; do
        c_head "SSH keys — $label"
        keys_list "$f"
        echo "   1) Add a key"
        echo "   2) Remove a key"
        echo "   3) Replace ALL keys with one"
        echo "   0) Back"
        read -r -p "  > " choice
        case "$choice" in
            1) keys_add "$f" ;;
            2) keys_remove "$f" ;;
            3) keys_replace "$f" ;;
            0|"") return 0 ;;
            *) c_warn "Invalid choice." ;;
        esac
    done
}

# ---- PHONE (Termux host) sshd ----------------------------------------------
host_authkeys(){ printf '%s/.ssh/authorized_keys' "$HOME"; }

host_sshd_running(){
    if command -v ss >/dev/null 2>&1; then
        ss -tln 2>/dev/null | grep -qE ":${HOST_SSH_PORT}([^0-9]|$)"
    else
        pgrep -x sshd >/dev/null 2>&1
    fi
}

host_sshd_start(){
    if host_sshd_running; then c_info "Phone sshd already listening on port $HOST_SSH_PORT."; return 0; fi
    if sshd; then c_ok "Phone sshd started (port $HOST_SSH_PORT)."; else c_warn "Could not start sshd."; fi
}

host_sshd_stop(){
    if [ -f "$HOST_SSHD_PID" ] && kill -0 "$(cat "$HOST_SSHD_PID" 2>/dev/null)" 2>/dev/null; then
        kill "$(cat "$HOST_SSHD_PID")" && c_ok "Phone sshd stopped."
    else
        c_warn "No sshd pidfile found ($HOST_SSHD_PID)."
        c_warn "Fallback 'pkill -x sshd' may ALSO stop sshd listeners inside containers."
        if ask_yes_no "Proceed with pkill -x sshd anyway?"; then
            pkill -x sshd && c_ok "sshd processes killed." || c_info "Nothing to kill."
        else
            c_info "Cancelled."
        fi
    fi
}

host_sshd_restart(){ host_sshd_stop; sleep 1; host_sshd_start; }

host_auth_summary(){
    local pass pub haskeys
    pass=$(sshd_get_directive "$HOST_SSHD_CONFIG" PasswordAuthentication yes)  # Termux default: yes
    pub=$(sshd_get_directive "$HOST_SSHD_CONFIG" PubkeyAuthentication yes)
    if [ -s "$(host_authkeys)" ]; then haskeys=1; else haskeys=0; fi
    _auth_label "$pub" "$pass" "$haskeys"
}

host_set_auth_mode(){
    case "$1" in
        key)      sshd_set_directive "$HOST_SSHD_CONFIG" PasswordAuthentication no
                  sshd_set_directive "$HOST_SSHD_CONFIG" PubkeyAuthentication  yes ;;
        password) sshd_set_directive "$HOST_SSHD_CONFIG" PasswordAuthentication yes
                  sshd_set_directive "$HOST_SSHD_CONFIG" PubkeyAuthentication  no ;;
        both)     sshd_set_directive "$HOST_SSHD_CONFIG" PasswordAuthentication yes
                  sshd_set_directive "$HOST_SSHD_CONFIG" PubkeyAuthentication  yes ;;
        *) c_warn "Unknown auth mode: $1"; return 1 ;;
    esac
}

# ---- VM (container) sshd ----------------------------------------------------
vm_container_conf(){ printf '%s/etc/ssh/sshd_config.d/container.conf' "$(vm_rootfs "$1")"; }
vm_authkeys(){ printf '%s/root/.ssh/authorized_keys' "$(vm_rootfs "$1")"; }

vm_auth_summary(){
    local name="$1" cfg pass pub haskeys
    cfg=$(vm_container_conf "$name")
    pass=$(sshd_get_directive "$cfg" PasswordAuthentication no)   # our template ships: no
    pub=$(sshd_get_directive "$cfg" PubkeyAuthentication yes)
    if [ -s "$(vm_authkeys "$name")" ]; then haskeys=1; else haskeys=0; fi
    _auth_label "$pub" "$pass" "$haskeys"
}

vm_set_auth_mode(){
    local name="$1" mode="$2" cfg; cfg=$(vm_container_conf "$name")
    case "$mode" in
        key)      sshd_set_directive "$cfg" PasswordAuthentication no
                  sshd_set_directive "$cfg" PubkeyAuthentication  yes
                  sshd_set_directive "$cfg" PermitRootLogin       prohibit-password ;;
        password) sshd_set_directive "$cfg" PasswordAuthentication yes
                  sshd_set_directive "$cfg" PubkeyAuthentication  no
                  sshd_set_directive "$cfg" PermitRootLogin       yes ;;
        both)     sshd_set_directive "$cfg" PasswordAuthentication yes
                  sshd_set_directive "$cfg" PubkeyAuthentication  yes
                  sshd_set_directive "$cfg" PermitRootLogin       yes ;;
        *) c_warn "Unknown auth mode: $mode"; return 1 ;;
    esac
}

# vm_sshd_restart <name> — reload the container's sshd so config changes (incl.
# a new Port) take effect, WITHOUT dropping current sessions. Targets the exact
# pid from /run/sshd.pid (never a name-based kill, which would hit host PIDs).
vm_sshd_restart(){
    local name="$1"
    if ! running "$name"; then c_info "$name is not running; SSH changes apply on next start."; return 0; fi
    if proot-distro login "$name" -- bash -c '
            if [ -f /run/sshd.pid ] && kill -0 "$(cat /run/sshd.pid)" 2>/dev/null; then
                kill -HUP "$(cat /run/sshd.pid)"; echo reloaded
            else
                mkdir -p /run/sshd; /usr/sbin/sshd; echo started
            fi' 2>/dev/null; then
        c_ok "$name sshd reloaded (sessions kept)."
    else
        c_warn "Could not reload $name sshd."
    fi
}

# vm_set_root_password <name> — prompt (hidden) and apply via chpasswd.
vm_set_root_password(){
    local name="$1" pass
    pass=$(ask_secret "New root password for VM '$name'") || return 1
    if printf 'root:%s\n' "$pass" | proot-distro login "$name" -- chpasswd 2>/dev/null; then
        c_ok "Root password set for '$name'."
    else
        c_warn "Could not set the root password (is the container OK?)."; return 1
    fi
}

# ---- ~/.ssh/config block generators ----------------------------------------
_emit_identity(){
    case "$1" in
        *key*)    printf '    IdentityFile ~/.ssh/YOUR_PRIVATE_KEY\n' ;;
        password) printf '    # password login — ssh will prompt for the password\n' ;;
        none)     printf '    # WARNING: SSH auth is currently disabled for this host\n' ;;
    esac
}

ssh_config_block_cf(){
    local alias="$1" host="$2" user="$3" auth="$4"
    printf 'Host %s\n' "$alias"
    printf '    HostName %s\n' "$host"
    printf '    User %s\n' "$user"
    printf '    ProxyCommand cloudflared access tcp --hostname %%h\n'
    _emit_identity "$auth"
}

ssh_config_block_lan(){
    local alias="$1" ip="$2" port="$3" user="$4" auth="$5"
    printf 'Host %s\n' "$alias"
    printf '    HostName %s\n' "$ip"
    printf '    Port %s\n' "$port"
    printf '    User %s\n' "$user"
    _emit_identity "$auth"
}

# print_vm_connect_info <name> — show & save the PC ~/.ssh/config block for one
# VM (Cloudflare block if it has a hostname, otherwise a LAN block).
print_vm_connect_info(){
    local name="$1" sshp host user auth out ip
    sshp=$(vm_get "$name" SSH_PORT); user="root"; auth=$(vm_auth_summary "$name")
    out="$CONTAINERS_DIR/$name/ssh-config-snippet.txt"
    host=$(cf_host_for_port "$sshp")
    {
        echo "# ===================================================================="
        echo "#  ~/.ssh/config block for VM '$name'  (paste on your PC)"
        echo "#  Auth mode: $auth"
        [ "$auth" = "none" ] && echo "#  WARNING: enable an auth mode first (keys or password)."
        echo "# ===================================================================="
        echo ""
        if [ -n "$host" ]; then
            ssh_config_block_cf "$name" "$host" "$user" "$auth"
        else
            ip=$(lan_ip)
            echo "# (no Cloudflare hostname — LAN mode; phone & PC must share Wi-Fi)"
            ssh_config_block_lan "$name" "$ip" "$sshp" "$user" "$auth"
        fi
    } > "$out"
    c_head "PC ~/.ssh/config for '$name'"
    sed 's/^/   /' "$out"; echo ""
    [[ "$auth" == *key* ]] && c_info "Edit IdentityFile -> path to your PRIVATE key on the PC."
    c_info "Saved to: $out"
}

# gen_ssh_config — full PC ~/.ssh/config for the phone (if it has SSH set up)
# plus every VM. Saved for reuse and printed.
gen_ssh_config(){
    local out="$CONTAINERS_DIR/ssh-config-snippet.txt"
    local name host user auth ip sshp hauth phost any=0
    {
        echo "# ===================================================================="
        echo "#  Paste into ~/.ssh/config on your PC."
        echo "#  Replace YOUR_PRIVATE_KEY with the path to your private key."
        echo "# ===================================================================="
        echo ""
        hauth=$(host_auth_summary)
        phost=$(cf_host_for_port "$HOST_SSH_PORT")
        if [ -s "$(host_authkeys)" ] || [ "$hauth" != "none" ]; then
            echo "# --- Phone (Termux host) — auth: $hauth ---"
            if [ -n "$phost" ]; then
                ssh_config_block_cf "phone" "$phost" "$TERMUX_USER" "$hauth"
            else
                ip=$(lan_ip)
                echo "# (no Cloudflare hostname for the phone — LAN mode)"
                ssh_config_block_lan "phone" "$ip" "$HOST_SSH_PORT" "$TERMUX_USER" "$hauth"
            fi
            echo ""
        fi
        while read -r name; do
            [ -z "$name" ] && continue
            any=1
            sshp=$(vm_get "$name" SSH_PORT); user="root"; auth=$(vm_auth_summary "$name")
            host=$(cf_host_for_port "$sshp")
            echo "# --- VM: $name — auth: $auth ---"
            [ "$auth" = "none" ] && echo "# WARNING: enable keys or a password for this VM first."
            if [ -n "$host" ]; then
                ssh_config_block_cf "$name" "$host" "$user" "$auth"
            else
                ip=$(lan_ip)
                echo "# (LAN — phone & PC on the same Wi-Fi)"
                ssh_config_block_lan "$name" "$ip" "$sshp" "$user" "$auth"
            fi
            echo ""
        done < <(list_vm_names)
    } > "$out"

    c_head "PC ~/.ssh/config (copy this)"
    sed 's/^/   /' "$out"; echo ""
    c_info "Saved to: $out   (view again: cat $out)"
    c_info "Edit only IdentityFile -> the path to your PRIVATE key on the PC."
    [ "$any" = 0 ] && c_warn "No VMs found yet (create one with install.sh)."
}
