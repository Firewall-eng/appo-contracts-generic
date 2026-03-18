// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

interface IActions {
    event Init(address deployer);
    event Action(address indexed msgSender, bytes4 indexed identifier, bytes data);

    function INIT_ACCUMULATOR() external view returns (bytes32);
    function accumulator() external view returns (bytes32);

    function accumulatorUpperLookup(uint256 blockNumber) external view returns (bytes32);

    function action(bytes4 identifier, bytes memory data) external;
}
