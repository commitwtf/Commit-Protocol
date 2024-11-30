// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "../lib/forge-std/src/Script.sol";
import {console} from "../lib/forge-std/src/console.sol";
import {Upgrades} from "../lib/openzeppelin-foundry-upgrades/src/Upgrades.sol";
import {CommitProtocol} from "src/CommitProtocol.sol";

contract UpgradeCommitProtocol is Script {
    function run() public {
        // Get protocol fee address from environment
        address proxyAddress = vm.envAddress("PROXY_ADDRESS");

        vm.startBroadcast();

        // Deploy UUPS Proxy
        address proxy = Upgrades.upgradeProxy(
            proxyAddress,
            "CommitProtocol.sol",
            ""
        );

        vm.stopBroadcast();

        console.log("CommitProtocol proxy upgraded");
    }
}
