#!/usr/bin/env bash
# Stable CLI for the Ubuntu NFS/SMB fstab installer. Audience: human and agent.
set -Eeuo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec /usr/bin/python3 "$script_dir/linux/storage/lab_mounts.py" "$@"
