#!/usr/bin/env bash
# Install a versioned OpenSSH host fragment. Audience: human and agent.
set -Eeuo pipefail

spec=""
mode=dry-run
format=text
include='Include ~/.ssh/config.d/chain.conf'
marker='# Managed by install_sshconfig.sh; edit the spec and rerun.'
ssh_dir="$HOME/.ssh"
config="$ssh_dir/config"
fragment="$ssh_dir/config.d/chain.conf"
temp_dir=""

usage() {
    cat <<'HELP'
Usage: install_sshconfig.sh --spec FILE [--dry-run | --apply] [--json] [--help]

Audience: human and agent. FILE is an OpenSSH config fragment containing
Host entries. The script installs it at ~/.ssh/config.d/chain.conf and puts
one Include line at the top of ~/.ssh/config. Re-run after editing FILE.

--dry-run  Default. Validate the combined SSH config without changing files.
--apply    Install the fragment and Include line for the current user.
--json     Emit one JSON result object; diagnostics stay on stderr.
--help     Show this help.

Do not use sudo: this config belongs to the login user. Keep legacy SSH
algorithms inside the device's Host block, never under Host *. This script
does not copy private keys, accept host keys, or change the remote device.
HELP
}

emit() {
    if [[ "$format" == json ]]; then
        printf '{"schemaVersion":1,"state":"%s"}\n' "$1"
    else
        printf 'STATE: %s\nCONFIG: %s\nFRAGMENT: %s\n' "$1" "$config" "$fragment"
    fi
}

blocker() {
    printf 'BLOCKER: %s\nSAFE_NEXT_STEP: %s\n' "$1" "$2" >&2
    emit blocked
    exit 3
}

cleanup() {
    if [[ -n "$temp_dir" && -d "$temp_dir" ]]; then
        rm -rf -- "$temp_dir"
    fi
}
trap cleanup EXIT

while (($#)); do
    case "$1" in
        --spec)
            (($# >= 2)) || { usage >&2; exit 2; }
            spec="$2"
            shift 2
            ;;
        --dry-run) mode=dry-run; shift ;;
        --apply) mode=apply; shift ;;
        --json) format=json; shift ;;
        --help|-h) usage; exit 0 ;;
        *) printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
done

[[ -n "$spec" ]] || blocker '--spec FILE is required' \
    'Pass the SSH host fragment to install.'
[[ -f "$spec" && -r "$spec" ]] || blocker "SSH spec is unreadable: $spec" \
    'Create a readable OpenSSH Host fragment and retry.'
[[ ! -L "$config" && ! -L "$fragment" ]] || blocker 'SSH target is a symlink' \
    'Inspect ~/.ssh/config and ~/.ssh/config.d/chain.conf before retrying.'
grep -Eq '^[[:space:]]*Host[[:space:]]+' "$spec" || blocker 'SSH spec has no Host entry' \
    'Add at least one Host block to the spec.'
command -v ssh >/dev/null 2>&1 || blocker 'ssh is unavailable' \
    'Install the OpenSSH client before retrying.'

temp_dir="$(mktemp -d)"
candidate="$temp_dir/config"
candidate_fragment="$temp_dir/chain.conf"
{
    printf '%s\n' "$marker"
    sed -e '/^# Managed by install_sshconfig\.sh; edit the spec and rerun\.$/d' "$spec"
} > "$candidate_fragment"
{
    printf 'Include %s\n' "$candidate_fragment"
    if [[ -f "$config" ]]; then
        grep -Fvx "$include" "$config" || true
    fi
} > "$candidate"

if ! ssh -G -F "$candidate" localhost >/dev/null 2>"$temp_dir/ssh-check.log"; then
    sed -n '1,20p' "$temp_dir/ssh-check.log" >&2
    blocker 'OpenSSH rejected the combined configuration' \
        'Correct the spec or the existing ~/.ssh/config, then rerun --dry-run.'
fi

current_matches=false
if [[ -f "$fragment" && -f "$config" ]] &&
   cmp -s "$candidate_fragment" "$fragment" &&
   [[ "$(sed -n '1p' "$config")" == "$include" ]]; then
    current_matches=true
fi
if [[ "$mode" == dry-run ]]; then
    if [[ "$current_matches" == true ]]; then emit no-op; else emit ready; fi
    exit 0
fi
((EUID != 0)) || blocker '--apply must run as the login user, not root' \
    'Run this script without sudo so it updates your ~/.ssh/config.'
if [[ "$current_matches" == true ]]; then emit no-op; exit 0; fi

mkdir -p "$ssh_dir/config.d"
chmod 0700 "$ssh_dir" "$ssh_dir/config.d"
if [[ -e "$fragment" ]] && ! grep -Fxq "$marker" "$fragment"; then
    blocker "$fragment already contains unmanaged content" \
        'Move that file aside or choose a clean target after inspecting it.'
fi
previous_fragment="$temp_dir/previous-fragment"
previous_config="$temp_dir/previous-config"
had_fragment=false
had_config=false
if [[ -f "$fragment" ]]; then cp -p "$fragment" "$previous_fragment"; had_fragment=true; fi
if [[ -f "$config" ]]; then cp -p "$config" "$previous_config"; had_config=true; fi

install -m 0600 "$candidate_fragment" "$fragment"
{
    printf '%s\n' "$include"
    if [[ "$had_config" == true ]]; then
        grep -Fvx "$include" "$previous_config" || true
    fi
} > "$temp_dir/final-config"
if ! install -m 0600 "$temp_dir/final-config" "$config"; then
    if [[ "$had_fragment" == true ]]; then
        install -m 0600 "$previous_fragment" "$fragment"
    else
        rm -f -- "$fragment"
    fi
    blocker 'could not install ~/.ssh/config; fragment restored' \
        'Inspect directory permissions and retry.'
fi
if ! ssh -G -F "$config" localhost >/dev/null 2>"$temp_dir/ssh-check.log"; then
    if [[ "$had_config" == true ]]; then install -m 0600 "$previous_config" "$config"; else rm -f -- "$config"; fi
    if [[ "$had_fragment" == true ]]; then install -m 0600 "$previous_fragment" "$fragment"; else rm -f -- "$fragment"; fi
    sed -n '1,20p' "$temp_dir/ssh-check.log" >&2
    blocker 'installed SSH config failed readback; previous files restored' \
        'Correct the spec and rerun --dry-run.'
fi
emit applied
