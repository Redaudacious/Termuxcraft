#!/bin/bash
# lib/cloudflare.sh - Cloudflare helpers (shared by install-time and commands.sh)
#
# The active tunnel and every SSH route live in ~/.cloudflared/config.yml.
# We no longer store a subdomain per VM anywhere else: config.yml is the source
# of truth for "which hostname points at which local port".

cf_logged_in(){ [ -f "$CF_CERT" ]; }

cf_login_flow(){
    command -v cloudflared >/dev/null 2>&1 || { c_warn "cloudflared is not installed (pkg install cloudflared)."; return 1; }
    c_info "Starting Cloudflare account login."
    echo "     1. A URL will appear below."
    echo "     2. Open it in your phone's browser and log in."
    echo "     3. Select your domain and click Authorize."
    read -r -p "  Press Enter to begin the login..." _ || true
    cloudflared tunnel login || true
    if cf_logged_in; then
        chmod 600 "$CF_CERT" 2>/dev/null || true   # cert.pem = account credential
        c_ok "Cloudflare account linked."
        return 0
    fi
    c_warn "No cert.pem found yet — login may not have finished."
    return 1
}

# ---- zone / root-domain detection ------------------------------------------
cf_zone_from_config(){
    local first=""
    [ -f "$CF_CONFIG" ] || return 0
    first=$(awk '/hostname:/{sub(/.*hostname:[ \t]*/,"");gsub(/[ \t]+$/,"");print;exit}' "$CF_CONFIG" 2>/dev/null || true)
    [ -n "$first" ] && printf '%s' "${first#*.}"
    return 0
}

cf_zone_from_cert(){
    local blob json zid tok name=""
    [ -f "$CF_CERT" ] || return 0
    command -v base64 >/dev/null 2>&1 || return 0
    blob=$(awk '/BEGIN ARGO TUNNEL TOKEN/{f=1;next}/END ARGO TUNNEL TOKEN/{f=0}f' "$CF_CERT" 2>/dev/null | tr -d '[:space:]' || true)
    [ -n "$blob" ] || return 0
    json=$(printf '%s' "$blob" | base64 -d 2>/dev/null || true)
    [ -n "$json" ] || return 0
    zid=$(printf '%s' "$json" | grep -oiE '"zoneID"[[:space:]]*:[[:space:]]*"[^"]+"' | head -n1 | sed -E 's/.*"([^"]+)"$/\1/' || true)
    tok=$(printf '%s' "$json" | grep -oiE '"apiToken"[[:space:]]*:[[:space:]]*"[^"]+"' | head -n1 | sed -E 's/.*"([^"]+)"$/\1/' || true)
    [ -n "$zid" ] && [ -n "$tok" ] || return 0
    name=$(wget -qO- --header="Authorization: Bearer $tok" "https://api.cloudflare.com/client/v4/zones/$zid" 2>/dev/null \
        | grep -oE '"name"[[:space:]]*:[[:space:]]*"[^"]+"' | head -n1 | sed -E 's/.*"([^"]+)"$/\1/' || true)
    [ -n "$name" ] && printf '%s' "$name"
    return 0
}

cf_detect_zone(){
    local z=""; z=$(cf_zone_from_config)
    [ -n "$z" ] && { printf '%s' "$z"; return 0; }
    if [ -f "$CF_ZONE_CACHE" ]; then
        z=$(head -n1 "$CF_ZONE_CACHE" 2>/dev/null || true)
        [ -n "$z" ] && { printf '%s' "$z"; return 0; }
    fi
    z=$(cf_zone_from_cert)
    [ -n "$z" ] && { printf '%s' "$z"; return 0; }
    return 0
}

cf_save_zone(){ mkdir -p "$HOME/.cloudflared"; printf '%s\n' "$1" > "$CF_ZONE_CACHE"; }

# cf_require_zone — ensure a root domain is known (ask once, cache it); prints it.
cf_require_zone(){
    local z; z=$(cf_detect_zone)
    if [ -z "$z" ]; then
        z=$(ask "Root domain (e.g. example.com)")
        [ -z "$z" ] && { c_warn "A root domain is required." >&2; return 1; }
    fi
    z="${z#*://}"; z="${z#.}"; z="${z%/}"
    cf_save_zone "$z"
    printf '%s' "$z"
}

get_tunnel_uuid(){
    local name="$1" uuid="" f
    uuid=$(cloudflared tunnel list 2>/dev/null | awk -v n="$name" '$2==n{print $1; exit}' || true)
    if [ -z "$uuid" ]; then
        f=$(ls -t "$HOME/.cloudflared"/*.json 2>/dev/null | head -n1 || true)
        [ -n "$f" ] && uuid=$(basename "$f" .json)
    fi
    printf '%s' "$uuid"
    return 0
}

# ---- hostname helpers ------------------------------------------------------
# Free Cloudflare Universal SSL only covers ONE level of subdomain, so we
# flatten nested names (a.b.zone -> a-b.zone).
flatten_host(){
    local input="$1" zone="$2" label
    input="${input%".$zone"}"; input="${input%.}"
    if [[ "$input" == *.* ]]; then label="${input//./-}"; else label="$input"; fi
    printf '%s.%s' "$label" "$zone"
}

ask_cf_hostname(){
    local prompt="$1" zone="$2" def="$3" input label
    input=$(ask "$prompt (just the part before .$zone)" "$def")
    input="${input%".$zone"}"; input="${input%.}"
    if [[ "$input" == *.* ]]; then
        label="${input//./-}"
        c_warn "'$input.$zone' is nested. Flattening to: $label.$zone" >&2
    else
        label="$input"
    fi
    printf '%s.%s' "$label" "$zone"
}

# ---- config.yml plumbing ---------------------------------------------------
cfg_tunnel_name(){ awk -F': ' '/^tunnel:/{print $2; exit}' "$CF_CONFIG" 2>/dev/null; }

cfg_routes(){
    [ -f "$CF_CONFIG" ] || return 0
    awk '/hostname:/ { line=$0; sub(/.*hostname:[ \t]*/,"",line); gsub(/[ \t]+$/,"",line); h=line }
         /service:[ \t]*tcp:\/\/localhost:/ {
             s=$0; sub(/.*localhost:/,"",s); gsub(/[^0-9].*/,"",s);
             if (h!="") { print h"\t"s; h="" }
         }' "$CF_CONFIG"
}

cfg_zone(){
    local first; first=$(cfg_routes | head -n1 | cut -f1)
    [ -n "$first" ] && printf '%s' "${first#*.}"
}

# cf_host_for_port <port> — the hostname currently routed to a local port.
cf_host_for_port(){
    local port="$1" host p
    while IFS=$'\t' read -r host p; do
        if [ "$p" = "$port" ]; then printf '%s' "$host"; return 0; fi
    done < <(cfg_routes)
    return 0
}

# cf_ensure_config — guarantee config.yml exists with a trailing 404 fallback
# (cf_add_route always inserts new hostnames ABOVE that fallback).
cf_ensure_config(){
    mkdir -p "$HOME/.cloudflared"
    if [ ! -s "$CF_CONFIG" ]; then
        printf 'ingress:\n  - service: http_status:404\n' > "$CF_CONFIG"
        return 0
    fi
    grep -q '^ingress:' "$CF_CONFIG" || printf 'ingress:\n' >> "$CF_CONFIG"
    grep -q 'service: http_status:404' "$CF_CONFIG" || printf '  - service: http_status:404\n' >> "$CF_CONFIG"
}

# cf_set_active_tunnel <name> — write tunnel: + credentials-file: into config.yml
# and remember it for this run (CF_TUNNEL).
cf_set_active_tunnel(){
    local name="$1" uuid cred
    [ -z "$name" ] && { c_warn "No tunnel name given."; return 1; }
    cf_ensure_config
    uuid=$(get_tunnel_uuid "$name")
    if [ -n "$uuid" ]; then cred="$HOME/.cloudflared/$uuid.json"; else cred="$HOME/.cloudflared/$name.json"; fi

    if grep -q '^tunnel:' "$CF_CONFIG"; then
        sed -i "s#^tunnel:.*#tunnel: $name#" "$CF_CONFIG"
    else
        sed -i "1i tunnel: $name" "$CF_CONFIG"
    fi
    if grep -q '^credentials-file:' "$CF_CONFIG"; then
        sed -i "s#^credentials-file:.*#credentials-file: $cred#" "$CF_CONFIG"
    else
        sed -i "/^tunnel:/a credentials-file: $cred" "$CF_CONFIG"
    fi

    export CF_TUNNEL="$name"
    c_ok "Active tunnel: $name"
    if [ -n "$uuid" ]; then c_info "UUID: $uuid"; else c_warn "No <uuid>.json for '$name' in ~/.cloudflared yet."; fi
}

# cf_require_ready — interactive gate: cloudflared present, account linked, and
# a tunnel selected in config.yml. Sets CF_TUNNEL. Returns non-zero on refusal.
cf_require_ready(){
    command -v cloudflared >/dev/null 2>&1 || { c_warn "cloudflared is not installed (pkg install cloudflared)."; return 1; }
    if ! cf_logged_in; then
        c_warn "This phone is not linked to a Cloudflare account yet."
        ask_yes_no "Link it now?" && cf_login_flow || return 1
        cf_logged_in || return 1
    fi
    local t; t=$(cfg_tunnel_name)
    if [ -z "$t" ]; then
        c_warn "No active tunnel is selected."
        c_info "Existing tunnels on this account:"
        cloudflared tunnel list 2>/dev/null | sed 's/^/     /' || echo "     (none)"
        local name; name=$(ask "Tunnel to use (name), or leave empty to create a new one" "")
        if [ -z "$name" ]; then
            name=$(ask "New tunnel name" "phone-ssh")
            cloudflared tunnel create "$name" || c_warn "Create failed (a tunnel with that name may already exist)."
        fi
        cf_set_active_tunnel "$name" || return 1
        t="$name"
    fi
    export CF_TUNNEL="$t"
    return 0
}

# ---- ingress add / remove / re-point ---------------------------------------
cf_add_route(){
    local host="$1" port="$2"
    cf_ensure_config
    if grep -q "hostname: $host" "$CF_CONFIG" 2>/dev/null; then
        c_info "Ingress for $host already present."
    else
        sed -i "/- service: http_status:404/i \ \ - hostname: $host\n    service: tcp://localhost:$port" "$CF_CONFIG"
        c_ok "Added ingress: $host -> localhost:$port"
    fi
}

# cf_remove_route <hostname> — delete the "- hostname:" line and its "service:"
# line. Temp file lives NEXT TO config.yml (Termux can't write /tmp).
cf_remove_route(){
    local host="$1" tmp
    [ -f "$CF_CONFIG" ] || return 0
    grep -q "hostname: $host" "$CF_CONFIG" 2>/dev/null || { c_info "No ingress for $host to remove."; return 0; }
    tmp="$CF_CONFIG.tmp.$$"
    awk -v h="$host" '
        $0 ~ ("- hostname: " h "$") { skip=1; next }
        skip==1 { skip=0; if ($0 ~ /service:[ \t]*tcp:\/\/localhost:/) next }
        { print }
    ' "$CF_CONFIG" > "$tmp" && mv "$tmp" "$CF_CONFIG"
    c_ok "Removed ingress for $host from config.yml"
}

# cf_update_route_port <hostname> <new-port> — repoint an existing ingress at a
# new local port (used when a VM's SSH port changes).
cf_update_route_port(){
    local host="$1" newport="$2" tmp
    [ -f "$CF_CONFIG" ] || return 0
    grep -q "hostname: $host" "$CF_CONFIG" 2>/dev/null || return 0
    tmp="$CF_CONFIG.tmp.$$"
    awk -v h="$host" -v p="$newport" '
        $0 ~ ("hostname: " h "$") { print; inblock=1; next }
        inblock==1 && $0 ~ /service:[ \t]*tcp:\/\/localhost:/ { sub(/localhost:[0-9]+/, "localhost:" p); inblock=0 }
        { print }
    ' "$CF_CONFIG" > "$tmp" && mv "$tmp" "$CF_CONFIG"
    c_ok "Re-pointed $host -> localhost:$newport"
}

# cf_route_dns <hostname> — create the CNAME that binds hostname to the tunnel.
# Handles the common "record with that host already exists" (code 1003) by
# offering --overwrite-dns; remembers the choice for the rest of the run.
cf_route_dns(){
    local host="$1" out="" flag=""
    [ "${CF_DNS_OVERWRITE:-0}" = "1" ] && flag="--overwrite-dns"

    if out=$(cloudflared tunnel route dns $flag "$CF_TUNNEL" "$host" 2>&1); then
        c_ok "DNS route set: $host"
        return 0
    fi

    if printf '%s' "$out" | grep -qiE 'already exists|record with that host|code: *1003'; then
        c_warn "A DNS record for $host already exists (leftover, or on another tunnel)."
        if [ "${CF_DNS_OVERWRITE:-0}" != "1" ] && ask_yes_no "Overwrite it so $host points at THIS tunnel ($CF_TUNNEL)?"; then
            export CF_DNS_OVERWRITE=1
            if out=$(cloudflared tunnel route dns --overwrite-dns "$CF_TUNNEL" "$host" 2>&1); then
                c_ok "DNS record overwritten: $host"
                return 0
            fi
        fi
    fi

    c_warn "DNS route for $host not created:"
    printf '%s\n' "$out" | sed 's/^/       /' >&2 || true
    return 0
}

# cf_tunnel_restart [tunnel] [session] — kill the tunnel's tmux session and
# start it fresh so it re-reads config.yml.
cf_tunnel_restart(){
    local tun="${1:-$CF_TUNNEL}" sess="${2:-$CF_SESSION}"
    tmux kill-session -t "=$sess" 2>/dev/null || true
    if tmux new -d -s "$sess" "cloudflared tunnel run $tun"; then
        c_ok "Cloudflare tunnel (re)started in session '$sess'."
    else
        c_warn "Could not start the tunnel (is tmux/cloudflared available?)."
    fi
}
