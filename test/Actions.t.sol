// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Base} from "./Base.t.sol";
import {TestConstants} from "./TestConstants.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {Actions} from "../src/Actions.sol";
import {IActions} from "../src/interfaces/IActions.sol";

/// @title ActionsTest
/// @notice Tests for Actions.sol -- the canonical action log and accumulator hash chain.
/// @dev The accumulator is the trust anchor for the entire Appo system. If it can be
///      skipped, reordered, or fabricated, the proving model breaks. These tests verify
///      hash chain integrity, block-level storage, event emission, and that the chain
///      can be independently reconstructed from events alone (as the offchain node does).
contract ActionsTest is Base {
    // --- Constructor ---

    /// @notice INIT_ACCUMULATOR is deterministic: keccak256(abi.encode("Init", TestConstants.DEPLOYER))
    function test_constructor_initAccumulator() public view {
        bytes32 expected = keccak256(abi.encode("Init", TestConstants.DEPLOYER));
        assertEq(actions.INIT_ACCUMULATOR(), expected);
    }

    /// @notice A fresh Actions contract has accumulator == INIT_ACCUMULATOR
    function test_constructor_accumulatorMatchesInit() public {
        Actions freshActions = new Actions();
        assertEq(freshActions.accumulator(), freshActions.INIT_ACCUMULATOR());
    }

    /// @notice Deploy block gets a checkpoint entry immediately
    function test_constructor_accumulatorAtDeployBlock() public {
        Actions freshActions = new Actions();
        bytes32 freshInit = keccak256(abi.encode("Init", address(this)));
        assertEq(freshActions.accumulatorUpperLookup(block.number), freshInit);
    }

    /// @notice Init event is emitted with the deployer address during construction
    function test_constructor_initEvent() public {
        vm.prank(TestConstants.USER_1);
        vm.expectEmit(true, true, true, true);
        emit IActions.Init(TestConstants.USER_1);
        new Actions();
    }

    // --- Single action ---

    /// @notice Single action produces the correct keccak hash chain step
    function test_action_singleAction_accumulatorCorrect() public {
        bytes4 id = TestConstants.MINT;
        bytes memory data = abi.encode(uint256(42));

        bytes32 expected = computeAccumulator(actions.accumulator(), TestConstants.USER_1, id, data);

        vm.prank(TestConstants.USER_1);
        actions.action(id, data);

        assertEq(actions.accumulator(), expected);
    }

    /// @notice Checkpoint is updated to match live accumulator
    function test_action_singleAction_checkpointUpdated() public {
        bytes4 id = TestConstants.MINT;
        bytes memory data = abi.encode(uint256(42));

        vm.prank(TestConstants.USER_1);
        actions.action(id, data);

        assertEq(actions.accumulatorUpperLookup(block.number), actions.accumulator());
    }

    // --- Hash chain ---

    /// @notice Sequential actions from different senders produce a correct running chain
    function test_action_multipleActions_chainIntegrity() public {
        bytes32 acc = actions.accumulator();

        address[3] memory senders = [TestConstants.USER_1, TestConstants.USER_2, TestConstants.DEPLOYER];
        bytes4[3] memory ids = [TestConstants.SUPPLY, TestConstants.REDEEM, TestConstants.REPAY];

        for (uint256 i = 0; i < 3; i++) {
            bytes memory data = abi.encode(i);
            acc = computeAccumulator(acc, senders[i], ids[i], data);

            vm.prank(senders[i]);
            actions.action(ids[i], data);

            assertEq(actions.accumulator(), acc, "Chain mismatch at step");
        }
    }

    /// @notice Accumulator can be fully reconstructed from Action events alone.
    ///         This is what the offchain operator node does to replay state.
    function test_action_accumulatorReconstruction_fromEvents() public {
        bytes32 startAcc = actions.accumulator();
        vm.recordLogs();

        bytes4[5] memory ids = [
            TestConstants.SUPPLY,
            TestConstants.REDEEM,
            TestConstants.REPAY,
            TestConstants.LIQUIDATE,
            TestConstants.WITHDRAW_COLLATERAL
        ];
        for (uint256 i = 0; i < 5; i++) {
            address sender = i % 2 == 0 ? TestConstants.USER_1 : TestConstants.USER_2;
            bytes4 id = ids[i];
            bytes memory data = abi.encode(i, i * 100);

            vm.prank(sender);
            actions.action(id, data);
        }

        VmSafe.Log[] memory logs = vm.getRecordedLogs();
        bytes32 acc = startAcc;

        bytes32 actionSig = keccak256("Action(address,bytes4,bytes)");

        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != actionSig) continue;

            address sender = address(uint160(uint256(logs[i].topics[1])));
            bytes4 identifier = bytes4(logs[i].topics[2]);
            bytes memory contextPrefixedData = abi.decode(logs[i].data, (bytes));

            acc = keccak256(abi.encode(acc, sender, identifier, contextPrefixedData));
        }

        assertEq(acc, actions.accumulator(), "Event reconstruction mismatch");
    }

    /// @notice Multiple actions in the same block: checkpoint stores the LAST value only
    function test_action_sameBlock_lastValueStored() public {
        bytes4 id1 = TestConstants.SUPPLY;
        bytes4 id2 = TestConstants.REDEEM;

        vm.prank(TestConstants.USER_1);
        actions.action(id1, "");

        bytes32 afterFirst = actions.accumulator();

        vm.prank(TestConstants.USER_1);
        actions.action(id2, "");

        bytes32 afterSecond = actions.accumulator();

        assertEq(actions.accumulatorUpperLookup(block.number), afterSecond);
        assertTrue(afterFirst != afterSecond);
    }

    /// @notice Actions in different blocks each get their own checkpoint entry
    function test_action_differentBlocks_bothStored() public {
        uint256 block1 = block.number;
        vm.prank(TestConstants.USER_1);
        actions.action(TestConstants.SUPPLY, "");
        bytes32 acc1 = actions.accumulator();

        vm.roll(block1 + 1);

        vm.prank(TestConstants.USER_1);
        actions.action(TestConstants.REDEEM, "");
        bytes32 acc2 = actions.accumulator();

        assertEq(actions.accumulatorUpperLookup(block1), acc1);
        assertEq(actions.accumulatorUpperLookup(block1 + 1), acc2);
        assertTrue(acc1 != acc2);
    }

    // --- Events ---

    /// @notice Action event emits correct indexed params and contextPrefixedData
    function test_action_eventEmission() public {
        bytes4 id = TestConstants.BURN;
        bytes memory data = abi.encode(uint256(99));
        bytes memory expectedContextData = computeContextPrefixedData(data);

        vm.expectEmit(true, true, false, true, address(actions));
        emit IActions.Action(TestConstants.USER_1, id, expectedContextData);

        vm.prank(TestConstants.USER_1);
        actions.action(id, data);
    }

    /// @notice Context prefix encodes (block.number, block.timestamp, tx.gasprice, data)
    function test_action_contextPrefixCorrect() public {
        bytes4 id = TestConstants.SET_PARAMS;
        bytes memory data = abi.encode(uint256(7), address(0xBEEF));

        vm.roll(100);
        vm.warp(9999);
        vm.txGasPrice(5 gwei);

        vm.recordLogs();
        vm.prank(TestConstants.USER_1);
        actions.action(id, data);

        VmSafe.Log[] memory logs = vm.getRecordedLogs();
        bytes32 actionSig = keccak256("Action(address,bytes4,bytes)");

        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != actionSig) continue;

            bytes memory contextPrefixedData = abi.decode(logs[i].data, (bytes));
            bytes memory expected = abi.encode(uint256(100), uint256(9999), uint256(5 gwei), data);
            assertEq(contextPrefixedData, expected, "Context prefix mismatch");
            return;
        }
        revert("Action event not found");
    }

    // --- Edge cases ---

    /// @notice Empty data is valid -- context prefix still gets encoded around it
    function test_action_emptyData() public {
        bytes memory emptyData = "";
        bytes32 expected =
            computeAccumulator(actions.accumulator(), TestConstants.USER_1, TestConstants.HEARTBEAT, emptyData);

        vm.prank(TestConstants.USER_1);
        actions.action(TestConstants.HEARTBEAT, emptyData);

        assertEq(actions.accumulator(), expected);
    }

    /// @notice action() has no access control -- any address can submit
    function test_action_anyoneCanCall() public {
        address[4] memory callers =
            [TestConstants.USER_1, TestConstants.USER_2, TestConstants.DEPLOYER, address(0xDEAD)];
        bytes4[4] memory ids =
            [TestConstants.DEPOSIT_COLLATERAL, TestConstants.BORROW, TestConstants.SUPPLY, TestConstants.REDEEM];
        for (uint256 i = 0; i < callers.length; i++) {
            vm.prank(callers[i]);
            actions.action(ids[i], abi.encode(i));
        }
        assertTrue(actions.accumulator() != bytes32(0));
    }
}
