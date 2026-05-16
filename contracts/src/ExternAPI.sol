// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ExternAPI
/// @notice Solidity library for calling the ExternEVM API_CALL precompile.
/// @dev Provides a cleaner interface over raw staticcall to 0xAA.
///      Full implementation will be added in Chat 4.
library ExternAPI {
    address constant API_CALL =
        address(0x00000000000000000000000000000000000000AA);

    // Library functions will be added in Chat 4.
}