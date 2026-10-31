#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
"$ROOT_DIR/scripts/build.sh"
exec "$ROOT_DIR/build/the_unobserved"
