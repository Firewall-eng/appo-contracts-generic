// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Base} from "./Base.t.sol";
import {TestConstants} from "./TestConstants.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {IProver} from "../src/interfaces/IProver.sol";
import {IActions} from "../src/interfaces/IActions.sol";
import {ICaller} from "../src/interfaces/ICaller.sol";

/// @title AccumulatorTest
/// @notice End-to-end tests validating the accumulator chain across all contracts.
/// @dev These tests exercise the full pipeline: Vault deposits -> Actions accumulator ->
///      Prover proof submission -> pending -> finalized. They also verify that the
///      accumulator can be reconstructed from events emitted by different contracts,
///      and that Prover admin actions (activations) are correctly part of the chain.
contract AccumulatorTest is Base {
    /// @notice Full pipeline: deposit -> prove -> move pending -> finalize
    function test_fullPipeline_vaultActionsProver() public {
        uint256 genesisBlock = deployBlock - 1;
        bytes32 preDepositAcc = actions.accumulator();

        fundEth(TestConstants.USER_1, 2 ether);
        vm.prank(TestConstants.USER_1);
        vault.enterEth{value: 1 ether}(TestConstants.USER_1);

        mintAndApprove(TestConstants.USER_1, address(vault), 500);
        vm.prank(TestConstants.USER_1);
        vault.enterErc20(TestConstants.USER_1, address(token), 500);

        // Verify accumulator is a 2-step chain from init
        bytes memory ethData = abi.encode(TestConstants.USER_1, uint256(1 ether));
        bytes32 acc1 = computeAccumulator(preDepositAcc, address(vault), TestConstants.ENTER_ETH, ethData);
        bytes memory erc20Data = abi.encode(TestConstants.USER_1, address(token), uint256(500));
        bytes32 acc2 = computeAccumulator(acc1, address(vault), TestConstants.ENTER_ERC20, erc20Data);
        assertEq(actions.accumulator(), acc2);

        // Prove inclusion and stf root, move pending, finalize
        uint256 proofBlock = block.number;
        bytes32 inclusionAcc = keccak256("test_inclusion_accumulator");
        prover.proveBoth(genesisBlock, proofBlock, inclusionAcc, TestConstants.STF_ROOT, "", "");

        IProver.Commitment memory p = getPending();
        assertEq(p.blockNumber, proofBlock);
        assertEq(p.actionsAccumulator, acc2);

        vm.roll(proofBlock + TestConstants.FINALITY + 1);
        prover.finalize(proofBlock);
        IProver.Commitment memory f = getFinalized();
        assertEq(f.blockNumber, proofBlock);
        assertEq(f.actionsAccumulator, acc2);
    }

    /// @notice Reconstruct accumulator from events across Vault, Actions, and Caller
    function test_accumulatorReconstructionFromEvents_crossContract() public {
        bytes32 startAcc = actions.accumulator();
        vm.recordLogs();

        fundEth(TestConstants.USER_1, 1 ether);
        vm.prank(TestConstants.USER_1);
        vault.enterEth{value: 1 ether}(TestConstants.USER_1);

        vm.prank(TestConstants.USER_2);
        actions.action(TestConstants.DEPOSIT_COLLATERAL, abi.encode(uint256(42)));

        ICaller.Call[] memory calls = new ICaller.Call[](1);
        calls[0] = ICaller.Call({
            to: address(callerHelper), callData: abi.encodeCall(callerHelper.calculatePrice, ()), isStatic: false
        });
        vm.prank(TestConstants.USER_2);
        caller.call(TestConstants.BORROW, "", calls);

        // Replay the chain using only event data
        VmSafe.Log[] memory logs = vm.getRecordedLogs();
        bytes32 acc = startAcc;
        bytes32 actionSig = keccak256("Action(address,bytes4,bytes)");

        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != actionSig) continue;
            if (logs[i].emitter != address(actions)) continue;

            address sender = address(uint160(uint256(logs[i].topics[1])));
            bytes4 identifier = bytes4(logs[i].topics[2]);
            bytes memory contextPrefixedData = abi.decode(logs[i].data, (bytes));

            acc = keccak256(abi.encode(acc, sender, identifier, contextPrefixedData));
        }

        assertEq(acc, actions.accumulator(), "Cross-contract reconstruction mismatch");
    }

    /// @notice scheduleStfUpgrade does not record an action in the accumulator
    function test_scheduleStfUpgrade_noAccumulatorSideEffect() public {
        bytes32 accBefore = actions.accumulator();

        bytes32 newStfHash = bytes32(uint256(0xFF));
        vm.prank(TestConstants.STF_ADMIN);
        prover.scheduleStfUpgrade(newStfHash, block.number + 5);

        assertEq(actions.accumulator(), accBefore, "Schedule should not touch accumulator");
    }
}
