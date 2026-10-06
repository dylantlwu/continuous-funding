// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {ConsensusFeed} from "../src/ConsensusFeed.sol";
import {CreFeedReceiver} from "../src/cre/CreFeedReceiver.sol";
import {Config} from "./Config.sol";

/// Deploys a second ConsensusFeed whose relayer is a CreFeedReceiver, so a Chainlink CRE workflow posts to it while the
/// live feed keeps its Python relayer; both can be compared post by post. Same bounds as the live feed (Config).
///
///   forge clean && forge script script/DeployCre.s.sol --rpc-url $MONAD_TESTNET_RPC --broadcast --slow \
///     --gas-estimate-multiplier 200
///
/// Env: PRIVATE_KEY; CRE_FORWARDER (default: Monad testnet MockKeystoneForwarder, for `cre workflow simulate`;
/// switch to the KeystoneForwarder 0xF8344CFd5c43616a4366C34E3EEE75af79a74482 with setForwarder for a deployed workflow).
contract DeployCre is Script {
    address constant MOCK_FORWARDER = 0xB9F79d863261869B234c481D1f9A7af84AeAd192; // CRE forwarder directory, simulation

    function run() external {
        address forwarder = vm.envOr("CRE_FORWARDER", MOCK_FORWARDER);
        address deployer = vm.addr(vm.envUint("PRIVATE_KEY"));
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        ConsensusFeed feed = Config.newFeed(deployer);
        CreFeedReceiver receiver = new CreFeedReceiver(feed, 0, forwarder);
        feed.setRelayer(address(receiver));
        vm.stopBroadcast();
        console.log("ConsensusFeed (CRE) ", address(feed));
        console.log("CreFeedReceiver     ", address(receiver));
        console.log("forwarder           ", forwarder);
        if (vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)) {
            string memory o = "cre";
            vm.serializeUint(o, "chainId", block.chainid);
            vm.serializeUint(o, "block", block.number);
            vm.serializeAddress(o, "consensusFeed", address(feed));
            vm.serializeAddress(o, "receiver", address(receiver));
            string memory json = vm.serializeAddress(o, "forwarder", forwarder);
            vm.writeJson(json, "deployments/monad-testnet-cre.json");
        }
    }
}
