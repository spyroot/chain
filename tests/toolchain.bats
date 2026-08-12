#!/usr/bin/env bats
# Tests for scripts/toolchain.sh. All external tools (brew, conda, rustup,
# npm) are stubbed via the CHAIN_* overrides; stubs record every invocation
# into $STUB_LOG, serve state from $STUB_DATA files, and fail on demand via
# $STUB_DATA/fail_* knob files — no test touches the real machine.

bats_require_minimum_version 1.5.0

SCRIPT="$BATS_TEST_DIRNAME/../scripts/toolchain.sh"

setup() {
  STUBS="$BATS_TEST_TMPDIR/stubs"
  export STUB_DATA="$BATS_TEST_TMPDIR/data"
  export STUB_LOG="$BATS_TEST_TMPDIR/stub.log"
  MANIFEST="$BATS_TEST_TMPDIR/manifest"
  mkdir -p "$STUBS" "$STUB_DATA"
  : >"$STUB_LOG"
  JQ="$(command -v jq || echo /usr/bin/jq)"

  cat >"$STUBS/brew" <<'EOF'
#!/bin/bash
echo "brew $*" >>"$STUB_LOG"
data() { [ -f "$STUB_DATA/$1" ] && cat "$STUB_DATA/$1"; return 0; }
case "$1" in
--version) echo "Homebrew 6.0.0-stub" ;;
tap) [ $# -eq 1 ] && data taps ;;
tap-info)
  n="$2"
  r=""
  [ -f "$STUB_DATA/tap_remotes" ] && r="$(awk -v n="$n" '$1 == n {print $2}' "$STUB_DATA/tap_remotes")"
  if [ "$r" = "null" ]; then
    printf '[\n  {\n    "name": "%s",\n    "remote": null\n  }\n]\n' "$n"
  else
    printf '[\n  {\n    "name": "%s",\n    "remote": "%s"\n  }\n]\n' "$n" "${r:-https://github.com/stub/homebrew-tap}"
  fi ;;
leaves)
  if [ -f "$STUB_DATA/fail_brew_list" ]; then exit 1; fi
  data leaves ;;
list)
  if [ -f "$STUB_DATA/fail_brew_list" ]; then exit 1; fi
  case "${2:-}" in
  --formula) data formulae ;;
  --cask) data casks ;;
  esac ;;
bundle)
  out=""
  for a in "$@"; do case "$a" in --file=*) out="${a#--file=}" ;; esac; done
  {
    data taps | sed 's/.*/tap "&"/'
    data formulae | sed 's/.*/brew "&"/'
    data casks | sed 's/.*/cask "&"/'
  } >"$out" ;;
install)
  if [ -f "$STUB_DATA/slurp_stdin" ]; then cat >/dev/null; fi
  if [ -f "$STUB_DATA/fail_brew_install" ]; then exit 1; fi ;;
esac
exit 0
EOF

  cat >"$STUBS/conda" <<'EOF'
#!/bin/bash
echo "conda $*" >>"$STUB_LOG"
case "$1 ${2:-}" in
"env list")
  echo "# conda environments:"
  echo "#"
  echo "base                     /stub/miniconda3"
  if [ -f "$STUB_DATA/conda_envs" ]; then
    while read -r e; do
      [ -n "$e" ] && printf '%s                /stub/envs/%s\n' "$e" "$e"
    done <"$STUB_DATA/conda_envs"
  fi ;;
"env export")
  if [ -f "$STUB_DATA/fail_conda_export" ]; then exit 1; fi
  if [ -f "$STUB_DATA/slow_conda_export" ]; then sleep 5; fi
  printf 'name: %s\nchannels:\n  - defaults\ndependencies:\n  - python=3.10\nprefix: /stub/envs/%s\n' "$4" "$4" ;;
"env create")
  if [ -f "$STUB_DATA/require_tos" ] && [ ! -f "$STUB_DATA/tos_accepted" ]; then exit 1; fi ;;
"tos accept")
  if [ -f "$STUB_DATA/fail_conda_tos" ]; then exit 2; fi
  touch "$STUB_DATA/tos_accepted" ;;
esac
exit 0
EOF

  cat >"$STUBS/rustup" <<'EOF'
#!/bin/bash
echo "rustup $*" >>"$STUB_LOG"
case "$1 ${2:-}" in
"toolchain list") [ -f "$STUB_DATA/rustup_list" ] && cat "$STUB_DATA/rustup_list" ;;
"toolchain install") : ;;
esac
exit 0
EOF

  cat >"$STUBS/npm" <<'EOF'
#!/bin/bash
echo "npm $*" >>"$STUB_LOG"
case "$1" in
ls)
  echo "/stub/lib/node_modules"
  [ -f "$STUB_DATA/npm_paths" ] && cat "$STUB_DATA/npm_paths" ;;
install) : ;;
esac
exit 0
EOF

  cat >"$STUBS/gitleaks" <<'EOF'
#!/bin/bash
echo "gitleaks $*" >>"$STUB_LOG"
exit 0
EOF

  chmod +x "$STUBS"/brew "$STUBS"/conda "$STUBS"/rustup "$STUBS"/npm "$STUBS"/gitleaks
  export CHAIN_BREW="$STUBS/brew"
  export CHAIN_CONDA="$STUBS/conda"
  export CHAIN_RUSTUP="$STUBS/rustup"
  export CHAIN_NPM="$STUBS/npm"
  export CHAIN_GITLEAKS="$STUBS/gitleaks"

  seed_default_data
}

seed_default_data() {
  printf 'homebrew/services\n' >"$STUB_DATA/taps"
  printf 'gcc\njq\n' >"$STUB_DATA/formulae"
  printf 'gcloud-cli\n' >"$STUB_DATA/casks"
  printf 'gcc\njq\n' >"$STUB_DATA/leaves"
  printf 'demo\nnv72\n' >"$STUB_DATA/conda_envs"
  printf 'stable-aarch64-apple-darwin (active, default)\n' >"$STUB_DATA/rustup_list"
  printf '/stub/lib/node_modules/@angular/cli\n/stub/lib/node_modules/js-beautify\n/stub/lib/node_modules/npm\n' \
    >"$STUB_DATA/npm_paths"
}

capture() {
  run "$SCRIPT" capture --manifest-dir "$MANIFEST"
  if [ "$status" -ne 0 ]; then
    echo "capture helper failed: status=$status output=$output"
    return 1
  fi
}

# ------------------------------------------------------------- CLI surface --

@test "help exits 0 and carries the audience tag" {
  run "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Audience: both"* ]]
  [[ "$output" == *"Exit codes"* ]]
}

@test "missing subcommand is a usage error (exit 2)" {
  run "$SCRIPT"
  [ "$status" -eq 2 ]
}

@test "unknown subcommand is a usage error (exit 2)" {
  run "$SCRIPT" frobnicate
  [ "$status" -eq 2 ]
}

@test "unknown flag is a usage error (exit 2)" {
  run "$SCRIPT" check --bogus
  [ "$status" -eq 2 ]
}

@test "unknown component is a usage error (exit 2)" {
  run "$SCRIPT" check --components brew,pipx
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown component"* ]]
}

@test "check without a manifest dir is a usage error naming capture" {
  run "$SCRIPT" check --manifest-dir "$BATS_TEST_TMPDIR/nope"
  [ "$status" -eq 2 ]
  [[ "$output" == *"capture"* ]]
}

@test "check on a dir with no manifest files is a usage error with error JSON" {
  mkdir -p "$BATS_TEST_TMPDIR/empty"
  run "$SCRIPT" check --manifest-dir "$BATS_TEST_TMPDIR/empty"
  [ "$status" -eq 2 ]
  [[ "$output" == *"capture"* ]]
  [[ "$output" == *'"status":"error"'* ]]
}

# ----------------------------------------------------------------- capture --

@test "capture writes all manifest files" {
  capture
  [ -f "$MANIFEST/Brewfile" ]
  [ -f "$MANIFEST/conda/envs.txt" ]
  [ -f "$MANIFEST/conda/demo.yml" ]
  [ -f "$MANIFEST/conda/nv72.yml" ]
  [ -f "$MANIFEST/rustup-toolchains.txt" ]
  [ -f "$MANIFEST/npm-globals.txt" ]
  [ -f "$MANIFEST/meta.json" ]
  grep -q 'brew "gcc"' "$MANIFEST/Brewfile"
  grep -q 'tap "homebrew/services"' "$MANIFEST/Brewfile"
}

@test "capture strips the prefix line from conda yamls" {
  capture
  grep -q '^name: demo' "$MANIFEST/conda/demo.yml"
  ! grep -q '^prefix:' "$MANIFEST/conda/demo.yml"
}

@test "capture excludes base env and keeps real env names" {
  capture
  run cat "$MANIFEST/conda/envs.txt"
  [[ "$output" == *"demo"* && "$output" == *"nv72"* ]]
  ! grep -q '^base$' "$MANIFEST/conda/envs.txt"
}

@test "capture skips nameless -p conda envs (path-only lines)" {
  printf 'demo\n' >"$STUB_DATA/conda_envs"
  # a nameless env line has a path as its first field; fake one via the stub
  printf '/stub/envs/pathonly\n' >>"$STUB_DATA/conda_envs"
  capture
  run cat "$MANIFEST/conda/envs.txt"
  [ "$output" = "demo" ]
}

@test "capture normalizes rustup toolchains to channel names" {
  capture
  run cat "$MANIFEST/rustup-toolchains.txt"
  [ "$output" = "stable" ]
}

@test "capture keeps scoped npm names and drops npm itself" {
  capture
  grep -q '^@angular/cli$' "$MANIFEST/npm-globals.txt"
  grep -q '^js-beautify$' "$MANIFEST/npm-globals.txt"
  ! grep -q '^npm$' "$MANIFEST/npm-globals.txt"
}

@test "capture meta.json is valid JSON with provenance fields" {
  capture
  run "$JQ" -e '.captured_at and .arch and .tool_version' "$MANIFEST/meta.json"
  [ "$status" -eq 0 ]
}

@test "capture with --components brew only writes only brew files" {
  run "$SCRIPT" capture --manifest-dir "$MANIFEST" --components brew
  [ "$status" -eq 0 ]
  [ -f "$MANIFEST/Brewfile" ]
  [ ! -d "$MANIFEST/conda" ]
  [ ! -f "$MANIFEST/npm-globals.txt" ]
}

@test "capture blocks with BLOCKER/SAFE_NEXT_STEP when brew is missing (exit 3)" {
  run env CHAIN_BREW=/nonexistent "$SCRIPT" capture --manifest-dir "$MANIFEST"
  [ "$status" -eq 3 ]
  [[ "$output" == *"BLOCKER"* ]]
  [[ "$output" == *"SAFE_NEXT_STEP"* ]]
}

@test "failed capture leaves the previous manifest untouched, emits error JSON, cleans workdir" {
  capture
  printf 'gcc\njq\nnewpkg\n' >"$STUB_DATA/formulae"
  touch "$STUB_DATA/fail_conda_export"
  mkdir -p "$BATS_TEST_TMPDIR/tmpd"
  run env TMPDIR="$BATS_TEST_TMPDIR/tmpd/" "$SCRIPT" capture --manifest-dir "$MANIFEST"
  [ "$status" -ne 0 ]
  [[ "$output" == *'"status":"error"'* ]]
  grep -q 'brew "gcc"' "$MANIFEST/Brewfile"
  ! grep -q 'brew "newpkg"' "$MANIFEST/Brewfile"
  [ -f "$MANIFEST/conda/demo.yml" ]
  [ -z "$(/bin/ls -A "$BATS_TEST_TMPDIR/tmpd")" ]
}

@test "interrupted capture cleans its workdir and leaves the manifest untouched" {
  touch "$STUB_DATA/slow_conda_export"
  mkdir -p "$BATS_TEST_TMPDIR/tmpd"
  TMPDIR="$BATS_TEST_TMPDIR/tmpd/" "$SCRIPT" capture --manifest-dir "$MANIFEST" \
    >"$BATS_TEST_TMPDIR/int.log" 2>&1 &
  local pid=$!
  sleep 1
  kill -TERM "$pid" 2>/dev/null || true
  local rc=0
  wait "$pid" || rc=$?
  [ "$rc" -eq 143 ]
  [ -z "$(/bin/ls -A "$BATS_TEST_TMPDIR/tmpd")" ]
  [ ! -f "$MANIFEST/meta.json" ]
  grep -q '"status":"error"' "$BATS_TEST_TMPDIR/int.log"
}

@test "capture drops taps without a git remote" {
  printf 'homebrew/services\nlocal/tap\n' >"$STUB_DATA/taps"
  printf 'local/tap null\n' >"$STUB_DATA/tap_remotes"
  run "$SCRIPT" capture --manifest-dir "$MANIFEST"
  [ "$status" -eq 0 ]
  [[ "$output" == *"dropping tap 'local/tap'"* ]]
  grep -q 'tap "homebrew/services"' "$MANIFEST/Brewfile"
  ! grep -q 'local/tap' "$MANIFEST/Brewfile"
}

@test "check ignores remoteless local taps on the machine side" {
  capture
  printf 'homebrew/services\nlocal/tap\n' >"$STUB_DATA/taps"
  printf 'local/tap null\n' >"$STUB_DATA/tap_remotes"
  run --separate-stderr "$SCRIPT" check --manifest-dir "$MANIFEST"
  [ "$status" -eq 0 ]
  echo "$output" | "$JQ" -e '.status == "in-sync" and .components.brew.extra_taps == []'
}

@test "re-capture prunes yamls of conda envs that no longer exist" {
  capture
  printf 'nv72\n' >"$STUB_DATA/conda_envs"
  capture
  [ ! -f "$MANIFEST/conda/demo.yml" ]
  [ -f "$MANIFEST/conda/nv72.yml" ]
  run cat "$MANIFEST/conda/envs.txt"
  [ "$output" = "nv72" ]
}

# ------------------------------------------------------------------- check --

@test "check is in-sync right after capture (exit 0)" {
  capture
  run --separate-stderr "$SCRIPT" check --manifest-dir "$MANIFEST"
  [ "$status" -eq 0 ]
  echo "$output" | "$JQ" -e '.status == "in-sync" and .missing_total == 0 and .extra_total == 0'
}

@test "check reports a removed formula as missing (exit 1)" {
  capture
  printf 'jq\n' >"$STUB_DATA/formulae"
  printf 'jq\n' >"$STUB_DATA/leaves"
  run --separate-stderr "$SCRIPT" check --manifest-dir "$MANIFEST"
  [ "$status" -eq 1 ]
  echo "$output" | "$JQ" -e '.components.brew.missing_formulae == ["gcc"]'
}

@test "check reports missing taps and casks" {
  capture
  : >"$STUB_DATA/taps"
  : >"$STUB_DATA/casks"
  run --separate-stderr "$SCRIPT" check --manifest-dir "$MANIFEST"
  [ "$status" -eq 1 ]
  echo "$output" | "$JQ" -e '.components.brew.missing_taps == ["homebrew/services"] and .components.brew.missing_casks == ["gcloud-cli"]'
}

@test "check reports an extra local formula without counting it missing" {
  capture
  printf 'gcc\njq\nzardoz\n' >"$STUB_DATA/formulae"
  printf 'gcc\njq\nzardoz\n' >"$STUB_DATA/leaves"
  run --separate-stderr "$SCRIPT" check --manifest-dir "$MANIFEST"
  [ "$status" -eq 1 ]
  echo "$output" | "$JQ" -e '.missing_total == 0 and .components.brew.extra_formulae == ["zardoz"]'
}

@test "check reports extras for conda, rustup, and npm" {
  capture
  printf 'demo\nghost\nnv72\n' >"$STUB_DATA/conda_envs"
  printf 'stable-aarch64-apple-darwin (active, default)\nnightly-aarch64-apple-darwin\n' >"$STUB_DATA/rustup_list"
  printf '/stub/lib/node_modules/@angular/cli\n/stub/lib/node_modules/js-beautify\n/stub/lib/node_modules/extra-pkg\n' \
    >"$STUB_DATA/npm_paths"
  run --separate-stderr "$SCRIPT" check --manifest-dir "$MANIFEST"
  [ "$status" -eq 1 ]
  echo "$output" | "$JQ" -e '.missing_total == 0 and .extra_total == 3'
  echo "$output" | "$JQ" -e '.components.conda.extra_envs == ["ghost"] and .components.rustup.extra_toolchains == ["nightly"] and .components.npm.extra_globals == ["extra-pkg"]'
}

@test "check with conda missing reports tool_missing and all envs missing-safe" {
  capture
  run --separate-stderr env CHAIN_CONDA=/nonexistent "$SCRIPT" check --manifest-dir "$MANIFEST"
  [ "$status" -eq 1 ]
  echo "$output" | "$JQ" -e '.components.conda.tool_missing == true'
}

@test "check with failing brew inventory reports tool_error, not mass drift" {
  capture
  touch "$STUB_DATA/fail_brew_list"
  run --separate-stderr "$SCRIPT" check --manifest-dir "$MANIFEST"
  [ "$status" -eq 1 ]
  echo "$output" | "$JQ" -e '.status == "drift" and .components.brew.tool_error == true'
  echo "$output" | "$JQ" -e '.components.brew.missing_formulae == [] and .missing_total == 0'
}

@test "check honors --components (unselected drift is invisible)" {
  capture
  printf 'nv72\n' >"$STUB_DATA/conda_envs"
  run --separate-stderr "$SCRIPT" check --manifest-dir "$MANIFEST" --components brew
  [ "$status" -eq 0 ]
  echo "$output" | "$JQ" -e '.status == "in-sync" and .components.conda == null'
}

@test "check JSON stays valid for manifest entries with quotes and spaces" {
  capture
  printf 'weird "name\n' >>"$MANIFEST/npm-globals.txt"
  run --separate-stderr "$SCRIPT" check --manifest-dir "$MANIFEST"
  [ "$status" -eq 1 ]
  echo "$output" | "$JQ" -e '.components.npm.missing_globals == ["weird \"name"]'
}

@test "check JSON escapes tabs in manifest entries" {
  capture
  printf 'tab\tname\n' >>"$MANIFEST/npm-globals.txt"
  run --separate-stderr "$SCRIPT" check --manifest-dir "$MANIFEST"
  [ "$status" -eq 1 ]
  echo "$output" | "$JQ" -e '.components.npm.missing_globals == ["tab\tname"]'
}

@test "check flags a selected component absent from the manifest" {
  run "$SCRIPT" capture --manifest-dir "$MANIFEST" --components brew
  [ "$status" -eq 0 ]
  run --separate-stderr "$SCRIPT" check --manifest-dir "$MANIFEST"
  [ "$status" -eq 1 ]
  echo "$output" | "$JQ" -e '.components.conda.manifest_missing == true and .components.brew.manifest_missing == false'
  echo "$output" | "$JQ" -e '.missing_total == 0'
}

@test "apply --confirm warns about and reports manifest-missing components" {
  run "$SCRIPT" capture --manifest-dir "$MANIFEST" --components brew
  [ "$status" -eq 0 ]
  run --separate-stderr "$SCRIPT" apply --manifest-dir "$MANIFEST" --confirm
  [ "$status" -eq 0 ]
  echo "$output" | "$JQ" -e '.manifest_missing == ["conda","rustup","npm"] and .actions_ok == 0'
  [[ "$stderr" == *"absent from manifest"* ]]
}

@test "tap-qualified Brewfile formulae compare by short name" {
  capture
  sed -i '' 's|brew "gcc"|brew "local/tap/gcc"|' "$MANIFEST/Brewfile"
  run --separate-stderr "$SCRIPT" check --manifest-dir "$MANIFEST"
  [ "$status" -eq 0 ]
  echo "$output" | "$JQ" -e '.status == "in-sync"'
}

# ------------------------------------------------------------------- apply --

@test "apply without --confirm plans but never mutates" {
  capture
  printf 'jq\n' >"$STUB_DATA/formulae"
  printf 'jq\n' >"$STUB_DATA/leaves"
  : >"$STUB_LOG"
  run --separate-stderr "$SCRIPT" apply --manifest-dir "$MANIFEST"
  [ "$status" -eq 0 ]
  echo "$output" | "$JQ" -e '.mode == "plan" and .missing_total == 1'
  ! grep -qE 'brew tap [^ ]|brew install|conda env create|conda tos|rustup toolchain install|npm install' "$STUB_LOG"
}

@test "apply --confirm installs exactly the missing items across components" {
  capture
  printf 'jq\n' >"$STUB_DATA/formulae"
  printf 'jq\n' >"$STUB_DATA/leaves"
  printf 'nv72\n' >"$STUB_DATA/conda_envs"
  : >"$STUB_DATA/rustup_list"
  printf '/stub/lib/node_modules/@angular/cli\n' >"$STUB_DATA/npm_paths"
  : >"$STUB_LOG"
  run --separate-stderr "$SCRIPT" apply --manifest-dir "$MANIFEST" --confirm
  [ "$status" -eq 0 ]
  echo "$output" | "$JQ" -e '.mode == "applied" and .actions_failed == 0 and .actions_ok == 4'
  grep -q 'brew install gcc' "$STUB_LOG"
  grep -q 'conda env create -n demo' "$STUB_LOG"
  grep -q 'rustup toolchain install stable' "$STUB_LOG"
  grep -q 'npm install -g js-beautify' "$STUB_LOG"
  ! grep -q 'brew install jq' "$STUB_LOG"
}

@test "apply --confirm installs missing taps and casks" {
  capture
  : >"$STUB_DATA/taps"
  : >"$STUB_DATA/casks"
  : >"$STUB_LOG"
  run --separate-stderr "$SCRIPT" apply --manifest-dir "$MANIFEST" --confirm
  [ "$status" -eq 0 ]
  grep -q 'brew tap homebrew/services' "$STUB_LOG"
  grep -q 'brew install --cask gcloud-cli' "$STUB_LOG"
}

@test "apply --confirm installs tap-qualified formulae by their full name" {
  capture
  sed -i '' 's|brew "gcc"|brew "local/tap/gcc"|' "$MANIFEST/Brewfile"
  printf 'jq\n' >"$STUB_DATA/formulae"
  printf 'jq\n' >"$STUB_DATA/leaves"
  : >"$STUB_LOG"
  run --separate-stderr "$SCRIPT" apply --manifest-dir "$MANIFEST" --confirm
  [ "$status" -eq 0 ]
  grep -q 'brew install local/tap/gcc' "$STUB_LOG"
}

@test "apply --confirm on an in-sync machine does nothing (idempotent)" {
  capture
  : >"$STUB_LOG"
  run --separate-stderr "$SCRIPT" apply --manifest-dir "$MANIFEST" --confirm
  [ "$status" -eq 0 ]
  echo "$output" | "$JQ" -e '.actions_ok == 0 and .actions_failed == 0'
  ! grep -qE 'brew tap [^ ]|brew install|conda env create|conda tos|rustup toolchain install|npm install' "$STUB_LOG"
}

@test "apply --confirm continues past a failed installer and reports it" {
  capture
  printf 'jq\n' >"$STUB_DATA/formulae"
  printf 'jq\n' >"$STUB_DATA/leaves"
  printf 'nv72\n' >"$STUB_DATA/conda_envs"
  touch "$STUB_DATA/fail_brew_install"
  : >"$STUB_LOG"
  run --separate-stderr "$SCRIPT" apply --manifest-dir "$MANIFEST" --confirm
  [ "$status" -eq 1 ]
  echo "$output" | "$JQ" -e '.actions_ok == 1 and .actions_failed == 1 and .failed == ["brew install gcc"]'
  grep -q 'conda env create -n demo' "$STUB_LOG"
}

@test "conda envs create only after ToS acceptance (ordering by contract)" {
  capture
  printf 'nv72\n' >"$STUB_DATA/conda_envs"
  touch "$STUB_DATA/require_tos"
  run --separate-stderr "$SCRIPT" apply --manifest-dir "$MANIFEST" --confirm
  [ "$status" -eq 0 ]
  echo "$output" | "$JQ" -e '.actions_failed == 0 and .actions_ok == 1'
  grep -q 'conda env create -n demo' "$STUB_LOG"
}

@test "apply succeeds when conda has no tos subcommand (old conda)" {
  capture
  printf 'nv72\n' >"$STUB_DATA/conda_envs"
  touch "$STUB_DATA/fail_conda_tos"
  run --separate-stderr "$SCRIPT" apply --manifest-dir "$MANIFEST" --confirm
  [ "$status" -eq 0 ]
  echo "$output" | "$JQ" -e '.actions_failed == 0 and .actions_ok == 1'
}

@test "a stdin-consuming installer does not eat the remaining work list" {
  capture
  : >"$STUB_DATA/formulae"
  : >"$STUB_DATA/leaves"
  printf 'nv72\n' >"$STUB_DATA/conda_envs"
  touch "$STUB_DATA/slurp_stdin"
  : >"$STUB_LOG"
  run --separate-stderr "$SCRIPT" apply --manifest-dir "$MANIFEST" --confirm
  [ "$status" -eq 0 ]
  grep -q 'brew install gcc' "$STUB_LOG"
  grep -q 'brew install jq' "$STUB_LOG"
  grep -q 'conda env create -n demo' "$STUB_LOG"
  echo "$output" | "$JQ" -e '.actions_failed == 0 and .actions_ok == 3'
}

@test "apply --confirm fails loudly when a conda yaml is absent from the manifest" {
  capture
  rm "$MANIFEST/conda/demo.yml"
  printf 'nv72\n' >"$STUB_DATA/conda_envs"
  run --separate-stderr "$SCRIPT" apply --manifest-dir "$MANIFEST" --confirm
  [ "$status" -eq 1 ]
  echo "$output" | "$JQ" -e '.actions_failed == 1 and (.failed[0] | contains("demo"))'
}

@test "apply --confirm bootstraps miniconda when conda is missing (issue #1)" {
  capture
  FAKECONDA="$BATS_TEST_TMPDIR/fakeconda"
  cat >"$BATS_TEST_TMPDIR/bootstrap" <<EOF
#!/bin/bash
echo "bootstrap ran" >>"\$STUB_LOG"
cp "$STUBS/conda" "$FAKECONDA" && chmod +x "$FAKECONDA"
: >"\$STUB_DATA/conda_envs"
EOF
  chmod +x "$BATS_TEST_TMPDIR/bootstrap"
  run --separate-stderr env CHAIN_CONDA="$FAKECONDA" \
    CHAIN_CONDA_BOOTSTRAP="$BATS_TEST_TMPDIR/bootstrap" \
    "$SCRIPT" apply --manifest-dir "$MANIFEST" --confirm
  [ "$status" -eq 0 ]
  echo "$output" | "$JQ" -e '.blocked == [] and .actions_failed == 0 and .actions_ok == 3'
  grep -q 'bootstrap ran' "$STUB_LOG"
  grep -q 'tos accept' "$STUB_LOG"
  grep -q 'conda env create -n demo' "$STUB_LOG"
  grep -q 'conda env create -n nv72' "$STUB_LOG"
}

@test "apply --confirm reports conda blocked when the bootstrap fails" {
  capture
  run --separate-stderr env CHAIN_CONDA=/nonexistent CHAIN_CONDA_BOOTSTRAP=/usr/bin/false \
    "$SCRIPT" apply --manifest-dir "$MANIFEST" --confirm
  [ "$status" -eq 3 ]
  echo "$output" | "$JQ" -e '.blocked == ["conda"] and .actions_failed == 1'
  [[ "$stderr" == *"BLOCKED"* ]]
}

@test "apply --confirm continues past a blocked rustup and still applies brew drift" {
  capture
  printf 'jq\n' >"$STUB_DATA/formulae"
  printf 'jq\n' >"$STUB_DATA/leaves"
  : >"$STUB_LOG"
  run --separate-stderr env CHAIN_RUSTUP=/nonexistent "$SCRIPT" apply --manifest-dir "$MANIFEST" --confirm
  [ "$status" -eq 3 ]
  echo "$output" | "$JQ" -e '.blocked == ["rustup"] and .actions_ok == 1'
  grep -q 'brew install gcc' "$STUB_LOG"
  [[ "$stderr" == *"BLOCKED"* ]]
}

@test "apply --confirm reports npm blocked when missing" {
  capture
  run --separate-stderr env CHAIN_NPM=/nonexistent "$SCRIPT" apply --manifest-dir "$MANIFEST" --confirm
  [ "$status" -eq 3 ]
  echo "$output" | "$JQ" -e '.blocked == ["npm"]'
}

@test "apply --confirm still hard-blocks when brew itself is missing" {
  capture
  run env CHAIN_BREW=/nonexistent "$SCRIPT" apply --manifest-dir "$MANIFEST" --confirm
  [ "$status" -eq 3 ]
  [[ "$output" == *"BLOCKER"* ]]
  [[ "$output" == *"SAFE_NEXT_STEP"* ]]
}

@test "apply --confirm --only installs just the named items" {
  capture
  : >"$STUB_DATA/formulae"
  : >"$STUB_DATA/leaves"
  printf 'nv72\n' >"$STUB_DATA/conda_envs"
  : >"$STUB_LOG"
  run --separate-stderr "$SCRIPT" apply --manifest-dir "$MANIFEST" --confirm --only jq
  [ "$status" -eq 0 ]
  echo "$output" | "$JQ" -e '.actions_ok == 1 and .blocked == []'
  grep -q 'brew install jq' "$STUB_LOG"
  ! grep -q 'brew install gcc' "$STUB_LOG"
  ! grep -q 'env create' "$STUB_LOG"
}

@test "apply --confirm --skip leaves the named items alone" {
  capture
  : >"$STUB_DATA/formulae"
  : >"$STUB_DATA/leaves"
  : >"$STUB_LOG"
  run --separate-stderr "$SCRIPT" apply --manifest-dir "$MANIFEST" --confirm --skip gcc
  [ "$status" -eq 0 ]
  grep -q 'brew install jq' "$STUB_LOG"
  ! grep -q 'brew install gcc' "$STUB_LOG"
}

@test "apply --only does not trigger the conda bootstrap" {
  capture
  : >"$STUB_DATA/formulae"
  : >"$STUB_DATA/leaves"
  : >"$STUB_LOG"
  run --separate-stderr env CHAIN_CONDA=/nonexistent CHAIN_CONDA_BOOTSTRAP=/usr/bin/false \
    "$SCRIPT" apply --manifest-dir "$MANIFEST" --confirm --only gcc
  [ "$status" -eq 0 ]
  echo "$output" | "$JQ" -e '.blocked == [] and .actions_ok == 1'
  ! grep -q 'bootstrap' "$STUB_LOG"
}

@test "apply plan respects --only" {
  capture
  : >"$STUB_DATA/formulae"
  : >"$STUB_DATA/leaves"
  run --separate-stderr "$SCRIPT" apply --manifest-dir "$MANIFEST" --only jq
  [ "$status" -eq 0 ]
  echo "$output" | "$JQ" -e '.missing_total == 1 and .components.brew.missing_formulae == ["jq"]'
}

@test "--only and --skip are rejected for check and capture" {
  run "$SCRIPT" check --only jq
  [ "$status" -eq 2 ]
  run "$SCRIPT" capture --skip jq
  [ "$status" -eq 2 ]
}

# ---------------------------------------------------------------- dotfiles --

seed_fake_home() {
  FAKEHOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$FAKEHOME/.vim/plugged/bigplugin" "$FAKEHOME/.config/gh"
  echo 'set number' >"$FAKEHOME/.vimrc"
  echo 'call plug#begin()' >"$FAKEHOME/.vim/autoload.vim"
  echo 'huge plugin blob' >"$FAKEHOME/.vim/plugged/bigplugin/plugin.vim"
  printf 'github.com:\n    user: spyroot\n' >"$FAKEHOME/.config/gh/hosts.yml"
  mkdir -p "$MANIFEST"
  printf '.vimrc\n.vim\n!.vim/plugged\n.config/gh\n' >"$MANIFEST/dotfiles.list"
}

@test "capture copies dotfiles, applies excludes, scrubs gh tokens" {
  seed_fake_home
  printf '    oauth_token: gho_FAKETESTTOKEN1234567890abcdef\n' >>"$FAKEHOME/.config/gh/hosts.yml"
  run env HOME="$FAKEHOME" "$SCRIPT" capture --manifest-dir "$MANIFEST" --components dotfiles
  [ "$status" -eq 0 ]
  [ -f "$MANIFEST/dotfiles/.vimrc" ]
  [ -f "$MANIFEST/dotfiles/.vim/autoload.vim" ]
  [ ! -d "$MANIFEST/dotfiles/.vim/plugged" ]
  [ -f "$MANIFEST/dotfiles/.config/gh/hosts.yml" ]
  ! grep -q 'oauth_token' "$MANIFEST/dotfiles/.config/gh/hosts.yml"
  grep -q 'user: spyroot' "$MANIFEST/dotfiles/.config/gh/hosts.yml"
}

@test "check flags differing dotfiles but ignores target-only files" {
  seed_fake_home
  run env HOME="$FAKEHOME" "$SCRIPT" capture --manifest-dir "$MANIFEST" --components dotfiles
  [ "$status" -eq 0 ]
  echo 'set nonumber' >"$FAKEHOME/.vimrc"
  echo 'local extra' >"$FAKEHOME/.vim/localonly.vim"
  run --separate-stderr env HOME="$FAKEHOME" "$SCRIPT" check --manifest-dir "$MANIFEST" --components dotfiles
  [ "$status" -eq 1 ]
  echo "$output" | "$JQ" -e '.components.dotfiles.missing_dotfiles == [".vimrc"]'
}

@test "apply --confirm syncs dotfiles without touching unlisted target files" {
  seed_fake_home
  run env HOME="$FAKEHOME" "$SCRIPT" capture --manifest-dir "$MANIFEST" --components dotfiles
  [ "$status" -eq 0 ]
  echo 'set nonumber' >"$FAKEHOME/.vimrc"
  echo 'local extra' >"$FAKEHOME/.vim/localonly.vim"
  run --separate-stderr env HOME="$FAKEHOME" "$SCRIPT" apply --manifest-dir "$MANIFEST" --components dotfiles --confirm
  [ "$status" -eq 0 ]
  echo "$output" | "$JQ" -e '.actions_ok == 1 and .actions_failed == 0'
  grep -q 'set number' "$FAKEHOME/.vimrc"
  [ -f "$FAKEHOME/.vim/localonly.vim" ]
  [ -f "$FAKEHOME/.vim/plugged/bigplugin/plugin.vim" ]
  run env HOME="$FAKEHOME" "$SCRIPT" check --manifest-dir "$MANIFEST" --components dotfiles
  [ "$status" -eq 0 ]
}

@test "capture blocks (exit 3) when the secret scan finds leaks" {
  seed_fake_home
  cat >"$BATS_TEST_TMPDIR/fakeleaks" <<'EOF'
#!/bin/bash
echo "leak found" >&2
exit 1
EOF
  chmod +x "$BATS_TEST_TMPDIR/fakeleaks"
  run env HOME="$FAKEHOME" CHAIN_GITLEAKS="$BATS_TEST_TMPDIR/fakeleaks" \
    "$SCRIPT" capture --manifest-dir "$MANIFEST" --components dotfiles
  [ "$status" -eq 3 ]
  [[ "$output" == *"BLOCKER"* ]]
  [[ "$output" == *"secrets detected"* ]]
  [ ! -d "$MANIFEST/dotfiles" ]
}

@test "capture warns and continues when gitleaks is unavailable" {
  seed_fake_home
  run env HOME="$FAKEHOME" CHAIN_GITLEAKS=/nonexistent \
    "$SCRIPT" capture --manifest-dir "$MANIFEST" --components dotfiles
  [ "$status" -eq 0 ]
  [[ "$output" == *"not secret-scanned"* ]]
  [ -f "$MANIFEST/dotfiles/.vimrc" ]
}

@test "check treats an unreadable dotfile target as drift, not in-sync" {
  seed_fake_home
  run env HOME="$FAKEHOME" "$SCRIPT" capture --manifest-dir "$MANIFEST" --components dotfiles
  [ "$status" -eq 0 ]
  chmod 000 "$FAKEHOME/.vimrc"
  run --separate-stderr env HOME="$FAKEHOME" "$SCRIPT" check --manifest-dir "$MANIFEST" --components dotfiles
  chmod 644 "$FAKEHOME/.vimrc"
  [ "$status" -eq 1 ]
  echo "$output" | "$JQ" -e '.components.dotfiles.missing_dotfiles == [".vimrc"]'
}

@test "empty --only, --skip, or --components values are usage errors" {
  run "$SCRIPT" apply --only ""
  [ "$status" -eq 2 ]
  run "$SCRIPT" apply --skip ""
  [ "$status" -eq 2 ]
  run "$SCRIPT" check --components ""
  [ "$status" -eq 2 ]
}

@test "apply --confirm --pretty shows progress markers and no JSON" {
  capture
  : >"$STUB_DATA/formulae"
  : >"$STUB_DATA/leaves"
  touch "$STUB_DATA/slurp_stdin"
  run --separate-stderr "$SCRIPT" apply --manifest-dir "$MANIFEST" --confirm --pretty
  [ "$status" -eq 0 ]
  [[ "$output" == *"[1/2] brew install gcc"* ]]
  [[ "$output" == *"[2/2] brew install jq"* ]]
  [[ "$output" == *"✅"* ]]
  [[ "$output" != *'"command"'* ]]
}

@test "malicious dotfiles.list entries are rejected (exit 2)" {
  seed_fake_home
  printf '../evil\n' >"$MANIFEST/dotfiles.list"
  run env HOME="$FAKEHOME" "$SCRIPT" capture --manifest-dir "$MANIFEST" --components dotfiles
  [ "$status" -eq 2 ]
  [[ "$output" == *"invalid dotfiles.list entry"* ]]
}

@test "dotfiles component is inert when no dotfiles.list exists" {
  capture
  run --separate-stderr "$SCRIPT" check --manifest-dir "$MANIFEST"
  [ "$status" -eq 0 ]
  echo "$output" | "$JQ" -e '.status == "in-sync" and .components.dotfiles == null'
}

# ------------------------------------------------------------ pretty mode --

@test "--pretty produces human output with no JSON" {
  capture
  run --separate-stderr "$SCRIPT" check --manifest-dir "$MANIFEST" --pretty
  [ "$status" -eq 0 ]
  [[ "$output" == *"in sync"* ]]
  [[ "$output" != *'"command"'* ]]
  run --separate-stderr "$SCRIPT" apply --manifest-dir "$MANIFEST" --pretty
  [ "$status" -eq 0 ]
  [[ "$output" == *"plan only"* ]]
}

@test "--json keeps machine output" {
  capture
  run --separate-stderr "$SCRIPT" check --manifest-dir "$MANIFEST" --json
  [ "$status" -eq 0 ]
  echo "$output" | "$JQ" -e '.command == "check"'
}

@test "apply --confirm blocks (exit 3) when brew inventory is failing" {
  capture
  touch "$STUB_DATA/fail_brew_list"
  run "$SCRIPT" apply --manifest-dir "$MANIFEST" --confirm
  [ "$status" -eq 3 ]
  [[ "$output" == *"BLOCKER"* ]]
  [[ "$output" == *"inventory"* ]]
}
