// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "../lib/forge-std/src/Script.sol";
import {console} from "../lib/forge-std/src/console.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {CommitProtocol} from "src/CommitProtocol.sol";

contract DeployCommitProtocol is Script {
    function run() public {
        // Get protocol fee address from environment
        address protocolFeeAddress = vm.envAddress("PROTOCOL_FEE_ADDRESS");
        address disperseContractAddress = vm.envAddress(
            "DISPERSE_CONTRACT_ADDRESS"
        );
        vm.startBroadcast();

        // Deploy UUPS Proxy
        address proxy = Upgrades.deployUUPSProxy(
            "CommitProtocol.sol",
            abi.encodeCall(
                CommitProtocol.initialize,
                (protocolFeeAddress, disperseContractAddress)
            )
        );

        vm.stopBroadcast();

        console.log("CommitProtocol proxy deployed to:", proxy);
        console.log("Protocol fee address set to:", protocolFeeAddress);
    }
}
