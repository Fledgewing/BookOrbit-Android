#!/usr/bin/env bash
# Coordinator only: no mutations by default. Never recreate the previous name.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec python3 "$ROOT/tools/rename-bridge.py" "$@"
