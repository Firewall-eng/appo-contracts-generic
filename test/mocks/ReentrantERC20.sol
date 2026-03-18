// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {Vault} from "../../src/Vault.sol";

/// @title ReentrantERC20
/// @notice Malicious ERC20 that re-enters Vault.enterErc20 during transferFrom.
/// @dev On the first transferFrom the token fires a callback to a VaultAttacker
///      contract, which re-enters vault.enterErc20 before the outer call records
///      its action. This inserts an extra accumulator step mid-transaction.
///      armed is reset to false after the first callback to prevent infinite recursion.
contract ReentrantERC20 is ERC20 {
    Vault public vault;
    VaultAttacker public attacker;
    bool public armed;
    uint256 public callbackCount;

    constructor(string memory name, string memory symbol, address _vault) ERC20(name, symbol) {
        vault = Vault(_vault);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setAttacker(address _attacker) external {
        attacker = VaultAttacker(_attacker);
    }

    function arm() external {
        armed = true;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (armed) {
            armed = false;
            callbackCount++;
            attacker.reenter();
        }
        return super.transferFrom(from, to, amount);
    }
}

/// @title VaultAttacker
/// @notice Helper contract that the ReentrantERC20 calls back into to re-enter
///         vault.enterErc20. Holds its own token balance and approval so the
///         inner enterErc20 call succeeds end-to-end.
contract VaultAttacker {
    Vault public vault;
    ReentrantERC20 public token;
    uint256 public reenterAmount;
    address public creditUser;

    constructor(address _vault, address _token, uint256 _amount, address _creditUser) {
        vault = Vault(_vault);
        token = ReentrantERC20(_token);
        reenterAmount = _amount;
        creditUser = _creditUser;
    }

    function approveVault() external {
        token.approve(address(vault), type(uint256).max);
    }

    function reenter() external {
        vault.enterErc20(creditUser, address(token), reenterAmount);
    }
}
