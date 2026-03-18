// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {ISP1Verifier} from "sp1-contracts/ISP1Verifier.sol";

/// @title MockVerifier
/// @notice Test-only ISP1Verifier implementation that bypasses SP1 proof verification.
/// @dev Default behavior: accept all proofs. Set `shouldRevert = true` to simulate
///      verification failures. Since ISP1Verifier.verifyProof is `view`, this mock
///      cannot track call state — it only supports pass/revert behavior.
contract MockVerifier is ISP1Verifier {
    bool public shouldRevert;

    function setShouldRevert(bool _shouldRevert) external {
        shouldRevert = _shouldRevert;
    }

    function verifyProof(bytes32, bytes calldata, bytes calldata) external view override {
        if (shouldRevert) revert("MockVerifier: forced revert");
    }
}
