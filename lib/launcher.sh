#!/bin/bash
# lib/launcher.sh - Turn commands.sh into shell commands you can type directly:
#   Termuxcraft / termuxcraft  -> the global (phone-admin) menu
#   <vm-name>                  -> that VM's own (VM-admin) menu
#
# Each wrapper is a tiny script in $BIN_DIR carrying $WRAPPER_MARKER, so we can
# find and delete exactly our files (grep the marker) and never clobber a real
# command. $COMMANDS_SH is exported by the entry script (install.sh/commands.sh/
# bootstrap.sh) so wrappers point at the right absolute path.

wrapper_path(){ printf '%s/%s' "$BIN_DIR" "$1"; }

_is_our_wrapper(){ [ -f "$1" ] && grep -qF -- "$WRAPPER_MARKER" "$1" 2>/dev/null; }

# name_is_free_for_wrapper <name> — 0 if we can safely create a command with
# this name, 1 if it would shadow/overwrite something (a real binary, a builtin,
# a function, an alias, or the reserved launcher names).
name_is_free_for_wrapper(){
    local name="$1" p t resolved
    case "$name" in "$LAUNCHER_NAME"|"$LAUNCHER_ALIAS") return 1;; esac
    p="$(wrapper_path "$name")"
    if [ -e "$p" ] && ! _is_our_wrapper "$p"; then return 1; fi
    t=$(type -t "$name" 2>/dev/null || true)
    case "$t" in builtin|keyword|alias|function) return 1;; esac
    if [ "$t" = "file" ]; then
        resolved=$(command -v "$name" 2>/dev/null || true)
        if [ -n "$resolved" ] && ! _is_our_wrapper "$resolved"; then return 1; fi
    fi
    return 0
}

# wrapper_write <name> [args-for-commands.sh...] — (over)write one wrapper.
wrapper_write(){
    local name="$1"; shift
    local p; p="$(wrapper_path "$name")"
    {
        printf '#!/data/data/com.termux/files/usr/bin/bash\n'
        printf '%s\n' "$WRAPPER_MARKER"
        printf 'exec bash "%s" %s "$@"\n' "$COMMANDS_SH" "$*"
    } > "$p"
    chmod +x "$p"
}

wrapper_install_launcher(){
    wrapper_write "$LAUNCHER_NAME"
    [ -n "$LAUNCHER_ALIAS" ] && wrapper_write "$LAUNCHER_ALIAS"
    c_ok "Command installed: $LAUNCHER_NAME${LAUNCHER_ALIAS:+ / $LAUNCHER_ALIAS}"
}

# wrapper_install_vm <name> — command '<name>' opens that VM's admin menu.
wrapper_install_vm(){
    local name="$1"
    wrapper_write "$name" vmadmin "$name"
    c_ok "Command installed: $name  (opens the '$name' VM menu)"
}

wrapper_remove(){
    local name="$1" p; p="$(wrapper_path "$name")"
    if [ -e "$p" ] && _is_our_wrapper "$p"; then rm -f "$p"; fi
}

# wrappers_relink_all — (re)install the launcher and a wrapper for every VM.
# Safe to run repeatedly (e.g. right after a fresh git clone).
wrappers_relink_all(){
    wrapper_install_launcher
    local n
    while read -r n; do [ -n "$n" ] && wrapper_install_vm "$n"; done < <(list_vm_names)
}

# wrappers_remove_all — delete every wrapper we ever created (marker-based).
wrappers_remove_all(){
    local f
    while IFS= read -r f; do
        [ -n "$f" ] && rm -f "$f"
    done < <(grep -lI -m1 -- "$WRAPPER_MARKER" "$BIN_DIR"/* 2>/dev/null || true)
}
