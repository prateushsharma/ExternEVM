# ExternEVM

**A custom Reth-based EVM runtime where Solidity smart contracts can call external APIs — during execution.**

> Normal smart contracts can't talk to the internet. ExternEVM changes that. Deploy a contract, call a function, and get live data from any public API — weather, crypto prices, space station coordinates — right inside the EVM.

---

## ⚠️ Warning

ExternEVM v0 is **single-node only**. Direct HTTP calls during EVM execution are non-deterministic and unsafe for multi-validator blockchains. This is an experimental research chain for development, demos, and prototyping. The long-term roadmap replaces direct calls with async request/finalize semantics and deterministic validator aggregation (see [Roadmap](#roadmap)).

---

## What This Actually Does

In a normal EVM chain, this is impossible:

```
Solidity contract → calls external API → gets live data back
```

Every EVM node must produce the same result for the same transaction. HTTP calls are non-deterministic. So every blockchain uses oracles — off-chain services that push data on-chain.

ExternEVM takes a different approach. It's a **custom EVM chain** built on a modified [Reth](https://github.com/paradigmxyz/reth) execution client. We added a **custom precompile** — a native Rust function baked into the EVM itself — at address `0x00000000000000000000000000000000000000AA`. When a Solidity contract calls that address, the node executes real Rust code that makes an HTTP request, parses the JSON response, ABI-encodes the result, and hands it back to the contract.

From the contract's perspective, it's just a `staticcall`. From the node's perspective, it's an HTTP round-trip happening inside block execution.

```
┌─────────────────────────────────┐
│  Solidity Contract              │
│  staticcall(0xAA, abi.encode…)  │
└──────────────┬──────────────────┘
               │
               ▼
┌─────────────────────────────────┐
│  Modified Reth EVM              │
│  Sees call to 0xAA              │
│  Routes to API_CALL precompile  │
└──────────────┬──────────────────┘
               │
               ▼
┌─────────────────────────────────┐
│  Native Rust Precompile         │
│  1. Decode ABI input            │
│  2. Validate URL + method       │
│  3. HTTP request (reqwest)      │
│  4. Parse JSON response         │
│  5. Extract field by JSON path  │
│  6. ABI-encode result           │
│  7. Return to EVM               │
└──────────────┬──────────────────┘
               │
               ▼
┌─────────────────────────────────┐
│  Contract receives result       │
│  abi.decode(out, (uint256))     │
│  Uses live data in logic        │
└─────────────────────────────────┘
```

---

## What's Been Built (Milestones Completed)

### Milestone 1 — Dummy Precompile
Forked Reth. Registered a custom precompile at `0xAA`. Any call returns `uint256(1234)`. ExternEVM is alive.

### Milestone 2 — Contract Deployment
Deployed `ExternApiDemo.sol` to the local chain using Foundry. Connected MetaMask. Called `getReserve()` from Remix. Got `1234` back through the precompile.

### Milestone 3 — ABI Decoding + Mock Responses
Rewrote the precompile to decode a full `ApiRequest` struct from calldata using `alloy-sol-types`. Added URL validation, method validation, private IP blocking, body size limits. Returns mock data based on URL keywords (weather → 72, gold → 2340, etc.).

### Milestone 4 — Real HTTP Calls
Replaced all mocks with actual HTTP requests using `reqwest::blocking` inside `tokio::task::block_in_place()`. Contracts now hit live APIs during execution. Bitcoin price from CoinGecko, weather from weather.gov, astronaut count from open-notify.org — all real.

### Milestone 5 — Docker
Containerized the node. `docker compose up --build` gives you a running ExternEVM node with RPC on port 8545.

---

## How It Works Under The Hood

### The Reth Fork

ExternEVM is built on [Reth](https://github.com/paradigmxyz/reth), Paradigm's Rust Ethereum execution client. The fork modifies one crate:

```
reth/crates/ethereum/evm/src/externevm.rs
```

This file contains:

- **The precompile function** — registered at address `0xAA`, called by the EVM when any contract does `staticcall` to that address.
- **`perform_http_call()`** — wraps `reqwest::blocking::Client` inside `tokio::task::block_in_place()` (Reth runs in a tokio async runtime; blocking HTTP inside async requires this escape hatch). Sets a 5-second timeout, blocks redirects, caps response at 32KB, sends `User-Agent: ExternEVM/0.4.0`.
- **`extract_json_path()`** — traverses JSON using dot notation (`bitcoin.usd`) and array indexing (`properties.periods[0].temperature`).
- **`encode_json_value()`** — converts a JSON value into ABI-encoded bytes based on the requested response type (uint256, string, bool, raw bytes).

### The Factory Wrapper

Reth uses an `EvmFactory` trait to construct EVM instances. The factory wrapper in `externevm.rs` intercepts precompile registration and injects the `API_CALL` precompile using:

```rust
DynPrecompile::new_stateful(PrecompileId::Custom("API_CALL".into()), api_call_fn)
precompiles.apply_precompile(&API_CALL_ADDRESS, |_| Some(dyn_precompile))
```

This means the precompile is available to every EVM execution context without modifying Reth's core EVM loop.

### Dependencies Added to Reth

Three dependencies were added to `reth/crates/ethereum/evm/Cargo.toml`:

```toml
reqwest = { version = "0.12", features = ["blocking", "json"] }
serde_json = { workspace = true, features = ["std"] }
tokio = { workspace = true, features = ["rt"] }
```

`reqwest` is the only non-workspace dependency — Reth doesn't use it directly, so it can't reference the workspace version. `serde_json` and `tokio` are workspace deps but needed the `std` and `rt` features respectively.

### Safety Checks

Even in single-node mode, the precompile enforces:

| Check | Behavior |
|---|---|
| URL scheme | Must start with `http://` or `https://` |
| Private IPs | Blocks `localhost`, `127.0.0.1`, `10.x.x.x`, `192.168.x.x`, `172.16-31.x.x` |
| HTTP method | Only `GET` and `POST` |
| Request body | Max 4,096 bytes |
| Response size | Max 32,768 bytes |
| Timeout | 5,000 ms |
| Redirects | Blocked entirely |
| Response type | Must be 0-3 |
| Gas cost | Fixed 3,000 gas per call |

---

## The ApiRequest Struct

Contracts communicate with the precompile through an ABI-encoded struct:

```solidity
struct ApiRequest {
    string url;            // Full URL — "https://api.coingecko.com/api/v3/simple/price?ids=bitcoin&vs_currencies=usd"
    string method;         // "GET" or "POST"
    bytes headers;         // JSON-encoded headers, e.g. '{"X-Api-Key":"abc123"}' or empty bytes
    bytes body;            // Request body for POST, empty for GET
    string responsePath;   // Dot-notation path to extract from JSON — "bitcoin.usd"
    uint8 responseType;    // 0 = raw bytes, 1 = uint256, 2 = string, 3 = bool
}
```

### Response Types

| Value | Type | What it does |
|---|---|---|
| 0 | `bytes` | Returns the raw JSON value as UTF-8 bytes |
| 1 | `uint256` | Parses number from JSON (handles floats by truncation, string-encoded numbers, comma-separated numbers, booleans) |
| 2 | `string` | Returns JSON string values directly, other types via `.to_string()` |
| 3 | `bool` | JSON bools, numbers (0 = false), strings ("true"/"1"/"yes"), null = false |

### Design Decision: Raw URLs, Not Endpoint IDs

The original spec used an `endpointId` model where contracts pass an ID like `"GOLD_RESERVE"` and the node operator maps it to a URL in a TOML config. We changed this to **raw URL mode** — contracts pass the full URL directly. This makes ExternEVM a universal API gateway where any developer can call any public API without node operator involvement.

---

## Tutorial: Writing Contracts for ExternEVM

### The Precompile Address

```solidity
address constant API_CALL = address(0x00000000000000000000000000000000000000AA);
```

This is a precompile — it's not a deployed contract. It exists at the EVM level. You don't need to deploy anything to use it.

### Basic Pattern

Every API call follows this pattern:

```solidity
// 1. Build the request
ApiRequest memory req = ApiRequest({
    url: "https://some-api.com/endpoint",
    method: "GET",
    headers: "",           // empty if no custom headers needed
    body: "",              // empty for GET
    responsePath: "data.value",
    responseType: 1        // uint256
});

// 2. Call the precompile
(bool ok, bytes memory out) = API_CALL.staticcall(abi.encode(req));
require(ok, "API_CALL failed");

// 3. Decode the response
uint256 result = abi.decode(out, (uint256));
```

### Complete Example Contract

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract MyApiContract {
    address constant API_CALL = address(0x00000000000000000000000000000000000000AA);

    struct ApiRequest {
        string url;
        string method;
        bytes headers;
        bytes body;
        string responsePath;
        uint8 responseType;
    }

    /// @notice Get the current Bitcoin price in USD from CoinGecko
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

    /// @notice Get the current Ethereum price in USD
    function getEthereumPrice() external view returns (uint256) {
        ApiRequest memory req = ApiRequest({
            url: "https://api.coingecko.com/api/v3/simple/price?ids=ethereum&vs_currencies=usd",
            method: "GET",
            headers: "",
            body: "",
            responsePath: "ethereum.usd",
            responseType: 1
        });
        (bool ok, bytes memory out) = API_CALL.staticcall(abi.encode(req));
        require(ok, "API_CALL failed");
        return abi.decode(out, (uint256));
    }

    /// @notice Get the number of people currently in space
    function getPeopleInSpace() external view returns (uint256) {
        ApiRequest memory req = ApiRequest({
            url: "http://api.open-notify.org/astros.json",
            method: "GET",
            headers: "",
            body: "",
            responsePath: "number",
            responseType: 1
        });
        (bool ok, bytes memory out) = API_CALL.staticcall(abi.encode(req));
        require(ok, "API_CALL failed");
        return abi.decode(out, (uint256));
    }

    /// @notice Get the ISS latitude as a string
    function getISSPosition() external view returns (string memory) {
        ApiRequest memory req = ApiRequest({
            url: "http://api.open-notify.org/iss-now.json",
            method: "GET",
            headers: "",
            body: "",
            responsePath: "iss_position.latitude",
            responseType: 2
        });
        (bool ok, bytes memory out) = API_CALL.staticcall(abi.encode(req));
        require(ok, "API_CALL failed");
        return abi.decode(out, (string));
    }

    /// @notice Get weather forecast for a US location
    function getTemperature() external view returns (uint256) {
        ApiRequest memory req = ApiRequest({
            url: "https://api.weather.gov/gridpoints/TOP/32,81/forecast",
            method: "GET",
            headers: "",
            body: "",
            responsePath: "properties.periods[0].temperature",
            responseType: 1
        });
        (bool ok, bytes memory out) = API_CALL.staticcall(abi.encode(req));
        require(ok, "API_CALL failed");
        return abi.decode(out, (uint256));
    }

    /// @notice Call any API with full control
    function callCustomApi(
        string calldata url,
        string calldata method,
        bytes calldata headers,
        bytes calldata body,
        string calldata responsePath,
        uint8 responseType
    ) external view returns (bytes memory) {
        ApiRequest memory req = ApiRequest({
            url: url,
            method: method,
            headers: headers,
            body: body,
            responsePath: responsePath,
            responseType: responseType
        });
        (bool ok, bytes memory out) = API_CALL.staticcall(abi.encode(req));
        require(ok, "API_CALL failed");
        return out;
    }
}
```

### JSON Path Syntax

The `responsePath` field uses dot notation with optional array indexing:

| JSON | Path | Result |
|---|---|---|
| `{"bitcoin": {"usd": 77004}}` | `bitcoin.usd` | `77004` |
| `{"properties": {"periods": [{"temperature": 72}]}}` | `properties.periods[0].temperature` | `72` |
| `{"number": 12}` | `number` | `12` |
| `{"data": "hello"}` | `data` | `"hello"` |
| `{...entire object...}` | `` (empty string) | The root JSON value |

### Tips for Contract Developers

1. **Always use `view` or `pure` functions** — API calls happen via `staticcall`, which doesn't modify state.
2. **Pick APIs that return JSON** — the precompile parses JSON only.
3. **Keep `responsePath` simple** — deep nesting works, but simpler paths are less fragile.
4. **Watch the response type** — if the API returns `"77004.50"` as a string and you want uint256, the precompile handles truncation. But if it returns `"not a number"`, the call will fail.
5. **No API keys in calldata** — if an API requires authentication, pass keys in the `headers` field as JSON: `'{"Authorization":"Bearer YOUR_KEY"}'`. Keys are visible on-chain in calldata, so this is fine for dev/demo but not for production secrets.
6. **Some APIs need User-Agent** — the precompile adds `User-Agent: ExternEVM/0.4.0` automatically. If an API needs a specific one, pass it in headers.

---

## Running Locally

### Prerequisites

- [Rust](https://rustup.rs/) (stable, 1.80+)
- [Foundry](https://book.getfoundry.sh/getting-started/installation) (forge, cast)
- Git

### 1. Clone the repo

```bash
git clone --recursive https://github.com/AKhilRaghworkerV/ExternEVM.git
cd ExternEVM
```

The `reth/` directory is a git submodule pointing to the modified Reth fork. `--recursive` pulls it automatically.

### 2. Build the modified Reth node

```bash
cd reth
cargo build --release
```

This takes 15-30 minutes on first build. Subsequent builds are fast.

### 3. Start the node

```bash
cargo run --release -- node \
  --dev \
  --chain ../config/genesis.json \
  --http \
  --http.api eth,net,web3,debug,trace \
  --http.addr 0.0.0.0 \
  --http.port 8545
```

The node runs in `--dev` mode (instant mining, pre-funded accounts, resets on restart).

### 4. Verify it's running

```bash
# In a new terminal
cast chain-id --rpc-url http://127.0.0.1:8545
# Should return: 22042004

# Test the precompile directly
cast call 0x00000000000000000000000000000000000000AA 0x --rpc-url http://127.0.0.1:8545
# Returns: ABI-encoded uint256(1234) — backward compatibility for empty input
```

### 5. Build and deploy a contract

```bash
cd ../contracts
forge build

forge create src/ExternApiDemo.sol:ExternApiDemo \
  --rpc-url http://127.0.0.1:8545 \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
  --broadcast
```

Note the deployed contract address from the output.

### 6. Call API functions

```bash
CONTRACT=0x5FbDB2315678afecb367f032d93F642f64180aa3  # replace with your address

# Get live Bitcoin price
cast call $CONTRACT "getBitcoinPrice()(uint256)" --rpc-url http://127.0.0.1:8545

# Get number of people in space right now
cast call $CONTRACT "getPeopleInSpace()(uint256)" --rpc-url http://127.0.0.1:8545

# Get ISS latitude
cast call $CONTRACT "getISSPosition()(string)" --rpc-url http://127.0.0.1:8545

# Get weather
cast call $CONTRACT "getWeather()(uint256)" --rpc-url http://127.0.0.1:8545
```

### 7. Connect MetaMask (optional)

Add a custom network in MetaMask:

| Field | Value |
|---|---|
| Network Name | ExternEVM Local |
| RPC URL | `http://127.0.0.1:8545` |
| Chain ID | `22042004` |
| Currency Symbol | `XETH` |

Import the dev private key to get pre-funded XETH:
```
0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
```

Now you can deploy and interact from Remix using "Injected Provider — MetaMask".

---

## Running With Docker

```bash
docker compose up --build
```

First build takes ~8 minutes (compiling Reth from source). The node starts on port 8545 with the same RPC interface as the local build.

The Docker setup uses:
- `rust:1.93` as the builder stage
- `debian:trixie-slim` as the runtime (must match the builder's glibc — bookworm doesn't work)
- A persistent volume for chain data at `/data`
- Genesis config mounted from `./config/genesis.json`

To interact with the Dockerized node, use the same `forge` and `cast` commands pointed at `http://127.0.0.1:8545`.

---

## Chain Configuration

| Parameter | Value |
|---|---|
| Chain ID | `22042004` |
| Consensus | Post-merge PoS from genesis |
| Gas Limit | 30,000,000 |
| All EVM forks | Activated at genesis (Homestead through Cancun) |
| Dev mode | Instant mining, no real validators |

### Pre-funded Dev Accounts

| Account | Private Key |
|---|---|
| `0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266` | `0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80` |
| `0x70997970C51812dc3A010C7d01b50e0d17dc79C8` | `0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d` |
| `0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC` | `0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a` |

These are the standard Hardhat/Anvil dev keys. **Never use them with real funds.**

---

## Repo Structure

```
externevm/
├── reth/                          # Modified Reth (git submodule)
│   └── crates/ethereum/evm/src/
│       └── externevm.rs           # ← The precompile lives here
│
├── contracts/                     # Solidity contracts (Foundry project)
│   ├── foundry.toml
│   ├── src/
│   │   ├── ExternApiDemo.sol      # Demo contract with API functions
│   │   ├── ExternAPI.sol          # Solidity library (future)
│   │   └── RWAReserveDemo.sol     # RWA reserve proof-of-concept
│   └── test/
│
├── config/
│   └── genesis.json               # Custom chain genesis (ID 22042004)
│
├── docker/
│   ├── reth.Dockerfile            # Multi-stage Reth build
│   └── entrypoint.sh              # Node startup script
│
├── docker-compose.yml
│
├── .github/workflows/
│   ├── ci.yml                     # Rust CI (fmt, clippy, test)
│   ├── contracts.yml              # Foundry CI (build, test)
│   └── docker.yml                 # Docker build CI
│
├── scripts/
│   ├── run-local.sh
│   ├── deploy-demo.sh
│   └── metamask-network.md
│
└── docs/
    ├── architecture.md
    ├── api-precompile.md
    ├── direct-api-mode.md
    ├── consensus-v2.md
    ├── solc-plan.md
    └── roadmap.md
```

---

## Key File: `externevm.rs`

The entire precompile implementation lives in one file. Here's what each function does:

| Function | Purpose |
|---|---|
| `api_call_precompile()` | Entry point. Decodes ABI input, validates fields, dispatches HTTP call, encodes response. Returns `uint256(1234)` for empty input (backward compat). |
| `perform_http_call()` | Builds and executes HTTP request using `reqwest::blocking::Client` inside `tokio::task::block_in_place()`. Handles GET/POST, custom headers, timeouts. |
| `extract_json_path()` | Navigates JSON using dot notation and array indexing. `"bitcoin.usd"` → `json["bitcoin"]["usd"]`. |
| `encode_json_value()` | Converts a `serde_json::Value` into ABI-encoded bytes matching the requested response type. |

### ABI Patterns (alloy-sol-types)

These were hard-won through compile errors:

```rust
// Encoding single values — MUST wrap in tuple:
(U256::from(val),).abi_encode_params()
(my_string,).abi_encode_params()

// Decoding the struct — use abi_decode, NOT abi_decode_params:
ApiRequest::abi_decode(input.data)

// PrecompileOutput:
PrecompileOutput::new(gas_used, bytes, reservoir)
PrecompileOutput::halt(PrecompileHalt::Other("msg".into()), reservoir)
```

---

## Roadmap

### Completed

- [x] Milestone 1 — Dummy precompile at `0xAA` returning `uint256(1234)`
- [x] Milestone 2 — Deploy contract from Remix/Foundry, call through MetaMask
- [x] Milestone 3 — ABI decoding, URL validation, mock responses
- [x] Milestone 4 — Real HTTP calls with `reqwest`, JSON path extraction, all 4 response types
- [x] Milestone 5 — Docker containerization

### Upcoming

- [ ] Milestone 6 — Cloud deployment (public RPC endpoint anyone can connect to)
- [ ] Milestone 7 — Async API mode (`API_REQUEST` at `0xA1` / `API_READ` at `0xA2`)
- [ ] Milestone 8 — Consensus research prototype (commit/reveal/median over API results)
- [ ] Milestone 9 — Experimental `solc` syntax (`api_call(...)` keyword lowered to precompile call)

### Future: Async API Mode

Direct HTTP during execution is a v0 shortcut. The production design uses two precompiles:

```
0xA1 = API_REQUEST  — contract submits a request, gets a requestId back
0xA2 = API_READ     — contract reads the finalized result by requestId
```

In single-node mode, one node finalizes immediately. In multi-node mode, validators independently fetch, commit hashes, reveal values, and the chain computes a deterministic median.

### Future: Multi-Validator Consensus

```
1. Contract creates API request
2. Validators observe the request
3. Each validator fetches data independently
4. Commit phase: validator submits hash(value, salt)
5. Reveal phase: validator submits value + salt
6. Chain verifies hash(value, salt)
7. If ≥ 2/3 validators reveal → compute median
8. Store finalized result on-chain
9. Contract reads finalized value
```

### Future: `solc` Modification

Replace the verbose `staticcall` pattern with native syntax:

```solidity
// Today (v0):
(bool ok, bytes memory out) = API_CALL.staticcall(abi.encode(req));
uint256 price = abi.decode(out, (uint256));

// Future:
uint256 price = api_call("https://api.coingecko.com/...", "bitcoin.usd");
```

The compiler would lower `api_call(...)` into the same precompile call, ABI encode/decode, and type checking — just without the boilerplate.

---

## Technical Notes

### Why `tokio::task::block_in_place()`?

Reth runs inside a tokio async runtime. Using `reqwest::blocking::Client` directly inside an async context panics with "Cannot start a runtime from within a runtime." `block_in_place()` tells tokio to temporarily convert the current async worker thread into a blocking thread, execute the HTTP call, and resume async work. It's the correct escape hatch for synchronous I/O inside an async runtime.

### Why `serde_json` needs `features = ["std"]`?

Reth's workspace defines `serde_json` with `alloc`-only by default (for no-std contexts). The precompile needs `std` features for full JSON parsing, so the crate-level dependency adds `features = ["std"]`.

### Why `debian:trixie-slim` and not `bookworm-slim`?

The Rust builder stage uses `rust:1.93`, which is based on Debian Trixie (13). The compiled binary links against glibc 2.38/2.39. Bookworm (12) ships older glibc and the binary segfaults on missing symbols. The runtime stage must match the builder's Debian version.

### Gas Cost

Fixed at 3,000 gas per precompile call. This is a placeholder. Future versions should price gas based on HTTP latency, response size, and computational complexity of JSON parsing.

---

## Contributing

ExternEVM is experimental research software. If you're interested in custom EVM runtimes, oracle alternatives, or consensus-safe external data — contributions are welcome.

The immediate areas that need work:

1. **Better error messages** — the precompile halts with generic strings; structured error codes would help debugging.
2. **Gas metering** — fixed 3,000 gas is a placeholder; real gas should reflect actual work done.
3. **More response types** — arrays, nested objects, multiple fields from one response.
4. **Solidity library** — a clean `ExternAPI.sol` wrapper that hides the ABI encoding boilerplate.
5. **Integration tests** — automated tests that spin up the node, deploy a contract, and verify API responses.

---

## License

MIT

---

*ExternEVM — because smart contracts shouldn't need a middleman to check the weather.*

Made with 💖 by Prateush Sharma
