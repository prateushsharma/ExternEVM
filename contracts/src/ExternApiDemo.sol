// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ExternApiDemo — showcases ExternEVM's API_CALL precompile
/// @notice Milestone 4: precompile performs REAL HTTP calls and returns live data.
contract ExternApiDemo {
    address constant API_CALL =
        address(0x00000000000000000000000000000000000000AA);

    struct ApiRequest {
        string url;
        string method;
        bytes headers;
        bytes body;
        string responsePath;
        uint8 responseType;
    }

    /// @notice Backward compat — empty input returns uint256(1234)
    function getReserveDummy() external view returns (uint256) {
        (bool ok, bytes memory out) = API_CALL.staticcall("");
        require(ok, "API_CALL failed");
        require(out.length == 32, "unexpected output length");
        return abi.decode(out, (uint256));
    }

    /// @notice REAL weather temperature from weather.gov
    function getWeather() external view returns (uint256) {
        ApiRequest memory req = ApiRequest({
            url: "https://api.weather.gov/gridpoints/TOP/31,80/forecast",
            method: "GET",
            headers: bytes(""),
            body: bytes(""),
            responsePath: "properties.periods[0].temperature",
            responseType: 1
        });
        (bool ok, bytes memory out) = API_CALL.staticcall(abi.encode(req));
        require(ok, "API_CALL failed");
        return abi.decode(out, (uint256));
    }

    /// @notice REAL weather description from weather.gov
    function getWeatherDescription() external view returns (string memory) {
        ApiRequest memory req = ApiRequest({
            url: "https://api.weather.gov/gridpoints/TOP/31,80/forecast",
            method: "GET",
            headers: bytes(""),
            body: bytes(""),
            responsePath: "properties.periods[0].shortForecast",
            responseType: 2
        });
        (bool ok, bytes memory out) = API_CALL.staticcall(abi.encode(req));
        require(ok, "API_CALL failed");
        return abi.decode(out, (string));
    }

    /// @notice REAL ISS position latitude
    function getISSPosition() external view returns (string memory) {
        ApiRequest memory req = ApiRequest({
            url: "http://api.open-notify.org/iss-now.json",
            method: "GET",
            headers: bytes(""),
            body: bytes(""),
            responsePath: "iss_position.latitude",
            responseType: 2
        });
        (bool ok, bytes memory out) = API_CALL.staticcall(abi.encode(req));
        require(ok, "API_CALL failed");
        return abi.decode(out, (string));
    }

    /// @notice REAL people count currently in space
    function getPeopleInSpace() external view returns (uint256) {
        ApiRequest memory req = ApiRequest({
            url: "http://api.open-notify.org/astros.json",
            method: "GET",
            headers: bytes(""),
            body: bytes(""),
            responsePath: "number",
            responseType: 1
        });
        (bool ok, bytes memory out) = API_CALL.staticcall(abi.encode(req));
        require(ok, "API_CALL failed");
        return abi.decode(out, (uint256));
    }

    /// @notice REAL Bitcoin price from CoinGecko
    function getBitcoinPrice() external view returns (uint256) {
        ApiRequest memory req = ApiRequest({
            url: "https://api.coingecko.com/api/v3/simple/price?ids=bitcoin&vs_currencies=usd",
            method: "GET",
            headers: bytes(""),
            body: bytes(""),
            responsePath: "bitcoin.usd",
            responseType: 1
        });
        (bool ok, bytes memory out) = API_CALL.staticcall(abi.encode(req));
        require(ok, "API_CALL failed");
        return abi.decode(out, (uint256));
    }

    /// @notice REAL Ethereum price from CoinGecko
    function getEthereumPrice() external view returns (uint256) {
        ApiRequest memory req = ApiRequest({
            url: "https://api.coingecko.com/api/v3/simple/price?ids=ethereum&vs_currencies=usd",
            method: "GET",
            headers: bytes(""),
            body: bytes(""),
            responsePath: "ethereum.usd",
            responseType: 1
        });
        (bool ok, bytes memory out) = API_CALL.staticcall(abi.encode(req));
        require(ok, "API_CALL failed");
        return abi.decode(out, (uint256));
    }

    /// @notice Generic API caller
    function callCustomApi(
        string calldata url,
        string calldata method,
        string calldata responsePath,
        uint8 responseType
    ) external view returns (bytes memory) {
        ApiRequest memory req = ApiRequest({
            url: url,
            method: method,
            headers: bytes(""),
            body: bytes(""),
            responsePath: responsePath,
            responseType: responseType
        });
        (bool ok, bytes memory out) = API_CALL.staticcall(abi.encode(req));
        require(ok, "API_CALL failed");
        return out;
    }

    /// @notice Raw precompile call
    function rawApiCall(bytes calldata data) external view returns (bytes memory) {
        (bool ok, bytes memory out) = API_CALL.staticcall(data);
        require(ok, "API_CALL failed");
        return out;
    }
}