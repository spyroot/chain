# Scripts

- `toolchain.sh`: original macOS toolchain CLI, unchanged. The explicit
  `toolchain_mac.sh` alias invokes it.
- `toolchain_linux.sh`: Ubuntu apt/npm and editor bootstrap. Package names
  live in `../manifests/linux/apt-packages.txt` and `npm-globals.txt`;
  `editor-files.txt` selects portable Vim/Neovim files from the shared
  dotfiles. `apply` plans; `sudo toolchain_linux.sh apply --confirm` installs
  missing items and restores editor plugins for the checkout owner, including
  YouCompleteMe's native module with system Python.
  Existing `--dry-run`/`--apply` flags still work. Terminals get a compact
  progress view; pipes get JSON. Linux installs Vim, Neovim, Cascadia Code,
  and Powerline fonts; the macOS manifest retains VS Code and its Nerd Font.
- `install_sshconfig.sh`: install a separate OpenSSH Host fragment for the
  current login user. Pass `--spec FILE`; no private key is copied.
- `linux/network/add_lab_routes.sh`: Ubuntu Netplan route CLI. Pass a
  machine-specific YAML file with `--config`, or put it at
  `../specs/linux/network/lab_routes.yaml` for the default path. Use
  `../specs/linux/network/lab_routes.example.yaml` as a format example.
- `linux/network/add_labdns.sh`: host-only Ubuntu split DNS. Pass a private
  YAML file with `--config`; use `linux/network/lab_dns.example.yaml` only as
  a format example. It does not change BIND or client-facing DNS.
- `install_labmounts.sh`: Ubuntu NFS/SMB fstab CLI. The default spec is
  `../specs/linux/storage/lab_mounts.yaml`, resolved from the script location,
  not the current working directory. Pass a mount key, such as `k8s`, to select
  one named entry under `mounts:`. Each entry's `type` selects NFS or SMB, so
  the same spec can contain several of each. Pass `--config FILE` to use
  another spec. `--apply` changes only that key's managed fstab block and
  reloads systemd; it installs `nfs-common` or `cifs-utils` only if the selected
  mount helper is missing. It does not mount now.
  Mount the chosen target separately after checking the NAS export.
  `../specs/linux/storage/lab_mounts.example.yaml` shows both NFS and SMB
  entries. From `scripts/`, test with `./install_labmounts.sh k8s --dry-run`.
  SMB credentials belong in a private mode-0600 file.

Keep real lab addresses, credentials, SSH host entries, and private keys out of
this public repository. The Linux route script does not configure DNS.
