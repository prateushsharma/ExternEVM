#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

echo "=== ExternEVM Local Node ==="
echo "Starting modified Reth..."

cd "$ROOT_DIR/reth"

cargo run --release -p reth -- node \
    --dev \
    --http \
    --http.addr 127.0.0.1 \
    --http.port 8545 \
    --http.api eth,net,web3,debug,trace \
    --ws \
    --ws.addr 127.0.0.1 \
    --ws.port 8546