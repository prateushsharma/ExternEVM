// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/ExternApiDemo.sol";

/// @notice Tests for ExternApiDemo.
/// @dev These tests will only pass on a running ExternEVM node with the
///      API_CALL precompile registered. Standard Foundry `forge test` will
///      fail because 0xAA is not a precompile in vanilla EVM.
contract ExternApiDemoTest is Test {
    ExternApiDemo demo;

    function setUp() public {
        demo = new ExternApiDemo();
    }

    // Tests will be added in Chat 4 once precompile is running.
}