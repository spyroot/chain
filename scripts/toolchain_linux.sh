#!/usr/bin/env bash
# Ubuntu counterpart to toolchain_mac.sh. Audience: human and agent.
set -Eeuo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
manifest="$script_dir/../manifests/linux/apt-packages.txt"
npm_manifest="$script_dir/../manifests/linux/npm-globals.txt"
editor_manifest="$script_dir/../manifests/linux/editor-files.txt"
editor_source="$repo_root/manifests/default/dotfiles"
command_name=apply
mode=dry-run
format=auto
requested_mode=""
work_dir=""
declare -a packages=() missing=() unavailable=()
declare -a npm_packages=() npm_missing=()
declare -a editor_files=() editor_missing=()
declare -a editor_plugins_missing=()
declare -A seen=()
installed=0
npm_installed=0
editor_installed=0
target_user=""
target_home=""
target_group=""

usage() {
    cat <<'HELP'
Usage: toolchain_linux.sh [check | apply] [--manifest FILE]
                          [--npm-manifest FILE] [--editor-manifest FILE]
                          [--user NAME] [--confirm]
                          [--pretty | --json] [--help]
       toolchain_linux.sh [--dry-run | --apply] [--json] [--help]

Audience: human and agent. Run on Ubuntu. Packages and portable editor files
come from separate Linux manifests; the flags select other lists.
The no-argument command and "apply" without --confirm only show the plan.

check      Report drift and exit 1 when packages are missing.
apply      Plan only; --confirm installs the missing packages.
--dry-run  Existing alias for the plan (no changes).
--apply    Existing alias for apply --confirm; requires root.
--pretty   Human progress and summary, as on the macOS toolchain.
--json     Emit one JSON result object on stdout; diagnostics stay on stderr.
--help     Show this help.

In a terminal, output is pretty by default; when piped, it is JSON.
The script never installs Mac-only apps, touches Mac-only shell configuration,
deliberately upgrades already-installed apt packages, or reboots. Existing
editor files are backed up before replacement. Neovim plugins are restored
from the checked-in lazy-lock.json for the selected user; Vim plugins use
vim-plug. Apt may restart affected services; npm may run install hooks.
Run apply --confirm from a console after reviewing the plan and while no
other apt operation is active.
HELP
}

resolve_format() {
    if [[ "$format" == auto ]]; then
        if [[ -t 1 ]]; then format=pretty; else format=json; fi
    fi
}

bar() {
    local done_count="$1" total="$2" width=12 filled=0 i
    ((total == 0)) || filled=$((done_count * width / total))
    ((filled <= width)) || filled=$width
    for ((i = 0; i < width; i++)); do
        if ((i < filled)); then printf '▰'; else printf '▱'; fi
    done
}

preview() {
    local item shown=0 total=$#
    for item in "$@"; do
        ((shown < 8)) || break
        printf '      %s\n' "$item"
        ((shown += 1))
    done
    if ((total > shown)); then
        printf '      … and %d more (use --json for the full list)\n' \
            "$((total - shown))"
    fi
}

json_array() {
    local first=true item
    printf '['
    for item in "$@"; do
        if [[ "$first" == true ]]; then first=false; else printf ','; fi
        printf '"%s"' "$item"
    done
    printf ']'
}

emit() {
    local state="$1"
    if [[ "$format" == json ]]; then
        printf '{"schemaVersion":1,"command":"%s","state":"%s","mode":"%s","installed":%d,"missing":' \
            "$command_name" "$state" "$mode" "$installed"
        json_array "${missing[@]}"
        printf ',"unavailable":'
        json_array "${unavailable[@]}"
        printf ',"npmInstalled":%d,"npmMissing":' "$npm_installed"
        json_array "${npm_missing[@]}"
        printf ',"editorInstalled":%d,"editorMissing":' "$editor_installed"
        json_array "${editor_missing[@]}"
        printf ',"editorPluginsMissing":'
        json_array "${editor_plugins_missing[@]}"
        printf ',"user":"%s"' "$target_user"
        printf '}\n'
    else
        printf '🔗 chain linux %s — %s\n' "$command_name" "$state"
        if ((${#unavailable[@]})); then
            printf '  🚫 apt — %d unavailable\n' "${#unavailable[@]}"
            preview "${unavailable[@]}"
        elif ((${#missing[@]})); then
            printf '  📦 apt — %d installed, %d to install\n' \
                "$installed" "${#missing[@]}"
            preview "${missing[@]}"
        else
            printf '  ✅ apt — %d packages present\n' "$installed"
        fi
        if ((${#npm_missing[@]})); then
            printf '  🧩 npm — %d installed, %d to install\n' \
                "$npm_installed" "${#npm_missing[@]}"
            preview "${npm_missing[@]}"
        else
            printf '  ✅ npm — %d globals present\n' "$npm_installed"
        fi
        if ((${#editor_missing[@]})); then
            printf '  🖊️  editor — %d files present, %d to sync\n' \
                "$editor_installed" "${#editor_missing[@]}"
            preview "${editor_missing[@]}"
        else
            printf '  ✅ editor — %d files present\n' "$editor_installed"
        fi
        if ((${#editor_plugins_missing[@]})); then
            printf '  🧩 editor plugins — %d to restore\n' \
                "${#editor_plugins_missing[@]}"
            preview "${editor_plugins_missing[@]}"
        fi
        if [[ "$mode" == dry-run ]]; then
            printf '  ▫️  plan only — nothing changed; use apply --confirm to install\n'
        fi
    fi
}

blocker() {
    printf 'BLOCKER: %s\nSAFE_NEXT_STEP: %s\n' "$1" "$2" >&2
    emit blocked
    exit 3
}

if [[ "${1:-}" == check || "${1:-}" == apply ]]; then
    command_name="$1"
    shift
fi
while (($#)); do
    case "$1" in
        --manifest)
            (($# >= 2)) || { usage >&2; exit 2; }
            manifest="$2"
            shift 2
            ;;
        --npm-manifest)
            (($# >= 2)) || { usage >&2; exit 2; }
            npm_manifest="$2"
            shift 2
            ;;
        --editor-manifest)
            (($# >= 2)) || { usage >&2; exit 2; }
            editor_manifest="$2"
            shift 2
            ;;
        --user)
            (($# >= 2)) || { usage >&2; exit 2; }
            target_user="$2"
            shift 2
            ;;
        --dry-run)
            [[ "$requested_mode" != apply ]] || { usage >&2; exit 2; }
            mode=dry-run
            requested_mode=dry-run
            shift
            ;;
        --apply|--confirm)
            [[ "$requested_mode" != dry-run ]] || { usage >&2; exit 2; }
            mode=apply
            requested_mode=apply
            shift
            ;;
        --json) format=json; shift ;;
        --pretty) format=pretty; shift ;;
        --help|-h) usage; exit 0 ;;
        *) printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
done
resolve_format
[[ "$command_name" != check || "$mode" != apply ]] || {
    printf 'check cannot be combined with --apply or --confirm\n' >&2
    exit 2
}

[[ -r "$manifest" ]] || blocker "manifest is unreadable: $manifest" \
    "Pass --manifest FILE or restore manifests/linux/apt-packages.txt."
[[ -r "$npm_manifest" ]] || blocker "npm manifest is unreadable: $npm_manifest" \
    "Pass --npm-manifest FILE or restore manifests/linux/npm-globals.txt."
[[ -r "$editor_manifest" ]] || blocker "editor manifest is unreadable: $editor_manifest" \
    "Pass --editor-manifest FILE or restore manifests/linux/editor-files.txt."
[[ -r /etc/os-release ]] || blocker 'cannot identify the operating system' \
    'Run this script on Ubuntu.'
# shellcheck disable=SC1091
source /etc/os-release
[[ "${ID:-}" == ubuntu ]] || blocker "unsupported operating system: ${ID:-unknown}" \
    'Use toolchain_mac.sh on macOS, or run this tool on Ubuntu.'
for command in dpkg-query apt-cache; do
    command -v "$command" >/dev/null 2>&1 || blocker "missing $command" \
        'Restore the Ubuntu package-management tools before retrying.'
done

line_number=0
while IFS= read -r line || [[ -n "$line" ]]; do
    ((line_number += 1))
    line="${line%%#*}"
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    if [[ ! "$line" =~ ^[[:space:]]*([a-z0-9][a-z0-9+.-]*)[[:space:]]*$ ]]; then
        blocker "invalid package at manifest line $line_number" \
            'Use one Ubuntu package name per line, with optional comments.'
    fi
    package="${BASH_REMATCH[1]}"
    [[ -v seen[$package] ]] && continue
    seen[$package]=1
    packages+=("$package")
done < "$manifest"
((${#packages[@]})) || blocker 'package manifest is empty' \
    'Add at least one Ubuntu package to the manifest.'

seen=()
line_number=0
while IFS= read -r line || [[ -n "$line" ]]; do
    ((line_number += 1))
    line="${line%%#*}"
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    if [[ ! "$line" =~ ^[[:space:]]*(@[a-z0-9._-]+/)?[a-z0-9][a-z0-9._-]*[[:space:]]*$ ]]; then
        blocker "invalid npm package at manifest line $line_number" \
            'Use one npm package name per line, with optional comments.'
    fi
    package="${line//[[:space:]]/}"
    [[ -v seen[$package] ]] && continue
    seen[$package]=1
    npm_packages+=("$package")
done < "$npm_manifest"

if [[ -z "$target_user" ]]; then
    target_user="${SUDO_USER:-}"
    if [[ -z "$target_user" || "$target_user" == root ]]; then
        target_user="$(stat -c %U -- "$repo_root")"
    fi
fi
[[ "$target_user" =~ ^[a-z_][a-z0-9_-]*$ ]] || blocker \
    "invalid target user: $target_user" \
    'Pass --user with a local Ubuntu login name.'
passwd_record="$(getent passwd "$target_user" || true)"
[[ -n "$passwd_record" ]] || blocker "user does not exist: $target_user" \
    'Pass --user with an existing Ubuntu login.'
IFS=: read -r _ _ _ _ _ target_home _ <<< "$passwd_record"
[[ "$target_home" == /* && -d "$target_home" ]] || blocker \
    "home directory is unavailable for $target_user" \
    'Create the user home directory before running the toolchain.'
target_group="$(id -gn "$target_user")"

seen=()
line_number=0
while IFS= read -r line || [[ -n "$line" ]]; do
    ((line_number += 1))
    line="${line%%#*}"
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    if [[ ! "$line" =~ ^[[:space:]]*(\.[a-zA-Z0-9._/-]+)[[:space:]]*$ ]]; then
        blocker "invalid editor path at manifest line $line_number" \
            'Use one home-relative dotfile path per line.'
    fi
    editor_file="${BASH_REMATCH[1]}"
    [[ "$editor_file" != *..* && "$editor_file" != */. && "$editor_file" != */ ]] || \
        blocker "unsafe editor path: $editor_file" \
            'Remove parent traversal and directory entries from the manifest.'
    [[ -v seen[$editor_file] ]] && continue
    seen[$editor_file]=1
    [[ -f "$editor_source/$editor_file" && ! -L "$editor_source/$editor_file" ]] || \
        blocker "editor source is missing: $editor_file" \
            'Restore the corresponding file under manifests/default/dotfiles.'
    editor_files+=("$editor_file")
    target_file="$target_home/$editor_file"
    [[ ! -L "$target_file" && ! -d "$target_file" ]] || blocker \
        "editor target is not a regular file: $target_file" \
        'Inspect the existing path and choose how to preserve it.'
    if [[ -f "$target_file" ]] && cmp -s -- "$editor_source/$editor_file" "$target_file"; then
        ((editor_installed += 1))
    else
        editor_missing+=("$editor_file")
    fi
done < "$editor_manifest"
if [[ -f "$target_home/.config/nvim/init.lua" || \
      " ${editor_files[*]} " == *' .config/nvim/init.lua '* ]]; then
    if [[ ! -d "$target_home/.local/share/nvim/lazy/lazy.nvim" || \
          " ${editor_missing[*]} " == *' .config/nvim/'* ]]; then
        editor_plugins_missing+=(neovim)
    fi
fi
if [[ -f "$target_home/.vimrc" || " ${editor_files[*]} " == *' .vimrc '* ]]; then
    if [[ ! -d "$target_home/.vim/plugged/iceberg.vim" || \
          -z "$(find "$target_home/.vim/plugged/YouCompleteMe/third_party/ycmd" \
              -maxdepth 1 -name 'ycm_core*.so' -print -quit 2>/dev/null)" || \
          " ${editor_missing[*]} " == *' .vimrc '* ]]; then
        editor_plugins_missing+=(vim)
    fi
fi

check_npm() {
    local npm_bin npm_root package
    npm_missing=()
    npm_installed=0
    npm_bin=/usr/bin/npm
    if [[ ! -x "$npm_bin" ]]; then
        npm_missing=("${npm_packages[@]}")
        return
    fi
    if ! npm_root="$("$npm_bin" root --global 2>/dev/null)"; then
        blocker 'npm global inventory failed' \
            'Repair /usr/bin/npm or its configuration, then rerun --dry-run.'
    fi
    [[ "$npm_root" == /* ]] || blocker 'npm returned an invalid global root' \
        'Inspect /usr/bin/npm root --global before applying packages.'
    for package in "${npm_packages[@]}"; do
        if [[ -f "$npm_root/$package/package.json" ]]; then
            ((npm_installed += 1))
        else
            npm_missing+=("$package")
        fi
    done
}

for package in "${packages[@]}"; do
    if [[ "$(dpkg-query -W -f='${Status}' "$package" 2>/dev/null || true)" == 'install ok installed' ]]; then
        ((installed += 1))
        continue
    fi
    # Consume all apt-cache output: early awk exit can SIGPIPE under pipefail.
    candidate="$(apt-cache policy "$package" | awk '/^[[:space:]]*Candidate: / && !seen++ {print $2}')"
    if [[ -z "$candidate" || "$candidate" == '(none)' ]]; then
        unavailable+=("$package")
    else
        missing+=("$package")
    fi
done
check_npm

if ((${#unavailable[@]})); then
    blocker "${#unavailable[@]} package(s) have no apt candidate" \
        'Refresh apt indexes or correct the Linux package manifest.'
fi
if [[ "$command_name" == check ]]; then
    if ((${#missing[@]} || ${#npm_missing[@]} || \
          ${#editor_missing[@]} || ${#editor_plugins_missing[@]})); then
        emit drift
        exit 1
    fi
    emit in-sync
    exit 0
fi
if [[ "$mode" == dry-run ]]; then
    if ((${#missing[@]} || ${#npm_missing[@]} || \
          ${#editor_missing[@]} || ${#editor_plugins_missing[@]})); then
        emit ready
    else
        emit no-op
    fi
    exit 0
fi
((EUID == 0)) || blocker '--apply requires root' \
    'Review --dry-run, then run sudo scripts/toolchain_linux.sh --apply.'
command -v apt-get >/dev/null 2>&1 || blocker 'apt-get is missing' \
    'Restore apt-get before applying packages.'
if ((${#missing[@]} == 0 && ${#npm_missing[@]} == 0 && \
      ${#editor_missing[@]} == 0 && ${#editor_plugins_missing[@]} == 0)); then
    emit no-op
    exit 0
fi

if ! work_dir="$(mktemp -d)"; then
    blocker 'cannot create a temporary log directory' \
        'Check free space and permissions under the system temporary directory.'
fi
trap '[[ -z "$work_dir" ]] || rm -rf -- "$work_dir"' EXIT
actions_total=$(( (${#missing[@]} > 0) + ${#npm_missing[@]} + \
    (${#editor_missing[@]} > 0) + ${#editor_plugins_missing[@]} ))
actions_done=0

action_start() {
    local label="$1" next=$((actions_done + 1))
    if [[ "$format" == pretty ]]; then
        printf '  %s [%d/%d] %s ' \
            "$(bar "$next" "$actions_total")" "$next" "$actions_total" "$label"
    else
        printf 'apply: %s\n' "$label" >&2
    fi
}

action_end() {
    local status="$1"
    ((actions_done += 1))
    if [[ "$format" == pretty ]]; then
        if [[ "$status" == ok ]]; then printf '✅\n'; else printf '❌\n'; fi
    fi
}

if ((${#missing[@]})); then
    if ! DEBIAN_FRONTEND=noninteractive APT_LISTCHANGES_FRONTEND=none \
        apt-get -s --no-remove --no-upgrade --no-install-recommends \
        install "${missing[@]}" >"$work_dir/apt-plan.log" 2>&1; then
        tail -20 "$work_dir/apt-plan.log" >&2
        printf 'BLOCKER: apt simulation requires an unsafe package change\nSAFE_NEXT_STEP: revise the manifest or inspect apt dependencies before retrying.\n' >&2
        emit blocked
        exit 3
    fi
    action_start "apt install ${#missing[@]} missing package(s)"
    if ! DEBIAN_FRONTEND=noninteractive APT_LISTCHANGES_FRONTEND=none \
        apt-get -o DPkg::Lock::Timeout=0 \
        -o Dpkg::Options::=--force-confold \
        install -y --no-remove --no-upgrade --no-install-recommends \
        "${missing[@]}" \
        </dev/null >"$work_dir/apt.log" 2>&1; then
        action_end failed
        tail -20 "$work_dir/apt.log" >&2
        printf 'BLOCKER: apt-get failed\nSAFE_NEXT_STEP: inspect apt output; do not rerun until the package manager is healthy.\n' >&2
        emit failed
        exit 1
    fi
    for package in "${missing[@]}"; do
        if [[ "$(dpkg-query -W -f='${Status}' "$package" 2>/dev/null || true)" != 'install ok installed' ]]; then
            action_end failed
            printf 'BLOCKER: %s was not installed\nSAFE_NEXT_STEP: inspect dpkg and apt logs.\n' "$package" >&2
            emit failed
            exit 1
        fi
    done
    installed=$((installed + ${#missing[@]}))
    missing=()
    action_end ok
fi
check_npm
if ((${#npm_missing[@]})); then
    [[ -x /usr/bin/npm ]] || blocker 'npm is missing after apt installation' \
        'Add npm to the apt manifest, then rerun --dry-run.'
    for package in "${npm_missing[@]}"; do
        action_start "npm install -g $package"
        if ! /usr/bin/npm install --global --no-audit --no-fund "$package" \
            </dev/null >"$work_dir/npm.log" 2>&1; then
            action_end failed
            tail -20 "$work_dir/npm.log" >&2
            printf 'BLOCKER: npm failed for %s\nSAFE_NEXT_STEP: inspect npm output, then rerun --dry-run.\n' "$package" >&2
            emit failed
            exit 1
        fi
        action_end ok
    done
    check_npm
    if ((${#npm_missing[@]})); then
        printf 'BLOCKER: npm read-back still shows missing packages\nSAFE_NEXT_STEP: inspect the global npm prefix and PATH.\n' >&2
        emit failed
        exit 1
    fi
fi
if ((${#editor_missing[@]})); then
    backup_dir=""
    action_start "sync ${#editor_missing[@]} editor file(s) for $target_user"
    for editor_file in "${editor_missing[@]}"; do
        source_file="$editor_source/$editor_file"
        target_file="$target_home/$editor_file"
        if [[ -e "$target_file" ]]; then
            if [[ -z "$backup_dir" ]]; then
                backup_parent="$target_home/.local/share/chain-backups"
                install -d -m 0755 -o "$target_user" -g "$target_group" \
                    "$backup_parent"
                backup_dir="$(mktemp -d "$backup_parent/toolchain-linux.XXXXXX")"
                chown "$target_user:$target_group" "$backup_dir"
            fi
            install -d -m 0700 -o "$target_user" -g "$target_group" \
                "$backup_dir/$(dirname "$editor_file")"
            cp -p -- "$target_file" "$backup_dir/$editor_file"
        fi
        install -d -m 0755 -o "$target_user" -g "$target_group" \
            "$(dirname "$target_file")"
        install -m 0644 -o "$target_user" -g "$target_group" \
            "$source_file" "$target_file"
    done
    editor_installed=$((editor_installed + ${#editor_missing[@]}))
    editor_missing=()
    action_end ok
    if [[ -n "$backup_dir" ]]; then
        printf 'editor: replaced files backed up at %s\n' "$backup_dir" >&2
    fi
fi
command -v runuser >/dev/null 2>&1 || blocker 'runuser is missing' \
    'Restore util-linux before installing editor plugins for another user.'
for editor_plugin in "${editor_plugins_missing[@]}"; do
    case "$editor_plugin" in
        neovim)
            action_start "restore Neovim plugins for $target_user"
            if ! timeout 900 runuser -u "$target_user" -- \
                env HOME="$target_home" /usr/bin/nvim --headless \
                '+Lazy! restore' '+qa' \
                </dev/null >"$work_dir/nvim.log" 2>&1; then
                action_end failed
                tail -20 "$work_dir/nvim.log" >&2
                printf 'FAILED: Neovim plugin restore; inspect the log and rerun apply.\n' >&2
                emit failed
                exit 1
            fi
            if [[ ! -d "$target_home/.local/share/nvim/lazy/lazy.nvim" ]]; then
                action_end failed
                printf 'FAILED: Neovim plugin manager was not installed.\n' >&2
                emit failed
                exit 1
            fi
            lock_source="$editor_source/.config/nvim/lazy-lock.json"
            lock_target="$target_home/.config/nvim/lazy-lock.json"
            if ! lazy_pin="$(jq -er \
                '."lazy.nvim".commit | select(test("^[0-9a-f]{40}$"))' \
                "$lock_source")"; then
                action_end failed
                printf 'FAILED: checked-in Neovim lock has no valid lazy.nvim commit.\n' >&2
                emit failed
                exit 1
            fi
            lazy_dir="$target_home/.local/share/nvim/lazy/lazy.nvim"
            lazy_head="$(git -C "$lazy_dir" rev-parse HEAD)"
            if [[ "$lazy_head" != "$lazy_pin" ]] || \
                ! cmp -s -- "$lock_source" "$lock_target"; then
                if ! timeout 120 runuser -u "$target_user" -- \
                    git -C "$lazy_dir" checkout --detach --quiet "$lazy_pin" \
                    >"$work_dir/nvim-pin.log" 2>&1; then
                    action_end failed
                    tail -20 "$work_dir/nvim-pin.log" >&2
                    printf 'FAILED: cannot select the manifest-pinned lazy.nvim commit.\n' >&2
                    emit failed
                    exit 1
                fi
                install -m 0644 -o "$target_user" -g "$target_group" \
                    "$lock_source" "$lock_target"
                if ! timeout 900 runuser -u "$target_user" -- \
                    env HOME="$target_home" /usr/bin/nvim --headless \
                    '+Lazy! restore' '+qa' \
                    </dev/null >"$work_dir/nvim-pinned.log" 2>&1; then
                    action_end failed
                    tail -20 "$work_dir/nvim-pinned.log" >&2
                    printf 'FAILED: pinned Neovim plugin restore; inspect the log.\n' >&2
                    emit failed
                    exit 1
                fi
            fi
            if ! cmp -s -- "$lock_source" "$lock_target" || \
                [[ "$(git -C "$lazy_dir" rev-parse HEAD)" != "$lazy_pin" ]]; then
                action_end failed
                printf 'FAILED: Neovim lockfile or manager still differs from the manifest.\n' >&2
                emit failed
                exit 1
            fi
            action_end ok
            ;;
        vim)
            action_start "install Vim plugins for $target_user"
            if [[ ! -d "$target_home/.vim/plugged/iceberg.vim" ]]; then
                install -d -m 0755 -o "$target_user" -g "$target_group" \
                    "$target_home/.vim/plugged"
                if ! timeout 120 runuser -u "$target_user" -- \
                    env HOME="$target_home" git clone --depth 1 \
                    https://github.com/cocopon/iceberg.vim \
                    "$target_home/.vim/plugged/iceberg.vim" \
                    </dev/null >"$work_dir/vim-theme.log" 2>&1; then
                    action_end failed
                    tail -20 "$work_dir/vim-theme.log" >&2
                    printf 'FAILED: Vim theme bootstrap; inspect the log and rerun apply.\n' >&2
                    emit failed
                    exit 1
                fi
            fi
            if ! timeout 900 runuser -u "$target_user" -- \
                env HOME="$target_home" /usr/bin/vim -es -n \
                -Nu "$target_home/.vimrc" \
                -c 'PlugInstall --sync' -c 'qa!' \
                </dev/null >"$work_dir/vim.log" 2>&1; then
                action_end failed
                tail -20 "$work_dir/vim.log" >&2
                printf 'FAILED: Vim plugin install; inspect the log and rerun apply.\n' >&2
                emit failed
                exit 1
            fi
            if [[ ! -d "$target_home/.vim/plugged/iceberg.vim" ]]; then
                action_end failed
                printf 'FAILED: Vim plugins were not installed.\n' >&2
                emit failed
                exit 1
            fi
            ycm_dir="$target_home/.vim/plugged/YouCompleteMe"
            if [[ -z "$(find "$ycm_dir/third_party/ycmd" -maxdepth 1 \
                -name 'ycm_core*.so' -print -quit 2>/dev/null)" ]]; then
                # The child shell expands its positional argument.
                # shellcheck disable=SC2016
                if ! timeout 1800 runuser -u "$target_user" -- \
                    /bin/bash -c \
                    'cd "$1" && exec env PATH=/usr/bin:/bin:/usr/local/bin /usr/bin/python3 install.py --clangd-completer' \
                    _ "$ycm_dir" \
                    </dev/null >"$work_dir/ycm.log" 2>&1; then
                    action_end failed
                    tail -20 "$work_dir/ycm.log" >&2
                    printf 'FAILED: YouCompleteMe native build; inspect the log.\n' >&2
                    emit failed
                    exit 1
                fi
            fi
            if [[ -z "$(find "$ycm_dir/third_party/ycmd" -maxdepth 1 \
                -name 'ycm_core*.so' -print -quit 2>/dev/null)" ]]; then
                action_end failed
                printf 'FAILED: YouCompleteMe ycm_core is still missing.\n' >&2
                emit failed
                exit 1
            fi
            action_end ok
            ;;
    esac
done
editor_plugins_missing=()
emit applied
