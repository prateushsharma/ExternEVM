# Consensus-Safe External Data (v2 Design)

> Future design. Not implemented in v0.

## Overview

Replace direct HTTP calls with async request/finalize:

1. Contract calls `API_REQUEST(endpointId, payload)` → receives `requestId`
2. Validators independently fetch data
3. Commit phase: validators submit `hash(value, salt)`
4. Reveal phase: validators submit `value + salt`
5. Protocol verifies hashes, computes median
6. Contract calls `API_READ(requestId)` → receives finalized value

## Precompile Addresses

- `0xA1` — API_REQUEST
- `0xA2` — API_READ

TODO: Expand after Milestone 7.