// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {IProver} from "./interfaces/IProver.sol";
import {IActions} from "./interfaces/IActions.sol";
import {ISP1Verifier} from "../lib/sp1-contracts/contracts/src/ISP1Verifier.sol";
import {ActivationSchedule} from "./libraries/ActivationSchedule.sol";

contract Prover {
    using ActivationSchedule for ActivationSchedule.Schedule;

    address public immutable ACTIONS;
    address public immutable SP1_VERIFIER;
    uint256 public immutable FINALITY;

    /// @notice Hash of the committed addresses binding proofs to specific contract addresses
    /// @dev Computed as keccak256(abi.encode(actions_address, caller_address, vault_address))
    bytes32 public immutable COMMITTED_ADDRESSES_HASH;

    address public stfAdmin;
    address public inclusionAdmin;

    ActivationSchedule.Schedule private activations;

    IProver.Commitment public pending;
    IProver.Commitment public finalized;

    uint256 public resetId;
    mapping(uint256 resetId => mapping(uint256 blockNumber => IProver.Commitment)) public submittedProofs;

    constructor(
        address _actions,
        address _sp1Verifier,
        uint256 _finality,
        bytes32 _committedAddressesHash,
        address _stfAdmin,
        bytes32 _stfHash,
        address _inclusionAdmin,
        bytes32 _inclusionHash,
        bytes32 _stfRoot
    ) {
        ACTIONS = _actions;
        SP1_VERIFIER = _sp1Verifier;
        FINALITY = _finality;

        COMMITTED_ADDRESSES_HASH = _committedAddressesHash;

        stfAdmin = _stfAdmin;
        inclusionAdmin = _inclusionAdmin;

        uint256 lastBlockNumber = block.number - 1;
        activations.initialize(_stfHash, _inclusionHash, lastBlockNumber);

        bytes32 initActionsAccumulator = IActions(ACTIONS).INIT_ACCUMULATOR();
        bytes32 initInclusionAccumulator = bytes32(0);

        IProver.Commitment memory genesisCommitment =
            IProver.Commitment(lastBlockNumber, initActionsAccumulator, initInclusionAccumulator, _stfRoot);
        submittedProofs[resetId][lastBlockNumber] = genesisCommitment;

        pending = genesisCommitment;
        finalized = pending;
    }

    modifier onlyStfAdmin() {
        require(msg.sender == stfAdmin, "Not stf admin");
        _;
    }

    modifier onlyInclusionAdmin() {
        require(msg.sender == inclusionAdmin, "Not inclusion admin");
        _;
    }

    function changeStfAdmin(address _stfAdmin) public onlyStfAdmin {
        stfAdmin = _stfAdmin;
    }

    function changeInclusionAdmin(address _inclusionAdmin) public onlyInclusionAdmin {
        inclusionAdmin = _inclusionAdmin;
    }

    function getActivationHashes(uint256 _blockNumber) public view returns (bytes32 stfHash, bytes32 inclusionHash) {
        return activations.getHashesForBlock(_blockNumber);
    }

    /// @notice Schedule a stf hash upgrade at a future block
    /// @param _stfHash The new stf program hash
    /// @param _activationBlock Block number when the upgrade activates (must be >= block.number)
    function scheduleStfUpgrade(bytes32 _stfHash, uint256 _activationBlock) public onlyStfAdmin {
        require(_activationBlock > 0, "Activation block must be greater than 0");
        activations.appendStfUpgrade(_stfHash, _activationBlock, block.number);
    }

    /// @notice Schedule a inclusion hash upgrade at a future block
    /// @param _inclusionHash The new inclusion program hash
    /// @param _activationBlock Block number when the upgrade activates (must be >= block.number)
    function scheduleInclusionUpgrade(bytes32 _inclusionHash, uint256 _activationBlock) public onlyInclusionAdmin {
        require(_activationBlock > 0, "Activation block must be greater than 0");
        activations.appendInclusionUpgrade(_inclusionHash, _activationBlock, block.number);
    }

    /// @notice Reset the commitments to finalized and activate the inclusion program (invalidates all pending proofs)
    /// @param _inclusionHash The new inclusion program hash
    /// @param _activationBlock Block number when the upgrade activates (must be > finalizedBlock)
    function retroInclusionUpgrade(bytes32 _inclusionHash, uint256 _activationBlock) public onlyInclusionAdmin {
        uint256 finalizedBlock = block.number > FINALITY ? block.number - FINALITY : 0;
        require(_activationBlock > finalizedBlock, "Retroactive upgrade block must be > finalized block");
        require(_activationBlock < block.number, "Retroactive upgrade block must be < block.number");
        require(_activationBlock > 0, "Activation block must be greater than 0");

        resetId++;
        pending = finalized;

        // insert finalized into the submitted proofs on the new reset id
        submittedProofs[resetId][finalized.blockNumber] = finalized;

        activations.retroInclusionInsert(_inclusionHash, _activationBlock, finalizedBlock);
    }

    function proveInclusion(
        uint256 _startBlockNumber,
        uint256 _endBlockNumber,
        bytes32 _endInclusionAccumulator,
        bytes calldata _proof
    ) public {
        require(_startBlockNumber < _endBlockNumber, "End must be greater than start");

        IProver.Commitment memory startCommitment = submittedProofs[resetId][_startBlockNumber];
        require(startCommitment.stfRoot != bytes32(0), "Start commitment not fully verified");

        IProver.Commitment memory endCommitment = submittedProofs[resetId][_endBlockNumber];
        // note: we check the actions accumulator because the inclusion accumulator can validly be zero
        require(endCommitment.actionsAccumulator == bytes32(0), "End commitment inclusion already verified");
        require(endCommitment.stfRoot == bytes32(0), "End commitment already fully verified");

        (, bytes32 inclusionHash) = activations.getHashesForProofRange(_startBlockNumber, _endBlockNumber);

        bytes32 endActionsAccumulator = IActions(ACTIONS).accumulatorUpperLookup(_endBlockNumber);

        bytes memory publicValues = abi.encode(
            COMMITTED_ADDRESSES_HASH,
            _startBlockNumber,
            startCommitment.actionsAccumulator,
            startCommitment.inclusionAccumulator,
            startCommitment.stfRoot,
            _endBlockNumber,
            endActionsAccumulator,
            _endInclusionAccumulator
        );
        ISP1Verifier(SP1_VERIFIER).verifyProof(inclusionHash, publicValues, _proof);

        // Add the commitment to the submitted proofs
        submittedProofs[resetId][_endBlockNumber] = IProver.Commitment({
            blockNumber: _endBlockNumber,
            actionsAccumulator: endActionsAccumulator,
            inclusionAccumulator: _endInclusionAccumulator,
            stfRoot: bytes32(0)
        });
    }

    function proveStfRoot(uint256 _startBlockNumber, uint256 _endBlockNumber, bytes32 _stfRoot, bytes calldata _proof)
        public
    {
        require(_startBlockNumber < _endBlockNumber, "End must be greater than start");
        require(_stfRoot != bytes32(0), "STF root must be non-zero");

        IProver.Commitment memory startCommitment = submittedProofs[resetId][_startBlockNumber];
        require(startCommitment.stfRoot != bytes32(0), "Start commitment not fully verified");

        IProver.Commitment memory endCommitment = submittedProofs[resetId][_endBlockNumber];
        // note: we check the actions accumulator for inclusion verification because the inclusion accumulator can validly be zero
        require(endCommitment.actionsAccumulator != bytes32(0), "End commitment inclusion not verified");
        require(endCommitment.stfRoot == bytes32(0), "End commitment already fully verified");

        (bytes32 stfHash,) = activations.getHashesForProofRange(_startBlockNumber, _endBlockNumber);

        bytes memory publicValues = abi.encode(
            COMMITTED_ADDRESSES_HASH,
            _startBlockNumber,
            startCommitment.inclusionAccumulator,
            startCommitment.stfRoot,
            _endBlockNumber,
            endCommitment.actionsAccumulator,
            endCommitment.inclusionAccumulator,
            _stfRoot
        );
        ISP1Verifier(SP1_VERIFIER).verifyProof(stfHash, publicValues, _proof);

        // Add the commitment to the submitted proofs
        endCommitment.stfRoot = _stfRoot;
        submittedProofs[resetId][_endBlockNumber] = endCommitment;

        // Check if we can finalize
        if (block.number > FINALITY) {
            // Must be finalizable
            if (_endBlockNumber <= block.number - FINALITY) {
                // Finalized must move forward
                if (_endBlockNumber > finalized.blockNumber) {
                    // Update finalized
                    finalized = endCommitment;
                    // Prune old activations entries
                    activations.prune(_endBlockNumber);
                }
            }
        }

        // Update pending (must also be above or at finalized)
        if (_endBlockNumber > pending.blockNumber) {
            pending = endCommitment;
        }
    }

    function proveBoth(
        uint256 _startBlockNumber,
        uint256 _endBlockNumber,
        bytes32 _endInclusionAccumulator,
        bytes32 _stfRoot,
        bytes calldata _inclusionProof,
        bytes calldata _stfRootProof
    ) public {
        proveInclusion(_startBlockNumber, _endBlockNumber, _endInclusionAccumulator, _inclusionProof);
        proveStfRoot(_startBlockNumber, _endBlockNumber, _stfRoot, _stfRootProof);
    }

    function finalize(uint256 _blockNumber) public {
        uint256 blockNumber = block.number;

        // Must be finalizable
        require(_blockNumber <= blockNumber - FINALITY, "Not finalizable");

        // Finalized must move forward
        require(_blockNumber > finalized.blockNumber, "Finalized must move forward");

        // Submitted proof exists
        IProver.Commitment memory commitment = submittedProofs[resetId][_blockNumber];
        require(commitment.stfRoot != bytes32(0), "Commitment is not fully verified");

        // Update finalized
        finalized = commitment;

        // Pending must be above or at finalized
        if (_blockNumber > pending.blockNumber) {
            pending = finalized;
        }

        // Prune old activations entries
        activations.prune(_blockNumber);
    }
}
