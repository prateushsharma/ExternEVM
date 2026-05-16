//! ExternEVM custom precompile: API_CALL at 0xAA
//!
//! v0: single-node direct API mode.
//! See docs/architecture.md for details.

pub mod api_call;
pub mod api_config;
pub mod abi;
pub mod errors;

/// Precompile address for API_CALL
pub const API_CALL_ADDRESS: [u8; 20] = {
    let mut addr = [0u8; 20];
    addr[19] = 0xAA;
    addr
};