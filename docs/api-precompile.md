# API_CALL Precompile

Address: `0x00000000000000000000000000000000000000AA`

## Input Format

ABI-encoded `ApiRequest`:
- `string endpointId` — registered endpoint identifier
- `bytes body` — JSON request payload
- `string responsePath` — dot-separated path into JSON response
- `uint8 responseType` — 0=bytes, 1=uint256, 2=string, 3=bool

## Output Format

ABI-encoded response matching `responseType`.

## Gas Cost

Fixed 3000 gas (v0).

TODO: Expand after Milestone 3.