// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console2} from "forge-std/Script.sol";

import {Actions} from "../src/Actions.sol";
import {Caller} from "../src/Caller.sol";
import {Prover} from "../src/Prover.sol";
import {Vault} from "../src/Vault.sol";

contract DeployAppo is Script {
    struct ProverEnvVars {
        uint256 finality;
        address stfAdmin;
        bytes32 stfHash;
        address inclusionAdmin;
        bytes32 inclusionHash;
        bytes32 stfRoot;
    }

    struct DeployedAddresses {
        address actions;
        address caller;
        address prover;
        address vault;
    }

    /// @notice Compute the committed addresses hash that binds proofs to specific contract addresses
    /// @dev Must match the computation in deployment-record crate (CommittedAddresses::hash):
    ///      keccak256(abi.encode(actions_address, caller_address, vault_address))
    function _computeCommittedAddressesHash(address actionsAddress, address callerAddress, address vaultAddress)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(actionsAddress, callerAddress, vaultAddress));
    }

    function _writeDeploymentRecord(
        string memory deploymentRecordJsonPath,
        DeployedAddresses memory d,
        uint64 deploymentBlockNumber,
        bytes32 deploymentParentBlockHash,
        bytes32 initialActionsAccumulator
    ) internal {
        string memory recordKey = "deployment_record";

        vm.serializeUint(recordKey, "chain_id", block.chainid);
        vm.serializeUint(recordKey, "block_number", uint256(deploymentBlockNumber));
        vm.serializeBytes32(recordKey, "parent_block_hash", deploymentParentBlockHash);
        vm.serializeBytes32(recordKey, "initial_actions_accumulator", initialActionsAccumulator);
        vm.serializeAddress(recordKey, "actions_address", d.actions);
        vm.serializeAddress(recordKey, "caller_address", d.caller);
        vm.serializeAddress(recordKey, "prover_address", d.prover);
        string memory recordJson = vm.serializeAddress(recordKey, "vault_address", d.vault);

        vm.writeJson(recordJson, deploymentRecordJsonPath);
    }

    function _readProverEnvVars() internal view returns (ProverEnvVars memory) {
        return ProverEnvVars({
            finality: vm.envUint("CONTRACTS_FINALITY"),
            stfAdmin: vm.envAddress("CONTRACTS_STF_ADMIN"),
            stfHash: vm.envBytes32("CONTRACTS_STF_HASH"),
            inclusionAdmin: vm.envAddress("CONTRACTS_INCLUSION_ADMIN"),
            inclusionHash: vm.envBytes32("CONTRACTS_INCLUSION_HASH"),
            stfRoot: vm.envBytes32("CONTRACTS_STF_ROOT")
        });
    }

    function _deployActions() internal returns (address) {
        return address(new Actions());
    }

    function _deployCaller(address actionsAddress) internal returns (address) {
        return address(new Caller(actionsAddress));
    }

    function _deployVault(
        address actionsAddress,
        address proverAddress,
        address admin,
        address sp1Verifier,
        bytes32 withdrawalVKey
    ) internal returns (address) {
        return address(new Vault(actionsAddress, proverAddress, admin, sp1Verifier, withdrawalVKey));
    }

    function _deployProver(address actions, address sp1Verifier, bytes32 committedAddressesHash, ProverEnvVars memory p)
        internal
        returns (address)
    {
        return address(
            new Prover(
                actions,
                sp1Verifier,
                p.finality,
                committedAddressesHash,
                p.stfAdmin,
                p.stfHash,
                p.inclusionAdmin,
                p.inclusionHash,
                p.stfRoot
            )
        );
    }

    function run() external {
        // Output
        string memory deploymentRecordJsonPath = vm.envString("CONTRACTS_DEPLOYMENT_RECORD_JSON_PATH");

        // Deployer private key
        uint256 deployerPk = vm.envUint("CONTRACTS_DEPLOYER_PRIVATE_KEY");

        // SP1 Verifier address (pre-deployed)
        address sp1Verifier = vm.envAddress("SP1_VERIFIER_ADDRESS");

        // Ensure ProverParams environment variables are set
        ProverEnvVars memory proverEnvVars = _readProverEnvVars();

        // Start broadcast
        vm.startBroadcast(deployerPk);
        DeployedAddresses memory deployed;

        deployed.actions = _deployActions();
        deployed.caller = _deployCaller(deployed.actions);

        // calculate prover address in order to deploy vault
        address deployer = vm.addr(deployerPk);
        uint64 proverNonce = vm.getNonce(deployer) + 1;
        address predictedProver = vm.computeCreateAddress(deployer, proverNonce);
        bytes32 withdrawalVKey = vm.envBytes32("CONTRACTS_WITHDRAWAL_VKEY");
        deployed.vault = _deployVault(deployed.actions, predictedProver, deployer, sp1Verifier, withdrawalVKey);

        // Construct ProverParams and deploy prover
        bytes32 committedAddressesHash =
            _computeCommittedAddressesHash(deployed.actions, deployed.caller, deployed.vault);

        deployed.prover = _deployProver(deployed.actions, sp1Verifier, committedAddressesHash, proverEnvVars);
        require(deployed.prover == predictedProver, "Prover address mismatch");

        uint64 deploymentBlockNumber = uint64(block.number);
        bytes32 deploymentParentBlockHash = block.number == 0 ? bytes32(0) : blockhash(block.number - 1);
        bytes32 initialActionsAccumulator = Actions(deployed.actions).INIT_ACCUMULATOR();

        vm.stopBroadcast();

        console2.log("Actions:", deployed.actions);
        console2.log("Caller:", deployed.caller);
        console2.log("Prover:", deployed.prover);
        console2.log("Vault:", deployed.vault);
        console2.log("SP1 Verifier:", sp1Verifier);

        console2.log("Committed addresses hash:", vm.toString(committedAddressesHash));
        console2.log("Initial actions accumulator:", vm.toString(initialActionsAccumulator));

        _writeDeploymentRecord(
            deploymentRecordJsonPath,
            deployed,
            deploymentBlockNumber,
            deploymentParentBlockHash,
            initialActionsAccumulator
        );
        console2.log("Deployment record written to", deploymentRecordJsonPath);
    }
}
