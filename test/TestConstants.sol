// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

/// @title TestConstants
/// @notice Canonical action identifiers and addresses for the Appo test suite.
/// @dev Use these for accumulator computation and assertions; Vault.sol defines
///      matching action constants. Tests assert vault.ENTER_ETH() == TestConstants.ENTER_ETH.
library TestConstants {
    // Action identifiers
    bytes4 public constant ENTER_ETH = bytes4(keccak256("EnterEth"));
    bytes4 public constant ENTER_ERC20 = bytes4(keccak256("EnterErc20"));
    bytes4 public constant WHITELIST_ASSET = bytes4(keccak256("WhitelistAsset"));
    bytes4 public constant DELIST_ASSET = bytes4(keccak256("DelistAsset"));
    bytes4 public constant CHANGE_VAULT_ADMIN = bytes4(keccak256("ChangeVaultAdmin"));
    bytes4 public constant DEPOSIT_COLLATERAL = bytes4(keccak256("DepositCollateral"));
    bytes4 public constant BORROW = bytes4(keccak256("Borrow"));
    bytes4 public constant REPAY = bytes4(keccak256("Repay"));
    bytes4 public constant LIQUIDATE = bytes4(keccak256("Liquidate"));
    bytes4 public constant SUPPLY = bytes4(keccak256("Supply"));
    bytes4 public constant REDEEM = bytes4(keccak256("Redeem"));
    bytes4 public constant WITHDRAW_COLLATERAL = bytes4(keccak256("WithdrawCollateral"));
    bytes4 public constant SET_ORACLE = bytes4(keccak256("SetOracle"));
    bytes4 public constant UPDATE_RATE = bytes4(keccak256("UpdateRate"));
    bytes4 public constant SWAP = bytes4(keccak256("Swap"));
    bytes4 public constant FLASH_LOAN = bytes4(keccak256("FlashLoan"));
    bytes4 public constant CLOSE_POSITION = bytes4(keccak256("ClosePosition"));
    bytes4 public constant MINT = bytes4(keccak256("Mint"));
    bytes4 public constant BURN = bytes4(keccak256("Burn"));
    bytes4 public constant SET_PARAMS = bytes4(keccak256("SetParams"));
    bytes4 public constant HEARTBEAT = bytes4(keccak256("Heartbeat"));
    bytes4 public constant NOOP = bytes4(keccak256("Noop"));

    // ETH sentinel (matches Vault.ETH_ADDRESS)
    address public constant ETH_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    // Test addresses (keccak256-derived, deterministic)
    address public constant DEPLOYER = address(uint160(uint256(keccak256("DEPLOYER"))));
    address public constant STF_ADMIN = address(uint160(uint256(keccak256("STF_ADMIN"))));
    address public constant INCLUSION_ADMIN = address(uint160(uint256(keccak256("INCLUSION_ADMIN"))));
    address public constant USER_1 = address(uint160(uint256(keccak256("USER_1"))));
    address public constant USER_2 = address(uint160(uint256(keccak256("USER_2"))));

    // denominated in blocks
    uint256 public constant FINALITY = 10;

    // Prover hashes
    bytes32 public constant STF_HASH = keccak256("STF_HASH");
    bytes32 public constant INCLUSION_HASH = keccak256("INCLUSION_HASH");
    bytes32 public constant STF_ROOT = keccak256("STF_ROOT");

    // Withdrawal proof constants
    bytes32 public constant WITHDRAWAL_VKEY = keccak256("WITHDRAWAL_VKEY");
    bytes4 public constant EXIT_ETH = bytes4(keccak256("ExitEth"));
    bytes4 public constant EXIT_ERC20 = bytes4(keccak256("ExitErc20"));
    bytes4 public constant SET_WITHDRAWAL_VKEY = bytes4(keccak256("SetWithdrawalVKey"));
}
