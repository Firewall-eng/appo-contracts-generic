// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

/// @title CallerHelper
/// @notice Mock contract used as a call target for Caller.sol batch tests.
/// @dev Provides semantic helpers (calculatePrice for Borrow flows) and generic
///      behaviors: state mutation (increment), view read (get), forced revert (failAlways).
contract CallerHelper {
    uint256 public value;

    /// @notice Mock: "calculate" asset price for offchain Borrow program.
    /// @dev Any state change; here we increment for simplicity. Return value is a mock price.
    function calculatePrice() external returns (uint256) {
        value += 1; // does this to make it a non-static call for tests purposes
        return 1e18; // mock price
    }

    function increment() external returns (uint256) {
        value += 1;
        return value;
    }

    function get() external view returns (uint256) {
        return value;
    }

    function failAlways() external pure {
        revert("CallerHelper: forced failure");
    }
}
