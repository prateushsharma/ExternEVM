# Direct API Mode — Warning

## This mode is NOT consensus-safe.

Direct HTTP calls during EVM execution are non-deterministic. Two nodes calling the same API at different times may receive different responses, breaking consensus.

## When to use direct API mode

- Local development
- Single-node demos
- Experimentation and prototyping

## When NOT to use direct API mode

- Multi-validator networks
- Production deployments
- Any scenario requiring deterministic execution

## Future replacement

See `consensus-v2.md` for the async request/finalize design.