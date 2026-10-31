#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
mkdir -p build
OUTPUT_PATH="build/the_unobserved"
if [[ "${OS:-}" == "Windows_NT" ]]; then
	OUTPUT_PATH="${OUTPUT_PATH}.exe"
fi
odin build examples/unobserved/main -collection:rugops=. "-out:${OUTPUT_PATH}" -strict-style -vet
printf 'Built %s\n' "$OUTPUT_PATH"
