// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {IActions} from "./interfaces/IActions.sol";

import {Checkpoints} from "@openzeppelin/contracts/utils/structs/Checkpoints.sol";

contract Actions is IActions {
    using Checkpoints for Checkpoints.Trace256;

    bytes32 public immutable INIT_ACCUMULATOR;

    bytes32 public accumulator;

    Checkpoints.Trace256 private accumulatorCheckpoints;

    constructor() {
        INIT_ACCUMULATOR = keccak256(abi.encode("Init", msg.sender));
        accumulator = INIT_ACCUMULATOR;
        accumulatorCheckpoints.push(block.number, uint256(accumulator));
        emit IActions.Init(msg.sender);
    }

    function accumulatorUpperLookup(uint256 blockNumber) external view returns (bytes32) {
        return bytes32(accumulatorCheckpoints.upperLookup(blockNumber));
    }

    function action(bytes4 identifier, bytes memory data) public {
        bytes memory contextPrefixedData = abi.encode(block.number, block.timestamp, tx.gasprice, data);
        accumulator = keccak256(abi.encode(accumulator, msg.sender, identifier, contextPrefixedData));
        accumulatorCheckpoints.push(block.number, uint256(accumulator));
        emit IActions.Action(msg.sender, identifier, contextPrefixedData);
    }
}
