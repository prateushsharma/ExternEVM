#!/bin/bash
set -euo pipefail

echo "Starting ExternEVM Reth node..."

exec reth node \
    --chain /config/genesis.json \
    --datadir /data \
    --http \
    --http.addr 0.0.0.0 \
    --http.port 8545 \
    --http.api eth,net,web3,debug,trace \
    --ws \
    --ws.addr 0.0.0.0 \
    --ws.port 8546 \
    "$@"