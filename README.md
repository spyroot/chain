# chain

Replicate one mac's toolchain on another mac. One script captures this
machine's brew/conda/rustup/npm state into a versioned manifest; the same
script applies that manifest on a fresh machine.

## Layout

```
scripts/toolchain.sh     the CLI (capture | check | apply); audience: both agent and human
manifests/default/       the shared machine profile, written by `capture`
  Brewfile               taps + formulae + casks (brew bundle format)
  conda/envs.txt         conda env names; one pinned <env>.yml per env next to it
  rustup-toolchains.txt  rustup channel names (arch suffix stripped)
  npm-globals.txt        npm -g package names
  meta.json              capture provenance (host, arch, macOS, date)
tests/toolchain.bats     bats suite; all tools stubbed, never touches the machine
```

## Flow

On the source mac (this one):

```bash
scripts/toolchain.sh capture
```

Commit the resulting `manifests/default/` changes. On the new mac:

```bash
git clone https://github.com/spyroot/chain && cd chain
scripts/toolchain.sh check            # what differs (JSON, exit 1 on drift)
scripts/toolchain.sh apply            # dry-run plan, changes nothing
scripts/toolchain.sh apply --confirm  # install everything missing
```

`apply` only ever installs what is missing — it never uninstalls, never
upgrades existing packages, and is safe to re-run. If a prerequisite is
absent (Homebrew itself, Miniconda), the script exits 3 with a
`BLOCKER:`/`SAFE_NEXT_STEP:` pair on stderr telling you the exact bootstrap
command to run first; those two installers are deliberately left manual.
The same blocker fires when a tool is present but its inventory command
fails (`tool_error` in the JSON) — acting on unknown installed state would
reinstall, and thereby upgrade, everything. `capture` stages to a temp dir
and only replaces the manifest (per component) after every export
succeeded, so a mid-run failure cannot corrupt a committed manifest; fatal
failures still emit a `{"status":"error","exit_code":..}` object on stdout.

## Versioning philosophy

- **brew**: names only, no versions — brew self-updates constantly and the
  Brewfile (written by `capture` via `brew bundle dump`) tracks presence,
  not pins.
- **conda**: exact pinned versions per env (`conda env export --no-builds`,
  with the machine-local `prefix:` line stripped) — project envs are meant
  to be reproduced faithfully.
- **rustup**: channel names (`stable`, `nightly`) with the
  `-<arch>-apple-darwin` suffix stripped, so the same manifest works on
  arm64 and x86_64 macs.
- **npm**: global package names only.

## Contract

Non-interactive (mutation only behind `--confirm`), idempotent, JSON on
stdout, diagnostics on stderr. Exit codes: `0` ok/in-sync, `1` drift or a
failed action, `2` usage error, `3` blocker. Tool binaries resolve from
`CHAIN_BREW`/`CHAIN_CONDA`/`CHAIN_RUSTUP`/`CHAIN_NPM` overrides, then PATH,
then well-known locations. The script is deliberately bash-3.2 compatible
and pinned to `#!/bin/bash`: a fresh mac has no brew bash yet, and brew's
bash 5.3.15 intermittently segfaulted running these pipelines (3/60 repro
runs, 2026-08-11 — see the note in the script header) while `/bin/bash`
never did.

## Known limits

- `check` compares conda at env-presence granularity; it does not diff
  packages inside an existing env.
- Brewfile `args:`/options are not replayed; `apply` does per-item
  `brew install <name>` (tap-qualified Brewfile entries compare by short
  name but install by their full `tap/name`). Extras (installed locally,
  absent from the manifest — reported for every component) count as drift
  for `check`'s exit code but are never removed — `missing_total` in the
  JSON tells you whether `apply` would do anything.
- Casks that wrap a macOS `.pkg` (e.g. `mactex-no-gui`) make Homebrew run
  `sudo installer`, which prompts for a password on a TTY and fails without
  one — so an unattended `apply --confirm` records those casks as failed
  actions rather than hanging; re-run them attended.
- A cask renamed upstream can leave its old token in `brew list --cask`
  (e.g. `google-cloud-sdk` → `gcloud-cli`), which shows up as a permanent
  extra on the source machine until the old Caskroom entry is removed.
- Taps without a git remote (e.g. a hand-made `local/tap`) cannot be
  replayed on another machine, so `capture` drops them from the Brewfile
  with a warning and `check` ignores them on the machine side too.
- A component selected for `check` but absent from the manifest (say the
  manifest was captured with `--components brew` only) is reported as
  `manifest_missing` and counts as drift — exit 0 always means every
  selected component was actually compared.
- Not captured: App Store (`mas`) apps, VS Code extensions, and manually
  installed binaries such as `/usr/local/bin/kubectl`.
- Homebrew's installer needs the Xcode Command Line Tools; its own prompt
  handles that on a fresh mac.

## Tests

```bash
/Users/spyroot/miniconda3/envs/nv72-demo/bin/bats tests/toolchain.bats
```
