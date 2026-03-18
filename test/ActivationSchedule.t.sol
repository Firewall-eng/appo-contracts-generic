// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {ActivationSchedule} from "../src/libraries/ActivationSchedule.sol";
import {ActivationScheduleHarness} from "./mocks/ActivationScheduleHarness.sol";

/// @title ActivationScheduleTest
/// @notice Direct unit and invariant tests for ActivationSchedule.sol, exercised
///         through the harness to bypass Prover admin/resetId logic.
///
/// Add coverage for:
///   1. The insert-middle branch of retroInclusionInsert (retro between two
///      existing entries requiring a right-shift). Every existing retro test
///      either appends or replaces at an existing block.
///   2. Inclusion-hash inheritance correctness in appendStf/InclusionUpgrade
///      after multiple prior upgrades of the OTHER type.
///   3. The RetroInsertAtStartIndex revert (including whether replacement-at-
///      start is wrongly blocked).
///   4. Stf-hash preservation through an insert-middle retro with >2
///      entries already in the schedule.
///
/// This file closes those gaps with targeted unit tests plus an invariant
/// checker that validates sorted order, non-zero stf hashes, and inclusion
/// propagation after every mutation.
contract ActivationScheduleTest is Test {
    ActivationScheduleHarness h;

    bytes32 constant M1 = keccak256("M1");
    bytes32 constant M2 = keccak256("M2");
    bytes32 constant M3 = keccak256("M3");
    bytes32 constant G1 = keccak256("G1");
    bytes32 constant G2 = keccak256("G2");
    bytes32 constant G3 = keccak256("G3");
    bytes32 constant G_FIX = keccak256("G_FIX");
    bytes32 constant G_FIX2 = keccak256("G_FIX2");

    function setUp() public {
        h = new ActivationScheduleHarness();
        h.initialize(M1, G1, 0);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // SECTION 1: appendStfUpgrade — inclusion hash inheritance
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Stf upgrade inherits inclusion hash from the last entry (base case)
    function test_appendStf_inheritsInclusionFromGenesis() public {
        h.appendStfUpgrade(M2, 10, 0);
        (bytes32 m, bytes32 g) = h.getHashesForBlock(10);
        assertEq(m, M2);
        assertEq(g, G1, "Stf upgrade should inherit G1 from genesis");
        h.checkInvariants();
    }

    /// @notice Stf upgrade inherits the LATEST inclusion hash, not genesis
    function test_appendStf_inheritsLatestInclusion() public {
        h.appendInclusionUpgrade(G2, 10, 0);
        h.appendStfUpgrade(M2, 20, 0);

        (bytes32 m, bytes32 g) = h.getHashesForBlock(20);
        assertEq(m, M2);
        assertEq(g, G2, "Stf upgrade at 20 should inherit G2 from entry at 10");
        h.checkInvariants();
    }

    /// @notice Chain: G2 → M2 → G3 → M3. Each inherits from its predecessor.
    function test_appendAlternating_inheritsCorrectly() public {
        h.appendInclusionUpgrade(G2, 10, 0);
        h.appendStfUpgrade(M2, 20, 0);
        h.appendInclusionUpgrade(G3, 30, 0);
        h.appendStfUpgrade(M3, 40, 0);

        (bytes32 m10, bytes32 g10) = h.getHashesForBlock(10);
        assertEq(m10, M1);
        assertEq(g10, G2);

        (bytes32 m20, bytes32 g20) = h.getHashesForBlock(20);
        assertEq(m20, M2);
        assertEq(g20, G2);

        (bytes32 m30, bytes32 g30) = h.getHashesForBlock(30);
        assertEq(m30, M2);
        assertEq(g30, G3);

        (bytes32 m40, bytes32 g40) = h.getHashesForBlock(40);
        assertEq(m40, M3);
        assertEq(g40, G3);

        h.checkInvariants();
    }

    // ═══════════════════════════════════════════════════════════════════════
    // SECTION 2: appendInclusionUpgrade — stf hash inheritance
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Inclusion upgrade inherits stf hash from last entry
    function test_appendInclusion_inheritsStfFromGenesis() public {
        h.appendInclusionUpgrade(G2, 10, 0);
        (bytes32 m, bytes32 g) = h.getHashesForBlock(10);
        assertEq(m, M1, "Inclusion upgrade should inherit M1 from genesis");
        assertEq(g, G2);
        h.checkInvariants();
    }

    /// @notice Inclusion upgrade inherits latest stf, not genesis
    function test_appendInclusion_inheritsLatestStf() public {
        h.appendStfUpgrade(M2, 10, 0);
        h.appendInclusionUpgrade(G2, 20, 0);

        (bytes32 m, bytes32 g) = h.getHashesForBlock(20);
        assertEq(m, M2, "Inclusion upgrade at 20 should inherit M2 from entry at 10");
        assertEq(g, G2);
        h.checkInvariants();
    }

    // ═══════════════════════════════════════════════════════════════════════
    // SECTION 3: retroInclusionInsert — INSERT-MIDDLE branch
    //           (the branch NO existing Prover test exercises)
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Insert retro between genesis(0) and stf(20) — exercises shift-right
    function test_retroInsert_middle_basic() public {
        h.appendStfUpgrade(M2, 20, 0);
        // Schedule: [genesis@0, M2@20]. Insert retro at block 10.
        h.retroInclusionInsert(G_FIX, 10, 0);

        assertEq(h.activeCount(), 3, "Should have 3 entries after insert-middle");

        // Entry at 10: stfHash inherited from genesis (M1), inclusionHash = G_FIX
        (bytes32 m10, bytes32 g10) = h.getHashesForBlock(10);
        assertEq(m10, M1, "Retro entry inherits stf from predecessor");
        assertEq(g10, G_FIX);

        // Entry at 20: stfHash preserved (M2), inclusionHash propagated (G_FIX)
        (bytes32 m20, bytes32 g20) = h.getHashesForBlock(20);
        assertEq(m20, M2, "Stf upgrade must survive insert-middle retro");
        assertEq(g20, G_FIX, "Inclusion must propagate to entries after insertion");

        h.checkInvariants();
        h.checkInclusionPropagation(10, G_FIX);
    }

    /// @notice Insert retro between two non-genesis entries in a 4-entry schedule
    function test_retroInsert_middle_multipleEntries() public {
        h.appendStfUpgrade(M2, 10, 0);
        h.appendInclusionUpgrade(G2, 30, 0);
        h.appendStfUpgrade(M3, 50, 0);
        // Schedule: [M1,G1@0] [M2,G1@10] [M2,G2@30] [M3,G2@50]
        // Insert retro at block 20 (between entries at 10 and 30)
        h.retroInclusionInsert(G_FIX, 20, 0);

        assertEq(h.activeCount(), 5);

        // Block 9: still genesis
        (bytes32 m9, bytes32 g9) = h.getHashesForBlock(9);
        assertEq(m9, M1);
        assertEq(g9, G1);

        // Block 10: M2, still G1 (before retro activation)
        (bytes32 m10, bytes32 g10) = h.getHashesForBlock(10);
        assertEq(m10, M2);
        assertEq(g10, G1);

        // Block 20: M2 (inherited from entry@10), G_FIX
        (bytes32 m20, bytes32 g20) = h.getHashesForBlock(20);
        assertEq(m20, M2);
        assertEq(g20, G_FIX);

        // Block 30: M2 preserved, G_FIX propagated (NOT G2)
        (bytes32 m30, bytes32 g30) = h.getHashesForBlock(30);
        assertEq(m30, M2, "M2 at block 30 preserved through shift");
        assertEq(g30, G_FIX, "G2 overwritten by G_FIX propagation");

        // Block 50: M3 preserved, G_FIX propagated
        (bytes32 m50, bytes32 g50) = h.getHashesForBlock(50);
        assertEq(m50, M3, "M3 at block 50 preserved through shift");
        assertEq(g50, G_FIX, "Inclusion propagated to final entry");

        h.checkInvariants();
        h.checkInclusionPropagation(20, G_FIX);
    }

    /// @notice Insert retro at block 1 in a schedule with entries at [0, 10, 20]
    ///         — tests shift at the earliest valid position (insertAt == start + 1)
    function test_retroInsert_middle_nearStart() public {
        h.appendStfUpgrade(M2, 10, 0);
        h.appendStfUpgrade(M3, 20, 0);
        // Insert at block 1 — just after genesis
        h.retroInclusionInsert(G_FIX, 1, 0);

        assertEq(h.activeCount(), 4);
        (bytes32 m1, bytes32 g1) = h.getHashesForBlock(1);
        assertEq(m1, M1, "Stf inherited from genesis");
        assertEq(g1, G_FIX);

        // All subsequent entries get G_FIX
        (, bytes32 g10) = h.getHashesForBlock(10);
        assertEq(g10, G_FIX);
        (, bytes32 g20) = h.getHashesForBlock(20);
        assertEq(g20, G_FIX);

        // Stf hashes preserved
        (bytes32 m10,) = h.getHashesForBlock(10);
        assertEq(m10, M2);
        (bytes32 m20,) = h.getHashesForBlock(20);
        assertEq(m20, M3);

        h.checkInvariants();
    }

    // ═══════════════════════════════════════════════════════════════════════
    // SECTION 4: retroInclusionInsert — REPLACEMENT branch
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Replacement at an existing entry preserves its stf hash
    function test_retroInsert_replacement_preservesStf() public {
        h.appendStfUpgrade(M2, 10, 0);
        h.appendStfUpgrade(M3, 20, 0);
        // Replace at block 10 (existing entry)
        h.retroInclusionInsert(G_FIX, 10, 0);

        assertEq(h.activeCount(), 3, "No new entry on replacement");

        (bytes32 m10, bytes32 g10) = h.getHashesForBlock(10);
        assertEq(m10, M2, "Stf preserved on replacement");
        assertEq(g10, G_FIX);

        // Propagated to entry at 20
        (bytes32 m20, bytes32 g20) = h.getHashesForBlock(20);
        assertEq(m20, M3, "Stf at 20 preserved");
        assertEq(g20, G_FIX, "Inclusion propagated to 20");

        h.checkInvariants();
        h.checkInclusionPropagation(10, G_FIX);
    }

    /// @notice Double replacement at same block
    function test_retroInsert_doubleReplacement_sameBlock() public {
        h.appendStfUpgrade(M2, 10, 0);
        h.retroInclusionInsert(G_FIX, 10, 0);
        h.retroInclusionInsert(G_FIX2, 10, 0);

        (bytes32 m10, bytes32 g10) = h.getHashesForBlock(10);
        assertEq(m10, M2, "Stf survives double replacement");
        assertEq(g10, G_FIX2, "Second replacement wins");

        h.checkInvariants();
    }

    // ═══════════════════════════════════════════════════════════════════════
    // SECTION 5: retroInclusionInsert — APPEND branch (after all entries)
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Retro append after all entries
    function test_retroInsert_append() public {
        // Schedule: [M1,G1@0]. Insert retro at block 10 (after last entry).
        h.retroInclusionInsert(G_FIX, 10, 0);

        assertEq(h.activeCount(), 2);

        (bytes32 m10, bytes32 g10) = h.getHashesForBlock(10);
        assertEq(m10, M1, "Stf inherited from last entry");
        assertEq(g10, G_FIX);

        h.checkInvariants();
    }

    // ═══════════════════════════════════════════════════════════════════════
    // SECTION 6: retroInclusionInsert — replacement at start after prune
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Replacement at start entry after prune (replacement-at-start is permitted)
    function test_retroInsert_replacementAtStart_afterPrune() public {
        h.appendStfUpgrade(M2, 10, 0);
        h.appendStfUpgrade(M3, 20, 0);
        // Prune genesis: startIndex → 1 (entry at block 10 is the new start)
        h.prune(10);
        assertEq(h.startIndex(), 1);

        // Replace at block 10 — the start entry. This is a replacement, so allowed.
        h.retroInclusionInsert(G_FIX, 10, 0);

        (bytes32 m10, bytes32 g10) = h.getHashesForBlock(10);
        assertEq(m10, M2, "Stf preserved at start entry");
        assertEq(g10, G_FIX, "Inclusion replaced at start entry");

        (bytes32 m20, bytes32 g20) = h.getHashesForBlock(20);
        assertEq(m20, M3, "Stf preserved at 20");
        assertEq(g20, G_FIX, "Inclusion propagated to 20");

        h.checkInvariants();
        h.checkInclusionPropagation(10, G_FIX);
    }

    /// @notice Double replacement at start after prune
    function test_retroInsert_doubleReplacementAtStart() public {
        h.appendStfUpgrade(M2, 10, 0);
        h.appendStfUpgrade(M3, 20, 0);
        h.prune(10);
        assertEq(h.startIndex(), 1);

        h.retroInclusionInsert(G_FIX, 10, 0);
        h.retroInclusionInsert(G_FIX2, 10, 0);

        (bytes32 m10, bytes32 g10) = h.getHashesForBlock(10);
        assertEq(m10, M2, "Stf preserved through double replacement");
        assertEq(g10, G_FIX2, "Second replacement wins");

        (bytes32 m20, bytes32 g20) = h.getHashesForBlock(20);
        assertEq(m20, M3, "Stf at 20 preserved");
        assertEq(g20, G_FIX2, "Inclusion propagated from second replacement");

        h.checkInvariants();
        h.checkInclusionPropagation(10, G_FIX2);
    }

    /// @notice Non-replacement insert at start still reverts (needs pruned predecessor data)
    function test_retroInsert_insertAtStart_reverts() public {
        h.appendStfUpgrade(M2, 10, 0);
        h.prune(5);
        assertEq(h.startIndex(), 0);

        h.prune(10);
        assertEq(h.startIndex(), 1);

        // Insert at block 5 — no matching entry, so replacement=false, insertAt==start.
        // The shift-right path would need entries[insertAt-1] (pruned data). Must revert.
        vm.expectRevert(ActivationSchedule.RetroInsertBeforeStartIndex.selector);
        h.retroInclusionInsert(G_FIX, 5, 0);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // SECTION 7: retroInclusionInsert after prune — insert-middle with non-zero startIndex
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Insert-middle after prune with non-zero startIndex
    function test_retroInsert_middle_afterPrune() public {
        h.appendStfUpgrade(M2, 10, 0);
        h.appendStfUpgrade(M3, 30, 0);
        h.appendInclusionUpgrade(G2, 50, 0);

        // Prune past genesis and first entry: startIndex -> 1 (entry at block 10)
        h.prune(10);
        assertEq(h.startIndex(), 1);

        // Insert retro at block 20 — between entries at 10 and 30
        h.retroInclusionInsert(G_FIX, 20, 0);

        // Entry at 10: inclusion unchanged (before retro)
        (bytes32 m10, bytes32 g10) = h.getHashesForBlock(10);
        assertEq(m10, M2);
        assertEq(g10, G1);

        // Entry at 20: stf inherited from entry@10 (M2), inclusion = G_FIX
        (bytes32 m20, bytes32 g20) = h.getHashesForBlock(20);
        assertEq(m20, M2);
        assertEq(g20, G_FIX);

        // Entry at 30: stf preserved (M3), inclusion propagated
        (bytes32 m30, bytes32 g30) = h.getHashesForBlock(30);
        assertEq(m30, M3);
        assertEq(g30, G_FIX);

        // Entry at 50: stf from M3 (inherited by appendInclusionUpgrade), inclusion propagated
        (bytes32 m50, bytes32 g50) = h.getHashesForBlock(50);
        assertEq(m50, M3);
        assertEq(g50, G_FIX);

        h.checkInvariants();
        h.checkInclusionPropagation(20, G_FIX);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // SECTION 8: Invariant verification — sorted order after every mutation
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Build a complex schedule and verify invariants hold throughout
    function test_invariants_complexSchedule() public {
        // Build up
        h.appendInclusionUpgrade(G2, 10, 0);
        h.checkInvariants();

        h.appendStfUpgrade(M2, 20, 0);
        h.checkInvariants();

        h.appendInclusionUpgrade(G3, 30, 0);
        h.checkInvariants();

        h.appendStfUpgrade(M3, 40, 0);
        h.checkInvariants();

        // Insert-middle retro at block 15 (between entries at 10 and 20)
        h.retroInclusionInsert(G_FIX, 15, 0);
        h.checkInvariants();
        h.checkInclusionPropagation(15, G_FIX);

        assertEq(h.activeCount(), 6);

        // Verify sorted order explicitly via raw entries
        uint256 start = h.startIndex();
        uint256 prevBlock = 0;
        for (uint256 i = start; i < h.entryCount(); i++) {
            (,, uint256 ab) = h.getEntry(i);
            assertTrue(i == start || ab > prevBlock, "Entries must be strictly ascending");
            prevBlock = ab;
        }
    }

    /// @notice Successive retros: insert-middle then replacement, invariants hold
    function test_invariants_retroThenReplacement() public {
        h.appendStfUpgrade(M2, 10, 0);
        h.appendStfUpgrade(M3, 30, 0);

        // Insert-middle at 20
        h.retroInclusionInsert(G_FIX, 20, 0);
        h.checkInvariants();

        // Replace at 20 with a new inclusion hash
        h.retroInclusionInsert(G_FIX2, 20, 0);
        h.checkInvariants();

        (bytes32 m20, bytes32 g20) = h.getHashesForBlock(20);
        assertEq(m20, M2, "Stf at 20 inherited from entry@10, survives replacement");
        assertEq(g20, G_FIX2, "Second retro overwrites first");

        h.checkInclusionPropagation(20, G_FIX2);
    }

    /// @notice Insert-middle retro, then another insert-middle before it
    function test_invariants_twoInsertMiddles() public {
        h.appendStfUpgrade(M2, 30, 0);
        // Schedule: [M1,G1@0] [M2,G1@30]

        // Insert at 20
        h.retroInclusionInsert(G_FIX, 20, 0);
        h.checkInvariants();
        // Schedule: [M1,G1@0] [M1,G_FIX@20] [M2,G_FIX@30]

        // Insert at 10 (before the first retro)
        h.retroInclusionInsert(G_FIX2, 10, 0);
        h.checkInvariants();
        // Schedule: [M1,G1@0] [M1,G_FIX2@10] [M1,G_FIX2@20] [M2,G_FIX2@30]

        assertEq(h.activeCount(), 4);

        // Genesis unchanged
        (, bytes32 g0) = h.getHashesForBlock(0);
        assertEq(g0, G1);

        // Everything from block 10 onward has G_FIX2
        h.checkInclusionPropagation(10, G_FIX2);

        // Stf hashes preserved
        h.checkStfPreserved(0, M1);
        h.checkStfPreserved(3, M2);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // SECTION 9: getHashesForProofRange — segmentation around insert-middle
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice After insert-middle retro, proof ranges segment correctly
    function test_proofRange_afterInsertMiddle() public {
        h.appendStfUpgrade(M2, 20, 0);
        h.retroInclusionInsert(G_FIX, 10, 0);
        // Schedule: [M1,G1@0] [M1,G_FIX@10] [M2,G_FIX@20]

        // Segment 1: prove [0 → 9]. startBlock=0, endBlock=9.
        // Processes blocks [1..9]. Activation at 10 is NOT in (1,9]. OK.
        (bytes32 m1, bytes32 g1) = h.getHashesForProofRange(0, 9);
        assertEq(m1, M1);
        assertEq(g1, G1);

        // Segment 2: prove [9 → 19]. startBlock=9, endBlock=19.
        // Processes blocks [10..19]. Activation at 10 == startBlock+1. OK.
        (bytes32 m2, bytes32 g2) = h.getHashesForProofRange(9, 19);
        assertEq(m2, M1);
        assertEq(g2, G_FIX);

        // Segment 3: prove [19 → 25]. startBlock=19, endBlock=25.
        // Processes blocks [20..25]. Activation at 20 == startBlock+1. OK.
        (bytes32 m3, bytes32 g3) = h.getHashesForProofRange(19, 25);
        assertEq(m3, M2);
        assertEq(g3, G_FIX);

        // Cross-boundary: prove [0 → 15] should revert (activation at 10 in (1,15])
        vm.expectRevert(abi.encodeWithSignature("ActivationInRange(uint256)", 10));
        h.getHashesForProofRange(0, 15);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // SECTION 10: Edge cases and error paths
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice retroInclusionInsert below finalized reverts
    function test_retroInsert_belowFinalized_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(ActivationSchedule.RetroInsertFinalized.selector, 5, 10));
        h.retroInclusionInsert(G_FIX, 5, 10);
    }

    /// @notice retroInclusionInsert at exactly the finalized block reverts (== boundary)
    function test_retroInsert_atFinalized_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(ActivationSchedule.RetroInsertFinalized.selector, 10, 10));
        h.retroInclusionInsert(G_FIX, 10, 10);
    }

    /// @notice appendStfUpgrade at same block as last entry reverts
    function test_appendStf_sameBlockAsLast_reverts() public {
        h.appendStfUpgrade(M2, 10, 0);
        vm.expectRevert();
        h.appendStfUpgrade(M3, 10, 0);
    }

    /// @notice appendInclusionUpgrade at same block as last entry reverts
    function test_appendInclusion_sameBlockAsLast_reverts() public {
        h.appendInclusionUpgrade(G2, 10, 0);
        vm.expectRevert();
        h.appendInclusionUpgrade(G3, 10, 0);
    }

    /// @notice appendStf then appendInclusion at same block reverts
    function test_appendStfThenInclusion_sameBlock_reverts() public {
        h.appendStfUpgrade(M2, 10, 0);
        vm.expectRevert();
        h.appendInclusionUpgrade(G2, 10, 0);
    }

    /// @notice appendInclusion then appendStf at same block reverts
    function test_appendInclusionThenStf_sameBlock_reverts() public {
        h.appendInclusionUpgrade(G2, 10, 0);
        vm.expectRevert();
        h.appendStfUpgrade(M2, 10, 0);
    }
}
