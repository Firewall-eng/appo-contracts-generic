// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {TestConstants} from "./TestConstants.sol";
import {Actions} from "../src/Actions.sol";
import {Caller} from "../src/Caller.sol";
import {Vault} from "../src/Vault.sol";
import {Prover} from "../src/Prover.sol";
import {IProver} from "../src/interfaces/IProver.sol";
import {IActions} from "../src/interfaces/IActions.sol";
import {ICaller} from "../src/interfaces/ICaller.sol";
import {MockVerifier} from "./mocks/MockVerifier.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {ReentrantERC20, VaultAttacker} from "./mocks/ReentrantERC20.sol";
import {CallerHelper} from "./mocks/CallerHelper.sol";

/// @title Base
/// @notice Shared test setup that deploys the full Appo contract suite.
/// @dev Mirrors the deployment order in DeployAppo.s.sol:
///      Actions -> Caller -> MockVerifier -> (predict Prover addr) -> Vault -> Prover.
///      Vault needs the Prover address at construction, so we predict it via nonce.
///      After setUp, the accumulator equals INIT_ACCUMULATOR — no constructor in the
///      suite calls actions.action(), so the chain starts clean for every test.
abstract contract Base is Test {
    Actions public actions;
    Caller public caller;
    Vault public vault;
    Prover public prover;
    MockVerifier public mockVerifier;
    MockERC20 public token;
    CallerHelper public callerHelper;

    uint256 public deployBlock;
    bytes32 public initAccumulator;

    function setUp() public virtual {
        vm.startPrank(TestConstants.DEPLOYER);

        actions = new Actions();
        deployBlock = block.number;
        initAccumulator = keccak256(abi.encode("Init", TestConstants.DEPLOYER));

        caller = new Caller(address(actions));
        mockVerifier = new MockVerifier();

        // calculate Prover address — Vault needs it in its constructor but Prover
        // needs Vault's address for committedAddressesHash, creating a circular dep.
        // Solved the same way as DeployAppo.s.sol: predict via deployer nonce.
        uint64 proverNonce = vm.getNonce(TestConstants.DEPLOYER) + 1;
        address predictedProver = vm.computeCreateAddress(TestConstants.DEPLOYER, proverNonce);

        vault = new Vault(
            address(actions),
            predictedProver,
            TestConstants.DEPLOYER,
            address(mockVerifier),
            TestConstants.WITHDRAWAL_VKEY
        );

        bytes32 committedAddressesHash = keccak256(abi.encode(address(actions), address(caller), address(vault)));

        prover = new Prover(
            address(actions),
            address(mockVerifier),
            TestConstants.FINALITY,
            committedAddressesHash,
            TestConstants.STF_ADMIN,
            TestConstants.STF_HASH,
            TestConstants.INCLUSION_ADMIN,
            TestConstants.INCLUSION_HASH,
            TestConstants.STF_ROOT
        );
        require(address(prover) == predictedProver, "Prover address mismatch");

        token = new MockERC20("Mock USDC", "USDC");

        vault.whitelistAsset(TestConstants.ETH_ADDRESS);
        vault.whitelistAsset(address(token));
        callerHelper = new CallerHelper();

        vm.stopPrank();
    }

    // --- Prover struct accessors ---
    // Solidity auto-generated getters for public struct storage vars return tuples,
    // not structs. These helpers destructure back into Commitment for readable tests.

    function getPending() internal view returns (IProver.Commitment memory c) {
        (c.blockNumber, c.actionsAccumulator, c.inclusionAccumulator, c.stfRoot) = prover.pending();
    }

    function getFinalized() internal view returns (IProver.Commitment memory c) {
        (c.blockNumber, c.actionsAccumulator, c.inclusionAccumulator, c.stfRoot) = prover.finalized();
    }

    function getSubmittedProof(uint256 resetId, uint256 blockNum) internal view returns (IProver.Commitment memory c) {
        (c.blockNumber, c.actionsAccumulator, c.inclusionAccumulator, c.stfRoot) =
            prover.submittedProofs(resetId, blockNum);
    }

    // --- Accumulator helpers ---

    /// @notice Recompute expected accumulator using the same formula as Actions.sol.
    /// @dev MUST be called in the same block context as the action (match vm.roll/vm.warp/vm.txGasPrice).
    function computeAccumulator(bytes32 prevAccumulator, address sender, bytes4 identifier, bytes memory data)
        internal
        view
        returns (bytes32)
    {
        bytes memory contextPrefixedData = abi.encode(block.number, block.timestamp, tx.gasprice, data);
        return keccak256(abi.encode(prevAccumulator, sender, identifier, contextPrefixedData));
    }

    /// @notice Build the contextPrefixedData that Actions.sol would produce this block.
    function computeContextPrefixedData(bytes memory data) internal view returns (bytes memory) {
        return abi.encode(block.number, block.timestamp, tx.gasprice, data);
    }

    /// @notice Roll forward past finality, prove, and finalize so that prover.finalized() advances.
    function _advanceToFinalized() internal {
        uint256 genesisBlock = deployBlock - 1;

        vm.roll(block.number + 1);
        uint256 proofBlock = block.number;

        vm.prank(TestConstants.USER_1);
        actions.action(TestConstants.NOOP, abi.encode(uint256(0)));

        vm.roll(proofBlock + TestConstants.FINALITY + 1);

        prover.proveBoth(genesisBlock, proofBlock, keccak256("INC"), TestConstants.STF_ROOT, "", "");
    }

    function fundEth(address to, uint256 amount) internal {
        vm.deal(to, amount);
    }

    /// @notice Mint tokens to `owner` and pre-approve `spender` in one call.
    function mintAndApprove(address owner, address spender, uint256 amount) internal {
        token.mint(owner, amount);
        vm.prank(owner);
        token.approve(spender, amount);
    }

    /// @notice Mint `tok` to `owner` and pre-approve `spender` — works with any MockERC20.
    function mintAndApproveToken(MockERC20 tok, address owner, address spender, uint256 amount) internal {
        tok.mint(owner, amount);
        vm.prank(owner);
        tok.approve(spender, amount);
    }

    /// @notice Deploy an additional MockERC20 with the given name/symbol.
    function deployMockERC20(string memory name, string memory symbol) internal returns (MockERC20) {
        return new MockERC20(name, symbol);
    }

    /// @notice Deploy a ReentrantERC20 wired to the Vault.
    function deployReentrantERC20(string memory name, string memory symbol) internal returns (ReentrantERC20) {
        return new ReentrantERC20(name, symbol, address(vault));
    }
}
