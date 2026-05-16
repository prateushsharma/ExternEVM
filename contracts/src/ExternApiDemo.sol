// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ExternApiDemo
/// @notice Demo contract that calls the ExternEVM API_CALL precompile at 0xAA.
/// @dev v0: single-node direct API mode only. NOT consensus-safe.
contract ExternApiDemo {
    address constant API_CALL =
        address(0x00000000000000000000000000000000000000AA);

    struct ApiRequest {
        string endpointId;    // e.g. "GOLD_RESERVE"
        bytes body;           // JSON payload
        string responsePath;  // e.g. "reserve" or "data.reserve"
        uint8 responseType;   // 0 = raw bytes, 1 = uint256, 2 = string, 3 = bool
    }

    /// @notice Calls the API_CALL precompile with a GOLD_RESERVE request.
    /// @return The reserve value as uint256.
    function getReserve() external view returns (uint256) {
        ApiRequest memory req = ApiRequest({
            endpointId: "GOLD_RESERVE",
            body: bytes('{"vaultId":"VAULT_1"}'),
            responsePath: "reserve",
            responseType: 1
        });

        (bool ok, bytes memory out) = API_CALL.staticcall(abi.encode(req));
        require(ok, "API_CALL_FAILED");

        return abi.decode(out, (uint256));
    }
}