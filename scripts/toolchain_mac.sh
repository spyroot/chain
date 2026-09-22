#!/bin/bash
# Explicit macOS entry point; the original toolchain.sh remains unchanged.
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
exec "$script_dir/toolchain.sh" "$@"
