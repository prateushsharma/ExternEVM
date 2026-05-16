//! ABI encoding/decoding utilities for ApiRequest and responses.
//!
//! Handles:
//!   - Decoding (string endpointId, bytes body, string responsePath, uint8 responseType)
//!   - Encoding response based on responseType (0=bytes, 1=uint256, 2=string, 3=bool)

// Implementation will be added in Chat 2.