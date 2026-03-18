// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Script, console2} from "forge-std/Script.sol";

import {SP1Verifier} from "sp1-contracts/v5.0.0/SP1VerifierPlonk.sol";

/// @title Deploy SP1 Verifier Infrastructure
/// @notice Deploys the SP1 verifier contract.
/// @dev Only required on chains where the SP1 verifier is not canonically deployed
/// (for example on local devnet). Run this script BEFORE DeployAppo.s.sol. The output
/// address is consumed by DeployAppo via the SP1_VERIFIER_ADDRESS environment variable.
contract DeploySP1 is Script {
    function _writeDeploymentRecord(string memory deploymentRecordJsonPath, address sp1Verifier) internal {
        string memory recordKey = "sp1_deployment_record";
        string memory recordJson = vm.serializeAddress(recordKey, "sp1_verifier", sp1Verifier);
        vm.writeJson(recordJson, deploymentRecordJsonPath);
    }

    function run() external {
        // Output
        string memory outputPath = vm.envString("SP1_DEPLOYMENT_RECORD_JSON_PATH");

        // Deployer private key
        uint256 deployerPk = vm.envUint("CONTRACTS_DEPLOYER_PRIVATE_KEY");

        // Start broadcast
        vm.startBroadcast(deployerPk);
        address sp1Verifier = address(new SP1Verifier());

        vm.stopBroadcast();

        console2.log("SP1 verifier:", sp1Verifier);
        _writeDeploymentRecord(outputPath, sp1Verifier);

        console2.log("SP1 deployment record written to", outputPath);
    }
}
