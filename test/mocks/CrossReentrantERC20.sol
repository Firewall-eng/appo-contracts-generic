// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {Vault} from "../../src/Vault.sol";

/// @title CrossReentrantERC20
/// @notice Malicious ERC20 that re-enters Vault.enterEth during transferFrom,
///         exercising cross-function reentrancy (enterErc20 -> enterEth).
contract CrossReentrantERC20 is ERC20 {
    Vault public vault;
    address public creditUser;
    uint256 public ethAmount;
    bool public armed;
    uint256 public callbackCount;

    constructor(string memory name, string memory symbol, address _vault) ERC20(name, symbol) {
        vault = Vault(_vault);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function arm(address _creditUser, uint256 _ethAmount) external {
        creditUser = _creditUser;
        ethAmount = _ethAmount;
        armed = true;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (armed) {
            armed = false;
            callbackCount++;
            vault.enterEth{value: ethAmount}(creditUser);
        }
        return super.transferFrom(from, to, amount);
    }

    receive() external payable {}
}
