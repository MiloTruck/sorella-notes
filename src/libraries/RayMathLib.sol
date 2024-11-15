// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @author philogy <https://github.com/philogy>
/// @dev Similar to "wad math" except that the decimals used is a bit higher for the sake of
/// precision. Done to accomodate tokens that maybe have very large denominations.
library RayMathLib {
    uint256 internal constant RAY = 1e27;
    uint256 internal constant RAY_2 = 1e54;

    function mulRay(uint256 x, uint256 y) internal pure returns (uint256) {
        return x * y / RAY;
    }

    function divRay(uint256 x, uint256 y) internal pure returns (uint256) {
        return x * RAY / y;
    }

    function invRayUnchecked(uint256 x) internal pure returns (uint256 y) {
        assembly {
            y := div(RAY_2, x)
        }
    }

    function wadToRay(uint256 x) internal pure returns (uint256) {
        return x * 1e9;
    }

    function rayToWad(uint256 x) internal pure returns (uint256) {
        return x / 1e9;
    }
}
