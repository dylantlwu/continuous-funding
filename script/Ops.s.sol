// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {ConsensusFeed} from "../src/ConsensusFeed.sol";
import {PerpEngine} from "../src/PerpEngine.sol";
import {TestUSDC} from "../src/TestUSDC.sol";
import {Usdc} from "../src/lib/Units.sol";

/// One-off operations against a deployment, signed in-process with PRIVATE_KEY from .env (the key never
/// appears on a command line). Addresses come from $DEPLOY_OUT (default deployments/monad-testnet.json).
///
///   forge script script/Ops.s.sol --sig "post(int256[5])" "[a,b,c,d,e]" --rpc-url $RPC --broadcast
///   forge script script/Ops.s.sol --sig "commitOpen(int256,uint256)" <size> <margin> ...
///   forge script script/Ops.s.sol --sig "settle(address,bytes)" <account> <pyth update> ...
///   forge script script/Ops.s.sol --sig "commitClose()" ...
contract Ops is Script {
    function _addr(string memory key) internal view returns (address) {
        string memory path = vm.envOr("DEPLOY_OUT", string("deployments/monad-testnet.json"));
        return vm.parseJsonAddress(vm.readFile(path), string.concat(".", key));
    }

    function post(int256[5] memory venues) external {
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        ConsensusFeed(_addr("consensusFeed")).post(0, uint64(block.timestamp - 1), venues);
        vm.stopBroadcast();
    }

    function commitOpen(int256 size, uint256 margin) external {
        PerpEngine engine = PerpEngine(_addr("perpEngine"));
        TestUSDC usdc = TestUSDC(_addr("testUsdc"));
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(pk);
        vm.startBroadcast(pk);
        if (usdc.balanceOf(me) < margin) usdc.mint(me, margin);
        if (usdc.allowance(me, address(engine)) < margin) usdc.approve(address(engine), type(uint256).max);
        engine.commitOpen(size, Usdc.wrap(margin));
        vm.stopBroadcast();
    }

    function commitClose() external {
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        PerpEngine(_addr("perpEngine")).commitClose();
        vm.stopBroadcast();
    }

    function settle(address account, bytes calldata update) external {
        PerpEngine engine = PerpEngine(_addr("perpEngine"));
        bytes[] memory u = new bytes[](1);
        u[0] = update;
        uint256 fee = engine.priceSource().updateFee(u);
        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));
        engine.settle{value: fee}(account, u);
        vm.stopBroadcast();
    }
}
