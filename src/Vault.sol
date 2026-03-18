// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {ISP1Verifier} from "../lib/sp1-contracts/contracts/src/ISP1Verifier.sol";
import {IActions} from "./interfaces/IActions.sol";
import {IProver} from "./interfaces/IProver.sol";

contract Vault {
    using SafeERC20 for IERC20;

    bytes4 public constant ENTER_ETH = bytes4(keccak256("EnterEth"));
    bytes4 public constant ENTER_ERC20 = bytes4(keccak256("EnterErc20"));
    bytes4 public constant EXIT_ETH = bytes4(keccak256("ExitEth"));
    bytes4 public constant EXIT_ERC20 = bytes4(keccak256("ExitErc20"));
    bytes4 public constant SET_WITHDRAWAL_VKEY = bytes4(keccak256("SetWithdrawalVKey"));
    bytes4 public constant WHITELIST_ASSET = bytes4(keccak256("WhitelistAsset"));
    bytes4 public constant DELIST_ASSET = bytes4(keccak256("DelistAsset"));
    bytes4 public constant CHANGE_VAULT_ADMIN = bytes4(keccak256("ChangeVaultAdmin"));
    address public constant ETH_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    address public immutable ACTIONS;
    address public immutable PROVER;
    address public immutable SP1_VERIFIER;

    address public admin;
    bytes32 public withdrawalVKey;
    mapping(address => bool) public whitelistedAssets;

    /// @notice Monotonic cumulative amount withdrawn per user per asset.
    /// The withdrawal proof enforces: withdrawable_in_stf >= amount + totalWithdrawn.
    /// Neither withdrawable_in_stf (STF-side) nor totalWithdrawn (on-chain) can decrease,
    /// so their difference is always the correct remaining entitlement.
    mapping(address user => mapping(address asset => uint256)) public totalWithdrawn;

    modifier onlyAdmin() {
        require(msg.sender == admin, "only admin can call this");
        _;
    }

    constructor(address _actions, address _prover, address _admin, address _sp1Verifier, bytes32 _withdrawalVKey) {
        ACTIONS = _actions;
        PROVER = _prover;
        admin = _admin;
        SP1_VERIFIER = _sp1Verifier;
        withdrawalVKey = _withdrawalVKey;
    }

    function whitelistAsset(address asset) external onlyAdmin {
        require(asset != address(0), "cannot asset whitelist the zero address");
        require(!whitelistedAssets[asset], "asset is already whitelisted");
        whitelistedAssets[asset] = true;
        IActions(ACTIONS).action(WHITELIST_ASSET, abi.encode(asset));
    }

    function delistAsset(address asset) external onlyAdmin {
        require(whitelistedAssets[asset], "asset is already not whitelisted");
        whitelistedAssets[asset] = false;
        IActions(ACTIONS).action(DELIST_ASSET, abi.encode(asset));
    }

    function changeAdmin(address newAdmin) external onlyAdmin {
        require(newAdmin != address(0), "new admin cannot be the zero address");
        require(newAdmin != admin, "new admin is already equal to the current admin");
        admin = newAdmin;
        IActions(ACTIONS).action(CHANGE_VAULT_ADMIN, abi.encode(newAdmin));
    }

    function enterEth(address user) public payable {
        require(whitelistedAssets[ETH_ADDRESS], "ETH is not whitelisted");
        require(msg.value > 0, "msg.value must be greater than 0");

        bytes memory data = abi.encode(user, msg.value);
        IActions(ACTIONS).action(ENTER_ETH, data);
    }

    function exitEth(uint256 amount, bytes calldata proof) external {
        _verifyAndRecordExit(msg.sender, ETH_ADDRESS, amount, proof);

        // TODO: revisit whether call (forwards all gas) vs transfer (2300 gas cap) is
        // preferred here. call supports smart-wallet receivers but widens reentrancy surface.
        (bool success,) = msg.sender.call{value: amount}("");
        require(success, "ETH transfer failed");

        IActions(ACTIONS).action(EXIT_ETH, abi.encode(msg.sender, amount));
    }

    function enterErc20(address user, address asset, uint256 amount) public {
        require(whitelistedAssets[asset], "this asset is not whitelisted");
        require(amount > 0, "amount must be greater than 0");
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);

        bytes memory data = abi.encode(user, asset, amount);
        IActions(ACTIONS).action(ENTER_ERC20, data);
    }

    function exitErc20(address asset, uint256 amount, bytes calldata proof) external {
        _verifyAndRecordExit(msg.sender, asset, amount, proof);

        IERC20(asset).safeTransfer(msg.sender, amount);

        IActions(ACTIONS).action(EXIT_ERC20, abi.encode(msg.sender, asset, amount));
    }

    function setWithdrawalVKey(bytes32 _withdrawalVKey) external onlyAdmin {
        withdrawalVKey = _withdrawalVKey;
        IActions(ACTIONS).action(SET_WITHDRAWAL_VKEY, abi.encode(_withdrawalVKey));
    }

    function _verifyAndRecordExit(address user, address asset, uint256 amount, bytes calldata proof) internal {
        require(whitelistedAssets[asset], "asset is not whitelisted");
        require(amount > 0, "amount must be greater than 0");

        IProver.Commitment memory fin = IProver(PROVER).finalized();
        require(fin.stfRoot != bytes32(0), "no finalized state");

        uint256 alreadyWithdrawn = totalWithdrawn[user][asset];

        // Record before verify (checks-effects-interactions)
        totalWithdrawn[user][asset] = alreadyWithdrawn + amount;

        // The withdrawal proof verifies: in the state at stfRoot, the user's
        // withdrawable balance >= amount + alreadyWithdrawn.
        // assumption (that is currently true): SP1 verifyProof reverts on invalid proof;
        // no return value to check.
        bytes memory publicValues = abi.encode(fin.stfRoot, user, asset, amount, alreadyWithdrawn);
        ISP1Verifier(SP1_VERIFIER).verifyProof(withdrawalVKey, publicValues, proof);
    }
}
