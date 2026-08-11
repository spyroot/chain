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
#   - stdout = one JSON object per run (a {"status":"error"} object on
#     fatal failures); all diagnostics go to stderr.
#   - Exit codes: 0 ok/in-sync; 1 drift or action failure; 2 usage error;
#     3 BLOCKER (missing prerequisite — SAFE_NEXT_STEP printed to stderr).
#   - Zero hidden state: input is the manifest dir + flags + CHAIN_* env
#     overrides only.
set -euo pipefail

VERSION="0.3.0"

SCRIPT_PATH="$0"
case "$SCRIPT_PATH" in
/*) : ;;
*) SCRIPT_PATH="$(pwd)/$SCRIPT_PATH" ;;
esac
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

MANIFEST_DIR="$REPO_ROOT/manifests/default"
COMPONENTS="brew conda rustup npm"
CONFIRM=0
WORKDIR=""
CURRENT_CMD=""
JSON_EMITTED=0

# ---------------------------------------------------------------- logging ---
log() { printf '%s\n' "$*" >&2; }

usage() {
	cat <<EOF
toolchain.sh v$VERSION — replicate this mac's toolchain on another mac.
Audience: both (agent | human). JSON on stdout, diagnostics on stderr.

Usage:
  toolchain.sh capture [--manifest-dir DIR] [--components a,b,..]
  toolchain.sh check   [--manifest-dir DIR] [--components a,b,..]
  toolchain.sh apply   [--manifest-dir DIR] [--components a,b,..] [--confirm]
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

Components: brew (taps+formulae+casks), conda (env yamls), rustup (channels),
            npm (global packages). Default: all.

Env overrides (absolute paths to tool binaries, mainly for tests):
  CHAIN_BREW CHAIN_CONDA CHAIN_RUSTUP CHAIN_NPM

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
	local rc=$?
	# if capture died between moving the old conda dir aside and promoting
	# the new one, put the old data back before the workdir is removed
	if [ -n "$WORKDIR" ] && [ -d "$WORKDIR/conda.old" ] && [ ! -d "$MANIFEST_DIR/conda" ]; then
		mv "$WORKDIR/conda.old" "$MANIFEST_DIR/conda"
	fi
	# keep the one-JSON-object-per-run contract even on fatal failures
	if [ -n "$CURRENT_CMD" ] && [ "$JSON_EMITTED" -eq 0 ] && [ "$rc" -ne 0 ]; then
		printf '{"command":"%s","status":"error","exit_code":%s}\n' \
			"$CURRENT_CMD" "$rc"
	fi
	if [ -n "$WORKDIR" ]; then rm -rf "$WORKDIR"; fi
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
	info="$("$1" tap-info "$2" --json 2>/dev/null | tr -d ' \n')" || return 0
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
			"$conda_bin" env export -n "$e" --no-builds |
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
	mv -f "$stage/meta.json" "$MANIFEST_DIR/meta.json"

	printf '{"command":"capture","status":"ok","manifest_dir":"%s","components":"%s"}\n' \
		"$(json_escape "$MANIFEST_DIR")" "$(json_escape "$COMPONENTS")"
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
	fi
	printf '%s' "$out"
}

require_manifest() {
	[ -d "$MANIFEST_DIR" ] ||
		die_usage "manifest dir not found: $MANIFEST_DIR (run 'capture' on the source mac first)"
	local found=0
	has_component brew && [ -f "$MANIFEST_DIR/Brewfile" ] && found=1
	has_component conda && [ -f "$MANIFEST_DIR/conda/envs.txt" ] && found=1
	has_component rustup && [ -f "$MANIFEST_DIR/rustup-toolchains.txt" ] && found=1
	has_component npm && [ -f "$MANIFEST_DIR/npm-globals.txt" ] && found=1
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
	printf '{"command":"check","status":"%s","missing_total":%s,"extra_total":%s,"manifest_dir":"%s","components":{%s}}\n' \
		"$status" "$total" "$extras" "$(json_escape "$MANIFEST_DIR")" "$(drift_components_json)"
	JSON_EMITTED=1
	[ "$status" = "in-sync" ] || exit 1
}

# ------------------------------------------------------------------- apply ---
run_action() {
	# $1 = human label; rest = command. Appends to ok/failed counters via
	# files; a failed action never aborts the remaining actions.
	local label="$1"
	shift
	log "apply: $label"
	if "$@" >&2; then
		echo "$label" >>"$WORKDIR/applied_ok"
	else
		log "apply: FAILED: $label"
		echo "$label" >>"$WORKDIR/applied_failed"
	fi
}

cmd_apply() {
	require_manifest
	local total
	total="$(compute_drift)"

	if [ "$CONFIRM" -eq 0 ]; then
		log "apply: plan only (no --confirm); nothing was changed"
		printf '{"command":"apply","mode":"plan","missing_total":%s,"manifest_dir":"%s","components":{%s}}\n' \
			"$total" "$(json_escape "$MANIFEST_DIR")" "$(drift_components_json)"
		JSON_EMITTED=1
		return 0
	fi

	# Prerequisite gates: refuse to act when a selected component's tool is
	# absent, or present but failing inventory (installed state unknown —
	# acting on it would reinstall, and thereby upgrade, everything).
	[ -f "$WORKDIR/brew_tool_missing" ] && blocker_brew
	[ -f "$WORKDIR/conda_tool_missing" ] && blocker_conda
	[ -f "$WORKDIR/rustup_tool_missing" ] && blocker_rustup
	[ -f "$WORKDIR/npm_tool_missing" ] && blocker_npm
	[ -f "$WORKDIR/brew_tool_error" ] && blocker_inventory brew "brew list --formula"
	[ -f "$WORKDIR/conda_tool_error" ] && blocker_inventory conda "conda env list"
	[ -f "$WORKDIR/rustup_tool_error" ] && blocker_inventory rustup "rustup toolchain list"
	[ -f "$WORKDIR/npm_tool_error" ] && blocker_inventory npm "npm ls -g --depth=0"

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

	if has_component rustup && [ -f "$WORKDIR/missing_channels" ]; then
		rustup_bin="$(resolve_rustup)" || blocker_rustup
		while IFS= read -r item; do
			[ -z "$item" ] || run_action "rustup toolchain install $item" "$rustup_bin" toolchain install "$item"
		done <"$WORKDIR/missing_channels"
	fi

	if has_component npm && [ -f "$WORKDIR/missing_npm" ]; then
		npm_bin="$(resolve_npm)" || blocker_npm
		while IFS= read -r item; do
			[ -z "$item" ] || run_action "npm install -g $item" "$npm_bin" install -g "$item"
		done <"$WORKDIR/missing_npm"
	fi

	if has_component conda && [ -f "$WORKDIR/missing_envs" ]; then
		conda_bin="$(resolve_conda)" || blocker_conda
		while IFS= read -r item; do
			[ -z "$item" ] && continue
			if [ -f "$MANIFEST_DIR/conda/$item.yml" ]; then
				run_action "conda env create $item" \
					"$conda_bin" env create -n "$item" -f "$MANIFEST_DIR/conda/$item.yml"
			else
				log "apply: FAILED: conda env $item (no yaml in manifest)"
				echo "conda env create $item" >>"$WORKDIR/applied_failed"
			fi
		done <"$WORKDIR/missing_envs"
	fi

	local ok failed
	ok="$(wc -l <"$WORKDIR/applied_ok" | tr -d ' ')"
	failed="$(wc -l <"$WORKDIR/applied_failed" | tr -d ' ')"
	printf '{"command":"apply","mode":"applied","actions_ok":%s,"actions_failed":%s,"failed":%s,"manifest_missing":%s,"manifest_dir":"%s"}\n' \
		"$ok" "$failed" "$(json_array <"$WORKDIR/applied_failed")" \
		"$(json_array <"$WORKDIR/apply_manifest_missing")" \
		"$(json_escape "$MANIFEST_DIR")"
	JSON_EMITTED=1
	[ "$failed" -eq 0 ] || exit 1
}

# -------------------------------------------------------------------- main ---
main() {
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
			[ $# -ge 2 ] || die_usage "--components needs a value"
			COMPONENTS="$(printf '%s' "$2" | tr ',' ' ')"
			for c in $COMPONENTS; do
				case "$c" in
				brew | conda | rustup | npm) : ;;
				*) die_usage "unknown component: $c (valid: brew conda rustup npm)" ;;
				esac
			done
			shift 2
			;;
		--confirm)
			CONFIRM=1
			shift
			;;
		--help | -h)
			usage
			exit 0
			;;
		*) die_usage "unknown flag: $1" ;;
		esac
	done

	WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/toolchain.XXXXXX")"

	case "$cmd" in
	capture) cmd_capture ;;
	check) cmd_check ;;
	apply) cmd_apply ;;
	esac
}

main "$@"
