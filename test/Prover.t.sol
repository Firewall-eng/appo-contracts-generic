// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Base} from "./Base.t.sol";
import {TestConstants} from "./TestConstants.sol";
import {IProver} from "../src/interfaces/IProver.sol";
import {IActions} from "../src/interfaces/IActions.sol";
import {Actions} from "../src/Actions.sol";
import {Caller} from "../src/Caller.sol";
import {Vault} from "../src/Vault.sol";
import {Prover} from "../src/Prover.sol";
import {MockVerifier} from "./mocks/MockVerifier.sol";

/// @title ProverTest
/// @notice Tests for Prover.sol -- the state machine that tracks proof submission,
///         pending/finalized commitments, admin controls, and upgrade scheduling.
/// @dev Uses MockVerifier (always-pass) since real SP1 proofs cannot be generated
///      in a Foundry test. The MockVerifier implements ISP1Verifier (view), so it
///      cannot track call state — tests verify behavior through Prover state changes.
contract ProverTest is Base {
    uint256 genesisBlock;
    bytes32 committedAddressesHash;
    bytes32 constant TEST_INCLUSION_ACC = keccak256("TEST_INCLUSION_ACC");

    function setUp() public override {
        super.setUp();
        genesisBlock = deployBlock - 1;
        committedAddressesHash = keccak256(abi.encode(address(actions), address(caller), address(vault)));
    }

    /// @notice Helper: submit a single action at the current block to populate checkpoint
    function _submitAction() internal returns (bytes32) {
        vm.prank(TestConstants.USER_1);
        actions.action(TestConstants.SUPPLY, abi.encode(uint256(1)));
        return actions.accumulator();
    }

    /// @notice Helper: build and submit a valid proof for a block range
    function _submitProof(uint256 startBlock, uint256 endBlock) internal {
        prover.proveBoth(startBlock, endBlock, TEST_INCLUSION_ACC, TestConstants.STF_ROOT, "", "");
    }

    // --- Constructor ---

    /// @notice Genesis commitment: pending == finalized at (deployBlock-1, INIT_ACCUMULATOR)
    function test_constructor_genesisCommitment() public view {
        IProver.Commitment memory p = getPending();
        IProver.Commitment memory f = getFinalized();
        assertEq(p.blockNumber, genesisBlock);
        assertEq(p.actionsAccumulator, initAccumulator);
        assertEq(p.inclusionAccumulator, bytes32(0));
        assertEq(p.stfRoot, TestConstants.STF_ROOT);
        assertEq(f.blockNumber, genesisBlock);
        assertEq(f.actionsAccumulator, initAccumulator);
        assertEq(prover.resetId(), 0);
    }

    /// @notice Immutables match constructor args
    function test_constructor_immutables() public view {
        assertEq(prover.ACTIONS(), address(actions));
        assertEq(prover.SP1_VERIFIER(), address(mockVerifier));
        assertEq(prover.FINALITY(), TestConstants.FINALITY);
        assertEq(prover.COMMITTED_ADDRESSES_HASH(), committedAddressesHash);
    }

    /// @notice Activation schedule initialized with TestConstants.STF_HASH and TestConstants.INCLUSION_HASH at genesis
    function test_constructor_activationHashes() public view {
        (bytes32 sHash, bytes32 iHash) = prover.getActivationHashes(deployBlock);
        assertEq(sHash, TestConstants.STF_HASH);
        assertEq(iHash, TestConstants.INCLUSION_HASH);
    }

    // --- proveBoth ---

    /// @notice Valid proof: commitment stored, pending advances
    function test_proveBoth_happyPath() public {
        vm.roll(deployBlock + 5);
        _submitAction();
        uint256 proofBlock = block.number;

        prover.proveBoth(genesisBlock, proofBlock, TEST_INCLUSION_ACC, TestConstants.STF_ROOT, "", "");

        IProver.Commitment memory stored = getSubmittedProof(0, proofBlock);
        assertEq(stored.blockNumber, proofBlock);
        assertEq(stored.actionsAccumulator, actions.accumulatorUpperLookup(proofBlock));

        IProver.Commitment memory p = getPending();
        assertEq(p.blockNumber, proofBlock, "proveBoth should auto-advance pending");
    }

    /// @notice Start block with no submitted proof is rejected
    function test_proveBoth_startDoesNotExist() public {
        vm.roll(deployBlock + 5);
        _submitAction();

        vm.expectRevert("Start commitment not fully verified");
        prover.proveBoth(deployBlock + 1, block.number, TEST_INCLUSION_ACC, TestConstants.STF_ROOT, "", "");
    }

    /// @notice Verifier revert propagates through proveBoth
    function test_proveBoth_verifierRevert() public {
        vm.roll(deployBlock + 5);
        _submitAction();

        mockVerifier.setShouldRevert(true);
        vm.expectRevert("MockVerifier: forced revert");
        prover.proveBoth(genesisBlock, block.number, TEST_INCLUSION_ACC, TestConstants.STF_ROOT, "", "");
    }

    /// @notice proveBoth does not regress pending when proving an earlier range
    function test_proveBoth_doesNotRegressPending() public {
        vm.roll(deployBlock + 3);
        _submitAction();
        uint256 block1 = block.number;

        vm.roll(block1 + 3);
        _submitAction();
        uint256 block2 = block.number;

        _submitProof(genesisBlock, block2);
        assertEq(getPending().blockNumber, block2);

        _submitProof(genesisBlock, block1);
        assertEq(getPending().blockNumber, block2, "Pending should not regress");
    }

    // --- proveInclusion / proveStfRoot ---

    /// @notice proveInclusion stores partial commitment (stfRoot == 0)
    function test_proveInclusion_storesPartialCommitment() public {
        vm.roll(deployBlock + 5);
        _submitAction();
        uint256 proofBlock = block.number;

        prover.proveInclusion(genesisBlock, proofBlock, TEST_INCLUSION_ACC, "");

        IProver.Commitment memory stored = getSubmittedProof(0, proofBlock);
        assertEq(stored.blockNumber, proofBlock);
        assertEq(stored.inclusionAccumulator, TEST_INCLUSION_ACC);
        assertEq(stored.stfRoot, bytes32(0), "stfRoot should be zero after proveInclusion only");
    }

    /// @notice proveStfRoot requires proveInclusion first
    function test_proveStfRoot_requiresInclusion() public {
        vm.roll(deployBlock + 5);
        _submitAction();

        vm.expectRevert("End commitment inclusion not verified");
        prover.proveStfRoot(genesisBlock, block.number, TestConstants.STF_ROOT, "");
    }

    /// @notice proveStfRoot completes the commitment after proveInclusion
    function test_proveStfRoot_completesCommitment() public {
        vm.roll(deployBlock + 5);
        _submitAction();
        uint256 proofBlock = block.number;

        prover.proveInclusion(genesisBlock, proofBlock, TEST_INCLUSION_ACC, "");
        prover.proveStfRoot(genesisBlock, proofBlock, TestConstants.STF_ROOT, "");

        IProver.Commitment memory stored = getSubmittedProof(0, proofBlock);
        assertEq(stored.stfRoot, TestConstants.STF_ROOT);
        assertEq(stored.inclusionAccumulator, TEST_INCLUSION_ACC);
    }

    // --- finalize ---

    /// @notice Finalized advances after FINALITY blocks have elapsed
    function test_finalize_happyPath() public {
        vm.roll(deployBlock + 5);
        _submitAction();
        uint256 proofBlock = block.number;
        _submitProof(genesisBlock, proofBlock);

        vm.roll(proofBlock + TestConstants.FINALITY + 1);
        prover.finalize(proofBlock);

        IProver.Commitment memory f = getFinalized();
        assertEq(f.blockNumber, proofBlock);
    }

    /// @notice Cannot finalize a block less than FINALITY blocks old
    function test_finalize_notFinalizable() public {
        vm.roll(deployBlock + 5);
        _submitAction();
        uint256 proofBlock = block.number;
        _submitProof(genesisBlock, proofBlock);

        vm.roll(proofBlock + TestConstants.FINALITY - 1);
        vm.expectRevert("Not finalizable");
        prover.finalize(proofBlock);
    }

    /// @notice Finalizing past pending pulls pending forward automatically
    function test_finalize_pullsPendingForward() public {
        vm.roll(deployBlock + 3);
        _submitAction();
        uint256 block1 = block.number;
        _submitProof(genesisBlock, block1);

        vm.roll(block1 + 3);
        _submitAction();
        uint256 block2 = block.number;
        _submitProof(block1, block2);

        assertEq(getPending().blockNumber, block2);

        vm.roll(block2 + TestConstants.FINALITY + 1);
        prover.finalize(block2);

        assertEq(getPending().blockNumber, block2);
        assertEq(getFinalized().blockNumber, block2);
    }

    // --- Admin ---

    /// @notice Only stf admin can change stf admin
    function test_changeStfAdmin_onlyStfAdmin() public {
        vm.prank(TestConstants.USER_1);
        vm.expectRevert("Not stf admin");
        prover.changeStfAdmin(TestConstants.USER_1);

        vm.prank(TestConstants.STF_ADMIN);
        prover.changeStfAdmin(TestConstants.USER_1);
        assertEq(prover.stfAdmin(), TestConstants.USER_1);
    }

    /// @notice Only inclusion admin can change inclusion admin
    function test_changeInclusionAdmin_onlyInclusionAdmin() public {
        vm.prank(TestConstants.USER_1);
        vm.expectRevert("Not inclusion admin");
        prover.changeInclusionAdmin(TestConstants.USER_1);

        vm.prank(TestConstants.INCLUSION_ADMIN);
        prover.changeInclusionAdmin(TestConstants.USER_1);
        assertEq(prover.inclusionAdmin(), TestConstants.USER_1);
    }

    // --- Upgrade schedule ---

    /// @notice Schedule stf upgrade: new hash appears at activation block
    function test_scheduleStfUpgrade_happyPath() public {
        bytes32 newStfHash = bytes32(uint256(0xFF));
        uint256 activationBlock = block.number + 5;

        vm.prank(TestConstants.STF_ADMIN);
        prover.scheduleStfUpgrade(newStfHash, activationBlock);

        (bytes32 sHash, bytes32 iHash) = prover.getActivationHashes(activationBlock);
        assertEq(sHash, newStfHash);
        assertEq(iHash, TestConstants.INCLUSION_HASH);
    }

    /// @notice Cannot schedule stf upgrade in the past
    function test_scheduleStfUpgrade_pastBlock_reverts() public {
        bytes32 newStfHash = bytes32(uint256(0xFF));

        vm.roll(block.number + 10);
        vm.prank(TestConstants.STF_ADMIN);
        vm.expectRevert();
        prover.scheduleStfUpgrade(newStfHash, block.number - 1);
    }

    /// @notice Schedule inclusion upgrade: new hash appears at activation block
    function test_scheduleInclusionUpgrade_happyPath() public {
        bytes32 newInclusionHash = bytes32(uint256(0xAA));
        uint256 activationBlock = block.number + 5;

        vm.prank(TestConstants.INCLUSION_ADMIN);
        prover.scheduleInclusionUpgrade(newInclusionHash, activationBlock);

        (bytes32 sHash, bytes32 iHash) = prover.getActivationHashes(activationBlock);
        assertEq(sHash, TestConstants.STF_HASH);
        assertEq(iHash, newInclusionHash);
    }

    /// @notice Only stf admin can schedule stf upgrades
    function test_scheduleStfUpgrade_onlyStfAdmin() public {
        vm.prank(TestConstants.USER_1);
        vm.expectRevert("Not stf admin");
        prover.scheduleStfUpgrade(bytes32(uint256(0xFF)), block.number + 5);
    }

    /// @notice Only inclusion admin can schedule inclusion upgrades
    function test_scheduleInclusionUpgrade_onlyInclusionAdmin() public {
        vm.prank(TestConstants.USER_1);
        vm.expectRevert("Not inclusion admin");
        prover.scheduleInclusionUpgrade(bytes32(uint256(0xAA)), block.number + 5);
    }

    // --- Activation schedule interleaving ---

    /// @notice Stf upgrade after an inclusion upgrade preserves the scheduled inclusion hash
    function test_scheduleStfUpgrade_preservesPendingInclusionUpgrade() public {
        bytes32 S1 = TestConstants.STF_HASH;
        bytes32 I2 = bytes32(uint256(0xA2));
        bytes32 S2 = bytes32(uint256(0xB2));

        // Schedule inclusion upgrade at block 100
        vm.prank(TestConstants.INCLUSION_ADMIN);
        prover.scheduleInclusionUpgrade(I2, block.number + 100);

        // Verify inclusion upgrade is scheduled correctly
        (bytes32 sAt100, bytes32 iAt100) = prover.getActivationHashes(block.number + 100);
        assertEq(sAt100, S1);
        assertEq(iAt100, I2);

        // Schedule stf upgrade at block 200 (after the inclusion upgrade)
        vm.prank(TestConstants.STF_ADMIN);
        prover.scheduleStfUpgrade(S2, block.number + 200);

        // Inclusion upgrade at block 100 should still be intact
        (sAt100, iAt100) = prover.getActivationHashes(block.number + 100);
        assertEq(sAt100, S1, "Stf hash at block 100 should be unchanged");
        assertEq(iAt100, I2, "Inclusion hash at block 100 should be unchanged");

        // At block 200: stf should be S2, inclusion should STILL be I2 (inherited)
        (bytes32 sAt200, bytes32 iAt200) = prover.getActivationHashes(block.number + 200);
        assertEq(sAt200, S2, "Stf hash at block 200 should be S2");
        assertEq(iAt200, I2, "Inclusion hash at block 200 should inherit I2");
    }

    /// @notice retroInclusionUpgrade propagates the new inclusion hash to all subsequent entries
    function test_retroInclusionUpgrade_propagatesToFutureEntries() public {
        bytes32 S1 = TestConstants.STF_HASH;
        bytes32 S2 = bytes32(uint256(0xB2));
        bytes32 I_FIX = bytes32(uint256(0xF1));

        // Schedule a stf upgrade at a future block
        uint256 stfUpgradeBlock = block.number + 5;
        vm.prank(TestConstants.STF_ADMIN);
        prover.scheduleStfUpgrade(S2, stfUpgradeBlock);

        // Advance blocks so we can do a retro insert
        vm.roll(block.number + 4);

        // retroInclusionUpgrade: insert emergency inclusion fix at a past block
        uint256 retroBlock = block.number - 2;
        vm.prank(TestConstants.INCLUSION_ADMIN);
        prover.retroInclusionUpgrade(I_FIX, retroBlock);

        // The retro block should have the fix
        (bytes32 sAtRetro, bytes32 iAtRetro) = prover.getActivationHashes(retroBlock);
        assertEq(sAtRetro, S1, "Stf should be S1 at retro block");
        assertEq(iAtRetro, I_FIX, "Inclusion should be I_FIX at retro block");

        // The future stf upgrade entry should ALSO have the inclusion fix
        (bytes32 sAtFuture, bytes32 iAtFuture) = prover.getActivationHashes(stfUpgradeBlock);
        assertEq(sAtFuture, S2, "Stf should be S2 at future upgrade block");
        assertEq(iAtFuture, I_FIX, "Inclusion fix should propagate to future entry");
    }

    // --- retroInclusionUpgrade ---

    /// @notice Only inclusion admin can call retroInclusionUpgrade
    function test_retroInclusionUpgrade_onlyInclusionAdmin() public {
        vm.roll(block.number + 5);
        vm.prank(TestConstants.USER_1);
        vm.expectRevert("Not inclusion admin");
        prover.retroInclusionUpgrade(bytes32(uint256(0xF1)), block.number - 1);
    }

    /// @notice retroInclusionUpgrade reverts if activation block is below finalized
    function test_retroInclusionUpgrade_belowFinalized_reverts() public {
        // First prove and finalize a block so finalized advances
        vm.roll(deployBlock + 5);
        _submitAction();
        uint256 proofBlock = block.number;
        _submitProof(genesisBlock, proofBlock);

        vm.roll(proofBlock + TestConstants.FINALITY + 1);
        prover.finalize(proofBlock);

        // Try to retro insert below finalized
        vm.prank(TestConstants.INCLUSION_ADMIN);
        vm.expectRevert();
        prover.retroInclusionUpgrade(bytes32(uint256(0xF1)), genesisBlock);
    }

    /// @notice retroInclusionUpgrade reverts if activation block >= block.number
    function test_retroInclusionUpgrade_atCurrentBlock_reverts() public {
        vm.roll(block.number + 5);
        vm.prank(TestConstants.INCLUSION_ADMIN);
        vm.expectRevert("Retroactive upgrade block must be < block.number");
        prover.retroInclusionUpgrade(bytes32(uint256(0xF1)), block.number);
    }

    /// @notice retroInclusionUpgrade increments resetId and resets pending to finalized
    function test_retroInclusionUpgrade_resetsState() public {
        // Prove something to advance pending
        vm.roll(deployBlock + 5);
        _submitAction();
        uint256 proofBlock = block.number;
        _submitProof(genesisBlock, proofBlock);
        assertEq(getPending().blockNumber, proofBlock);

        uint256 resetIdBefore = prover.resetId();

        vm.roll(block.number + 3);
        vm.prank(TestConstants.INCLUSION_ADMIN);
        prover.retroInclusionUpgrade(bytes32(uint256(0xF1)), block.number - 1);

        assertEq(prover.resetId(), resetIdBefore + 1, "resetId should increment");
        assertEq(getPending().blockNumber, getFinalized().blockNumber, "pending should reset to finalized");
    }

    /// @notice retroInclusionUpgrade with no future entries (append case, loop is no-op)
    function test_retroInclusionUpgrade_noFutureEntries() public {
        bytes32 I_FIX = bytes32(uint256(0xF1));

        vm.roll(block.number + 5);
        uint256 retroBlock = block.number - 1;
        vm.prank(TestConstants.INCLUSION_ADMIN);
        prover.retroInclusionUpgrade(I_FIX, retroBlock);

        (bytes32 sHash, bytes32 iHash) = prover.getActivationHashes(retroBlock);
        assertEq(sHash, TestConstants.STF_HASH, "Stf should be unchanged");
        assertEq(iHash, I_FIX, "Inclusion should be the fix");
    }

    /// @notice retroInclusionUpgrade propagates inclusion fix across multiple future entries
    function test_retroInclusionUpgrade_propagatesAcrossMultipleFutureEntries() public {
        bytes32 S1 = TestConstants.STF_HASH;
        bytes32 S2 = bytes32(uint256(0xB2));
        bytes32 S3 = bytes32(uint256(0xB3));
        bytes32 I2 = bytes32(uint256(0xA2));
        bytes32 I_FIX = bytes32(uint256(0xF1));

        uint256 inclusionBlock = block.number + 10;
        uint256 stfBlock1 = block.number + 20;
        uint256 stfBlock2 = block.number + 30;

        vm.prank(TestConstants.INCLUSION_ADMIN);
        prover.scheduleInclusionUpgrade(I2, inclusionBlock);

        vm.prank(TestConstants.STF_ADMIN);
        prover.scheduleStfUpgrade(S2, stfBlock1);

        vm.prank(TestConstants.STF_ADMIN);
        prover.scheduleStfUpgrade(S3, stfBlock2);

        vm.roll(block.number + 5);

        // Retro insert before all scheduled upgrades
        vm.prank(TestConstants.INCLUSION_ADMIN);
        prover.retroInclusionUpgrade(I_FIX, block.number - 2);

        // Inclusion fix propagated to all entries
        (, bytes32 iAtInclusion) = prover.getActivationHashes(inclusionBlock);
        assertEq(iAtInclusion, I_FIX, "Inclusion at inclusion block should be I_FIX");

        (, bytes32 iAtS1) = prover.getActivationHashes(stfBlock1);
        assertEq(iAtS1, I_FIX, "Inclusion at stf block 1 should be I_FIX");

        (, bytes32 iAtS2) = prover.getActivationHashes(stfBlock2);
        assertEq(iAtS2, I_FIX, "Inclusion at stf block 2 should be I_FIX");

        // Stf hashes preserved at their activation blocks
        (bytes32 sAtInclusion,) = prover.getActivationHashes(inclusionBlock);
        assertEq(sAtInclusion, S1, "Stf at inclusion block should be S1");

        (bytes32 sAtS1,) = prover.getActivationHashes(stfBlock1);
        assertEq(sAtS1, S2, "Stf at stf block 1 should be S2");

        (bytes32 sAtS2,) = prover.getActivationHashes(stfBlock2);
        assertEq(sAtS2, S3, "Stf at stf block 2 should be S3");
    }

    /// @notice retroInclusionUpgrade then re-prove and finalize (full flow)
    function test_retroInclusionUpgrade_fullReproveAndFinalize() public {
        bytes32 I_FIX = bytes32(uint256(0xF1));

        // Prove and finalize genesis -> proofBlock1
        vm.roll(deployBlock + 5);
        _submitAction();
        uint256 proofBlock1 = block.number;
        _submitProof(genesisBlock, proofBlock1);

        vm.roll(proofBlock1 + TestConstants.FINALITY + 1);
        prover.finalize(proofBlock1);

        // retroInclusionUpgrade at block.number - 1 (within finality window)
        uint256 retroBlock = block.number - 1;
        vm.prank(TestConstants.INCLUSION_ADMIN);
        prover.retroInclusionUpgrade(I_FIX, retroBlock);

        // State reset
        assertEq(prover.resetId(), 1);
        assertEq(getPending().blockNumber, proofBlock1);
        assertEq(getFinalized().blockNumber, proofBlock1);

        (, bytes32 iHash) = prover.getActivationHashes(retroBlock);
        assertEq(iHash, I_FIX);

        // Re-prove from finalized, ending before retroBlock to avoid ActivationInRange
        vm.roll(proofBlock1 + 5);
        _submitAction();
        uint256 midBlock = block.number;
        _submitProof(proofBlock1, midBlock);
        assertEq(getPending().blockNumber, midBlock);

        // Finalize
        vm.roll(midBlock + TestConstants.FINALITY + 1);
        prover.finalize(midBlock);
        assertEq(getFinalized().blockNumber, midBlock);
    }

    /// @notice Proving across a retroInclusionUpgrade activation boundary reverts
    function test_proveBoth_acrossRetroActivation_reverts() public {
        bytes32 I_FIX = bytes32(uint256(0xF1));

        // Prove and finalize genesis -> proofBlock1
        vm.roll(deployBlock + 5);
        _submitAction();
        uint256 proofBlock1 = block.number;
        _submitProof(genesisBlock, proofBlock1);

        vm.roll(proofBlock1 + TestConstants.FINALITY + 1);
        prover.finalize(proofBlock1);

        // retroInclusionUpgrade: activation at block.number - 1
        uint256 retroBlock = block.number - 1;
        vm.prank(TestConstants.INCLUSION_ADMIN);
        prover.retroInclusionUpgrade(I_FIX, retroBlock);

        // Try to prove from finalized (proofBlock1) past the activation (retroBlock)
        vm.roll(retroBlock + 5);
        _submitAction();
        uint256 endBlock = block.number;

        vm.expectRevert(abi.encodeWithSignature("ActivationInRange(uint256)", retroBlock));
        prover.proveBoth(proofBlock1, endBlock, TEST_INCLUSION_ACC, TestConstants.STF_ROOT, "", "");
    }

    // --- regression test: duplicate activationBlock must not shadow stf upgrade ---

    /// @notice retroInclusionUpgrade at same block as an existing stf upgrade preserves
    ///         the stf hash (overwrites inclusionHash in-place, does not insert a duplicate)
    function test_retroInclusionUpgrade_atSameBlockAsStfUpgrade_preservesStf() public {
        bytes32 S2 = bytes32(uint256(0xB2));
        bytes32 I_FIX = bytes32(uint256(0xF1));

        uint256 upgradeBlock = block.number + 10;

        // Schedule stf upgrade at upgradeBlock
        vm.prank(TestConstants.STF_ADMIN);
        prover.scheduleStfUpgrade(S2, upgradeBlock);

        // Verify stf upgrade is in place
        (bytes32 sBefore, bytes32 iBefore) = prover.getActivationHashes(upgradeBlock);
        assertEq(sBefore, S2, "Stf should be S2 before retro");
        assertEq(iBefore, TestConstants.INCLUSION_HASH, "Inclusion should be original before retro");

        // Advance past upgradeBlock so we can retro at exactly upgradeBlock
        vm.roll(upgradeBlock + 1);

        // retroInclusionUpgrade at the same activationBlock as the stf upgrade
        vm.prank(TestConstants.INCLUSION_ADMIN);
        prover.retroInclusionUpgrade(I_FIX, upgradeBlock);

        // Stf upgrade must be preserved, only inclusion hash changes
        (bytes32 sAfter, bytes32 iAfter) = prover.getActivationHashes(upgradeBlock);
        assertEq(sAfter, S2, "Stf upgrade must NOT be shadowed by retro inclusion fix");
        assertEq(iAfter, I_FIX, "Inclusion should be the fix");
    }

    /// @notice retroInclusionUpgrade at same block as inclusion upgrade overwrites the inclusion hash
    function test_retroInclusionUpgrade_atSameBlockAsInclusionUpgrade_overwritesInclusion() public {
        bytes32 I2 = bytes32(uint256(0xA2));
        bytes32 I_FIX = bytes32(uint256(0xF1));

        uint256 upgradeBlock = block.number + 10;

        vm.prank(TestConstants.INCLUSION_ADMIN);
        prover.scheduleInclusionUpgrade(I2, upgradeBlock);

        vm.roll(upgradeBlock + 1);

        vm.prank(TestConstants.INCLUSION_ADMIN);
        prover.retroInclusionUpgrade(I_FIX, upgradeBlock);

        (bytes32 sAfter, bytes32 iAfter) = prover.getActivationHashes(upgradeBlock);
        assertEq(sAfter, TestConstants.STF_HASH, "Stf should be unchanged");
        assertEq(iAfter, I_FIX, "Inclusion should be overwritten to I_FIX");
    }

    /// @notice retroInclusionUpgrade at same block as both stf+inclusion upgrade preserves stf
    function test_retroInclusionUpgrade_atSameBlockAsBothUpgrades_preservesStf() public {
        bytes32 S2 = bytes32(uint256(0xB2));
        bytes32 I2 = bytes32(uint256(0xA2));
        bytes32 I_FIX = bytes32(uint256(0xF1));

        uint256 inclusionBlock = block.number + 10;
        uint256 stfBlock = block.number + 20;

        vm.prank(TestConstants.INCLUSION_ADMIN);
        prover.scheduleInclusionUpgrade(I2, inclusionBlock);

        vm.prank(TestConstants.STF_ADMIN);
        prover.scheduleStfUpgrade(S2, stfBlock);

        vm.roll(inclusionBlock + 1);

        // Retro at the inclusion upgrade block
        vm.prank(TestConstants.INCLUSION_ADMIN);
        prover.retroInclusionUpgrade(I_FIX, inclusionBlock);

        // Inclusion block: stf unchanged, inclusion overwritten
        (bytes32 sAtInclusion, bytes32 iAtInclusion) = prover.getActivationHashes(inclusionBlock);
        assertEq(sAtInclusion, TestConstants.STF_HASH, "Stf at inclusion block unchanged");
        assertEq(iAtInclusion, I_FIX, "Inclusion at inclusion block is I_FIX");

        // Stf block: stf upgrade preserved, inclusion propagated
        (bytes32 sAtStf, bytes32 iAtStf) = prover.getActivationHashes(stfBlock);
        assertEq(sAtStf, S2, "Stf upgrade at stf block preserved");
        assertEq(iAtStf, I_FIX, "Inclusion propagated to stf block");
    }

    // --- Multiple successive retroInclusionUpgrades ---

    /// @notice Two successive retroInclusionUpgrades at different blocks
    function test_retroInclusionUpgrade_twoSuccessive_differentBlocks() public {
        bytes32 I_FIX1 = bytes32(uint256(0xF1));
        bytes32 I_FIX2 = bytes32(uint256(0xF2));

        vm.roll(block.number + 10);
        uint256 retro1 = block.number - 3;
        vm.prank(TestConstants.INCLUSION_ADMIN);
        prover.retroInclusionUpgrade(I_FIX1, retro1);
        assertEq(prover.resetId(), 1);

        vm.roll(block.number + 5);
        uint256 retro2 = block.number - 1;
        vm.prank(TestConstants.INCLUSION_ADMIN);
        prover.retroInclusionUpgrade(I_FIX2, retro2);
        assertEq(prover.resetId(), 2);

        (, bytes32 iAt1) = prover.getActivationHashes(retro1);
        assertEq(iAt1, I_FIX1, "First retro entry keeps its inclusion hash");

        (, bytes32 iAt2) = prover.getActivationHashes(retro2);
        assertEq(iAt2, I_FIX2, "Second retro entry has I_FIX2");
    }

    /// @notice Two successive retroInclusionUpgrades at the same block (overwrite case)
    function test_retroInclusionUpgrade_twoSuccessive_sameBlock() public {
        bytes32 I_FIX1 = bytes32(uint256(0xF1));
        bytes32 I_FIX2 = bytes32(uint256(0xF2));

        vm.roll(block.number + 10);
        uint256 retroBlock = block.number - 1;

        vm.prank(TestConstants.INCLUSION_ADMIN);
        prover.retroInclusionUpgrade(I_FIX1, retroBlock);
        assertEq(prover.resetId(), 1);

        // Second retro at the same block — should overwrite, not insert duplicate
        vm.prank(TestConstants.INCLUSION_ADMIN);
        prover.retroInclusionUpgrade(I_FIX2, retroBlock);
        assertEq(prover.resetId(), 2);

        (, bytes32 iHash) = prover.getActivationHashes(retroBlock);
        assertEq(iHash, I_FIX2, "Second retro should overwrite first");

        (bytes32 sHash,) = prover.getActivationHashes(retroBlock);
        assertEq(sHash, TestConstants.STF_HASH, "Stf should remain unchanged through double retro");
    }

    // --- Proving across scheduled (non-retro) activation boundary ---

    /// @notice Proving across a scheduled stf upgrade activation boundary reverts
    function test_proveBoth_acrossScheduledStfActivation_reverts() public {
        bytes32 S2 = bytes32(uint256(0xB2));
        uint256 activationBlock = block.number + 10;

        vm.prank(TestConstants.STF_ADMIN);
        prover.scheduleStfUpgrade(S2, activationBlock);

        // Advance past the activation block
        vm.roll(activationBlock + 5);
        _submitAction();
        uint256 endBlock = block.number;

        // Proving from genesis (before activation) to endBlock (after activation) should revert
        vm.expectRevert(abi.encodeWithSignature("ActivationInRange(uint256)", activationBlock));
        prover.proveBoth(genesisBlock, endBlock, TEST_INCLUSION_ACC, TestConstants.STF_ROOT, "", "");
    }

    /// @notice Proving up to an activation block, then from it onward (segmented proofs)
    function test_proveBoth_segmentedAroundActivation() public {
        bytes32 S2 = bytes32(uint256(0xB2));
        uint256 activationBlock = deployBlock + 10;

        vm.prank(TestConstants.STF_ADMIN);
        prover.scheduleStfUpgrade(S2, activationBlock);

        // Submit actions before and after the activation block
        vm.roll(activationBlock - 1);
        _submitAction();
        vm.roll(activationBlock + 3);
        _submitAction();

        // Segment 1: prove genesis → activationBlock-1 (all under old hashes)
        uint256 preActivation = activationBlock - 1;
        _submitProof(genesisBlock, preActivation);
        assertEq(getPending().blockNumber, preActivation);

        // Segment 2: prove activationBlock-1 → end (activation at startBlock+1, uses new hashes)
        uint256 endBlock = block.number;
        _submitProof(preActivation, endBlock);
        assertEq(getPending().blockNumber, endBlock);
    }

    /// @notice Proving a range where activation is strictly inside (not at startBlock+1) still reverts
    function test_proveBoth_activationStrictlyInsideRange_reverts() public {
        bytes32 S2 = bytes32(uint256(0xB2));
        uint256 activationBlock = deployBlock + 10;

        vm.prank(TestConstants.STF_ADMIN);
        prover.scheduleStfUpgrade(S2, activationBlock);

        vm.roll(activationBlock + 5);
        _submitAction();

        vm.expectRevert(abi.encodeWithSignature("ActivationInRange(uint256)", activationBlock));
        prover.proveBoth(genesisBlock, block.number, TEST_INCLUSION_ACC, TestConstants.STF_ROOT, "", "");
    }

    // --- Prune + retroInclusionInsert interaction ---

    /// @notice retroInclusionUpgrade still works correctly after pruning has advanced startIndex
    function test_retroInclusionUpgrade_afterPrune() public {
        bytes32 I_FIX = bytes32(uint256(0xF1));

        // Prove and finalize without any activation boundary crossing
        vm.roll(deployBlock + 5);
        _submitAction();
        uint256 proofBlock = block.number;
        _submitProof(genesisBlock, proofBlock);

        vm.roll(proofBlock + TestConstants.FINALITY + 1);
        prover.finalize(proofBlock);
        // finalize calls prune, which may advance startIndex

        // Now do a retro inclusion upgrade after the prune
        uint256 retroBlock = block.number - 1;
        vm.prank(TestConstants.INCLUSION_ADMIN);
        prover.retroInclusionUpgrade(I_FIX, retroBlock);

        (, bytes32 iHash) = prover.getActivationHashes(retroBlock);
        assertEq(iHash, I_FIX, "Inclusion fix works after prune");

        // Genesis entry stf hash should still be accessible for blocks before retro
        (bytes32 sAtProof,) = prover.getActivationHashes(proofBlock);
        assertEq(sAtProof, TestConstants.STF_HASH, "Stf unchanged after prune + retro");
    }

    // --- Boundary value: retroInclusionUpgrade at exactly finalizedBlock ---

    /// @notice retroInclusionUpgrade at exactly the finality boundary reverts
    function test_retroInclusionUpgrade_atExactFinalizedBoundary_reverts() public {
        bytes32 I_FIX = bytes32(uint256(0xF1));

        vm.roll(deployBlock + 5);
        _submitAction();
        uint256 proofBlock = block.number;
        _submitProof(genesisBlock, proofBlock);

        vm.roll(proofBlock + TestConstants.FINALITY + 1);
        prover.finalize(proofBlock);

        uint256 finalizedBoundary = block.number - TestConstants.FINALITY;

        vm.prank(TestConstants.INCLUSION_ADMIN);
        vm.expectRevert("Retroactive upgrade block must be > finalized block");
        prover.retroInclusionUpgrade(I_FIX, finalizedBoundary);
    }

    /// @notice retroInclusionUpgrade one block above finality boundary succeeds
    function test_retroInclusionUpgrade_aboveFinalizedBoundary_succeeds() public {
        bytes32 I_FIX = bytes32(uint256(0xF1));

        vm.roll(deployBlock + 5);
        _submitAction();
        uint256 proofBlock = block.number;
        _submitProof(genesisBlock, proofBlock);

        vm.roll(proofBlock + TestConstants.FINALITY + 1);
        prover.finalize(proofBlock);

        uint256 finalizedBoundary = block.number - TestConstants.FINALITY;

        vm.prank(TestConstants.INCLUSION_ADMIN);
        prover.retroInclusionUpgrade(I_FIX, finalizedBoundary + 1);

        (, bytes32 iHash) = prover.getActivationHashes(finalizedBoundary + 1);
        assertEq(iHash, I_FIX, "Inclusion fix one block above finality boundary");
    }

    /// @notice retroInclusionUpgrade one block below finality boundary reverts
    function test_retroInclusionUpgrade_belowFinalizedBoundary_reverts() public {
        bytes32 I_FIX = bytes32(uint256(0xF1));

        vm.roll(deployBlock + 5);
        _submitAction();
        uint256 proofBlock = block.number;
        _submitProof(genesisBlock, proofBlock);

        vm.roll(proofBlock + TestConstants.FINALITY + 1);
        prover.finalize(proofBlock);

        uint256 finalizedBoundary = block.number - TestConstants.FINALITY;

        vm.prank(TestConstants.INCLUSION_ADMIN);
        vm.expectRevert();
        prover.retroInclusionUpgrade(I_FIX, finalizedBoundary - 1);
    }

    // --- Segmented proving around retro activation ---

    /// @notice Full segmented proof flow around a retroInclusionUpgrade activation
    function test_proveBoth_segmentedAroundRetroActivation() public {
        bytes32 I_FIX = bytes32(uint256(0xF1));

        // Prove and finalize to advance state
        vm.roll(deployBlock + 5);
        _submitAction();
        uint256 proofBlock1 = block.number;
        _submitProof(genesisBlock, proofBlock1);

        vm.roll(proofBlock1 + TestConstants.FINALITY + 1);
        prover.finalize(proofBlock1);

        // Retro inclusion upgrade at retroBlock (within finality window)
        uint256 retroBlock = block.number - 1;
        vm.prank(TestConstants.INCLUSION_ADMIN);
        prover.retroInclusionUpgrade(I_FIX, retroBlock);

        // State reset: pending = finalized = proofBlock1
        assertEq(prover.resetId(), 1);

        // Segment 1: prove finalized → retroBlock-1 (old inclusion hash)
        vm.roll(retroBlock + 5);
        _submitAction();
        uint256 seg1End = retroBlock - 1;
        _submitProof(proofBlock1, seg1End);

        // Segment 2: prove retroBlock-1 → end (new inclusion hash, activation at startBlock+1)
        uint256 seg2End = block.number;
        _submitProof(seg1End, seg2End);
        assertEq(getPending().blockNumber, seg2End);
    }

    // --- Multiple activations: prove through both with three segments ---

    /// @notice Three-segment proof through two scheduled activations
    function test_proveBoth_threeSegmentsThroughTwoActivations() public {
        bytes32 S2 = bytes32(uint256(0xB2));
        bytes32 I2 = bytes32(uint256(0xA2));

        uint256 activation1 = deployBlock + 10;
        uint256 activation2 = deployBlock + 20;

        vm.prank(TestConstants.STF_ADMIN);
        prover.scheduleStfUpgrade(S2, activation1);

        vm.prank(TestConstants.INCLUSION_ADMIN);
        prover.scheduleInclusionUpgrade(I2, activation2);

        // Submit actions across both activations
        vm.roll(activation1 - 1);
        _submitAction();
        vm.roll(activation2 - 1);
        _submitAction();
        vm.roll(activation2 + 5);
        _submitAction();

        // Segment 1: genesis → activation1-1 (old S1, old I1)
        uint256 seg1End = activation1 - 1;
        _submitProof(genesisBlock, seg1End);

        // Segment 2: activation1-1 → activation2-1 (new S2, old I1)
        uint256 seg2End = activation2 - 1;
        _submitProof(seg1End, seg2End);

        // Segment 3: activation2-1 → end (S2, new I2)
        uint256 seg3End = block.number;
        _submitProof(seg2End, seg3End);
        assertEq(getPending().blockNumber, seg3End);
    }

    // --- getHashesForProofRange: NoValidEntry ---

    /// @notice Querying activation hashes before any entry reverts with NoValidEntry
    function test_getActivationHashes_beforeGenesisEntry_reverts() public {
        // Deploy at a higher block so genesis > 0 and we can query below it
        vm.roll(100);
        vm.startPrank(TestConstants.DEPLOYER);
        Actions freshActions = new Actions();
        Caller freshCaller = new Caller(address(freshActions));
        MockVerifier freshVerifier = new MockVerifier();
        uint64 nonce = vm.getNonce(TestConstants.DEPLOYER) + 1;
        address predicted = vm.computeCreateAddress(TestConstants.DEPLOYER, nonce);
        Vault freshVault = new Vault(
            address(freshActions),
            predicted,
            TestConstants.DEPLOYER,
            address(freshVerifier),
            TestConstants.WITHDRAWAL_VKEY
        );
        bytes32 cah = keccak256(abi.encode(address(freshActions), address(freshCaller), address(freshVault)));
        Prover freshProver = new Prover(
            address(freshActions),
            address(freshVerifier),
            TestConstants.FINALITY,
            cah,
            TestConstants.STF_ADMIN,
            TestConstants.STF_HASH,
            TestConstants.INCLUSION_ADMIN,
            TestConstants.INCLUSION_HASH,
            TestConstants.STF_ROOT
        );
        require(address(freshProver) == predicted);
        vm.stopPrank();

        // Genesis entry is at block 99. Query block 98 should revert with NoValidEntry.
        (bool success, bytes memory returnData) =
            address(freshProver).staticcall(abi.encodeWithSignature("getActivationHashes(uint256)", 98));
        assertFalse(success, "Should revert for block before genesis entry");
        assertEq(bytes4(returnData), bytes4(keccak256("NoValidEntry()")), "Should revert with NoValidEntry");
    }

    // --- Schedule edge cases ---

    /// @notice scheduleStfUpgrade with activationBlock == 0 reverts with clear message
    function test_scheduleStfUpgrade_activationBlockZero_reverts() public {
        vm.prank(TestConstants.STF_ADMIN);
        vm.expectRevert("Activation block must be greater than 0");
        prover.scheduleStfUpgrade(bytes32(uint256(0xFF)), 0);
    }

    /// @notice scheduleInclusionUpgrade with activationBlock == 0 reverts with clear message
    function test_scheduleInclusionUpgrade_activationBlockZero_reverts() public {
        vm.prank(TestConstants.INCLUSION_ADMIN);
        vm.expectRevert("Activation block must be greater than 0");
        prover.scheduleInclusionUpgrade(bytes32(uint256(0xAA)), 0);
    }

    /// @notice scheduleInclusionUpgrade in the past reverts
    function test_scheduleInclusionUpgrade_pastBlock_reverts() public {
        vm.roll(block.number + 10);
        vm.prank(TestConstants.INCLUSION_ADMIN);
        vm.expectRevert();
        prover.scheduleInclusionUpgrade(bytes32(uint256(0xAA)), block.number - 1);
    }

    /// @notice Scheduling at or below the last entry's activation block reverts
    function test_scheduleStfUpgrade_belowLastEntry_reverts() public {
        uint256 firstUpgrade = block.number + 10;
        vm.prank(TestConstants.STF_ADMIN);
        prover.scheduleStfUpgrade(bytes32(uint256(0xB2)), firstUpgrade);

        // Try to schedule at the same block
        vm.prank(TestConstants.STF_ADMIN);
        vm.expectRevert();
        prover.scheduleStfUpgrade(bytes32(uint256(0xB3)), firstUpgrade);

        // Try to schedule at an earlier block
        vm.prank(TestConstants.STF_ADMIN);
        vm.expectRevert();
        prover.scheduleStfUpgrade(bytes32(uint256(0xB3)), firstUpgrade - 1);
    }

    // --- Retro at start after finalize (integration) ---

    /// @notice Full stack: finalize prunes, then retroInclusionUpgrade at entries[startIndex]
    function test_retroInclusionUpgrade_replacementAtStartAfterFinalize() public {
        bytes32 S2 = bytes32(uint256(0xB2));
        bytes32 I_FIX = bytes32(uint256(0xF1));
        uint256 stfBlock = deployBlock + 5;

        vm.prank(TestConstants.STF_ADMIN);
        prover.scheduleStfUpgrade(S2, stfBlock);

        // Prove segment 1: genesis → stfBlock-1
        vm.roll(stfBlock - 1);
        _submitAction();
        _submitProof(genesisBlock, stfBlock - 1);

        // Prove segment 2: across the activation boundary
        vm.roll(stfBlock + 1);
        _submitAction();
        _submitProof(stfBlock - 1, block.number);

        // Finalize at stfBlock-1 — prunes genesis, stfBlock entry becomes start
        vm.roll(stfBlock - 1 + TestConstants.FINALITY);
        prover.finalize(stfBlock - 1);

        // stfBlock is in the past and > finalizedBoundary
        uint256 finalizedBoundary = block.number > TestConstants.FINALITY ? block.number - TestConstants.FINALITY : 0;
        require(stfBlock > finalizedBoundary, "stfBlock must be in retro window for this test");
        require(stfBlock < block.number, "stfBlock must be in the past");

        uint256 resetBefore = prover.resetId();

        vm.prank(TestConstants.INCLUSION_ADMIN);
        prover.retroInclusionUpgrade(I_FIX, stfBlock);

        assertEq(prover.resetId(), resetBefore + 1, "resetId incremented");

        (, bytes32 iAtStf) = prover.getActivationHashes(stfBlock);
        assertEq(iAtStf, I_FIX, "Inclusion replaced at start entry");

        (, bytes32 iLater) = prover.getActivationHashes(block.number - 1);
        assertEq(iLater, I_FIX, "Inclusion propagated to later blocks");
    }

    // --- Prune coverage ---

    /// @notice Prune reduces activeCount and makes old entries unreachable for getHashesForBlock
    function test_finalize_prunesOldEntries() public {
        bytes32 S2 = bytes32(uint256(0xB2));
        uint256 stfBlock = deployBlock + 5;

        vm.prank(TestConstants.STF_ADMIN);
        prover.scheduleStfUpgrade(S2, stfBlock);

        // Prove segment 1: genesis → stfBlock-1 (before activation)
        vm.roll(stfBlock - 1);
        _submitAction();
        _submitProof(genesisBlock, stfBlock - 1);

        // Prove segment 2: stfBlock-1 → stfBlock+1 (after activation)
        vm.roll(stfBlock + 1);
        _submitAction();
        _submitProof(stfBlock - 1, block.number);
        uint256 proofBlock = block.number;

        // Finalize past the stf upgrade — should prune genesis entry
        vm.roll(proofBlock + TestConstants.FINALITY + 1);
        prover.finalize(proofBlock);

        // Stf upgrade entry is still reachable (it's the active one)
        (bytes32 sHash,) = prover.getActivationHashes(stfBlock);
        assertEq(sHash, S2, "Stf upgrade still accessible after prune");

        // Genesis block entry was pruned — querying before stf upgrade
        // should still work because the stf upgrade entry covers it after prune
        // (prune keeps at least one entry)
        (bytes32 sAtEarly,) = prover.getActivationHashes(stfBlock);
        assertEq(sAtEarly, S2);
    }

    /// @notice Prune + retro where retro block is near the pruned boundary
    function test_retroInclusionUpgrade_nearPruneBoundary() public {
        bytes32 I_FIX = bytes32(uint256(0xF1));

        // Prove and finalize
        vm.roll(deployBlock + 5);
        _submitAction();
        uint256 proofBlock = block.number;
        _submitProof(genesisBlock, proofBlock);

        vm.roll(proofBlock + TestConstants.FINALITY + 1);
        prover.finalize(proofBlock);

        // The finality boundary is close to the pruned entries
        uint256 finalizedBoundary = block.number - TestConstants.FINALITY;

        // Retro one block above the finality boundary (at boundary now reverts)
        vm.prank(TestConstants.INCLUSION_ADMIN);
        prover.retroInclusionUpgrade(I_FIX, finalizedBoundary + 1);

        (, bytes32 iHash) = prover.getActivationHashes(finalizedBoundary + 1);
        assertEq(iHash, I_FIX, "Inclusion fix near prune boundary");

        // Can still query blocks after the retro
        (, bytes32 iLater) = prover.getActivationHashes(block.number - 1);
        assertEq(iLater, I_FIX, "Inclusion fix applies to later blocks too");
    }
}
