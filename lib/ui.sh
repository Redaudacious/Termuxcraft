#!/bin/bash
# lib/ui.sh - Interface & display helpers
#
# NOTE: any function whose OUTPUT is captured with $( ) must send its
# prompts/warnings to stderr, otherwise they end up inside the captured value.

c_ok(){   printf "  \033[32m[OK]\033[0m   %s\n" "$*"; }
c_info(){ printf "  \033[36m[INFO]\033[0m %s\n" "$*"; }
c_warn(){ printf "  \033[33m[!]\033[0m    %s\n" "$*"; }
c_err(){  printf "  \033[31m[ERR]\033[0m  %s\n" "$*" >&2; exit 1; }
c_head(){ printf "\n\033[1;35m=== %s ===\033[0m\n" "$*"; }
title(){  c_head "$@"; }
c_on(){   printf "\033[32m%s\033[0m" "$*"; }
c_off(){  printf "\033[90m%s\033[0m" "$*"; }

ask(){
    local prompt="$1" default="${2:-}" reply
    if [ -n "$default" ]; then
        read -r -p "  $prompt [$default]: " reply
        echo "${reply:-$default}"
    else
        read -r -p "  $prompt: " reply
        echo "$reply"
    fi
}

ask_yes_no(){
    local prompt="$1" reply
    read -r -p "  $prompt (y/N): " reply
    case "$reply" in [yY]*) return 0;; *) return 1;; esac
}

# ask_secret <prompt> — hidden input, asked twice; echoes the password.
ask_secret(){
    local prompt="$1" p1 p2
    while true; do
        read -r -s -p "  $prompt: " p1; echo "" >&2
        if [ -z "$p1" ]; then echo "  [!] Empty password, try again." >&2; continue; fi
        read -r -s -p "  Repeat to confirm: " p2; echo "" >&2
        if [ "$p1" = "$p2" ]; then printf '%s' "$p1"; return 0; fi
        echo "  [!] Passwords do not match. Try again." >&2
    done
}

# valid_name <name> — accept only names that are safe in sed, tmux, file paths
# AND valid as a DNS label (so a default subdomain stays correct).
valid_name(){ [[ "$1" =~ ^[a-z0-9][a-z0-9-]{0,19}$ ]]; }

# valid_port <n> — a usable, non-privileged TCP port.
valid_port(){ [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1024 ] && [ "$1" -le 65535 ]; }

# normalize_ram <input> — prints a canonical heap size (e.g. 2G / 3072M) or
# nothing if the input is invalid. Plain numbers are treated as GIGABYTES.
normalize_ram(){
    local r; r=$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]' | tr -d '[:space:]')
    r="${r%B}"                                   # allow 2GB / 2048MB
    case "$r" in
        *G) [[ "${r%G}" =~ ^[0-9]+$ ]] && [ "${r%G}" -ge 1 ]   && printf '%sG' "${r%G}" ;;
        *M) [[ "${r%M}" =~ ^[0-9]+$ ]] && [ "${r%M}" -ge 512 ] && printf '%sM' "${r%M}" ;;
        *)  [[ "$r" =~ ^[0-9]+$ ]]     && [ "$r" -ge 1 ]       && printf '%sG' "$r" ;;
    esac
}

# ask_ram [default] — asks until a valid RAM value is given; echoes e.g. "2G".
ask_ram(){
    local def="${1:-2}" input ram
    while true; do
        input=$(ask "RAM for the Minecraft server (GB, or e.g. 4G / 3072M)" "$def")
        ram=$(normalize_ram "$input")
        if [ -n "$ram" ]; then printf '%s' "$ram"; return 0; fi
        c_warn "Invalid RAM value. Examples: 2  |  4G  |  3072M  (min 512M)." >&2
    done
}

ask_ssh_key(){
    local prompt="$1" reply cleaned
    while true; do
        read -r -p "  $prompt (Paste key or type 'help'): " reply
        cleaned=$(echo "$reply" | tr -d "'\"" | tr '[:upper:]' '[:lower:]')

        if [ "$cleaned" = "help" ]; then
            printf "\n  \033[36m--- SSH KEY TUTORIAL ---\033[0m\n" >&2
            echo "  1. Open a terminal on your PC." >&2
            echo "  2. Run this command: ssh-keygen -t ed25519" >&2
            echo "  3. Press Enter for all prompts." >&2
            echo "  4. View key: cat ~/.ssh/id_ed25519.pub (Mac/Linux) or type %USERPROFILE%\.ssh\id_ed25519.pub (Win)" >&2
            echo "  5. Paste the output here." >&2
            printf "  \033[36m------------------------\033[0m\n\n" >&2
        elif [[ "$reply" =~ ^ssh- ]]; then
            echo "$reply"; return
        else
            echo "  [!] Invalid key format. It must start with 'ssh-'. Try again." >&2
        fi
    done
}
