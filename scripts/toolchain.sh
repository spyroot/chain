#!/bin/bash
# toolchain.sh — capture, check, and apply a macOS toolchain manifest so any
# of my macs can be brought to the same brew/conda/rustup/npm setup.
#
# Audience: both (agent | human).
#
# NOTE on the shebang: /bin/bash (3.2) on purpose, deviating from the usual
# brew-bash rule, for two verified reasons: (1) `apply` must run on a FRESH
# mac where Homebrew's bash does not exist yet; (2) brew bash 5.3.15
# intermittently SIGSEGVs running this script's pipelines (3/60 repro loops,
# 2026-08-11) while /bin/bash was 0/60. So: no associative arrays, no
# mapfile, no bash-4isms anywhere in this file.
#
# Contract (agent-grade):
#   - Non-interactive: never prompts; mutation requires --confirm.
#   - Idempotent: apply only installs what is missing; safe to re-run blind.
#   - stdout = one JSON object per run when piped (a {"status":"error"}
#     object on fatal failures); on a TTY a human-pretty rendering
#     replaces it (--json restores the JSON contract, --pretty forces the
#     human one). All diagnostics go to stderr.
#   - Exit codes: 0 ok/in-sync; 1 drift or action failure; 2 usage error;
#     3 BLOCKER (missing prerequisite — SAFE_NEXT_STEP printed to stderr).
#   - Zero hidden state: input is the manifest dir + flags + CHAIN_* env
#     overrides only.
set -euo pipefail

VERSION="0.6.0"

SCRIPT_PATH="$0"
case "$SCRIPT_PATH" in
/*) : ;;
*) SCRIPT_PATH="$(pwd)/$SCRIPT_PATH" ;;
esac
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

MANIFEST_DIR="$REPO_ROOT/manifests/default"
COMPONENTS="brew conda rustup npm dotfiles frameworks"
CONFIRM=0
ONLY_ITEMS=""
SKIP_ITEMS=""
WORKDIR=""
CURRENT_CMD=""
JSON_EMITTED=0
FORCE_MODE=""
PRETTY=0
ACTION_N=0
ACTION_TOTAL=0

# ---------------------------------------------------------------- logging ---
log() { printf '%s\n' "$*" >&2; }

# ----------------------------------------------------------- pretty output ---
# On a terminal the tool talks to a human: icons, progress, no JSON. On a
# pipe (agents, scripts) stdout stays exactly one JSON object per run.
# --pretty / --json force either mode.
resolve_pretty() {
	case "$FORCE_MODE" in
	json) PRETTY=0 ;;
	pretty) PRETTY=1 ;;
	*) if [ -t 1 ]; then PRETTY=1; else PRETTY=0; fi ;;
	esac
}
ui() {
	[ "$PRETTY" -eq 1 ] || return 0
	printf '%s\n' "$*"
}
uin() {
	[ "$PRETTY" -eq 1 ] || return 0
	printf '%s' "$*"
}
icon_of() {
	case "$1" in
	brew) printf '🍺' ;;
	conda) printf '🐍' ;;
	rustup) printf '🦀' ;;
	npm) printf '📦' ;;
	dotfiles) printf '🏠' ;;
	frameworks) printf '🧩' ;;
	esac
}
bar() {
	# $1 = done, $2 = total -> a ▰▰▰▱▱-style 12-slot progress bar
	local w=12 fill=0 i=0 out=""
	[ "$2" -gt 0 ] && fill=$(($1 * w / $2))
	[ "$fill" -gt "$w" ] && fill=$w
	while [ "$i" -lt "$w" ]; do
		if [ "$i" -lt "$fill" ]; then out="${out}▰"; else out="${out}▱"; fi
		i=$((i + 1))
	done
	printf '%s' "$out"
}

usage() {
	cat <<EOF
toolchain.sh v$VERSION — replicate this mac's toolchain on another mac.
Audience: both (agent | human). JSON on stdout, diagnostics on stderr.

Usage:
  toolchain.sh capture [--manifest-dir DIR] [--components a,b,..]
  toolchain.sh check   [--manifest-dir DIR] [--components a,b,..]
  toolchain.sh apply   [--manifest-dir DIR] [--components a,b,..]
                       [--only x,y,..] [--skip x,y,..] [--confirm]
  toolchain.sh --help | --version

Subcommands:
  capture  Snapshot THIS machine into the manifest dir (source mac). Writes
           to a staging dir first; the manifest is only replaced (per
           component) after every export succeeded.
  check    Compare THIS machine against the manifest. Exit 0 in-sync, 1 on
           any drift: missing entries, extras, a tool that is missing or
           failing its inventory command (tool_missing/tool_error in JSON),
           or a selected component absent from the manifest
           (manifest_missing in JSON).
  apply    Install what the manifest has and this machine lacks (target mac).
           Without --confirm prints the plan only; --confirm executes it.
           Never uninstalls anything; extras are reported, not removed.
           Selected components absent from the manifest are skipped with a
           warning and listed in the manifest_missing JSON field.
           With --confirm, a missing Miniconda is bootstrapped automatically
           (official batch installer into ~/miniconda3: no prompts, no
           sudo). A missing rustup/npm is re-checked after the brew phase
           (which may have just installed them); components whose tool is
           still unavailable are skipped, listed in the blocked JSON field,
           and the run exits 3 after doing everything else it could.
           --only/--skip filter apply to (or away from) exact item names
           across all components, e.g.:
             apply --confirm --only jq,ripgrep
             apply --confirm --skip mactex-no-gui,libreoffice

Components: brew (taps+formulae+casks), conda (env yamls), rustup (channels),
            npm (global packages), dotfiles (paths listed in the manifest's
            dotfiles.list), frameworks (installs listed in the manifest's
            frameworks.list — e.g. oh-my-zsh, powerlevel10k, the claude
            CLI). dotfiles/frameworks activate only when their list file
            exists. Default: all.

Frameworks: frameworks.list is user-authored, one
'<home-relative-path>|<install command>' per line; apply --confirm runs
the command when the path is missing, check reports missing paths as
drift. capture never touches it.

Output: on a terminal, human-friendly progress with icons; on a pipe, one
JSON object on stdout. --pretty / --json force either mode.

Dotfiles: dotfiles.list is user-authored, one \$HOME-relative path per
line; '!path' lines exclude regenerable payload (e.g. .vim/plugged), '#'
comments allowed. capture refuses (exit 3) if gitleaks finds secrets in
the captured payload; gh yml oauth_token lines are always stripped. apply
overlay-copies listed paths and never deletes target-only files.

Env overrides (absolute paths to tool binaries, mainly for tests):
  CHAIN_BREW CHAIN_CONDA CHAIN_RUSTUP CHAIN_NPM
  CHAIN_CONDA_BOOTSTRAP (replaces the Miniconda bootstrap command)
  CHAIN_GITLEAKS (replaces gitleaks resolution for the dotfiles scan)

Exit codes: 0 ok/in-sync; 1 drift/failure; 2 usage; 3 blocker (prerequisite
missing — a BLOCKER/SAFE_NEXT_STEP pair is printed to stderr). Fatal
failures still emit one {"command":..,"status":"error","exit_code":..}
object on stdout.
EOF
}

die_usage() {
	log "ERROR: $*"
	log "Run with --help for usage."
	exit 2
}

blocker() {
	# $1 = what is missing, $2 = safe next step for the operator
	log "BLOCKER: $1"
	log "SAFE_NEXT_STEP: $2"
	exit 3
}

cleanup() {
	local rc=$? d
	# if capture died between moving an old payload dir aside and promoting
	# the new one, put the old data back before the workdir is removed
	for d in conda dotfiles; do
		if [ -n "$WORKDIR" ] && [ -d "$WORKDIR/$d.old" ] && [ ! -d "$MANIFEST_DIR/$d" ]; then
			mv "$WORKDIR/$d.old" "$MANIFEST_DIR/$d"
		fi
	done
	# keep the one-JSON-object-per-run contract even on fatal failures
	if [ -n "$CURRENT_CMD" ] && [ "$JSON_EMITTED" -eq 0 ] && [ "$rc" -ne 0 ] && [ "$PRETTY" -eq 0 ]; then
		printf '{"command":"%s","status":"error","exit_code":%s}\n' \
			"$CURRENT_CMD" "$rc"
	fi
	if [ -n "$WORKDIR" ]; then
		# captured payloads can contain read-only trees; make them
		# deletable so the workdir never leaks
		chmod -R u+w "$WORKDIR" 2>/dev/null || true
		rm -rf "$WORKDIR"
	fi
}
trap cleanup EXIT
# turn fatal signals into exits so the EXIT trap still removes $WORKDIR
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# ------------------------------------------------------------------- json ---
json_escape() {
	# control characters are invalid raw JSON: drop them, except tab -> \t
	printf '%s' "$1" | LC_ALL=C tr -d '\000-\010\012-\037' |
		sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e "s/$(printf '\t')/\\\\t/g"
}

# newline-separated list on stdin -> JSON array on stdout
json_array() {
	local first=1 line out="["
	while IFS= read -r line; do
		[ -z "$line" ] && continue
		[ $first -eq 0 ] && out="$out,"
		out="$out\"$(json_escape "$line")\""
		first=0
	done
	printf '%s]' "$out"
}

# ---------------------------------------------------------- tool resolvers ---
# Resolution order: CHAIN_* override -> PATH -> well-known locations.
resolve_tool() {
	local override="$1" name="$2" found=""
	shift 2
	if [ -n "$override" ]; then
		[ -x "$override" ] && {
			printf '%s' "$override"
			return 0
		}
		return 1
	fi
	found="$(command -v "$name" 2>/dev/null || true)"
	[ -n "$found" ] && {
		printf '%s' "$found"
		return 0
	}
	for c in "$@"; do
		[ -x "$c" ] && {
			printf '%s' "$c"
			return 0
		}
	done
	return 1
}

resolve_brew() {
	resolve_tool "${CHAIN_BREW:-}" brew /opt/homebrew/bin/brew /usr/local/bin/brew
}
resolve_conda() {
	resolve_tool "${CHAIN_CONDA:-}" conda "$HOME/miniconda3/bin/conda"
}
resolve_rustup() {
	resolve_tool "${CHAIN_RUSTUP:-}" rustup /opt/homebrew/bin/rustup "$HOME/.cargo/bin/rustup"
}
resolve_npm() {
	resolve_tool "${CHAIN_NPM:-}" npm /opt/homebrew/bin/npm /usr/local/bin/npm
}

blocker_brew() {
	# shellcheck disable=SC2016  # the $(curl ...) is a literal for the operator
	blocker "Homebrew not found (checked CHAIN_BREW, PATH, /opt/homebrew, /usr/local)" \
		'install Homebrew first: /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
}
blocker_conda() {
	blocker "conda not found (checked CHAIN_CONDA, PATH, ~/miniconda3/bin/conda)" \
		"install Miniconda to ~/miniconda3: curl -fsSL https://repo.anaconda.com/miniconda/Miniconda3-latest-MacOSX-\$(uname -m).sh -o /tmp/miniconda.sh && bash /tmp/miniconda.sh -b -p \$HOME/miniconda3"
}
blocker_rustup() {
	blocker "rustup not found (checked CHAIN_RUSTUP, PATH, /opt/homebrew, ~/.cargo)" \
		"install rustup via brew first: brew install rustup (or re-run apply with --components brew,rustup)"
}
blocker_npm() {
	blocker "npm not found (checked CHAIN_NPM, PATH, /opt/homebrew, /usr/local)" \
		"install node via brew first: brew install node (or re-run apply with --components brew,npm)"
}
blocker_inventory() {
	# $1 = tool, $2 = its inventory command
	blocker "$1 is present but its inventory command is failing, so installed state is unknown" \
		"run '$2' manually, fix the underlying error, then re-run"
}

# ------------------------------------------------------------ list helpers ---
# All list files are LC_ALL=C sorted (empty lines dropped) so comm(1) is
# valid on them.
sorted() { awk 'NF' | LC_ALL=C sort -u; }

# missing = in manifest, not on machine; extra = on machine, not in manifest
missing_of() { LC_ALL=C comm -23 "$1" "$2"; }
extra_of() { LC_ALL=C comm -13 "$1" "$2"; }

# "some/tap/foo" -> "foo"; brew list prints short names, Brewfiles may not
short_names() { awk -F/ '{print $NF}'; }

brewfile_names() {
	# $1 = Brewfile, $2 = kind (tap|brew|cask)
	awk -F'"' -v k="$2" '$0 ~ "^" k " " {print $2}' "$1" | sorted
}

brewfile_qualified() {
	# $1 = Brewfile, $2 = kind (brew|cask), $3 = short name -> full name
	awk -F'"' -v k="$2" -v s="$3" '
		$0 ~ "^" k " " {
			n = $2; short = n; sub(".*/", "", short)
			if (short == s) { print n; exit }
		}' "$1"
}

tap_has_remote() {
	# $1 = brew bin, $2 = tap name. brew tap-info --json reports
	# `"remote": null` (pretty-printed) for a local-only tap. On tap-info
	# failure, keep the tap — only positive evidence of no remote drops it.
	local info
	info="$("$1" tap-info "$2" --json </dev/null 2>/dev/null | tr -d ' \n')" || return 0
	case "$info" in
	*'"remote":null'*) return 1 ;;
	*) return 0 ;;
	esac
}

brew_replayable_taps() {
	# installed taps that have a git remote (the only ones apply can replay)
	local raw t
	raw="$("$1" tap 2>/dev/null)" || return 1
	printf '%s\n' "$raw" | while IFS= read -r t; do
		[ -z "$t" ] && continue
		if tap_has_remote "$1" "$t"; then printf '%s\n' "$t"; fi
	done | sorted
}

conda_env_names() {
	# conda env list -> names; drops base, comments, and nameless -p envs
	# (their first field is a path). Non-zero exit = inventory failure.
	local raw
	raw="$("$1" env list 2>/dev/null)" || return 1
	printf '%s\n' "$raw" |
		awk '!/^#/ && NF && $1 != "base" && $1 !~ /^\// {print $1}' | sorted
}

rustup_channels() {
	# "stable-aarch64-apple-darwin (active, default)" -> "stable"; drops
	# prose lines like "no installed toolchains" (channels have no spaces)
	local raw
	raw="$("$1" toolchain list 2>/dev/null)" || return 1
	printf '%s\n' "$raw" |
		sed -E -e 's/ \(.*\)$//' -e 's/-(aarch64|x86_64)-apple-darwin$//' |
		awk '!/ /' | sorted
}

npm_globals() {
	# parseable paths -> package names (scoped names keep their scope).
	# npm ls can exit non-zero yet still print a usable tree (peer-dep
	# noise), so only a failure WITH empty output counts as an error.
	local raw rc=0
	raw="$("$1" ls -g --depth=0 --parseable 2>/dev/null)" || rc=$?
	if [ "$rc" -ne 0 ] && [ -z "$raw" ]; then return 1; fi
	printf '%s\n' "$raw" | sed -n 's|.*/node_modules/||p' | awk '$0 != "npm"' | sorted
}

has_component() {
	case " $COMPONENTS " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

# ------------------------------------------------------- dotfiles helpers ---
# The dotfiles component activates only when <manifest>/dotfiles.list
# exists. The list is user-authored (never regenerated by capture): one
# $HOME-relative path per line; `!path` lines remove already-captured
# content (regenerable payload like .vim/plugged); `#` comments allowed.
dotfiles_configured() { [ -f "$MANIFEST_DIR/dotfiles.list" ]; }

# ------------------------------------------------------ frameworks helpers ---
# The frameworks component covers installs no package manager owns
# (oh-my-zsh, powerlevel10k, the claude CLI). It activates only when
# <manifest>/frameworks.list exists — user-authored lines of
# `<home-relative-path>|<install command>`; the command runs under apply
# --confirm when the path is missing.
frameworks_configured() { [ -f "$MANIFEST_DIR/frameworks.list" ]; }

framework_cmd_for() {
	# $1 = path -> its install command (everything after the first |)
	awk -v p="$1" 'index($0, p "|") == 1 {print substr($0, length(p) + 2); exit}' \
		"$MANIFEST_DIR/frameworks.list"
}

validate_dotfile_path() {
	# $HOME-relative, no absolute paths, no .. segments — a hostile
	# manifest must not be able to write outside $HOME
	case "$1" in
	/* | *..* | "") return 1 ;;
	*) return 0 ;;
	esac
}

dotfile_in_sync() {
	# one-way: everything in the manifest payload must exist identically in
	# the target; files existing only in the target (vim plugins, caches,
	# local additions) are NOT drift. diff "trouble" (rc>=2: unreadable
	# files, broken symlinks) counts as drift so an I/O error can never
	# fake an in-sync verdict.
	local out rc=0
	out="$(LC_ALL=C diff -rq "$1" "$2" 2>/dev/null)" || rc=$?
	[ "$rc" -ge 2 ] && return 1
	printf '%s\n' "$out" |
		awk -v a="Only in $2:" -v b="Only in $2/" \
			'NF && index($0, a) != 1 && index($0, b) != 1 {found = 1} END {exit found}'
}

sync_dotfile() {
	# overlay-copy one payload path into $HOME; never deletes target files
	local src="$MANIFEST_DIR/dotfiles/$1" dst="$HOME/$1"
	mkdir -p "$(dirname "$dst")"
	if [ -d "$src" ]; then
		mkdir -p "$dst"
		cp -Rp "$src/." "$dst/"
	else
		cp -p "$src" "$dst"
	fi
}

dotfiles_secret_scan() {
	# gitleaks (when installed) must find no secrets in the staged
	# dotfiles: leaks block capture so they can never reach the manifest
	# repo, which may be public. CHAIN_GITLEAKS overrides resolution
	# (tests); an override pointing nowhere means "not installed".
	local gl
	if [ -n "${CHAIN_GITLEAKS:-}" ]; then
		gl="$CHAIN_GITLEAKS"
		[ -x "$gl" ] || gl=""
	else
		gl="$(command -v gitleaks || true)"
	fi
	if [ -z "$gl" ]; then
		log "capture: WARN gitleaks not installed — dotfiles not secret-scanned"
		return 0
	fi
	if "$gl" dir "$1" --no-banner >&2 2>&1; then
		return 0
	fi
	blocker "secrets detected in captured dotfiles (gitleaks report above)" \
		"move the flagged values out of the file (e.g. into an untracked ~/.zshrc.local sourced from .zshrc) and re-run capture"
}

# ---------------------------------------------------------------- capture ---
cmd_capture() {
	local stage="$WORKDIR/stage"
	local brew_bin="" conda_bin="" rustup_bin="" npm_bin="" e
	mkdir -p "$stage"

	if has_component brew; then
		brew_bin="$(resolve_brew)" || blocker_brew
		log "capture: brew -> Brewfile"
		"$brew_bin" bundle dump --force --formula --cask --tap \
			--file="$stage/Brewfile" >&2
		# a tap with no git remote cannot be replayed on a target mac; drop
		# it from the Brewfile (check ignores such taps on both sides too)
		brewfile_names "$stage/Brewfile" tap >"$WORKDIR/dump_taps"
		while IFS= read -r t; do
			[ -z "$t" ] && continue
			if ! tap_has_remote "$brew_bin" "$t"; then
				log "capture: WARN dropping tap '$t' (no git remote, not replayable)"
				awk -v t="$t" '$0 != "tap \"" t "\""' "$stage/Brewfile" >"$stage/Brewfile.tmp"
				mv "$stage/Brewfile.tmp" "$stage/Brewfile"
			fi
		done <"$WORKDIR/dump_taps"
	fi

	if has_component conda; then
		conda_bin="$(resolve_conda)" || blocker_conda
		log "capture: conda env yamls (one export per env, this can take minutes)"
		mkdir -p "$stage/conda"
		conda_env_names "$conda_bin" >"$stage/conda/envs.txt"
		while IFS= read -r e; do
			[ -z "$e" ] && continue
			log "capture: conda env '$e'"
			"$conda_bin" env export -n "$e" --no-builds </dev/null |
				grep -v '^prefix:' >"$stage/conda/$e.yml"
		done <"$stage/conda/envs.txt"
	fi

	if has_component rustup; then
		rustup_bin="$(resolve_rustup)" || blocker_rustup
		log "capture: rustup channels"
		rustup_channels "$rustup_bin" >"$stage/rustup-toolchains.txt"
	fi

	if has_component npm; then
		npm_bin="$(resolve_npm)" || blocker_npm
		log "capture: npm globals"
		npm_globals "$npm_bin" >"$stage/npm-globals.txt"
	fi

	if has_component dotfiles && dotfiles_configured; then
		log "capture: dotfiles (per dotfiles.list)"
		mkdir -p "$stage/dotfiles"
		local p ex
		# pass 1: collect !excludes as tar -X patterns (the dir entry and
		# its children) so excluded payload is never copied at all — some
		# of it (e.g. go module caches under vim plugins) is read-only and
		# cannot even be rm'd afterwards. Nested .git dirs are always
		# excluded: committed as-is they would become empty gitlinks and
		# the payload under them would silently not be stored.
		printf '*/.git\n*/.git/*\n' >"$WORKDIR/dotfiles.exclude"
		while IFS= read -r p || [ -n "$p" ]; do
			case "$p" in
			'!'*)
				ex="${p#!}"
				validate_dotfile_path "$ex" || die_usage "invalid dotfiles.list entry: $p"
				printf './%s\n./%s/*\n' "$ex" "$ex" >>"$WORKDIR/dotfiles.exclude"
				;;
			esac
		done <"$MANIFEST_DIR/dotfiles.list"
		# pass 2: copy each listed path, excludes applied during the copy
		while IFS= read -r p || [ -n "$p" ]; do
			case "$p" in '' | '#'* | '!'*) continue ;; esac
			validate_dotfile_path "$p" || die_usage "invalid dotfiles.list entry: $p"
			if [ ! -e "$HOME/$p" ]; then
				log "capture: WARN dotfile '$p' not found in \$HOME — skipped"
				continue
			fi
			log "capture: dotfile $p"
			tar -cf - -C "$HOME" -X "$WORKDIR/dotfiles.exclude" "./$p" </dev/null |
				tar -xpf - -C "$stage/dotfiles"
		done <"$MANIFEST_DIR/dotfiles.list"
		# some gh setups keep an oauth token in these ymls — never ship it
		for p in "$stage/dotfiles/.config/gh/hosts.yml" "$stage/dotfiles/.config/gh/config.yml"; do
			if [ -f "$p" ]; then sed -i '' '/oauth_token/d' "$p"; fi
		done
		dotfiles_secret_scan "$stage/dotfiles"
	fi

	local brew_version="unavailable"
	[ -n "$brew_bin" ] && brew_version="$("$brew_bin" --version | head -1)"
	cat >"$stage/meta.json" <<EOF
{
  "captured_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "host": "$(json_escape "$(hostname -s)")",
  "arch": "$(uname -m)",
  "macos": "$(sw_vers -productVersion 2>/dev/null || echo unknown)",
  "brew": "$(json_escape "$brew_version")",
  "tool_version": "$VERSION",
  "components": "$(json_escape "$COMPONENTS")"
}
EOF

	# Promote per captured component only now, so a failure above leaves the
	# existing manifest untouched. Replacing conda/ wholesale also prunes
	# yamls of envs that no longer exist.
	mkdir -p "$MANIFEST_DIR"
	has_component brew && mv -f "$stage/Brewfile" "$MANIFEST_DIR/Brewfile"
	if has_component conda; then
		# move the old dir aside rather than rm -rf; if anything interrupts
		# between the two mvs, cleanup() restores conda.old into place
		if [ -d "$MANIFEST_DIR/conda" ]; then
			mv "$MANIFEST_DIR/conda" "$WORKDIR/conda.old"
		fi
		mv "$stage/conda" "$MANIFEST_DIR/conda"
	fi
	has_component rustup && mv -f "$stage/rustup-toolchains.txt" "$MANIFEST_DIR/rustup-toolchains.txt"
	has_component npm && mv -f "$stage/npm-globals.txt" "$MANIFEST_DIR/npm-globals.txt"
	if has_component dotfiles && dotfiles_configured; then
		if [ -d "$MANIFEST_DIR/dotfiles" ]; then
			mv "$MANIFEST_DIR/dotfiles" "$WORKDIR/dotfiles.old"
		fi
		mv "$stage/dotfiles" "$MANIFEST_DIR/dotfiles"
	fi
	mv -f "$stage/meta.json" "$MANIFEST_DIR/meta.json"

	if [ "$PRETTY" -eq 1 ]; then
		ui "✅ manifest captured → $MANIFEST_DIR ($COMPONENTS)"
	else
		printf '{"command":"capture","status":"ok","manifest_dir":"%s","components":"%s"}\n' \
			"$(json_escape "$MANIFEST_DIR")" "$(json_escape "$COMPONENTS")"
	fi
	JSON_EMITTED=1
}

# ---------------------------------------------------- drift computation ------
# Runs an inventory command; a failing command yields an empty list PLUS the
# error flag file — never a silent empty list that fakes mass drift.
inv_or_flag() {
	# $1 = sorted list file to write, $2 = error flag file, rest = command
	local out="$1" flag="$2"
	shift 2
	if "$@" >"$WORKDIR/raw_inv" 2>/dev/null; then
		sorted <"$WORKDIR/raw_inv" >"$out"
	else
		: >"$out"
		echo 1 >"$flag"
	fi
}

component_degraded() {
	# $1 = component; true when its tool is absent or its inventory failed
	[ -f "$WORKDIR/${1}_tool_missing" ] || [ -f "$WORKDIR/${1}_tool_error" ]
}

# Writes per-component missing/extra list files into $WORKDIR and echoes the
# total number of missing entries. For a degraded component (tool missing or
# inventory failing) the lists stay empty — the flags carry the signal — so
# garbage inventory can never masquerade as drift. Used by check and apply.
compute_drift() {
	local total=0 brew_bin conda_bin rustup_bin npm_bin

	if has_component brew; then
		if [ ! -f "$MANIFEST_DIR/Brewfile" ]; then
			echo 1 >"$WORKDIR/brew_manifest_missing"
		else
			brewfile_names "$MANIFEST_DIR/Brewfile" tap >"$WORKDIR/m_taps"
			brewfile_names "$MANIFEST_DIR/Brewfile" brew | short_names | sorted >"$WORKDIR/m_formulae"
			brewfile_names "$MANIFEST_DIR/Brewfile" cask | short_names | sorted >"$WORKDIR/m_casks"
			if brew_bin="$(resolve_brew)"; then
				inv_or_flag "$WORKDIR/c_taps" "$WORKDIR/brew_tool_error" brew_replayable_taps "$brew_bin"
				inv_or_flag "$WORKDIR/c_formulae" "$WORKDIR/brew_tool_error" "$brew_bin" list --formula
				inv_or_flag "$WORKDIR/c_casks" "$WORKDIR/brew_tool_error" "$brew_bin" list --cask
				inv_or_flag "$WORKDIR/c_leaves" "$WORKDIR/brew_tool_error" "$brew_bin" leaves
			else
				echo 1 >"$WORKDIR/brew_tool_missing"
			fi
			for f in missing_taps missing_formulae missing_casks extra_taps extra_formulae extra_casks; do
				: >"$WORKDIR/$f"
			done
			if ! component_degraded brew; then
				missing_of "$WORKDIR/m_taps" "$WORKDIR/c_taps" >"$WORKDIR/missing_taps"
				missing_of "$WORKDIR/m_formulae" "$WORKDIR/c_formulae" >"$WORKDIR/missing_formulae"
				missing_of "$WORKDIR/m_casks" "$WORKDIR/c_casks" >"$WORKDIR/missing_casks"
				extra_of "$WORKDIR/m_taps" "$WORKDIR/c_taps" >"$WORKDIR/extra_taps"
				extra_of "$WORKDIR/m_formulae" "$WORKDIR/c_leaves" >"$WORKDIR/extra_formulae"
				extra_of "$WORKDIR/m_casks" "$WORKDIR/c_casks" >"$WORKDIR/extra_casks"
				total=$((total + $(wc -l <"$WORKDIR/missing_taps") + $(wc -l <"$WORKDIR/missing_formulae") + $(wc -l <"$WORKDIR/missing_casks")))
			fi
		fi
	fi

	if has_component conda; then
		if [ ! -f "$MANIFEST_DIR/conda/envs.txt" ]; then
			echo 1 >"$WORKDIR/conda_manifest_missing"
		else
			sorted <"$MANIFEST_DIR/conda/envs.txt" >"$WORKDIR/m_envs"
			if conda_bin="$(resolve_conda)"; then
				inv_or_flag "$WORKDIR/c_envs" "$WORKDIR/conda_tool_error" conda_env_names "$conda_bin"
			else
				echo 1 >"$WORKDIR/conda_tool_missing"
			fi
			: >"$WORKDIR/missing_envs"
			: >"$WORKDIR/extra_envs"
			if ! component_degraded conda; then
				missing_of "$WORKDIR/m_envs" "$WORKDIR/c_envs" >"$WORKDIR/missing_envs"
				extra_of "$WORKDIR/m_envs" "$WORKDIR/c_envs" >"$WORKDIR/extra_envs"
				total=$((total + $(wc -l <"$WORKDIR/missing_envs")))
			fi
		fi
	fi

	if has_component rustup; then
		if [ ! -f "$MANIFEST_DIR/rustup-toolchains.txt" ]; then
			echo 1 >"$WORKDIR/rustup_manifest_missing"
		else
			sorted <"$MANIFEST_DIR/rustup-toolchains.txt" >"$WORKDIR/m_channels"
			if rustup_bin="$(resolve_rustup)"; then
				inv_or_flag "$WORKDIR/c_channels" "$WORKDIR/rustup_tool_error" rustup_channels "$rustup_bin"
			else
				echo 1 >"$WORKDIR/rustup_tool_missing"
			fi
			: >"$WORKDIR/missing_channels"
			: >"$WORKDIR/extra_channels"
			if ! component_degraded rustup; then
				missing_of "$WORKDIR/m_channels" "$WORKDIR/c_channels" >"$WORKDIR/missing_channels"
				extra_of "$WORKDIR/m_channels" "$WORKDIR/c_channels" >"$WORKDIR/extra_channels"
				total=$((total + $(wc -l <"$WORKDIR/missing_channels")))
			fi
		fi
	fi

	if has_component npm; then
		if [ ! -f "$MANIFEST_DIR/npm-globals.txt" ]; then
			echo 1 >"$WORKDIR/npm_manifest_missing"
		else
			sorted <"$MANIFEST_DIR/npm-globals.txt" >"$WORKDIR/m_npm"
			if npm_bin="$(resolve_npm)"; then
				inv_or_flag "$WORKDIR/c_npm" "$WORKDIR/npm_tool_error" npm_globals "$npm_bin"
			else
				echo 1 >"$WORKDIR/npm_tool_missing"
			fi
			: >"$WORKDIR/missing_npm"
			: >"$WORKDIR/extra_npm"
			if ! component_degraded npm; then
				missing_of "$WORKDIR/m_npm" "$WORKDIR/c_npm" >"$WORKDIR/missing_npm"
				extra_of "$WORKDIR/m_npm" "$WORKDIR/c_npm" >"$WORKDIR/extra_npm"
				total=$((total + $(wc -l <"$WORKDIR/missing_npm")))
			fi
		fi
	fi

	if has_component dotfiles && dotfiles_configured; then
		: >"$WORKDIR/missing_dotfiles"
		local p
		while IFS= read -r p || [ -n "$p" ]; do
			case "$p" in '' | '#'* | '!'*) continue ;; esac
			validate_dotfile_path "$p" || continue
			if [ ! -e "$MANIFEST_DIR/dotfiles/$p" ]; then
				log "check: WARN dotfile '$p' listed but never captured — run capture on the source mac"
				continue
			fi
			if [ ! -e "$HOME/$p" ] || ! dotfile_in_sync "$MANIFEST_DIR/dotfiles/$p" "$HOME/$p"; then
				echo "$p" >>"$WORKDIR/missing_dotfiles"
			fi
		done <"$MANIFEST_DIR/dotfiles.list"
		sorted <"$WORKDIR/missing_dotfiles" >"$WORKDIR/missing_dotfiles.s"
		mv "$WORKDIR/missing_dotfiles.s" "$WORKDIR/missing_dotfiles"
		total=$((total + $(wc -l <"$WORKDIR/missing_dotfiles")))
	fi

	if has_component frameworks && frameworks_configured; then
		: >"$WORKDIR/missing_frameworks"
		local fw_path fw_rest
		while IFS='|' read -r fw_path fw_rest || [ -n "$fw_path" ]; do
			case "$fw_path" in '' | '#'*) continue ;; esac
			validate_dotfile_path "$fw_path" || continue
			[ -n "$fw_rest" ] || continue
			[ -e "$HOME/$fw_path" ] || echo "$fw_path" >>"$WORKDIR/missing_frameworks"
		done <"$MANIFEST_DIR/frameworks.list"
		sorted <"$WORKDIR/missing_frameworks" >"$WORKDIR/missing_frameworks.s"
		mv "$WORKDIR/missing_frameworks.s" "$WORKDIR/missing_frameworks"
		total=$((total + $(wc -l <"$WORKDIR/missing_frameworks")))
	fi

	printf '%s' "$total"
}

count_lines() { if [ -f "$1" ]; then wc -l <"$1" | tr -d ' '; else printf '0'; fi; }

# emits `"name":[..],..` JSON for one drift file set; args: label=file [..]
drift_json_lists() {
	local out="" label file first=1 spec
	for spec in "$@"; do
		label="${spec%%=*}"
		file="${spec#*=}"
		[ $first -eq 0 ] && out="$out,"
		if [ -f "$file" ]; then
			out="$out\"$label\":$(json_array <"$file")"
		else
			out="$out\"$label\":[]"
		fi
		first=0
	done
	printf '%s' "$out"
}

tool_flag() { [ -f "$WORKDIR/$1" ] && printf 'true' || printf 'false'; }

component_flags_json() {
	printf '"tool_missing":%s,"tool_error":%s,"manifest_missing":%s,' \
		"$(tool_flag "${1}_tool_missing")" "$(tool_flag "${1}_tool_error")" \
		"$(tool_flag "${1}_manifest_missing")"
}

drift_components_json() {
	local out="" first=1
	if has_component brew; then
		out="$out\"brew\":{$(component_flags_json brew)"
		out="$out$(drift_json_lists \
			missing_taps="$WORKDIR/missing_taps" \
			missing_formulae="$WORKDIR/missing_formulae" \
			missing_casks="$WORKDIR/missing_casks" \
			extra_taps="$WORKDIR/extra_taps" \
			extra_formulae="$WORKDIR/extra_formulae" \
			extra_casks="$WORKDIR/extra_casks")}"
		first=0
	fi
	if has_component conda; then
		[ $first -eq 0 ] && out="$out,"
		out="$out\"conda\":{$(component_flags_json conda)"
		out="$out$(drift_json_lists \
			missing_envs="$WORKDIR/missing_envs" \
			extra_envs="$WORKDIR/extra_envs")}"
		first=0
	fi
	if has_component rustup; then
		[ $first -eq 0 ] && out="$out,"
		out="$out\"rustup\":{$(component_flags_json rustup)"
		out="$out$(drift_json_lists \
			missing_toolchains="$WORKDIR/missing_channels" \
			extra_toolchains="$WORKDIR/extra_channels")}"
		first=0
	fi
	if has_component npm; then
		[ $first -eq 0 ] && out="$out,"
		out="$out\"npm\":{$(component_flags_json npm)"
		out="$out$(drift_json_lists \
			missing_globals="$WORKDIR/missing_npm" \
			extra_globals="$WORKDIR/extra_npm")}"
		first=0
	fi
	if has_component dotfiles && dotfiles_configured; then
		[ $first -eq 0 ] && out="$out,"
		out="$out\"dotfiles\":{$(component_flags_json dotfiles)"
		out="$out$(drift_json_lists missing_dotfiles="$WORKDIR/missing_dotfiles")}"
		first=0
	fi
	if has_component frameworks && frameworks_configured; then
		[ $first -eq 0 ] && out="$out,"
		out="$out\"frameworks\":{$(component_flags_json frameworks)"
		out="$out$(drift_json_lists missing_frameworks="$WORKDIR/missing_frameworks")}"
		first=0
	fi
	printf '%s' "$out"
}

# --------------------------------------------------------- pretty summary ---
component_missing_count() {
	case "$1" in
	brew) printf '%s' "$(($(count_lines "$WORKDIR/missing_taps") + $(count_lines "$WORKDIR/missing_formulae") + $(count_lines "$WORKDIR/missing_casks")))" ;;
	conda) count_lines "$WORKDIR/missing_envs" ;;
	rustup) count_lines "$WORKDIR/missing_channels" ;;
	npm) count_lines "$WORKDIR/missing_npm" ;;
	dotfiles) count_lines "$WORKDIR/missing_dotfiles" ;;
	frameworks) count_lines "$WORKDIR/missing_frameworks" ;;
	esac
}
component_extra_count() {
	case "$1" in
	brew) printf '%s' "$(($(count_lines "$WORKDIR/extra_taps") + $(count_lines "$WORKDIR/extra_formulae") + $(count_lines "$WORKDIR/extra_casks")))" ;;
	conda) count_lines "$WORKDIR/extra_envs" ;;
	rustup) count_lines "$WORKDIR/extra_channels" ;;
	npm) count_lines "$WORKDIR/extra_npm" ;;
	dotfiles | frameworks) printf '0' ;;
	esac
}

pretty_drift_summary() {
	local c m x
	for c in $COMPONENTS; do
		if [ "$c" = "dotfiles" ] && ! dotfiles_configured; then continue; fi
		if [ "$c" = "frameworks" ] && ! frameworks_configured; then continue; fi
		if [ -f "$WORKDIR/${c}_manifest_missing" ]; then
			ui "  ⚠️  $(icon_of "$c") $c — not in this manifest"
		elif [ -f "$WORKDIR/${c}_tool_missing" ]; then
			ui "  🚫 $(icon_of "$c") $c — tool not installed"
		elif [ -f "$WORKDIR/${c}_tool_error" ]; then
			ui "  🚫 $(icon_of "$c") $c — tool present but inventory failing"
		else
			m="$(component_missing_count "$c")"
			x="$(component_extra_count "$c")"
			if [ "$m" -eq 0 ] && [ "$x" -eq 0 ]; then
				ui "  ✅ $(icon_of "$c") $c — in sync"
			elif [ "$x" -eq 0 ]; then
				ui "  ❌ $(icon_of "$c") $c — $m to install"
			else
				ui "  ❌ $(icon_of "$c") $c — $m to install, $x extra here"
			fi
		fi
	done
}

require_manifest() {
	[ -d "$MANIFEST_DIR" ] ||
		die_usage "manifest dir not found: $MANIFEST_DIR (run 'capture' on the source mac first)"
	local found=0
	has_component brew && [ -f "$MANIFEST_DIR/Brewfile" ] && found=1
	has_component conda && [ -f "$MANIFEST_DIR/conda/envs.txt" ] && found=1
	has_component rustup && [ -f "$MANIFEST_DIR/rustup-toolchains.txt" ] && found=1
	has_component npm && [ -f "$MANIFEST_DIR/npm-globals.txt" ] && found=1
	has_component dotfiles && dotfiles_configured && found=1
	has_component frameworks && frameworks_configured && found=1
	[ "$found" -eq 1 ] ||
		die_usage "no manifest files for components '$COMPONENTS' in $MANIFEST_DIR (run 'capture' on the source mac first)"
}

any_degraded() {
	component_degraded brew || component_degraded conda ||
		component_degraded rustup || component_degraded npm
}

any_manifest_missing() {
	[ -f "$WORKDIR/brew_manifest_missing" ] || [ -f "$WORKDIR/conda_manifest_missing" ] ||
		[ -f "$WORKDIR/rustup_manifest_missing" ] || [ -f "$WORKDIR/npm_manifest_missing" ]
}

# ------------------------------------------------------------------- check ---
cmd_check() {
	require_manifest
	local total status extras f
	total="$(compute_drift)"
	extras=0
	for f in extra_taps extra_formulae extra_casks extra_envs extra_channels extra_npm; do
		extras=$((extras + $(count_lines "$WORKDIR/$f")))
	done
	status="drift"
	if [ "$total" -eq 0 ] && [ "$extras" -eq 0 ] && ! any_degraded && ! any_manifest_missing; then
		status="in-sync"
	fi
	if [ "$PRETTY" -eq 1 ]; then
		ui "🔗 chain check — $MANIFEST_DIR"
		pretty_drift_summary
		ui ""
		if [ "$status" = "in-sync" ]; then
			ui "✅ this machine matches the manifest"
		else
			ui "❌ drift: $total to install, $extras extra — run: toolchain.sh apply"
		fi
	else
		printf '{"command":"check","status":"%s","missing_total":%s,"extra_total":%s,"manifest_dir":"%s","components":{%s}}\n' \
			"$status" "$total" "$extras" "$(json_escape "$MANIFEST_DIR")" "$(drift_components_json)"
	fi
	JSON_EMITTED=1
	[ "$status" = "in-sync" ] || exit 1
}

# ------------------------------------------------------------------- apply ---
# apply --only/--skip exact-name filters to a list file, in place
filter_list() {
	local f="$1"
	[ -f "$f" ] || return 0
	if [ -n "$ONLY_ITEMS" ]; then
		awk -v keep="$ONLY_ITEMS" \
			'BEGIN { n = split(keep, a, ","); for (i = 1; i <= n; i++) k[a[i]] = 1 } $0 in k' \
			"$f" >"$f.flt"
		mv "$f.flt" "$f"
	fi
	if [ -n "$SKIP_ITEMS" ]; then
		awk -v drop="$SKIP_ITEMS" \
			'BEGIN { n = split(drop, a, ","); for (i = 1; i <= n; i++) d[a[i]] = 1 } !($0 in d)' \
			"$f" >"$f.flt"
		mv "$f.flt" "$f"
	fi
}

blocked_component() {
	# $1 = component, $2 = reason. Recorded in the JSON `blocked` array;
	# the run continues and exits 3 at the end instead of aborting here.
	log "apply: BLOCKED: $2 — component '$1' skipped"
	log "apply: SAFE_NEXT_STEP: make the '$1' tool available (see the line above), then re-run apply"
	echo "$1" >>"$WORKDIR/blocked"
}

conda_accept_tos() {
	# conda >= 25 (what Miniconda3-latest ships) refuses non-interactive
	# env creation until Anaconda's ToS is accepted for the defaults
	# channels (verified against conda 26.5.3: every `env create` fails
	# with CondaToSNonInteractiveError). Older condas have no `tos`
	# subcommand — the || true makes this a no-op there.
	"$1" tos accept --override-channels --channel https://repo.anaconda.com/pkgs/main >/dev/null 2>&1 || true
	"$1" tos accept --override-channels --channel https://repo.anaconda.com/pkgs/r >/dev/null 2>&1 || true
}

conda_bootstrap_cmd() {
	# official Miniconda batch install: non-interactive, no sudo, accepts
	# the license via -b, lands in ~/miniconda3 where resolve_conda looks.
	# CHAIN_CONDA_BOOTSTRAP replaces the whole step (tests use this).
	if [ -n "${CHAIN_CONDA_BOOTSTRAP:-}" ]; then
		"$CHAIN_CONDA_BOOTSTRAP"
	else
		curl -fsSL "https://repo.anaconda.com/miniconda/Miniconda3-latest-MacOSX-$(uname -m).sh" \
			-o "$WORKDIR/miniconda-installer.sh" &&
			/bin/bash "$WORKDIR/miniconda-installer.sh" -b -p "$HOME/miniconda3"
	fi
}

run_action() {
	# $1 = human label; rest = command. Appends to ok/failed counters via
	# files; a failed action never aborts the remaining actions. Pretty
	# mode shows a progress bar and hides tool chatter unless it fails.
	# stdin is /dev/null: the callers loop `while read` over the very list
	# being applied, and a stdin-consuming tool (brew!) would silently eat
	# the remaining items.
	local label="$1"
	shift
	ACTION_N=$((ACTION_N + 1))
	if [ "$PRETTY" -eq 1 ]; then
		uin "  $(bar "$ACTION_N" "$ACTION_TOTAL") [$ACTION_N/$ACTION_TOTAL] $label "
		if "$@" </dev/null >"$WORKDIR/action.log" 2>&1; then
			ui "✅"
			echo "$label" >>"$WORKDIR/applied_ok"
		else
			ui "❌"
			tail -6 "$WORKDIR/action.log" | sed 's/^/      /' >&2
			echo "$label" >>"$WORKDIR/applied_failed"
		fi
	else
		log "apply: $label"
		if "$@" </dev/null >&2; then
			echo "$label" >>"$WORKDIR/applied_ok"
		else
			log "apply: FAILED: $label"
			echo "$label" >>"$WORKDIR/applied_failed"
		fi
	fi
}

cmd_apply() {
	require_manifest
	local total ff
	total="$(compute_drift)"

	# --only/--skip narrow what apply acts on; the plan shows the same view
	if [ -n "$ONLY_ITEMS$SKIP_ITEMS" ]; then
		for ff in missing_taps missing_formulae missing_casks missing_envs missing_channels missing_npm missing_dotfiles missing_frameworks; do
			filter_list "$WORKDIR/$ff"
		done
		total=0
		for ff in missing_taps missing_formulae missing_casks missing_envs missing_channels missing_npm missing_dotfiles missing_frameworks; do
			total=$((total + $(count_lines "$WORKDIR/$ff")))
		done
	fi

	if [ "$CONFIRM" -eq 0 ]; then
		log "apply: plan only (no --confirm); nothing was changed"
		# frameworks run arbitrary commands: the plan must show exactly
		# what --confirm would execute
		if has_component frameworks && [ -f "$WORKDIR/missing_frameworks" ]; then
			while IFS= read -r ff || [ -n "$ff" ]; do
				[ -z "$ff" ] && continue
				log "plan: framework '$ff' would run: $(framework_cmd_for "$ff")"
			done <"$WORKDIR/missing_frameworks"
		fi
		if [ "$PRETTY" -eq 1 ]; then
			ui "🔗 chain apply (plan) — $MANIFEST_DIR"
			pretty_drift_summary
			ui ""
			ui "▫️  plan only — nothing changed; add --confirm to execute ($total to install)"
		else
			printf '{"command":"apply","mode":"plan","missing_total":%s,"manifest_dir":"%s","components":{%s}}\n' \
				"$total" "$(json_escape "$MANIFEST_DIR")" "$(drift_components_json)"
		fi
		JSON_EMITTED=1
		return 0
	fi

	ui "🔗 chain apply — $MANIFEST_DIR"
	ACTION_N=0
	ACTION_TOTAL=$total

	# Prerequisite gates. Homebrew cannot be bootstrapped non-interactively
	# (its installer needs sudo), so a missing brew stays a hard blocker.
	# A tool that is present but failing inventory also blocks — installed
	# state is unknown, and acting on it would reinstall (and thereby
	# upgrade) everything. Missing conda/rustup/npm are handled per
	# component below: conda is bootstrapped, rustup/npm may have just
	# arrived via the brew phase, and whatever is still missing is
	# reported as blocked instead of aborting the whole run.
	[ -f "$WORKDIR/brew_tool_missing" ] && blocker_brew
	[ -f "$WORKDIR/brew_tool_error" ] && blocker_inventory brew "brew list --formula"
	[ -f "$WORKDIR/conda_tool_error" ] && blocker_inventory conda "conda env list"
	[ -f "$WORKDIR/rustup_tool_error" ] && blocker_inventory rustup "rustup toolchain list"
	[ -f "$WORKDIR/npm_tool_error" ] && blocker_inventory npm "npm ls -g --depth=0"
	: >"$WORKDIR/blocked"

	# a selected component absent from the manifest cannot be applied; say
	# so loudly and carry it in the JSON instead of silently no-opping
	: >"$WORKDIR/apply_manifest_missing"
	local mm_c
	for mm_c in brew conda rustup npm; do
		if [ -f "$WORKDIR/${mm_c}_manifest_missing" ]; then
			log "apply: WARN component '$mm_c' selected but absent from manifest — skipped (scope with --components)"
			echo "$mm_c" >>"$WORKDIR/apply_manifest_missing"
		fi
	done

	: >"$WORKDIR/applied_ok"
	: >"$WORKDIR/applied_failed"
	local brew_bin conda_bin rustup_bin npm_bin item qual

	# Order matters: taps -> formulae -> casks -> rustup -> npm -> conda.
	if has_component brew && [ -f "$MANIFEST_DIR/Brewfile" ]; then
		brew_bin="$(resolve_brew)" || blocker_brew
		while IFS= read -r item; do
			[ -z "$item" ] || run_action "brew tap $item" "$brew_bin" tap "$item"
		done <"$WORKDIR/missing_taps"
		# missing lists hold short names; install by the Brewfile's full
		# (possibly tap-qualified) name
		while IFS= read -r item; do
			[ -z "$item" ] && continue
			qual="$(brewfile_qualified "$MANIFEST_DIR/Brewfile" brew "$item")"
			[ -n "$qual" ] || qual="$item"
			run_action "brew install $qual" "$brew_bin" install "$qual"
		done <"$WORKDIR/missing_formulae"
		while IFS= read -r item; do
			[ -z "$item" ] && continue
			qual="$(brewfile_qualified "$MANIFEST_DIR/Brewfile" cask "$item")"
			[ -n "$qual" ] || qual="$item"
			run_action "brew install --cask $qual" "$brew_bin" install --cask "$qual"
		done <"$WORKDIR/missing_casks"
	fi

	# frameworks next: shell/editor scaffolding (oh-my-zsh, p10k, claude
	# CLI) that the synced dotfiles reference
	if has_component frameworks && [ -f "$WORKDIR/missing_frameworks" ]; then
		local fw_cmd
		while IFS= read -r item || [ -n "$item" ]; do
			[ -z "$item" ] && continue
			fw_cmd="$(framework_cmd_for "$item")"
			if [ -n "$fw_cmd" ]; then
				run_action "install framework $item ($fw_cmd)" /bin/bash -c "$fw_cmd"
			else
				log "apply: FAILED: framework $item (no install command found in frameworks.list)"
				echo "install framework $item" >>"$WORKDIR/applied_failed"
			fi
		done <"$WORKDIR/missing_frameworks"
	fi

	# rustup/npm/conda resolve at ACTION time, not compute time — the brew
	# phase above may have just installed rustup/node, and conda can be
	# bootstrapped. Drift for these is recomputed live for the same reason.
	if has_component rustup && [ -f "$WORKDIR/m_channels" ]; then
		cp "$WORKDIR/m_channels" "$WORKDIR/m_channels_want"
		filter_list "$WORKDIR/m_channels_want"
		if [ -s "$WORKDIR/m_channels_want" ]; then
			if ! rustup_bin="$(resolve_rustup)"; then
				blocked_component rustup "rustup not found (brew install rustup, or add it to the Brewfile)"
			elif ! rustup_channels "$rustup_bin" >"$WORKDIR/c_channels_now"; then
				blocked_component rustup "rustup present but its inventory command is failing"
			else
				missing_of "$WORKDIR/m_channels_want" "$WORKDIR/c_channels_now" >"$WORKDIR/missing_channels_now"
				while IFS= read -r item; do
					[ -z "$item" ] || run_action "rustup toolchain install $item" "$rustup_bin" toolchain install "$item"
				done <"$WORKDIR/missing_channels_now"
			fi
		fi
	fi

	if has_component npm && [ -f "$WORKDIR/m_npm" ]; then
		cp "$WORKDIR/m_npm" "$WORKDIR/m_npm_want"
		filter_list "$WORKDIR/m_npm_want"
		if [ -s "$WORKDIR/m_npm_want" ]; then
			if ! npm_bin="$(resolve_npm)"; then
				blocked_component npm "npm not found (brew install node, or add it to the Brewfile)"
			elif ! npm_globals "$npm_bin" >"$WORKDIR/c_npm_now"; then
				blocked_component npm "npm present but its inventory command is failing"
			else
				missing_of "$WORKDIR/m_npm_want" "$WORKDIR/c_npm_now" >"$WORKDIR/missing_npm_now"
				while IFS= read -r item; do
					[ -z "$item" ] || run_action "npm install -g $item" "$npm_bin" install -g "$item"
				done <"$WORKDIR/missing_npm_now"
			fi
		fi
	fi

	if has_component dotfiles && [ -f "$WORKDIR/missing_dotfiles" ]; then
		while IFS= read -r item; do
			[ -z "$item" ] || run_action "sync dotfile $item" sync_dotfile "$item"
		done <"$WORKDIR/missing_dotfiles"
	fi

	if has_component conda && [ -f "$WORKDIR/m_envs" ]; then
		cp "$WORKDIR/m_envs" "$WORKDIR/m_envs_want"
		filter_list "$WORKDIR/m_envs_want"
		if [ -s "$WORKDIR/m_envs_want" ]; then
			if ! conda_bin="$(resolve_conda)"; then
				run_action "bootstrap miniconda (batch installer, no sudo)" conda_bootstrap_cmd
				conda_bin="$(resolve_conda)" || conda_bin=""
			fi
			if [ -z "$conda_bin" ]; then
				blocked_component conda "conda not found and the Miniconda bootstrap did not produce it"
			elif ! conda_env_names "$conda_bin" >"$WORKDIR/c_envs_now"; then
				blocked_component conda "conda present but its inventory command is failing"
			else
				missing_of "$WORKDIR/m_envs_want" "$WORKDIR/c_envs_now" >"$WORKDIR/missing_envs_now"
				# accept ToS only when envs will actually be created,
				# and always before the create loop
				if [ -s "$WORKDIR/missing_envs_now" ]; then
					conda_accept_tos "$conda_bin"
				fi
				while IFS= read -r item; do
					[ -z "$item" ] && continue
					if [ -f "$MANIFEST_DIR/conda/$item.yml" ]; then
						run_action "conda env create $item" \
							"$conda_bin" env create -n "$item" -f "$MANIFEST_DIR/conda/$item.yml"
					else
						log "apply: FAILED: conda env $item (no yaml in manifest)"
						echo "conda env create $item" >>"$WORKDIR/applied_failed"
					fi
				done <"$WORKDIR/missing_envs_now"
			fi
		fi
	fi

	local ok failed nblocked
	ok="$(wc -l <"$WORKDIR/applied_ok" | tr -d ' ')"
	failed="$(wc -l <"$WORKDIR/applied_failed" | tr -d ' ')"
	nblocked="$(wc -l <"$WORKDIR/blocked" | tr -d ' ')"
	if [ "$PRETTY" -eq 1 ]; then
		ui ""
		ui "✅ $ok done"
		if [ "$failed" -gt 0 ]; then
			ui "❌ $failed failed:"
			sed 's/^/     ❌ /' "$WORKDIR/applied_failed"
		fi
		if [ "$nblocked" -gt 0 ]; then
			ui "🚫 blocked (tool unavailable): $(tr '\n' ' ' <"$WORKDIR/blocked")"
		fi
		if [ -s "$WORKDIR/apply_manifest_missing" ]; then
			ui "⚠️  not in manifest: $(tr '\n' ' ' <"$WORKDIR/apply_manifest_missing")"
		fi
	else
		printf '{"command":"apply","mode":"applied","actions_ok":%s,"actions_failed":%s,"failed":%s,"blocked":%s,"manifest_missing":%s,"manifest_dir":"%s"}\n' \
			"$ok" "$failed" "$(json_array <"$WORKDIR/applied_failed")" \
			"$(json_array <"$WORKDIR/blocked")" \
			"$(json_array <"$WORKDIR/apply_manifest_missing")" \
			"$(json_escape "$MANIFEST_DIR")"
	fi
	JSON_EMITTED=1
	[ "$nblocked" -eq 0 ] || exit 3
	[ "$failed" -eq 0 ] || exit 1
}

# -------------------------------------------------------------------- main ---
main() {
	resolve_pretty # early TTY auto-detect so even usage errors pick the right mode
	[ $# -ge 1 ] || die_usage "missing subcommand"
	local cmd="$1"
	shift

	case "$cmd" in
	--help | -h | help)
		usage
		exit 0
		;;
	--version)
		printf '%s\n' "$VERSION"
		exit 0
		;;
	capture | check | apply) : ;;
	*) die_usage "unknown subcommand: $cmd" ;;
	esac
	CURRENT_CMD="$cmd"

	while [ $# -gt 0 ]; do
		case "$1" in
		--manifest-dir)
			[ $# -ge 2 ] || die_usage "--manifest-dir needs a value"
			MANIFEST_DIR="$2"
			shift 2
			;;
		--components)
			[ $# -ge 2 ] && [ -n "$2" ] || die_usage "--components needs a non-empty value"
			COMPONENTS="$(printf '%s' "$2" | tr ',' ' ')"
			for c in $COMPONENTS; do
				case "$c" in
				brew | conda | rustup | npm | dotfiles | frameworks) : ;;
				*) die_usage "unknown component: $c (valid: brew conda rustup npm dotfiles frameworks)" ;;
				esac
			done
			shift 2
			;;
		--confirm)
			CONFIRM=1
			shift
			;;
		--only)
			[ $# -ge 2 ] && [ -n "$2" ] || die_usage "--only needs a non-empty value"
			ONLY_ITEMS="$2"
			shift 2
			;;
		--skip)
			[ $# -ge 2 ] && [ -n "$2" ] || die_usage "--skip needs a non-empty value"
			SKIP_ITEMS="$2"
			shift 2
			;;
		--pretty)
			FORCE_MODE="pretty"
			shift
			;;
		--json)
			FORCE_MODE="json"
			shift
			;;
		--help | -h)
			usage
			exit 0
			;;
		*) die_usage "unknown flag: $1" ;;
		esac
	done

	if [ "$cmd" != "apply" ] && [ -n "$ONLY_ITEMS$SKIP_ITEMS" ]; then
		die_usage "--only/--skip are apply-only flags"
	fi

	resolve_pretty
	WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/toolchain.XXXXXX")"

	case "$cmd" in
	capture) cmd_capture ;;
	check) cmd_check ;;
	apply) cmd_apply ;;
	esac
}

main "$@"
