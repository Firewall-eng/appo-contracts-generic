// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {ActivationSchedule} from "../../src/libraries/ActivationSchedule.sol";

/// @title ActivationScheduleHarness
/// @notice Exposes ActivationSchedule internals for direct unit/invariant testing.
/// @dev Bypasses Prover's admin checks and resetId logic so we can test the
///      schedule data structure in isolation.
contract ActivationScheduleHarness {
    using ActivationSchedule for ActivationSchedule.Schedule;

    ActivationSchedule.Schedule private schedule;

    function initialize(bytes32 stfHash, bytes32 inclusionHash, uint256 genesisBlock) external {
        schedule.initialize(stfHash, inclusionHash, genesisBlock);
    }

    function appendStfUpgrade(bytes32 stfHash, uint256 activationBlock, uint256 currentBlock) external {
        schedule.appendStfUpgrade(stfHash, activationBlock, currentBlock);
    }

    function appendInclusionUpgrade(bytes32 inclusionHash, uint256 activationBlock, uint256 currentBlock) external {
        schedule.appendInclusionUpgrade(inclusionHash, activationBlock, currentBlock);
    }

    function retroInclusionInsert(bytes32 inclusionHash, uint256 activationBlock, uint256 finalizedBlock) external {
        schedule.retroInclusionInsert(inclusionHash, activationBlock, finalizedBlock);
    }

    function getHashesForBlock(uint256 blockNumber) external view returns (bytes32 stfHash, bytes32 inclusionHash) {
        return schedule.getHashesForBlock(blockNumber);
    }

    function getHashesForProofRange(uint256 startBlock, uint256 endBlock)
        external
        view
        returns (bytes32 stfHash, bytes32 inclusionHash)
    {
        return schedule.getHashesForProofRange(startBlock, endBlock);
    }

    function prune(uint256 finalizedBlock) external {
        schedule.prune(finalizedBlock);
    }

    function activeCount() external view returns (uint256) {
        return schedule.activeCount();
    }

    function startIndex() external view returns (uint256) {
        return schedule.startIndex;
    }

    function entryCount() external view returns (uint256) {
        return schedule.entries.length;
    }

    function getEntry(uint256 index)
        external
        view
        returns (bytes32 stfHash, bytes32 inclusionHash, uint256 activationBlock)
    {
        ActivationSchedule.Entry storage e = schedule.entries[index];
        return (e.stfHash, e.inclusionHash, e.activationBlock);
    }

    /// @notice Check all schedule invariants. Reverts with a descriptive message on violation.
    function checkInvariants() external view {
        uint256 len = schedule.entries.length;
        uint256 start = schedule.startIndex;

        require(len > 0, "INV: entries must be non-empty after initialize");
        require(start < len, "INV: startIndex must be < entries.length");

        for (uint256 i = start + 1; i < len; i++) {
            require(
                schedule.entries[i].activationBlock > schedule.entries[i - 1].activationBlock,
                "INV: activationBlocks must be strictly ascending"
            );
        }

        for (uint256 i = start; i < len; i++) {
            require(schedule.entries[i].stfHash != bytes32(0), "INV: stfHash must be non-zero");
        }
    }

    /// @notice Check inclusion hash propagation invariant: all active entries at or after
    ///         `fromBlock` must have `expectedInclusionHash`.
    function checkInclusionPropagation(uint256 fromBlock, bytes32 expectedInclusionHash) external view {
        uint256 len = schedule.entries.length;
        uint256 start = schedule.startIndex;

        for (uint256 i = start; i < len; i++) {
            if (schedule.entries[i].activationBlock >= fromBlock) {
                require(
                    schedule.entries[i].inclusionHash == expectedInclusionHash,
                    "INV: inclusion hash not propagated to entry at/after fromBlock"
                );
            }
        }
    }

    /// @notice Check that stf hashes are untouched at specific indices.
    function checkStfPreserved(uint256 index, bytes32 expectedStfHash) external view {
        require(
            schedule.entries[index].stfHash == expectedStfHash, "INV: stf hash was modified when it should be preserved"
        );
    }
}
