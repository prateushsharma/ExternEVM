# ExternEVM

**A custom EVM runtime with native external data access — from execution layer to consensus layer.**

> ExternEVM is a research blockchain protocol that embeds external API access directly into the EVM execution client, paired with a custom consensus layer implementing round-robin Proof of Authority over the Ethereum Engine API. Contracts call a native precompile. Validators fetch, aggregate, and finalize external data at the protocol level — no oracles, no middleware.

---

## ⚠️ Experimental Protocol

ExternEVM is research software. The v2 multi-node devnet uses a simplified consensus model (round-robin PoA) suitable for development and demonstration. The protocol roadmap progresses through commit-reveal schemes, stake-weighted consensus, and TEE-assisted verification (see [Protocol Evolution](#protocol-evolution)).

---

## Architecture Overview

ExternEVM is a two-component protocol following the post-merge Ethereum architecture ([EIP-3675](https://eips.ethereum.org/EIPS/eip-3675)):

```
┌─────────────────────────────────────────────────────────────┐
│                    ExternEVM Protocol                        │
│                                                              │
│  ┌──────────────────────┐    Engine API    ┌──────────────┐ │
│  │   Execution Layer    │◄───(EIP-3675)───►│  Consensus   │ │
│  │   (Modified Reth)    │    JWT Auth      │    Layer     │ │
│  │                      │   Port 8551      │              │ │
│  │  • API_CALL 0xAA     │                  │  • Round-    │ │
│  │  • extern/1 p2p      │                  │    Robin PoA │ │
│  │  • Protocol Store    │                  │  • Slot mgmt │ │
│  │  • Median aggregation│                  │  • Fork      │ │
│  │                      │                  │    choice    │ │
│  └──────────┬───────────┘                  └──────┬───────┘ │
│             │ eth/68 + extern/1                    │         │
│             └──────────────┬───────────────────────┘         │
│                            │                                 │
│                    ┌───────▼────────┐                        │
│                    │  Peer Nodes    │                        │
│                    │  (same stack)  │                        │
│                    └────────────────┘                        │
└─────────────────────────────────────────────────────────────┘
```

Each node runs two processes:

| Component | Binary | Role | Port |
|-----------|--------|------|------|
| Execution Layer | `reth` (modified) | Block execution, precompile, p2p value exchange | 8545 (RPC), 8551 (Engine API), 30303 (p2p) |
| Consensus Layer | `externevm-consensus` | Block production, proposer selection, fork choice | — (connects to EL) |

The EL and CL communicate exclusively through the **Engine API** ([Paris](https://github.com/ethereum/execution-apis/blob/main/src/engine/paris.md), [Cancun](https://github.com/ethereum/execution-apis/blob/main/src/engine/cancun.md)) with JWT authentication ([EIP-3675 Auth Spec](https://github.com/ethereum/execution-apis/blob/main/src/engine/authentication.md)). This mirrors the Lighthouse↔Geth / Prysm↔Reth architecture of production Ethereum, but with custom consensus logic.

---

## What This Does

Solidity contracts on ExternEVM can call external APIs during execution:

```solidity
function getBitcoinPrice() external view returns (uint256) {
    ApiRequest memory req = ApiRequest({
        url: "https://api.coingecko.com/api/v3/simple/price?ids=bitcoin&vs_currencies=usd",
        method: "GET",
        headers: "",
        body: "",
        responsePath: "bitcoin.usd",
        responseType: 1
    });
    (bool ok, bytes memory out) = API_CALL.staticcall(abi.encode(req));
    require(ok, "API_CALL failed");
    return abi.decode(out, (uint256));
}
```

In a multi-node deployment, each validator independently fetches the API, broadcasts its value via a custom devp2p subprotocol (`extern/1`), and the precompile returns the **median** of all validator submissions — tolerating minority Byzantine behavior without an external oracle network.

---

## Protocol Stack

### Execution Layer — Modified Reth

Built on [Reth](https://github.com/paradigmxyz/reth) v2.2.0 (Paradigm's Rust Ethereum execution client). Modifications are surgical — four files added to one crate (`reth-evm-ethereum`):

| File | Purpose | Lines |
|------|---------|-------|
| `externevm.rs` | `ExternEvmFactory` — injects `API_CALL` precompile at `0xAA`, performs HTTP fetch via `reqwest::blocking` inside `tokio::task::block_in_place()`, stores value in protocol store, broadcasts via `extern/1`, computes median/majority, returns aggregated result | ~500 |
| `protocol_store.rs` | Thread-safe in-memory storage (`Arc<RwLock<>>` + `LazyLock` singleton) — pending requests, validator submissions, finalized results, median aggregation for uint256, majority vote for string/bool | ~400 |
| `extern_proto.rs` | `ExternDataMsg` (RLP-encoded wire message), global `tokio::sync::broadcast` channel, deterministic `compute_request_hash()` via `keccak256(url ‖ 0xFF ‖ method ‖ 0xFF ‖ responsePath ‖ 0xFF ‖ responseType)` | ~120 |
| `extern_p2p.rs` | `ProtocolHandler` + `ConnectionHandler` + `Stream` impl — registers `extern/1` as a custom RLPx subprotocol, bidirectional: local precompile → broadcast to peers, peer messages → protocol store | ~200 |

The precompile is registered using Reth's `EvmFactory` trait, injected via `DynPrecompile` and `PrecompilesMap::apply_precompile`. No modifications to Reth's core EVM loop, block production pipeline, or consensus engine.

#### Precompile Interface

```
Address:  0x00000000000000000000000000000000000000AA
Name:     API_CALL
Gas:      3,000 (fixed, placeholder)
Input:    abi.encode(ApiRequest)
Output:   abi.encode(value) where value type depends on responseType
```

```solidity
struct ApiRequest {
    string url;            // Full URL
    string method;         // "GET" or "POST"
    bytes headers;         // JSON-encoded headers or empty
    bytes body;            // Request body or empty
    string responsePath;   // Dot-notation JSON path — "bitcoin.usd"
    uint8 responseType;    // 0=bytes, 1=uint256, 2=string, 3=bool
}
```

#### Safety Enforcement

| Check | Constraint |
|-------|-----------|
| URL scheme | `http://` or `https://` only |
| Private IPs | Blocks `127.0.0.0/8`, `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16` |
| HTTP method | `GET` and `POST` only |
| Request body | ≤ 4,096 bytes |
| Response size | ≤ 32,768 bytes |
| Timeout | 5,000 ms |
| Redirects | Blocked |

#### Multi-Node Aggregation (v2)

When multiple validators are active, the precompile:

1. Fetches the API independently on the local node
2. Stores the value in the protocol store with a deterministic request hash
3. Broadcasts `ExternDataMsg` to all peers via the `extern/1` RLPx subprotocol
4. Waits `EXTERNEVM_PEER_WAIT_MS` (default 300ms) for peer values
5. Computes the aggregate: **median** for `uint256`, **majority vote** for `string`/`bool`
6. Returns the aggregated result

The median is Byzantine-fault-tolerant: a single malicious validator cannot shift it. As long as >50% of validators are honest, the median reflects reality.

### Consensus Layer — `externevm-consensus`

A standalone Rust binary implementing **Round-Robin Proof of Authority** over the Ethereum Engine API. Zero Reth dependencies — pure HTTP client using `reqwest` + `serde_json` + `jsonwebtoken`.

The design follows [EIP-225](https://eips.ethereum.org/EIPS/eip-225) (Clique PoA) conceptually but is implemented as a separate consensus layer binary communicating over the Engine API, matching the post-merge Ethereum architecture rather than embedding consensus in the execution client.

#### Engine API Methods Used

| Method | Spec | Purpose |
|--------|------|---------|
| `engine_forkchoiceUpdatedV3` | [Cancun](https://github.com/ethereum/execution-apis/blob/main/src/engine/cancun.md#engine_forkchoiceupdatedv3) | Set chain head + trigger block building |
| `engine_getPayloadV3` | [Cancun](https://github.com/ethereum/execution-apis/blob/main/src/engine/cancun.md#engine_getpayloadv3) | Retrieve built block |
| `engine_newPayloadV3` | [Cancun](https://github.com/ethereum/execution-apis/blob/main/src/engine/cancun.md#engine_newpayloadv3) | Submit block for validation and execution |

Authentication uses the [Engine API JWT spec](https://github.com/ethereum/execution-apis/blob/main/src/engine/authentication.md) — HS256 tokens with `iat` claim, regenerated every request, validated against a shared 32-byte secret.

#### Consensus Model

```
Slot time:     5 seconds (configurable)
Validator set: Fixed, defined at startup
Selection:     Round-robin — proposer(slot) = validators[slot % count]
Finality:      Instant (PoA — proposer's block is canonical)
Fork choice:   Longest chain
```

#### Block Production Flow

```
Proposer CL (slot N belongs to this validator):
│
├─ engine_forkchoiceUpdatedV3(head, payloadAttributes)
│   → Reth starts building block with pending transactions
│   → Returns payload_id
│
├─ [wait 1 second for block assembly]
│
├─ engine_getPayloadV3(payload_id)
│   → Reth returns ExecutionPayloadV3 (the complete block)
│
├─ engine_newPayloadV3(payload) → ALL EL nodes
│   → Each Reth validates and executes the block
│   → Returns VALID / INVALID
│
└─ engine_forkchoiceUpdatedV3(new_head) → ALL EL nodes
    → Each Reth updates canonical chain head

Non-proposer CL:
│
└─ Polls local Reth via eth_getBlockByNumber("latest")
   → Tracks chain head as blocks arrive
```

#### `ConsensusStrategy` Trait

The consensus logic is behind a trait — the swap point for future upgrades:

```rust
pub trait ConsensusStrategy {
    fn proposer_for_slot(&self, slot: u64) -> String;
    fn is_my_turn(&self, slot: u64, my_address: &str) -> bool;
    fn validator_count(&self) -> usize;
}
```

v2 implements `RoundRobin`. v4 will implement `StakeWeighted`. Same Engine API calls, same CL binary structure, different selection logic.

#### CL Source Structure

```
consensus/
├── Cargo.toml
└── src/
    ├── main.rs           # Slot loop, CLI (clap), proposer/non-proposer flow
    ├── engine_api.rs     # Engine API HTTP client — JWT auth, 3 core methods
    ├── jwt.rs            # JWT token generation (HS256, iat claim)
    ├── consensus.rs      # ConsensusStrategy trait definition
    ├── round_robin.rs    # v2 round-robin implementation + unit tests
    └── types.rs          # Serde types matching Engine API JSON wire format
```

---

## Running the Multi-Node Devnet

### Prerequisites

- [Rust](https://rustup.rs/) stable 1.80+
- [Foundry](https://book.getfoundry.sh/getting-started/installation) (forge, cast)
- 6 terminal windows (3 EL + 3 CL)

### 1. Clone and build

```bash
git clone --recursive https://github.com/ExternEVM/ExternEVM.git
cd ExternEVM

# Build the execution layer
cd reth && cargo build --release && cd ..

# Build the consensus layer
cd consensus && cargo build && cd ..

# Generate JWT secret (shared by all nodes)
openssl rand -hex 32 > config/jwt.hex
```

### 2. Start 3 EL nodes

Start Node 1 first and note the enode URL from the logs:

```bash
# Node 1 — EL
EXTERNEVM_VALIDATOR_ADDRESS=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 \
cargo run --release -- node \
  --chain ../config/genesis.json \
  --http --http.api eth,net,web3,debug,trace,admin \
  --http.addr 0.0.0.0 --http.port 8545 \
  --authrpc.port 8551 --authrpc.jwtsecret ../config/jwt.hex \
  --port 30303 --discovery.port 30303 --discovery.v5.port 9200 \
  --datadir /tmp/externevm-node1
```

Copy the `enode://...@...` URL from Node 1's logs, replace the IP with `127.0.0.1`, and pass it to Nodes 2 and 3 via `--trusted-peers`.

```bash
# Node 2 — EL
EXTERNEVM_VALIDATOR_ADDRESS=0x70997970C51812dc3A010C7d01b50e0d17dc79C8 \
cargo run --release -- node \
  --chain ../config/genesis.json \
  --http --http.api eth,net,web3,debug,trace,admin \
  --http.addr 0.0.0.0 --http.port 8546 \
  --authrpc.port 8552 --authrpc.jwtsecret ../config/jwt.hex \
  --port 30304 --discovery.port 30304 --discovery.v5.port 9201 \
  --datadir /tmp/externevm-node2 \
  --trusted-peers enode://<NODE1_PUBKEY>@127.0.0.1:30303
```

```bash
# Node 3 — EL
EXTERNEVM_VALIDATOR_ADDRESS=0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC \
cargo run --release -- node \
  --chain ../config/genesis.json \
  --http --http.api eth,net,web3,debug,trace,admin \
  --http.addr 0.0.0.0 --http.port 8547 \
  --authrpc.port 8553 --authrpc.jwtsecret ../config/jwt.hex \
  --port 30305 --discovery.port 30305 --discovery.v5.port 9202 \
  --datadir /tmp/externevm-node3 \
  --trusted-peers enode://<NODE1_PUBKEY>@127.0.0.1:30303
```

### 3. Start 3 CL nodes

```bash
# Node 1 — CL
cargo run -- \
  --validator 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 \
  --validators 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266,0x70997970C51812dc3A010C7d01b50e0d17dc79C8,0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC \
  --el-auth-url http://127.0.0.1:8551 --el-rpc-url http://127.0.0.1:8545 \
  --all-el-auth-urls http://127.0.0.1:8551,http://127.0.0.1:8552,http://127.0.0.1:8553 \
  --jwt-secret ../config/jwt.hex --slot-time 5
```

```bash
# Node 2 — CL (change --validator, --el-auth-url, --el-rpc-url)
cargo run -- \
  --validator 0x70997970C51812dc3A010C7d01b50e0d17dc79C8 \
  --validators 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266,0x70997970C51812dc3A010C7d01b50e0d17dc79C8,0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC \
  --el-auth-url http://127.0.0.1:8552 --el-rpc-url http://127.0.0.1:8546 \
  --all-el-auth-urls http://127.0.0.1:8551,http://127.0.0.1:8552,http://127.0.0.1:8553 \
  --jwt-secret ../config/jwt.hex --slot-time 5
```

```bash
# Node 3 — CL (change --validator, --el-auth-url, --el-rpc-url)
cargo run -- \
  --validator 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC \
  --validators 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266,0x70997970C51812dc3A010C7d01b50e0d17dc79C8,0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC \
  --el-auth-url http://127.0.0.1:8553 --el-rpc-url http://127.0.0.1:8547 \
  --all-el-auth-urls http://127.0.0.1:8551,http://127.0.0.1:8552,http://127.0.0.1:8553 \
  --jwt-secret ../config/jwt.hex --slot-time 5
```

### 4. Verify block production

The CL logs show round-robin block production:

```
[CL] Slot 0 — I AM THE PROPOSER (block 1)
[CL]   Step 1: forkchoiceUpdated (start building)
[CL]   Payload ID: 0x55b6f5a78f8a1e98
[CL]   Step 2: Waiting 1s for block assembly...
[CL]   Step 3: getPayload
[CL]   Block #1 hash: 0x64f93c22...cef3e0
[CL]   Step 4: newPayload → 3 EL nodes
[CL]     Node 1: newPayload → VALID
[CL]     Node 2: newPayload → VALID
[CL]     Node 3: newPayload → VALID
[CL]   Step 5: forkchoiceUpdated (set head) → 3 EL nodes
[CL] Block 1 produced and submitted to all nodes
[CL] Slot 1 — proposer is 0x70997970... — waiting
[CL] Received block 2 (hash: 0xe2c219d3...)
[CL] Slot 2 — proposer is 0x3c44cddd... — waiting
[CL] Received block 3 (hash: 0xfe9b3309...)
[CL] Slot 3 — I AM THE PROPOSER (block 4)
```

### 5. Deploy and test contracts

```bash
# Deploy to Node 1
cd contracts && forge build
forge create src/ExternApiDemo.sol:ExternApiDemo \
  --rpc-url http://127.0.0.1:8545 \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
  --broadcast

# Query from any node
CONTRACT=<deployed_address>
cast call $CONTRACT "getBitcoinPrice()(uint256)" --rpc-url http://127.0.0.1:8545
cast call $CONTRACT "getPeopleInSpace()(uint256)" --rpc-url http://127.0.0.1:8546
cast call $CONTRACT "getISSPosition()(string)" --rpc-url http://127.0.0.1:8547
```

---

## Chain Configuration

| Parameter | Value |
|-----------|-------|
| Chain ID | `22042004` |
| Consensus | Round-Robin PoA (3 validators) |
| Slot Time | 5 seconds |
| Gas Limit | 30,000,000 |
| EVM Forks | All activated at genesis (Homestead → Cancun) |
| Merge | Active from genesis ([EIP-3675](https://eips.ethereum.org/EIPS/eip-3675)) |
| PREVRANDAO | Deterministic per-slot hash ([EIP-4399](https://eips.ethereum.org/EIPS/eip-4399)) |

### Pre-funded Validator Accounts

| Validator | Address | Private Key |
|-----------|---------|-------------|
| Node 1 | `0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266` | `0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80` |
| Node 2 | `0x70997970C51812dc3A010C7d01b50e0d17dc79C8` | `0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d` |
| Node 3 | `0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC` | `0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a` |

Standard Hardhat/Anvil dev keys. **Never use with real funds.**

---

## Repo Structure

```
ExternEVM/
├── reth/                                    # Execution Layer (git submodule — modified Reth)
│   ├── crates/ethereum/evm/src/
│   │   ├── externevm.rs                     # ExternEvmFactory + API_CALL precompile
│   │   ├── protocol_store.rs                # In-memory protocol store + aggregation
│   │   ├── extern_proto.rs                  # ExternDataMsg + broadcast channel
│   │   └── lib.rs                           # Module exports
│   └── bin/reth/src/
│       ├── main.rs                          # Node binary + subprotocol registration
│       └── extern_p2p.rs                    # ProtocolHandler + ConnectionHandler
│
├── consensus/                               # Consensus Layer (standalone binary)
│   ├── Cargo.toml
│   └── src/
│       ├── main.rs                          # Slot loop + CLI
│       ├── engine_api.rs                    # Engine API client (JWT + 3 methods)
│       ├── jwt.rs                           # JWT token generation
│       ├── consensus.rs                     # ConsensusStrategy trait
│       ├── round_robin.rs                   # v2 PoA implementation
│       └── types.rs                         # Engine API JSON types
│
├── contracts/                               # Solidity contracts (Foundry)
│   ├── foundry.toml
│   └── src/ExternApiDemo.sol                # Demo contract with API functions
│
├── config/
│   ├── genesis.json                         # Chain genesis (ID 22042004, all forks active)
│   └── jwt.hex                              # Shared JWT secret for EL↔CL auth
│
├── docker/
│   ├── reth.Dockerfile
│   └── entrypoint.sh
│
└── docker-compose.yml
```

---

## Protocol Evolution

ExternEVM is designed as a progressive protocol — each version ships independently while maintaining contract compatibility through the stable `ApiRequest` ABI interface.

| Version | Consensus | Trust Model | Data Latency | Status |
|---------|-----------|-------------|--------------|--------|
| **v1** | None (single operator) | Trust operator completely | Instant | ✅ Complete |
| **v2** | Round-Robin PoA + median aggregation | Honest majority (>50%) | Same block | ✅ Complete |
| **v3** | Commit-reveal + median | Honest supermajority (>2/3) | 4-6 blocks | Planned |
| **v4** | Stake-weighted + slashing | Economic security | 4-6 blocks | Research |
| **v5** | TEE-assisted + ZK proof of fetch | Cryptographic proof | 1-2 blocks | Research |

### Upgrade Path

The `ConsensusStrategy` trait in the CL binary is the swap point. The Engine API layer (`engine_api.rs`, `jwt.rs`) never changes. Upgrading consensus means implementing a new strategy and recompiling the CL binary — the EL stays untouched.

```
v2: RoundRobin::proposer_for_slot(slot) = validators[slot % count]
v4: StakeWeighted::proposer_for_slot(slot) = weighted_selection(stakes, slot)
```

New precompiles (`0xA1` API_REQUEST, `0xA2` API_READ) for the async two-step pattern are EL changes planned for v3, independent of consensus upgrades.

---

## References and Standards

| Specification | Relevance |
|---------------|-----------|
| [EIP-3675](https://eips.ethereum.org/EIPS/eip-3675) — The Merge | EL/CL separation architecture |
| [EIP-225](https://eips.ethereum.org/EIPS/eip-225) — Clique PoA | Round-robin proposer selection design reference |
| [EIP-4399](https://eips.ethereum.org/EIPS/eip-4399) — PREVRANDAO | Post-merge randomness field in payload attributes |
| [Engine API — Paris](https://github.com/ethereum/execution-apis/blob/main/src/engine/paris.md) | `forkchoiceUpdated`, `newPayload`, `getPayload` |
| [Engine API — Cancun](https://github.com/ethereum/execution-apis/blob/main/src/engine/cancun.md) | V3 methods with `parentBeaconBlockRoot` |
| [Engine API — Auth](https://github.com/ethereum/execution-apis/blob/main/src/engine/authentication.md) | JWT authentication spec |
| [Chainlink Whitepaper v1](https://research.chain.link/whitepaper-v1.pdf) | Oracle network design (application-layer comparison) |
| [Chainlink Whitepaper v2](https://research.chain.link/whitepaper-v2.pdf) | Off-chain reporting protocol |
| [TLSNotary](https://tlsnotary.org/) | TLS proof of fetch (v5 reference) |

---

## Technical Notes

### Why `tokio::task::block_in_place()`?

Reth runs inside a tokio async runtime. `reqwest::blocking::Client` inside an async context panics with "Cannot start a runtime from within a runtime." `block_in_place()` tells tokio to temporarily convert the current async worker thread into a blocking thread, execute the HTTP call, then resume. This is the documented escape hatch for synchronous I/O in async runtimes.

### Why a Separate CL Binary?

Post-merge Ethereum separates execution (Geth/Reth/Nethermind) from consensus (Lighthouse/Prysm/Teku/Lodestar). ExternEVM follows this architecture because consensus upgrades (v2→v3→v4→v5) should not require modifying the execution client. The Engine API is the stable boundary — three HTTP methods that never change regardless of what consensus model runs above them.

### Why Round-Robin Instead of PoS?

For a 3-node research devnet, round-robin PoA ([EIP-225](https://eips.ethereum.org/EIPS/eip-225) style) eliminates staking contract complexity while demonstrating the correct EL/CL architecture. The `ConsensusStrategy` trait makes swapping to stake-weighted selection a single-file change in the CL binary.

### Gas Cost

Fixed at 3,000 gas per `API_CALL`. This is a placeholder. Production gas metering should account for HTTP latency, response size, and JSON parsing complexity.

---

## Contributing

ExternEVM is experimental research software exploring whether external data access should be a protocol-level primitive rather than an application-layer service. Areas that need work:

1. **Multi-node API testing** — verify median aggregation with 3 nodes fetching independently
2. **Docker compose for 3-node cluster** — single command to spin up the full devnet
3. **Gas metering** — dynamic pricing based on actual work performed
4. **Solidity library** — `ExternAPI.sol` wrapper hiding the ABI encoding boilerplate
5. **Integration tests** — automated tests that deploy contracts and verify API responses
6. **CL-level p2p** — replace direct Engine API calls to remote ELs with proper CL gossip

---

## License

MIT

---

*ExternEVM — protocol-level external data for smart contracts.*

Made with 💖 by Prateush Sharma
