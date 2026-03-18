// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

interface IProver {
    struct Commitment {
        uint256 blockNumber;
        bytes32 actionsAccumulator;
        bytes32 inclusionAccumulator;
        bytes32 stfRoot;
    }

    function pending() external view returns (Commitment memory);
    function finalized() external view returns (Commitment memory);

    function proveInclusion(
        uint256 _startBlockNumber,
        uint256 _endBlockNumber,
        bytes32 _endInclusionAccumulator,
        bytes calldata _proof
    ) external;
    function proveStfRoot(uint256 _startBlockNumber, uint256 _endBlockNumber, bytes32 _stfRoot, bytes calldata _proof)
        external;
    function proveBoth(
        uint256 _startBlockNumber,
        uint256 _endBlockNumber,
        bytes32 _endInclusionAccumulator,
        bytes32 _stfRoot,
        bytes calldata _inclusionProof,
        bytes calldata _stfRootProof
    ) external;

    function finalize(uint256 _blockNumber) external;
}
