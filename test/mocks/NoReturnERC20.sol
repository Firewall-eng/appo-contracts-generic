// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

/// @title NoReturnERC20
/// @notice ERC20 that does not return a bool from transferFrom/transfer/approve.
///         Mirrors the behavior of USDT and other non-standard tokens.
///         Without SafeERC20, calling transferFrom on this contract would revert
///         because Solidity expects a bool return value from IERC20.transferFrom.
contract NoReturnERC20 {
    string public name;
    string public symbol;
    uint8 public decimals = 18;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    /// @notice approve that returns nothing (non-standard)
    function approve(address spender, uint256 amount) external {
        allowance[msg.sender][spender] = amount;
    }

    /// @notice transferFrom that returns nothing (non-standard, like USDT)
    function transferFrom(address from, address to, uint256 amount) external {
        require(balanceOf[from] >= amount, "insufficient balance");
        require(allowance[from][msg.sender] >= amount, "insufficient allowance");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }

    /// @notice transfer that returns nothing (non-standard)
    function transfer(address to, uint256 amount) external {
        require(balanceOf[msg.sender] >= amount, "insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
    }
}

/// @title FalseReturnERC20
/// @notice ERC20 whose transferFrom returns false instead of reverting on failure.
///         SafeERC20 should detect the false return and revert.
contract FalseReturnERC20 {
    string public name;
    string public symbol;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    /// @notice Always returns false -- SafeERC20 should revert on this
    function transferFrom(address, address, uint256) external pure returns (bool) {
        return false;
    }
}
