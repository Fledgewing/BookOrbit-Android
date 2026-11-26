#!/usr/bin/env bash
# Portable entry point for the supplied full review check set.
# Acceptance assertions and exploratory probes are classified in run-suite.js/README.
set -euo pipefail
if [ "$#" -lt 2 ]; then
  echo "Usage: bash all.sh <prototype.html> <output-directory>" >&2
  exit 2
fi
check_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
exec node "$check_dir/../run-suite.js" "$@"
