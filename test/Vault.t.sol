// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Base} from "./Base.t.sol";
import {Actions} from "../src/Actions.sol";
import {Caller} from "../src/Caller.sol";
import {Vault} from "../src/Vault.sol";
import {Prover} from "../src/Prover.sol";
import {TestConstants} from "./TestConstants.sol";
import {IActions} from "../src/interfaces/IActions.sol";
import {MockVerifier} from "./mocks/MockVerifier.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {ReentrantERC20, VaultAttacker} from "./mocks/ReentrantERC20.sol";
import {PhantomERC20} from "./mocks/PhantomERC20.sol";
import {CrossReentrantERC20} from "./mocks/CrossReentrantERC20.sol";
import {NoReturnERC20, FalseReturnERC20} from "./mocks/NoReturnERC20.sol";

/// @title VaultTest
/// @notice Tests for Vault.sol -- the fund custody contract for ETH and ERC20 deposits.
/// @dev Vault records every deposit/withdrawal as an action in the accumulator via Actions.sol.
///      The msg.sender in the Action event is always address(vault), not the depositor.
///      The depositor address is encoded in the action data instead. Exits are gated by
///      SP1 withdrawal proofs verified against the finalized stfRoot.
contract VaultTest is Base {
    // --- Identifier constants ---

    function test_identifierConstants() public view {
        assertEq(vault.ENTER_ETH(), TestConstants.ENTER_ETH);
        assertEq(vault.ENTER_ERC20(), TestConstants.ENTER_ERC20);
        assertEq(vault.EXIT_ETH(), TestConstants.EXIT_ETH);
        assertEq(vault.EXIT_ERC20(), TestConstants.EXIT_ERC20);
        assertEq(vault.SET_WITHDRAWAL_VKEY(), TestConstants.SET_WITHDRAWAL_VKEY);
        assertEq(vault.WHITELIST_ASSET(), TestConstants.WHITELIST_ASSET);
        assertEq(vault.DELIST_ASSET(), TestConstants.DELIST_ASSET);
        assertEq(vault.CHANGE_VAULT_ADMIN(), TestConstants.CHANGE_VAULT_ADMIN);
    }

    // ========================================================================
    // enterEth
    // ========================================================================

    function test_enterEth_ethCustody() public {
        fundEth(TestConstants.USER_1, 2 ether);

        vm.prank(TestConstants.USER_1);
        vault.enterEth{value: 1 ether}(TestConstants.USER_1);

        assertEq(address(vault).balance, 1 ether);
        assertEq(TestConstants.USER_1.balance, 1 ether);
    }

    function test_enterEth_accumulatorUpdated() public {
        fundEth(TestConstants.USER_1, 1 ether);

        bytes memory data = abi.encode(TestConstants.USER_1, uint256(1 ether));
        bytes32 expected = computeAccumulator(actions.accumulator(), address(vault), TestConstants.ENTER_ETH, data);

        vm.prank(TestConstants.USER_1);
        vault.enterEth{value: 1 ether}(TestConstants.USER_1);

        assertEq(actions.accumulator(), expected);
    }

    function test_enterEth_actionEventEmitted() public {
        fundEth(TestConstants.USER_1, 1 ether);

        bytes memory data = abi.encode(TestConstants.USER_1, uint256(1 ether));
        bytes memory expectedContextData = computeContextPrefixedData(data);

        vm.expectEmit(true, true, false, true, address(actions));
        emit IActions.Action(address(vault), TestConstants.ENTER_ETH, expectedContextData);

        vm.prank(TestConstants.USER_1);
        vault.enterEth{value: 1 ether}(TestConstants.USER_1);
    }

    function test_enterEth_revertsOnZeroValue() public {
        vm.prank(TestConstants.USER_1);
        vm.expectRevert("msg.value must be greater than 0");
        vault.enterEth{value: 0}(TestConstants.USER_1);
    }

    function test_enterEth_differentUserAndSender() public {
        fundEth(TestConstants.USER_1, 1 ether);

        bytes memory data = abi.encode(TestConstants.USER_2, uint256(1 ether));
        bytes32 expected = computeAccumulator(actions.accumulator(), address(vault), TestConstants.ENTER_ETH, data);

        vm.prank(TestConstants.USER_1);
        vault.enterEth{value: 1 ether}(TestConstants.USER_2);

        assertEq(actions.accumulator(), expected);
        assertEq(address(vault).balance, 1 ether);
    }

    // ========================================================================
    // enterErc20
    // ========================================================================

    function test_enterErc20_tokenTransfer() public {
        mintAndApprove(TestConstants.USER_1, address(vault), 100);

        vm.prank(TestConstants.USER_1);
        vault.enterErc20(TestConstants.USER_1, address(token), 100);

        assertEq(token.balanceOf(address(vault)), 100);
        assertEq(token.balanceOf(TestConstants.USER_1), 0);
    }

    function test_enterErc20_accumulatorUpdated() public {
        mintAndApprove(TestConstants.USER_1, address(vault), 100);

        bytes memory data = abi.encode(TestConstants.USER_1, address(token), uint256(100));
        bytes32 expected = computeAccumulator(actions.accumulator(), address(vault), TestConstants.ENTER_ERC20, data);

        vm.prank(TestConstants.USER_1);
        vault.enterErc20(TestConstants.USER_1, address(token), 100);

        assertEq(actions.accumulator(), expected);
    }

    function test_enterErc20_actionEventEmitted() public {
        mintAndApprove(TestConstants.USER_1, address(vault), 100);

        bytes memory data = abi.encode(TestConstants.USER_1, address(token), uint256(100));
        bytes memory expectedContextData = computeContextPrefixedData(data);

        vm.expectEmit(true, true, false, true, address(actions));
        emit IActions.Action(address(vault), TestConstants.ENTER_ERC20, expectedContextData);

        vm.prank(TestConstants.USER_1);
        vault.enterErc20(TestConstants.USER_1, address(token), 100);
    }

    function test_enterErc20_revertsOnFailedTransfer() public {
        vm.prank(TestConstants.USER_1);
        vm.expectRevert();
        vault.enterErc20(TestConstants.USER_1, address(token), 100);
    }

    function test_enterErc20_revertsOnZeroAmount() public {
        mintAndApprove(TestConstants.USER_1, address(vault), 100);

        vm.prank(TestConstants.USER_1);
        vm.expectRevert();
        vault.enterErc20(TestConstants.USER_1, address(token), 0);
    }

    /// @notice Deposits of two different ERC20 assets chain the accumulator correctly
    function test_enterErc20_multiAsset_chainedAccumulator() public {
        MockERC20 tokenB = deployMockERC20("Mock DAI", "DAI");
        vm.prank(TestConstants.DEPLOYER);
        vault.whitelistAsset(address(tokenB));

        mintAndApprove(TestConstants.USER_1, address(vault), 100);
        mintAndApproveToken(tokenB, TestConstants.USER_1, address(vault), 200);

        bytes memory dataA = abi.encode(TestConstants.USER_1, address(token), uint256(100));
        bytes32 acc1 = computeAccumulator(actions.accumulator(), address(vault), TestConstants.ENTER_ERC20, dataA);

        vm.prank(TestConstants.USER_1);
        vault.enterErc20(TestConstants.USER_1, address(token), 100);
        assertEq(actions.accumulator(), acc1);

        bytes memory dataB = abi.encode(TestConstants.USER_1, address(tokenB), uint256(200));
        bytes32 acc2 = computeAccumulator(acc1, address(vault), TestConstants.ENTER_ERC20, dataB);

        vm.prank(TestConstants.USER_1);
        vault.enterErc20(TestConstants.USER_1, address(tokenB), 200);
        assertEq(actions.accumulator(), acc2);

        assertEq(token.balanceOf(address(vault)), 100);
        assertEq(tokenB.balanceOf(address(vault)), 200);
    }

    // ========================================================================
    // No receive ------ direct ETH sends revert
    // ========================================================================

    /// @notice Vault has no receive(); direct ETH send reverts
    function test_vault_rejectsDirectEthSend() public {
        vm.deal(TestConstants.USER_1, 1 ether);

        vm.prank(TestConstants.USER_1);
        (bool success,) = address(vault).call{value: 1 ether}("");
        assertFalse(success);
        assertEq(address(vault).balance, 0);
    }

    /// @notice Vault has no fallback(); call with data and value reverts
    function test_vault_rejectsDirectEthSend_withData() public {
        vm.deal(TestConstants.USER_1, 1 ether);

        vm.prank(TestConstants.USER_1);
        (bool success,) = address(vault).call{value: 1 ether}("0x");
        assertFalse(success);
        assertEq(address(vault).balance, 0);
    }

    // ========================================================================
    // exitEth
    // ========================================================================

    function test_exitEth_succeeds() public {
        fundEth(TestConstants.USER_1, 1 ether);
        vm.prank(TestConstants.USER_1);
        vault.enterEth{value: 1 ether}(TestConstants.USER_1);

        _advanceToFinalized();

        uint256 userBalBefore = TestConstants.USER_1.balance;

        vm.prank(TestConstants.USER_1);
        vault.exitEth(1 ether, "");

        assertEq(TestConstants.USER_1.balance, userBalBefore + 1 ether);
        assertEq(address(vault).balance, 0);
    }

    function test_exitEth_zeroAmountReverts() public {
        _advanceToFinalized();

        vm.prank(TestConstants.USER_1);
        vm.expectRevert("amount must be greater than 0");
        vault.exitEth(0, "");
    }

    function test_exitEth_proofVerificationFails() public {
        fundEth(TestConstants.USER_1, 1 ether);
        vm.prank(TestConstants.USER_1);
        vault.enterEth{value: 1 ether}(TestConstants.USER_1);

        _advanceToFinalized();

        mockVerifier.setShouldRevert(true);

        vm.prank(TestConstants.USER_1);
        vm.expectRevert("MockVerifier: forced revert");
        vault.exitEth(1 ether, "");
    }

    function test_exitEth_accumulatorUpdated() public {
        fundEth(TestConstants.USER_1, 1 ether);
        vm.prank(TestConstants.USER_1);
        vault.enterEth{value: 1 ether}(TestConstants.USER_1);

        _advanceToFinalized();

        bytes memory data = abi.encode(TestConstants.USER_1, uint256(1 ether));
        bytes32 expected = computeAccumulator(actions.accumulator(), address(vault), TestConstants.EXIT_ETH, data);

        vm.prank(TestConstants.USER_1);
        vault.exitEth(1 ether, "");

        assertEq(actions.accumulator(), expected);
    }

    function test_exitEth_actionEventEmitted() public {
        fundEth(TestConstants.USER_1, 1 ether);
        vm.prank(TestConstants.USER_1);
        vault.enterEth{value: 1 ether}(TestConstants.USER_1);

        _advanceToFinalized();

        bytes memory data = abi.encode(TestConstants.USER_1, uint256(1 ether));
        bytes memory expectedContextData = computeContextPrefixedData(data);

        vm.expectEmit(true, true, false, true, address(actions));
        emit IActions.Action(address(vault), TestConstants.EXIT_ETH, expectedContextData);

        vm.prank(TestConstants.USER_1);
        vault.exitEth(1 ether, "");
    }

    function test_exitEth_totalWithdrawnTracked() public {
        fundEth(TestConstants.USER_1, 5 ether);
        vm.prank(TestConstants.USER_1);
        vault.enterEth{value: 5 ether}(TestConstants.USER_1);

        _advanceToFinalized();

        assertEq(vault.totalWithdrawn(TestConstants.USER_1, TestConstants.ETH_ADDRESS), 0);

        vm.prank(TestConstants.USER_1);
        vault.exitEth(2 ether, "");

        assertEq(vault.totalWithdrawn(TestConstants.USER_1, TestConstants.ETH_ADDRESS), 2 ether);

        vm.prank(TestConstants.USER_1);
        vault.exitEth(1 ether, "");

        assertEq(vault.totalWithdrawn(TestConstants.USER_1, TestConstants.ETH_ADDRESS), 3 ether);
    }

    function test_exitEth_reentrancyBlocked() public {
        ExitEthReentrant attacker = new ExitEthReentrant(address(vault));
        fundEth(address(attacker), 2 ether);
        attacker.deposit{value: 2 ether}();

        _advanceToFinalized();

        vm.expectRevert("ETH transfer failed");
        attacker.attack(1 ether);
    }

    function test_exitEth_multipleWithdrawals() public {
        fundEth(TestConstants.USER_1, 5 ether);
        vm.prank(TestConstants.USER_1);
        vault.enterEth{value: 5 ether}(TestConstants.USER_1);

        _advanceToFinalized();

        vm.prank(TestConstants.USER_1);
        vault.exitEth(2 ether, "");
        vm.prank(TestConstants.USER_1);
        vault.exitEth(1 ether, "");

        assertEq(address(vault).balance, 2 ether);
        assertEq(TestConstants.USER_1.balance, 3 ether);
    }

    function test_exitEth_noFinalizedState_reverts() public {
        // Deploy a fresh prover with stfRoot = bytes32(0) to hit the "no finalized state" path
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
            bytes32(0) // zero stfRoot
        );
        require(address(freshProver) == predicted);
        freshVault.whitelistAsset(TestConstants.ETH_ADDRESS);
        vm.stopPrank();

        vm.prank(TestConstants.USER_1);
        vm.expectRevert("no finalized state");
        freshVault.exitEth(1 ether, "");
    }

    // ========================================================================
    // exitErc20
    // ========================================================================

    function test_exitErc20_succeeds() public {
        mintAndApprove(TestConstants.USER_1, address(vault), 100);
        vm.prank(TestConstants.USER_1);
        vault.enterErc20(TestConstants.USER_1, address(token), 100);

        _advanceToFinalized();

        vm.prank(TestConstants.USER_1);
        vault.exitErc20(address(token), 100, "");

        assertEq(token.balanceOf(TestConstants.USER_1), 100);
        assertEq(token.balanceOf(address(vault)), 0);
    }

    function test_exitErc20_zeroAmountReverts() public {
        _advanceToFinalized();

        vm.prank(TestConstants.USER_1);
        vm.expectRevert("amount must be greater than 0");
        vault.exitErc20(address(token), 0, "");
    }

    function test_exitErc20_accumulatorUpdated() public {
        mintAndApprove(TestConstants.USER_1, address(vault), 100);
        vm.prank(TestConstants.USER_1);
        vault.enterErc20(TestConstants.USER_1, address(token), 100);

        _advanceToFinalized();

        bytes memory data = abi.encode(TestConstants.USER_1, address(token), uint256(100));
        bytes32 expected = computeAccumulator(actions.accumulator(), address(vault), TestConstants.EXIT_ERC20, data);

        vm.prank(TestConstants.USER_1);
        vault.exitErc20(address(token), 100, "");

        assertEq(actions.accumulator(), expected);
    }

    function test_exitErc20_totalWithdrawnTracked() public {
        mintAndApprove(TestConstants.USER_1, address(vault), 200);
        vm.prank(TestConstants.USER_1);
        vault.enterErc20(TestConstants.USER_1, address(token), 200);

        _advanceToFinalized();

        vm.prank(TestConstants.USER_1);
        vault.exitErc20(address(token), 50, "");

        assertEq(vault.totalWithdrawn(TestConstants.USER_1, address(token)), 50);

        vm.prank(TestConstants.USER_1);
        vault.exitErc20(address(token), 30, "");

        assertEq(vault.totalWithdrawn(TestConstants.USER_1, address(token)), 80);
    }

    function test_exitErc20_noReturnToken() public {
        NoReturnERC20 usdt = new NoReturnERC20("Tether", "USDT");
        vm.prank(TestConstants.DEPLOYER);
        vault.whitelistAsset(address(usdt));

        uint256 amount = 1000;
        usdt.mint(TestConstants.USER_1, amount);
        vm.prank(TestConstants.USER_1);
        usdt.approve(address(vault), amount);
        vm.prank(TestConstants.USER_1);
        vault.enterErc20(TestConstants.USER_1, address(usdt), amount);

        _advanceToFinalized();

        vm.prank(TestConstants.USER_1);
        vault.exitErc20(address(usdt), amount, "");

        assertEq(usdt.balanceOf(TestConstants.USER_1), amount);
        assertEq(usdt.balanceOf(address(vault)), 0);
    }

    // ========================================================================
    // setWithdrawalVKey
    // ========================================================================

    function test_setWithdrawalVKey_succeeds() public {
        bytes32 newVKey = keccak256("NEW_VKEY");

        vm.prank(TestConstants.DEPLOYER);
        vault.setWithdrawalVKey(newVKey);

        assertEq(vault.withdrawalVKey(), newVKey);
    }

    function test_setWithdrawalVKey_accumulatorUpdated() public {
        bytes32 newVKey = keccak256("NEW_VKEY");

        bytes memory data = abi.encode(newVKey);
        bytes32 expected =
            computeAccumulator(actions.accumulator(), address(vault), TestConstants.SET_WITHDRAWAL_VKEY, data);

        vm.prank(TestConstants.DEPLOYER);
        vault.setWithdrawalVKey(newVKey);

        assertEq(actions.accumulator(), expected);
    }

    function test_setWithdrawalVKey_revertsIfNotAdmin() public {
        vm.prank(TestConstants.USER_1);
        vm.expectRevert("only admin can call this");
        vault.setWithdrawalVKey(keccak256("NEW_VKEY"));
    }

    // ========================================================================
    // Multiple users withdrawing independently
    // ========================================================================

    function test_exit_multipleUsersIndependent() public {
        fundEth(TestConstants.USER_1, 5 ether);
        fundEth(TestConstants.USER_2, 3 ether);

        vm.prank(TestConstants.USER_1);
        vault.enterEth{value: 5 ether}(TestConstants.USER_1);
        vm.prank(TestConstants.USER_2);
        vault.enterEth{value: 3 ether}(TestConstants.USER_2);

        _advanceToFinalized();

        vm.prank(TestConstants.USER_1);
        vault.exitEth(2 ether, "");
        vm.prank(TestConstants.USER_2);
        vault.exitEth(1 ether, "");

        // Each user's totalWithdrawn is independent
        assertEq(vault.totalWithdrawn(TestConstants.USER_1, TestConstants.ETH_ADDRESS), 2 ether);
        assertEq(vault.totalWithdrawn(TestConstants.USER_2, TestConstants.ETH_ADDRESS), 1 ether);

        assertEq(address(vault).balance, 5 ether);
        assertEq(TestConstants.USER_1.balance, 2 ether);
        assertEq(TestConstants.USER_2.balance, 1 ether);
    }

    // ========================================================================
    // Same-block multiple withdrawals
    // ========================================================================

    function test_exitEth_sameBlockMultipleWithdrawals() public {
        fundEth(TestConstants.USER_1, 5 ether);
        vm.prank(TestConstants.USER_1);
        vault.enterEth{value: 5 ether}(TestConstants.USER_1);

        _advanceToFinalized();

        // Two withdrawals in the same block
        vm.prank(TestConstants.USER_1);
        vault.exitEth(1 ether, "");
        vm.prank(TestConstants.USER_1);
        vault.exitEth(2 ether, "");

        // Cumulative should be 3 ether total
        assertEq(vault.totalWithdrawn(TestConstants.USER_1, TestConstants.ETH_ADDRESS), 3 ether);
        assertEq(address(vault).balance, 2 ether);
        assertEq(TestConstants.USER_1.balance, 3 ether);
    }

    // ========================================================================
    // exitErc20 proof verification failure
    // ========================================================================

    function test_exitErc20_proofVerificationFails() public {
        mintAndApprove(TestConstants.USER_1, address(vault), 100);
        vm.prank(TestConstants.USER_1);
        vault.enterErc20(TestConstants.USER_1, address(token), 100);

        _advanceToFinalized();

        mockVerifier.setShouldRevert(true);

        vm.prank(TestConstants.USER_1);
        vm.expectRevert("MockVerifier: forced revert");
        vault.exitErc20(address(token), 100, "");

        // Verify no state change occurred
        assertEq(token.balanceOf(TestConstants.USER_1), 0);
        assertEq(token.balanceOf(address(vault)), 100);
        assertEq(vault.totalWithdrawn(TestConstants.USER_1, address(token)), 0);
    }

    // ========================================================================
    // Integration
    // ========================================================================

    function test_enterEth_thenEnterErc20_chainedAccumulator() public {
        fundEth(TestConstants.USER_1, 1 ether);
        mintAndApprove(TestConstants.USER_1, address(vault), 500);

        bytes memory ethData = abi.encode(TestConstants.USER_1, uint256(1 ether));
        bytes32 acc1 = computeAccumulator(actions.accumulator(), address(vault), TestConstants.ENTER_ETH, ethData);

        vm.prank(TestConstants.USER_1);
        vault.enterEth{value: 1 ether}(TestConstants.USER_1);
        assertEq(actions.accumulator(), acc1);

        bytes memory erc20Data = abi.encode(TestConstants.USER_1, address(token), uint256(500));
        bytes32 acc2 = computeAccumulator(acc1, address(vault), TestConstants.ENTER_ERC20, erc20Data);

        vm.prank(TestConstants.USER_1);
        vault.enterErc20(TestConstants.USER_1, address(token), 500);
        assertEq(actions.accumulator(), acc2);
    }

    /// @notice Verify the full accumulator chain from initAccumulator through
    ///         setUp whitelist actions and into deposits. Ensures no hidden steps.
    function test_fullChain_fromInitAccumulator() public {
        // setUp already whitelisted ETH + token. Verify that chain from initAccumulator.
        bytes memory whitelistEthData = abi.encode(TestConstants.ETH_ADDRESS);
        bytes32 afterWhitelistEth =
            computeAccumulator(initAccumulator, address(vault), TestConstants.WHITELIST_ASSET, whitelistEthData);

        bytes memory whitelistTokenData = abi.encode(address(token));
        bytes32 afterWhitelistToken =
            computeAccumulator(afterWhitelistEth, address(vault), TestConstants.WHITELIST_ASSET, whitelistTokenData);

        // This is the post-setUp accumulator ------ verify it chains from init
        assertEq(
            actions.accumulator(), afterWhitelistToken, "setUp accumulator != init -> whitelist ETH -> whitelist token"
        );

        // Now chain a deposit on top
        fundEth(TestConstants.USER_1, 1 ether);
        bytes memory ethData = abi.encode(TestConstants.USER_1, uint256(1 ether));
        bytes32 afterDeposit = computeAccumulator(afterWhitelistToken, address(vault), TestConstants.ENTER_ETH, ethData);

        vm.prank(TestConstants.USER_1);
        vault.enterEth{value: 1 ether}(TestConstants.USER_1);
        assertEq(actions.accumulator(), afterDeposit, "deposit did not chain correctly from whitelist");
    }

    function test_multipleCustody_cumulativeBalance() public {
        fundEth(TestConstants.USER_1, 3 ether);
        fundEth(TestConstants.USER_2, 2 ether);

        vm.prank(TestConstants.USER_1);
        vault.enterEth{value: 1 ether}(TestConstants.USER_1);
        vm.prank(TestConstants.USER_2);
        vault.enterEth{value: 2 ether}(TestConstants.USER_2);
        vm.prank(TestConstants.USER_1);
        vault.enterEth{value: 2 ether}(TestConstants.USER_1);

        assertEq(address(vault).balance, 5 ether);
    }

    // ========================================================================
    // Fuzz
    // ========================================================================

    function test_enterEth_fuzz(uint96 amount) public {
        vm.assume(amount > 0);

        fundEth(TestConstants.USER_1, amount);

        bytes memory data = abi.encode(TestConstants.USER_1, uint256(amount));
        bytes32 expected = computeAccumulator(actions.accumulator(), address(vault), TestConstants.ENTER_ETH, data);

        vm.prank(TestConstants.USER_1);
        vault.enterEth{value: amount}(TestConstants.USER_1);

        assertEq(address(vault).balance, amount);
        assertEq(TestConstants.USER_1.balance, 0);
        assertEq(actions.accumulator(), expected);
    }

    function test_enterErc20_fuzz(uint96 amount) public {
        vm.assume(amount > 0);

        mintAndApprove(TestConstants.USER_1, address(vault), amount);

        bytes memory data = abi.encode(TestConstants.USER_1, address(token), uint256(amount));
        bytes32 expected = computeAccumulator(actions.accumulator(), address(vault), TestConstants.ENTER_ERC20, data);

        vm.prank(TestConstants.USER_1);
        vault.enterErc20(TestConstants.USER_1, address(token), amount);

        assertEq(token.balanceOf(address(vault)), amount);
        assertEq(token.balanceOf(TestConstants.USER_1), 0);
        assertEq(actions.accumulator(), expected);
    }

    // ========================================================================
    // Reentrancy
    // ========================================================================

    /// @notice enterEth has no reentrancy surface -- it only calls the trusted
    ///         Actions contract, never untrusted external code. Confirm that two
    ///         sequential deposits chain the accumulator identically to the manual
    ///         computation (i.e. no way to inject an extra step mid-call).
    function test_enterEth_noReentrancySurface() public {
        fundEth(TestConstants.USER_1, 2 ether);

        bytes memory data1 = abi.encode(TestConstants.USER_1, uint256(1 ether));
        bytes32 acc1 = computeAccumulator(actions.accumulator(), address(vault), TestConstants.ENTER_ETH, data1);

        vm.prank(TestConstants.USER_1);
        vault.enterEth{value: 1 ether}(TestConstants.USER_1);
        assertEq(actions.accumulator(), acc1);

        bytes memory data2 = abi.encode(TestConstants.USER_1, uint256(1 ether));
        bytes32 acc2 = computeAccumulator(acc1, address(vault), TestConstants.ENTER_ETH, data2);

        vm.prank(TestConstants.USER_1);
        vault.enterEth{value: 1 ether}(TestConstants.USER_1);
        assertEq(actions.accumulator(), acc2);
    }

    /// @notice A malicious ERC20 can re-enter vault.enterErc20 during transferFrom.
    ///         The inner deposit records its action BEFORE the outer deposit does,
    ///         inserting an extra accumulator step. Both deposits succeed and the
    ///         Vault holds tokens for both. This demonstrates the reentrancy vector
    ///         exists ------ the offchain STF must handle it (e.g., via asset whitelists).
    function test_enterErc20_reentrancy_maliciousAsset() public {
        ReentrantERC20 evil = deployReentrantERC20("Evil", "EVIL");
        vm.prank(TestConstants.DEPLOYER);
        vault.whitelistAsset(address(evil));

        uint256 outerAmount = 100;
        uint256 innerAmount = 50;

        VaultAttacker attackContract =
            new VaultAttacker(address(vault), address(evil), innerAmount, TestConstants.USER_1);

        evil.setAttacker(address(attackContract));

        evil.mint(TestConstants.USER_1, outerAmount);
        evil.mint(address(attackContract), innerAmount);

        vm.prank(TestConstants.USER_1);
        evil.approve(address(vault), outerAmount);
        attackContract.approveVault();

        evil.arm();

        bytes32 accBefore = actions.accumulator();

        vm.prank(TestConstants.USER_1);
        vault.enterErc20(TestConstants.USER_1, address(evil), outerAmount);

        assertEq(evil.callbackCount(), 1, "Callback fired exactly once");

        assertEq(evil.balanceOf(address(vault)), outerAmount + innerAmount, "Vault holds tokens from both deposits");

        assertTrue(actions.accumulator() != accBefore, "Accumulator advanced");

        // The inner deposit's action was recorded first, then the outer deposit's.
        // Reconstruct the expected chain: inner action, then outer action.
        bytes memory innerData = abi.encode(TestConstants.USER_1, address(evil), innerAmount);
        bytes32 acc1 = computeAccumulator(accBefore, address(vault), TestConstants.ENTER_ERC20, innerData);

        bytes memory outerData = abi.encode(TestConstants.USER_1, address(evil), outerAmount);
        bytes32 acc2 = computeAccumulator(acc1, address(vault), TestConstants.ENTER_ERC20, outerData);

        assertEq(actions.accumulator(), acc2, "Accumulator reflects inner-then-outer ordering");
    }

    /// @notice A user passes a fake asset that returns true from transferFrom without
    ///         moving any tokens. The Vault records the deposit in the accumulator
    ///         even though it holds nothing ------ a phantom deposit. This documents that
    ///         asset validation is delegated to the offchain STF (e.g., whitelists).
    function test_enterErc20_phantomDeposit_noTokensBacked() public {
        PhantomERC20 phantom = new PhantomERC20();
        vm.prank(TestConstants.DEPLOYER);
        vault.whitelistAsset(address(phantom));
        uint256 phantomAmount = 1_000_000;

        bytes32 accBefore = actions.accumulator();

        vm.prank(TestConstants.USER_1);
        vault.enterErc20(TestConstants.USER_1, address(phantom), phantomAmount);

        bytes memory data = abi.encode(TestConstants.USER_1, address(phantom), phantomAmount);
        bytes32 expected = computeAccumulator(accBefore, address(vault), TestConstants.ENTER_ERC20, data);

        assertEq(actions.accumulator(), expected, "Accumulator recorded the phantom deposit");
        assertEq(phantom.balanceOf(address(vault)), 0, "Vault holds zero phantom tokens");
    }

    /// @notice Cross-function reentrancy: a malicious ERC20 calls vault.enterEth
    ///         during transferFrom, inserting an ETH deposit action (ENTER_ETH)
    ///         before the outer ERC20 deposit action (ENTER_ERC20) completes.
    ///         A single user-initiated enterErc20 produces two Action events with
    ///         different identifiers in the accumulator.
    function test_enterErc20_crossReentrancy_enterEth() public {
        CrossReentrantERC20 evil = new CrossReentrantERC20("Evil", "EVIL", address(vault));
        vm.prank(TestConstants.DEPLOYER);
        vault.whitelistAsset(address(evil));

        uint256 erc20Amount = 100;
        uint256 ethAmount = 1 ether;

        vm.deal(address(evil), ethAmount);
        evil.mint(TestConstants.USER_1, erc20Amount);
        vm.prank(TestConstants.USER_1);
        evil.approve(address(vault), erc20Amount);

        evil.arm(TestConstants.USER_1, ethAmount);

        bytes32 accBefore = actions.accumulator();

        vm.prank(TestConstants.USER_1);
        vault.enterErc20(TestConstants.USER_1, address(evil), erc20Amount);

        assertEq(evil.callbackCount(), 1, "Cross-reentrant callback fired");
        assertEq(address(vault).balance, ethAmount, "Vault received ETH from inner call");
        assertEq(evil.balanceOf(address(vault)), erc20Amount, "Vault received ERC20 from outer call");

        // Inner enterEth action recorded first, outer enterErc20 second
        bytes memory ethData = abi.encode(TestConstants.USER_1, ethAmount);
        bytes32 acc1 = computeAccumulator(accBefore, address(vault), TestConstants.ENTER_ETH, ethData);

        bytes memory erc20Data = abi.encode(TestConstants.USER_1, address(evil), erc20Amount);
        bytes32 acc2 = computeAccumulator(acc1, address(vault), TestConstants.ENTER_ERC20, erc20Data);

        assertEq(actions.accumulator(), acc2, "Accumulator reflects ETH-then-ERC20 ordering");
    }

    /// @notice When the re-entrant inner call reverts (insufficient balance), the
    ///         entire outer enterErc20 call reverts atomically ------ no partial actions.
    function test_enterErc20_reentrancy_innerRevertCascades() public {
        ReentrantERC20 evil = deployReentrantERC20("Evil", "EVIL");
        vm.prank(TestConstants.DEPLOYER);
        vault.whitelistAsset(address(evil));

        uint256 outerAmount = 100;
        uint256 innerAmount = 50;

        VaultAttacker attackContract =
            new VaultAttacker(address(vault), address(evil), innerAmount, TestConstants.USER_1);

        evil.setAttacker(address(attackContract));

        evil.mint(TestConstants.USER_1, outerAmount);
        // Do NOT mint tokens to attackContract ------ inner transferFrom will fail

        vm.prank(TestConstants.USER_1);
        evil.approve(address(vault), outerAmount);
        attackContract.approveVault();

        evil.arm();

        bytes32 accBefore = actions.accumulator();

        vm.prank(TestConstants.USER_1);
        vm.expectRevert();
        vault.enterErc20(TestConstants.USER_1, address(evil), outerAmount);

        assertEq(actions.accumulator(), accBefore, "Accumulator unchanged after full revert");
        assertEq(evil.balanceOf(address(vault)), 0, "No tokens transferred");
    }

    // ========================================================================
    // Asset whitelist
    // ========================================================================

    function test_whitelistAsset_succeeds() public {
        MockERC20 newToken = deployMockERC20("New", "NEW");
        assertFalse(vault.whitelistedAssets(address(newToken)));

        vm.prank(TestConstants.DEPLOYER);
        vault.whitelistAsset(address(newToken));

        assertTrue(vault.whitelistedAssets(address(newToken)));
    }

    function test_whitelistAsset_emitsActionEvent() public {
        MockERC20 newToken = deployMockERC20("New", "NEW");

        bytes memory data = abi.encode(address(newToken));
        bytes memory expectedContextData = computeContextPrefixedData(data);

        vm.expectEmit(true, true, false, true, address(actions));
        emit IActions.Action(address(vault), TestConstants.WHITELIST_ASSET, expectedContextData);

        vm.prank(TestConstants.DEPLOYER);
        vault.whitelistAsset(address(newToken));
    }

    function test_whitelistAsset_accumulatorUpdated() public {
        MockERC20 newToken = deployMockERC20("New", "NEW");

        bytes memory data = abi.encode(address(newToken));
        bytes32 expected =
            computeAccumulator(actions.accumulator(), address(vault), TestConstants.WHITELIST_ASSET, data);

        vm.prank(TestConstants.DEPLOYER);
        vault.whitelistAsset(address(newToken));

        assertEq(actions.accumulator(), expected);
    }

    function test_whitelistAsset_revertsIfNotAdmin() public {
        MockERC20 newToken = deployMockERC20("New", "NEW");

        vm.prank(TestConstants.USER_1);
        vm.expectRevert("only admin can call this");
        vault.whitelistAsset(address(newToken));
    }

    function test_whitelistAsset_revertsIfAlreadyWhitelisted() public {
        vm.prank(TestConstants.DEPLOYER);
        vm.expectRevert("asset is already whitelisted");
        vault.whitelistAsset(address(token));
    }

    function test_delistAsset_succeeds() public {
        assertTrue(vault.whitelistedAssets(address(token)));

        vm.prank(TestConstants.DEPLOYER);
        vault.delistAsset(address(token));

        assertFalse(vault.whitelistedAssets(address(token)));
    }

    function test_delistAsset_emitsActionEvent() public {
        bytes memory data = abi.encode(address(token));
        bytes memory expectedContextData = computeContextPrefixedData(data);

        vm.expectEmit(true, true, false, true, address(actions));
        emit IActions.Action(address(vault), TestConstants.DELIST_ASSET, expectedContextData);

        vm.prank(TestConstants.DEPLOYER);
        vault.delistAsset(address(token));
    }

    function test_delistAsset_revertsIfNotAdmin() public {
        vm.prank(TestConstants.USER_1);
        vm.expectRevert("only admin can call this");
        vault.delistAsset(address(token));
    }

    function test_delistAsset_revertsIfNotWhitelisted() public {
        MockERC20 newToken = deployMockERC20("New", "NEW");

        vm.prank(TestConstants.DEPLOYER);
        vm.expectRevert("asset is already not whitelisted");
        vault.delistAsset(address(newToken));
    }

    function test_enterEth_revertsWhenEthNotWhitelisted() public {
        vm.prank(TestConstants.DEPLOYER);
        vault.delistAsset(TestConstants.ETH_ADDRESS);

        fundEth(TestConstants.USER_1, 1 ether);
        vm.prank(TestConstants.USER_1);
        vm.expectRevert("ETH is not whitelisted");
        vault.enterEth{value: 1 ether}(TestConstants.USER_1);
    }

    function test_enterErc20_revertsOnNonWhitelistedAsset() public {
        MockERC20 newToken = deployMockERC20("New", "NEW");
        newToken.mint(TestConstants.USER_1, 100);
        vm.prank(TestConstants.USER_1);
        newToken.approve(address(vault), 100);

        vm.prank(TestConstants.USER_1);
        vm.expectRevert("this asset is not whitelisted");
        vault.enterErc20(TestConstants.USER_1, address(newToken), 100);
    }

    function test_enterErc20_revertsAfterDelisting() public {
        vm.prank(TestConstants.DEPLOYER);
        vault.delistAsset(address(token));

        mintAndApprove(TestConstants.USER_1, address(vault), 100);

        vm.prank(TestConstants.USER_1);
        vm.expectRevert("this asset is not whitelisted");
        vault.enterErc20(TestConstants.USER_1, address(token), 100);
    }

    function test_enterErc20_succeedsAfterRewhitelisting() public {
        vm.prank(TestConstants.DEPLOYER);
        vault.delistAsset(address(token));
        vm.prank(TestConstants.DEPLOYER);
        vault.whitelistAsset(address(token));

        mintAndApprove(TestConstants.USER_1, address(vault), 100);

        vm.prank(TestConstants.USER_1);
        vault.enterErc20(TestConstants.USER_1, address(token), 100);

        assertEq(token.balanceOf(address(vault)), 100);
    }

    /// @notice Non-whitelisted asset never triggers transferFrom -- no external call
    function test_enterErc20_nonWhitelistedAsset_noExternalCall() public {
        MockERC20 newToken = deployMockERC20("New", "NEW");

        bytes32 accBefore = actions.accumulator();

        vm.prank(TestConstants.USER_1);
        vm.expectRevert("this asset is not whitelisted");
        vault.enterErc20(TestConstants.USER_1, address(newToken), 100);

        assertEq(actions.accumulator(), accBefore, "Accumulator unchanged");
    }

    // ========================================================================
    // changeAdmin
    // ========================================================================

    function test_changeAdmin_succeeds() public {
        assertEq(vault.admin(), TestConstants.DEPLOYER);

        vm.prank(TestConstants.DEPLOYER);
        vault.changeAdmin(TestConstants.USER_1);

        assertEq(vault.admin(), TestConstants.USER_1);
    }

    function test_changeAdmin_accumulatorUpdated() public {
        bytes memory data = abi.encode(TestConstants.USER_1);
        bytes32 expected =
            computeAccumulator(actions.accumulator(), address(vault), TestConstants.CHANGE_VAULT_ADMIN, data);

        vm.prank(TestConstants.DEPLOYER);
        vault.changeAdmin(TestConstants.USER_1);

        assertEq(actions.accumulator(), expected);
    }

    function test_changeAdmin_emitsActionEvent() public {
        bytes memory data = abi.encode(TestConstants.USER_1);
        bytes memory expectedContextData = computeContextPrefixedData(data);

        vm.expectEmit(true, true, false, true, address(actions));
        emit IActions.Action(address(vault), TestConstants.CHANGE_VAULT_ADMIN, expectedContextData);

        vm.prank(TestConstants.DEPLOYER);
        vault.changeAdmin(TestConstants.USER_1);
    }

    function test_changeAdmin_revertsIfNotAdmin() public {
        vm.prank(TestConstants.USER_1);
        vm.expectRevert("only admin can call this");
        vault.changeAdmin(TestConstants.USER_1);
    }

    function test_changeAdmin_revertsIfZeroAddress() public {
        vm.prank(TestConstants.DEPLOYER);
        vm.expectRevert("new admin cannot be the zero address");
        vault.changeAdmin(address(0));
    }

    function test_changeAdmin_revertsIfSameAdmin() public {
        vm.prank(TestConstants.DEPLOYER);
        vm.expectRevert("new admin is already equal to the current admin");
        vault.changeAdmin(TestConstants.DEPLOYER);
    }

    function test_changeAdmin_newAdminCanAct() public {
        vm.prank(TestConstants.DEPLOYER);
        vault.changeAdmin(TestConstants.USER_1);

        MockERC20 newToken = deployMockERC20("New", "NEW");

        vm.prank(TestConstants.USER_1);
        vault.whitelistAsset(address(newToken));

        assertTrue(vault.whitelistedAssets(address(newToken)));
    }

    function test_changeAdmin_oldAdminCannotAct() public {
        vm.prank(TestConstants.DEPLOYER);
        vault.changeAdmin(TestConstants.USER_1);

        MockERC20 newToken = deployMockERC20("New", "NEW");

        vm.prank(TestConstants.DEPLOYER);
        vm.expectRevert("only admin can call this");
        vault.whitelistAsset(address(newToken));
    }

    // ========================================================================
    // SafeERC20
    // ========================================================================

    /// @notice A non-standard token (like USDT) that returns no data from
    ///         transferFrom succeeds with SafeERC20. Without SafeERC20 this
    ///         would revert because Solidity expects a bool return value.
    function test_enterErc20_noReturnToken_succeeds() public {
        NoReturnERC20 usdt = new NoReturnERC20("Tether", "USDT");
        vm.prank(TestConstants.DEPLOYER);
        vault.whitelistAsset(address(usdt));

        uint256 amount = 1000;
        usdt.mint(TestConstants.USER_1, amount);
        vm.prank(TestConstants.USER_1);
        usdt.approve(address(vault), amount);

        bytes memory data = abi.encode(TestConstants.USER_1, address(usdt), amount);
        bytes32 expected = computeAccumulator(actions.accumulator(), address(vault), TestConstants.ENTER_ERC20, data);

        vm.prank(TestConstants.USER_1);
        vault.enterErc20(TestConstants.USER_1, address(usdt), amount);

        assertEq(usdt.balanceOf(address(vault)), amount, "Vault holds USDT");
        assertEq(usdt.balanceOf(TestConstants.USER_1), 0, "User balance drained");
        assertEq(actions.accumulator(), expected, "Accumulator updated");
    }

    /// @notice A token whose transferFrom returns false (instead of reverting)
    ///         is caught by SafeERC20 and the entire call reverts.
    function test_enterErc20_falseReturnToken_reverts() public {
        FalseReturnERC20 bad = new FalseReturnERC20("Bad", "BAD");
        vm.prank(TestConstants.DEPLOYER);
        vault.whitelistAsset(address(bad));

        bad.mint(TestConstants.USER_1, 100);
        vm.prank(TestConstants.USER_1);
        bad.approve(address(vault), 100);

        bytes32 accBefore = actions.accumulator();

        vm.prank(TestConstants.USER_1);
        vm.expectRevert();
        vault.enterErc20(TestConstants.USER_1, address(bad), 100);

        assertEq(actions.accumulator(), accBefore, "Accumulator unchanged after revert");
    }

    /// @notice No-return token with insufficient balance reverts cleanly
    function test_enterErc20_noReturnToken_insufficientBalance_reverts() public {
        NoReturnERC20 usdt = new NoReturnERC20("Tether", "USDT");
        vm.prank(TestConstants.DEPLOYER);
        vault.whitelistAsset(address(usdt));

        // Mint less than deposit amount
        usdt.mint(TestConstants.USER_1, 50);
        vm.prank(TestConstants.USER_1);
        usdt.approve(address(vault), 100);

        vm.prank(TestConstants.USER_1);
        vm.expectRevert();
        vault.enterErc20(TestConstants.USER_1, address(usdt), 100);

        assertEq(usdt.balanceOf(address(vault)), 0, "No tokens transferred");
    }

    /// @notice No-return token with insufficient allowance reverts cleanly
    function test_enterErc20_noReturnToken_insufficientAllowance_reverts() public {
        NoReturnERC20 usdt = new NoReturnERC20("Tether", "USDT");
        vm.prank(TestConstants.DEPLOYER);
        vault.whitelistAsset(address(usdt));

        usdt.mint(TestConstants.USER_1, 100);
        // No approval

        vm.prank(TestConstants.USER_1);
        vm.expectRevert();
        vault.enterErc20(TestConstants.USER_1, address(usdt), 100);

        assertEq(usdt.balanceOf(address(vault)), 0, "No tokens transferred");
    }
}

/// @notice Attacker contract that tries to re-enter exitEth via receive()
contract ExitEthReentrant {
    Vault public vault;
    uint256 public attackAmount;

    constructor(address _vault) {
        vault = Vault(_vault);
    }

    function deposit() external payable {
        vault.enterEth{value: msg.value}(address(this));
    }

    function attack(uint256 amount) external {
        attackAmount = amount;
        vault.exitEth(amount, "");
    }

    receive() external payable {
        vault.exitEth(attackAmount, "");
    }
}
