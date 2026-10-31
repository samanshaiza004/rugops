#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
mkdir -p build
odin build examples/unobserved/main -collection:rugops=. -out:build/the_unobserved -strict-style -vet
printf 'Built build/the_unobserved\n'
