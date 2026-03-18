// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

/// @title ActivationSchedule
/// @notice A sorted array data structure for scheduling program hash upgrades by block number
library ActivationSchedule {
    struct Entry {
        bytes32 stfHash;
        bytes32 inclusionHash;
        uint256 activationBlock;
    }

    struct Schedule {
        Entry[] entries;
        uint256 startIndex;
    }

    error NoValidEntry();
    error ActivationInRange(uint256 activationBlock);
    error AppendBelowCurrent(uint256 activationBlock, uint256 currentBlock);
    error AppendBelowLast(uint256 activationBlock, uint256 lastBlock);
    error RetroInsertFinalized(uint256 activationBlock, uint256 finalizedBlock);
    /// @dev Reverts when a non-replacement retro insert targets the start entry.
    ///      The shift-right path needs entries[insertAt-1].stfHash, which is
    ///      unavailable at start (underflow or pruned). Replacement-at-start is
    ///      safe and permitted — it only overwrites guardHash from start onward.
    error RetroInsertBeforeStartIndex();

    /// @notice Append a future stf upgrade (must be after all existing entries)
    /// @param self The schedule to modify
    /// @param stfHash The stf program hash
    /// @param activationBlock Block number when the upgrade activates
    /// @param currentBlock Current block number (block.number)
    function appendStfUpgrade(Schedule storage self, bytes32 stfHash, uint256 activationBlock, uint256 currentBlock)
        internal
    {
        if (activationBlock < currentBlock) {
            revert AppendBelowCurrent(activationBlock, currentBlock);
        }

        // Invariant: there must be at least one entry after initialize()
        uint256 len = self.entries.length;
        Entry storage lastEntry = self.entries[len - 1];
        if (activationBlock <= lastEntry.activationBlock) {
            revert AppendBelowLast(activationBlock, lastEntry.activationBlock);
        }

        self.entries
            .push(Entry({stfHash: stfHash, inclusionHash: lastEntry.inclusionHash, activationBlock: activationBlock}));
    }

    /// @notice Append a future inclusion upgrade (must be after all existing entries)
    /// @param self The schedule to modify
    /// @param inclusionHash The inclusion program hash
    /// @param activationBlock Block number when the upgrade activates
    /// @param currentBlock Current block number (block.number)
    function appendInclusionUpgrade(
        Schedule storage self,
        bytes32 inclusionHash,
        uint256 activationBlock,
        uint256 currentBlock
    ) internal {
        if (activationBlock < currentBlock) {
            revert AppendBelowCurrent(activationBlock, currentBlock);
        }

        // Invariant: there must be at least one entry after initialize()
        uint256 len = self.entries.length;
        Entry storage lastEntry = self.entries[len - 1];
        if (activationBlock <= lastEntry.activationBlock) {
            revert AppendBelowLast(activationBlock, lastEntry.activationBlock);
        }

        self.entries
            .push(Entry({stfHash: lastEntry.stfHash, inclusionHash: inclusionHash, activationBlock: activationBlock}));
    }

    /// @notice Insert an upgrade at any point after finalized (for retroInclusionUpgrade)
    /// @param self The schedule to modify
    /// @param inclusionHash The inclusion program hash
    /// @param activationBlock Block number when the upgrade activates
    /// @param finalizedBlock Cannot insert before this block
    /// @dev Only called by retroInclusionUpgrade. Caller must increment resetId to invalidate affected proofs.
    function retroInclusionInsert(
        Schedule storage self,
        bytes32 inclusionHash,
        uint256 activationBlock,
        uint256 finalizedBlock
    ) internal {
        if (activationBlock <= finalizedBlock) {
            revert RetroInsertFinalized(activationBlock, finalizedBlock);
        }

        uint256 len = self.entries.length;
        uint256 start = self.startIndex;

        // Find insertion point (maintain ascending order by activationBlock)
        uint256 insertAt = len;
        bool replacement;
        if (activationBlock > self.entries[len - 1].activationBlock) {
            // skip looking for the insertion point, it's an append
        } else {
            for (uint256 i = start; i < len; i++) {
                uint256 entryActivation = self.entries[i].activationBlock;
                if (activationBlock <= entryActivation) {
                    insertAt = i;
                    replacement = activationBlock == entryActivation;
                    break;
                }
            }
        }

        if (insertAt == start && !replacement) {
            revert RetroInsertBeforeStartIndex();
        } else if (insertAt < len) {
            if (replacement) {
                // Do not shift elements, just overwrite the guard hash
                for (uint256 i = insertAt; i < len; i++) {
                    self.entries[i].inclusionHash = inclusionHash;
                }
            } else {
                // Shift elements right
                self.entries.push(self.entries[len - 1]);
                for (uint256 i = len; i > insertAt; i--) {
                    Entry storage prev = self.entries[i - 1];
                    self.entries[i] = Entry({
                        stfHash: prev.stfHash, inclusionHash: inclusionHash, activationBlock: prev.activationBlock
                    });
                }
                bytes32 prevStfHash = self.entries[insertAt - 1].stfHash;
                self.entries[insertAt] =
                    Entry({stfHash: prevStfHash, inclusionHash: inclusionHash, activationBlock: activationBlock});
            }
        } else {
            bytes32 lastStfHash = self.entries[len - 1].stfHash;
            self.entries
                .push(Entry({stfHash: lastStfHash, inclusionHash: inclusionHash, activationBlock: activationBlock}));
        }
    }

    /// @notice Get the hashes valid for a given block number
    /// @param self The schedule to query
    /// @param blockNumber The block number to look up
    /// @return stfHash The stf program hash valid for that block
    /// @return inclusionHash The inclusion program hash valid for that block
    function getHashesForBlock(Schedule storage self, uint256 blockNumber)
        internal
        view
        returns (bytes32 stfHash, bytes32 inclusionHash)
    {
        uint256 len = self.entries.length;
        uint256 start = self.startIndex;

        // Iterate backward from most recent
        for (uint256 i = len; i > start; i--) {
            Entry storage entry = self.entries[i - 1];
            if (blockNumber >= entry.activationBlock) {
                return (entry.stfHash, entry.inclusionHash);
            }
        }

        revert NoValidEntry();
    }

    /// @notice Get the stf and inclusion hashes to use for a proof block range
    /// @param self The schedule to query
    /// @param startBlock Start of the range (commitment exists here; not itself processed)
    /// @param endBlock End of the range (inclusive; last block processed)
    /// @return stfHash The stf hash to use for the range
    /// @return inclusionHash The inclusion hash to use for the range
    /// @dev A proof from startBlock to endBlock processes blocks [startBlock+1 .. endBlock].
    ///      All processed blocks must run under the same stf/inclusion program pair.
    ///      An activation at startBlock+1 is fine — every processed block uses the new hashes.
    ///      An activation anywhere in (startBlock+1, endBlock] splits the range across two
    ///      programs and reverts with ActivationInRange.
    ///
    ///      Example: activation at block 100.
    ///        prove(S, 99)  → allowed, uses old hashes (processed blocks [S+1..99])
    ///        prove(99, E)  → allowed, uses new hashes (activation at 99+1=100, all blocks [100..E] are new)
    ///        prove(50, E)  → reverts, activation at 100 is in (51, E] — mid-range program change
    function getHashesForProofRange(Schedule storage self, uint256 startBlock, uint256 endBlock)
        internal
        view
        returns (bytes32 stfHash, bytes32 inclusionHash)
    {
        uint256 len = self.entries.length;
        uint256 start = self.startIndex;

        bool foundEntry;

        // Backward scan:
        // - The proof processes blocks [startBlock+1 .. endBlock]. All must use the same hashes.
        // - An activation at startBlock+1 is allowed (all processed blocks use the new hashes).
        // - An activation at any block in (startBlock+1, endBlock] means a mid-range program
        //   change and causes a revert.
        // - The first entry with activationBlock <= startBlock+1 gives the hashes to use.
        for (uint256 i = len; i > start; i--) {
            Entry storage entry = self.entries[i - 1];

            if (entry.activationBlock <= endBlock) {
                if (entry.activationBlock > startBlock + 1) {
                    revert ActivationInRange(entry.activationBlock);
                }

                stfHash = entry.stfHash;
                inclusionHash = entry.inclusionHash;
                foundEntry = true;
                break;
            }
        }

        if (!foundEntry) {
            revert NoValidEntry();
        }

        return (stfHash, inclusionHash);
    }

    /// @notice Prune entries that are no longer needed (before finalized)
    /// @param self The schedule to prune
    /// @param finalizedBlock Entries strictly before this can be pruned
    /// @dev Keeps at least one entry (the currently active hashes)
    function prune(Schedule storage self, uint256 finalizedBlock) internal {
        uint256 len = self.entries.length;
        uint256 start = self.startIndex;

        // Advance startIndex while the *next* entry is also finalized
        // (we always keep at least one valid entry)
        while (start + 1 < len && self.entries[start + 1].activationBlock <= finalizedBlock) {
            start++;
        }

        self.startIndex = start;
    }

    /// @notice Get the number of active (non-pruned) entries
    /// @param self The schedule to query
    /// @return count Number of active entries
    function activeCount(Schedule storage self) internal view returns (uint256 count) {
        return self.entries.length - self.startIndex;
    }

    /// @notice Initialize the schedule with genesis hashes
    /// @param self The schedule to initialize
    /// @param stfHash The initial stf program hash
    /// @param inclusionHash The initial inclusion program hash
    /// @param genesisBlock The block from which these hashes are valid
    function initialize(Schedule storage self, bytes32 stfHash, bytes32 inclusionHash, uint256 genesisBlock) internal {
        self.entries.push(Entry({stfHash: stfHash, inclusionHash: inclusionHash, activationBlock: genesisBlock}));
        self.startIndex = 0;
    }
}
