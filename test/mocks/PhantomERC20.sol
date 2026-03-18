// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

/// @title PhantomERC20
/// @notice Minimal IERC20-compatible contract whose transferFrom always returns
///         true without moving any tokens. Used to test that Vault.enterErc20
///         records an accumulator action for a deposit the Vault never received.
contract PhantomERC20 {
    function transferFrom(address, address, uint256) external pure returns (bool) {
        return true;
    }

    function balanceOf(address) external pure returns (uint256) {
        return 0;
    }
}
