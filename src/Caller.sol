// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {IActions} from "./interfaces/IActions.sol";
import {ICaller} from "./interfaces/ICaller.sol";

contract Caller {
    address public actions;

    constructor(address _actions) {
        actions = _actions;
    }

    function call(bytes4 identifier, bytes memory prefixData, ICaller.Call[] memory calls) public {
        ICaller.Result[] memory results = new ICaller.Result[](calls.length);
        for (uint256 i = 0; i < calls.length; i++) {
            ICaller.Call memory _call = calls[i];

            bool success;
            bytes memory returnData;
            if (_call.isStatic) {
                (success, returnData) = _call.to.staticcall(_call.callData);
            } else {
                (success, returnData) = _call.to.call(_call.callData);
            }
            require(success, "Call failed");

            results[i] = ICaller.Result(_call.to, _call.callData, returnData, _call.isStatic);
        }

        bytes memory data = abi.encode(msg.sender, prefixData, results);
        IActions(actions).action(identifier, data);
    }
}
