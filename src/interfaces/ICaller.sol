// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

interface ICaller {
    struct Call {
        address to;
        bytes callData;
        bool isStatic;
    }

    struct Result {
        address to;
        bytes callData;
        bytes returnData;
        bool isStatic;
    }

    function call(bytes4 identifier, bytes memory prefixData, Call[] memory calls) external;
}
