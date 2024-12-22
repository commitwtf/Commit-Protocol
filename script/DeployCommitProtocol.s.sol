// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "../lib/forge-std/src/Script.sol";
import {console} from "../lib/forge-std/src/console.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {CommitProtocol} from "src/CommitProtocol.sol";
import {CommitProtocolFactory} from "src/CommitProtocolFactory.sol";

contract DeployCommitProtocol is Script {
    function run() public {
        // Get protocol fee address from environment
        address protocolFeeAddress = vm.envAddress("PROTOCOL_FEE_ADDRESS");
        address disperseContractAddress = vm.envAddress("DISPERSE_CONTRACT_ADDRESS");
        vm.startBroadcast();
        CommitProtocol implementation = new CommitProtocol();
        CommitProtocolFactory factory = new CommitProtocolFactory(address(implementation));

        vm.stopBroadcast();

        console.log("CommitProtocolFactory deployed to:", address(factory));
        console.log("Protocol fee address set to:", protocolFeeAddress);
    }
}
