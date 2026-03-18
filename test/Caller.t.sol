// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Base} from "./Base.t.sol";
import {TestConstants} from "./TestConstants.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {IActions} from "../src/interfaces/IActions.sol";
import {ICaller} from "../src/interfaces/ICaller.sol";

/// @title CallerTest
/// @notice Tests for Caller.sol -- the batch executor that composes external calls
///         and records their results as a single action in the accumulator.
/// @dev Caller is the bridge between arbitrary onchain operations and the Appo action log.
///      Key properties: atomic batch execution, correct result encoding, and that the
///      Caller contract (not the EOA) is the msg.sender recorded in Actions.
contract CallerTest is Base {
    // --- Constructor ---

    /// @notice Caller stores the correct Actions contract address
    function test_constructor_actionsAddress() public view {
        assertEq(caller.actions(), address(actions));
    }

    // --- Basic execution ---

    /// @notice Non-static call executes and mutates target state
    function test_call_singleNonStaticCall() public {
        ICaller.Call[] memory calls = new ICaller.Call[](1);
        calls[0] = ICaller.Call({
            to: address(callerHelper), callData: abi.encodeCall(callerHelper.increment, ()), isStatic: false
        });

        vm.prank(TestConstants.USER_1);
        caller.call(TestConstants.SUPPLY, "", calls);

        assertEq(callerHelper.value(), 1);
        assertTrue(actions.accumulator() != initAccumulator);
    }

    /// @notice Static call reads state without mutation, but still records an action
    function test_call_singleStaticCall() public {
        ICaller.Call[] memory calls = new ICaller.Call[](1);
        calls[0] =
            ICaller.Call({to: address(callerHelper), callData: abi.encodeCall(callerHelper.get, ()), isStatic: true});

        vm.prank(TestConstants.USER_1);
        caller.call(TestConstants.REDEEM, "", calls);

        assertEq(callerHelper.value(), 0);
        assertTrue(actions.accumulator() != initAccumulator);
    }

    /// @notice Static call to a state-modifying function reverts at the EVM level
    function test_call_staticCallCannotModifyState() public {
        ICaller.Call[] memory calls = new ICaller.Call[](1);
        calls[0] = ICaller.Call({
            to: address(callerHelper), callData: abi.encodeCall(callerHelper.increment, ()), isStatic: true
        });

        vm.prank(TestConstants.USER_1);
        vm.expectRevert("Call failed");
        caller.call(TestConstants.REPAY, "", calls);
    }

    /// @notice Batch of 3 calls: two increments + one static read, all execute in order
    function test_call_batchCalls() public {
        ICaller.Call[] memory calls = new ICaller.Call[](3);
        calls[0] = ICaller.Call({
            to: address(callerHelper), callData: abi.encodeCall(callerHelper.increment, ()), isStatic: false
        });
        calls[1] = ICaller.Call({
            to: address(callerHelper), callData: abi.encodeCall(callerHelper.increment, ()), isStatic: false
        });
        calls[2] =
            ICaller.Call({to: address(callerHelper), callData: abi.encodeCall(callerHelper.get, ()), isStatic: true});

        vm.prank(TestConstants.USER_1);
        caller.call(TestConstants.LIQUIDATE, "", calls);

        assertEq(callerHelper.value(), 2);
    }

    /// @notice Any failed call in a batch reverts the entire batch atomically
    function test_call_failedCallRevertsEntireBatch() public {
        ICaller.Call[] memory calls = new ICaller.Call[](2);
        calls[0] = ICaller.Call({
            to: address(callerHelper), callData: abi.encodeCall(callerHelper.increment, ()), isStatic: false
        });
        calls[1] = ICaller.Call({
            to: address(callerHelper), callData: abi.encodeCall(callerHelper.failAlways, ()), isStatic: false
        });

        vm.prank(TestConstants.USER_1);
        vm.expectRevert("Call failed");
        caller.call(TestConstants.WITHDRAW_COLLATERAL, "", calls);

        // Atomically reverted -- callerHelper is still 0
        assertEq(callerHelper.value(), 0);
    }

    // --- Data encoding ---

    /// @notice msg.sender in the Action event is address(caller), not the original EOA.
    ///         The EOA address is preserved inside the encoded action data instead.
    function test_call_senderInActionIsCaller() public {
        ICaller.Call[] memory calls = new ICaller.Call[](1);
        calls[0] =
            ICaller.Call({to: address(callerHelper), callData: abi.encodeCall(callerHelper.get, ()), isStatic: true});

        vm.recordLogs();
        vm.prank(TestConstants.USER_1);
        caller.call(TestConstants.SET_ORACLE, "", calls);

        VmSafe.Log[] memory logs = vm.getRecordedLogs();
        bytes32 actionSig = keccak256("Action(address,bytes4,bytes)");

        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != actionSig) continue;
            address eventSender = address(uint160(uint256(logs[i].topics[1])));
            assertEq(eventSender, address(caller));
            return;
        }
        revert("Action event not found");
    }

    /// @notice Result structs encode (to, callData, returnData, isStatic) correctly
    function test_call_resultEncodingCorrect() public {
        ICaller.Call[] memory calls = new ICaller.Call[](1);
        calls[0] =
            ICaller.Call({to: address(callerHelper), callData: abi.encodeCall(callerHelper.get, ()), isStatic: true});

        vm.recordLogs();
        vm.prank(TestConstants.USER_1);
        caller.call(TestConstants.UPDATE_RATE, abi.encode("prefix"), calls);

        VmSafe.Log[] memory logs = vm.getRecordedLogs();
        bytes32 actionSig = keccak256("Action(address,bytes4,bytes)");

        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != actionSig) continue;

            bytes memory contextPrefixedData = abi.decode(logs[i].data, (bytes));
            (,,, bytes memory innerData) = abi.decode(contextPrefixedData, (uint256, uint256, uint256, bytes));

            (address callerSender, bytes memory prefixData, ICaller.Result[] memory results) =
                abi.decode(innerData, (address, bytes, ICaller.Result[]));

            assertEq(callerSender, TestConstants.USER_1, "Original sender mismatch");
            assertEq(prefixData, abi.encode("prefix"), "Prefix data mismatch");
            assertEq(results.length, 1);
            assertEq(results[0].to, address(callerHelper));
            assertEq(results[0].callData, abi.encodeCall(callerHelper.get, ()));
            assertEq(results[0].returnData, abi.encode(uint256(0)));
            assertTrue(results[0].isStatic);
            return;
        }
        revert("Action event not found");
    }

    /// @notice Arbitrary prefixData bytes are preserved verbatim in the action encoding
    function test_call_prefixDataPreserved() public {
        bytes memory prefixData = abi.encode("test-prefix", uint256(999));

        ICaller.Call[] memory calls = new ICaller.Call[](1);
        calls[0] =
            ICaller.Call({to: address(callerHelper), callData: abi.encodeCall(callerHelper.get, ()), isStatic: true});

        vm.recordLogs();
        vm.prank(TestConstants.USER_1);
        caller.call(TestConstants.SWAP, prefixData, calls);

        VmSafe.Log[] memory logs = vm.getRecordedLogs();
        bytes32 actionSig = keccak256("Action(address,bytes4,bytes)");

        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != actionSig) continue;

            bytes memory contextPrefixedData = abi.decode(logs[i].data, (bytes));
            (,,, bytes memory innerData) = abi.decode(contextPrefixedData, (uint256, uint256, uint256, bytes));
            (, bytes memory decodedPrefix,) = abi.decode(innerData, (address, bytes, ICaller.Result[]));

            assertEq(decodedPrefix, prefixData, "Prefix data not preserved");
            return;
        }
        revert("Action event not found");
    }

    // --- Edge cases ---

    /// @notice Empty Call[] array succeeds and still records an action
    function test_call_emptyCalls() public {
        ICaller.Call[] memory calls = new ICaller.Call[](0);

        vm.prank(TestConstants.USER_1);
        caller.call(TestConstants.HEARTBEAT, "", calls);

        assertTrue(actions.accumulator() != initAccumulator);
    }

    /// @notice Call to an EOA (no code) succeeds with empty returnData in EVM
    function test_call_callToEOA() public {
        ICaller.Call[] memory calls = new ICaller.Call[](1);
        calls[0] = ICaller.Call({to: address(0xBEEF), callData: "", isStatic: false});

        vm.prank(TestConstants.USER_1);
        caller.call(TestConstants.CLOSE_POSITION, "", calls);

        assertTrue(actions.accumulator() != initAccumulator);
    }
}
