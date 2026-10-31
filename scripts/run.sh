#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
"$ROOT_DIR/scripts/build.sh"
BINARY_PATH="$ROOT_DIR/build/the_unobserved"
if [[ "${OS:-}" == "Windows_NT" ]]; then
	BINARY_PATH="${BINARY_PATH}.exe"
fi
exec "$BINARY_PATH"
