#!/bin/bash
set -euo pipefail

echo "=== Deploy ExternApiDemo ==="
echo "This script deploys the demo contract to a running ExternEVM node."
echo ""
echo "Prerequisites:"
echo "  1. ExternEVM node running on localhost:8545"
echo "  2. Foundry installed (forge, cast)"
echo ""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$ROOT_DIR/contracts"

echo "Building contracts..."
forge build

echo ""
echo "To deploy manually via Remix:"
echo "  1. Open Remix IDE"
echo "  2. Create ExternApiDemo.sol with the contract code"
echo "  3. Compile with Solidity 0.8.24"
echo "  4. Deploy using Injected Provider (MetaMask)"
echo "  5. Call getReserve()"
echo ""
echo "To deploy via forge script (once a deployer key is configured):"
echo "  forge create src/ExternApiDemo.sol:ExternApiDemo --rpc-url http://127.0.0.1:8545 --private-key <DEPLOYER_KEY>"