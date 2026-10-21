#!/usr/bin/env bash
# Builds and runs Tests/shim_test.c against the vendored libopenconnect
# (run scripts/build-openconnect.sh first).
set -euo pipefail
cd "$(dirname "$0")/.."

OC="$PWD/vendor/openconnect"
OUT="$(mktemp -d)/shim_test"
cc -Wall -Wextra -Wno-unused-parameter -I"$OC/include" -ISources/COpenConnectShim/include \
    Tests/shim_test.c -L"$OC/lib" -lopenconnect -lssl -lcrypto -lxml2 -lz -liconv -o "$OUT"
"$OUT"
