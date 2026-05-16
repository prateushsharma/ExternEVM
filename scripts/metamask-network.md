# MetaMask Network Configuration for ExternEVM

## Add Custom Network

Open MetaMask → Settings → Networks → Add Network

| Field            | Value                      |
|------------------|----------------------------|
| Network Name     | ExternEVM Local            |
| RPC URL          | http://127.0.0.1:8545      |
| Chain ID         | 1337                       |
| Currency Symbol  | XETH                       |
| Block Explorer   | *(leave empty)*            |

## Notes

- The node must be running locally before MetaMask can connect.
- Use `scripts/run-local.sh` to start the node.
- The `--dev` flag creates a dev account with pre-funded ETH.