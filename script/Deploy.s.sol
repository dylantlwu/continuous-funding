// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPyth} from "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import {ConsensusFeed} from "../src/ConsensusFeed.sol";
import {PerpEngine} from "../src/PerpEngine.sol";
import {PythPriceSource} from "../src/PythPriceSource.sol";
import {TestUSDC} from "../src/TestUSDC.sol";
import {Usdc} from "../src/lib/Units.sol";
import {Config} from "./Config.sol";

/// Deploys TestUSDC, ConsensusFeed, PythPriceSource and PerpEngine, seeds the vault, and writes the
/// addresses to $DEPLOY_OUT (default deployments/monad-testnet.json) -- only when broadcasting: a simulation
/// once overwrote the real addresses with ones that were never deployed.
///
///   forge clean && forge script script/Deploy.s.sol --rpc-url $MONAD_TESTNET_RPC --broadcast --slow \
///     --gas-estimate-multiplier 200
///
/// `forge clean` first: a stale compile cache once deployed a build whose comments differed from the
/// committed source (same code, different metadata hash), which Sourcify then only partially matched.
/// Monad charges the gas limit and reprices cold state access, so limits come from the node's estimate.
///
/// Env: PRIVATE_KEY (deployer, testnet only), RELAYER (default: the deployer), DEPLOY_OUT.
contract Deploy is Script {
    // Monad testnet Pyth contract: https://docs.monad.xyz/tooling-and-infra/oracles
    address internal constant PYTH_MONAD_TESTNET = 0x2880aB155794e7179c9eE2e38200202908C17B43;
    // BTC/USD feed id: https://hermes.pyth.network/v2/price_feeds
    bytes32 internal constant BTC_USD = 0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43;
    uint8 internal constant BTC_MARKET = 0;

    function run() external {
        require(block.chainid == 10143, "Monad testnet only (or a fork of it)");
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address relayer = vm.envOr("RELAYER", deployer);
        string memory out = vm.envOr("DEPLOY_OUT", string("deployments/monad-testnet.json"));

        vm.startBroadcast(pk);
        TestUSDC usdc = new TestUSDC();
        ConsensusFeed feed = Config.newFeed(relayer);
        PythPriceSource source = new PythPriceSource(IPyth(PYTH_MONAD_TESTNET), BTC_USD);
        PerpEngine engine = new PerpEngine(IERC20(address(usdc)), feed, BTC_MARKET, source, Config.engineParams());

        uint256 cap = usdc.FAUCET_MAX();
        for (uint256 minted = 0; minted < Config.VAULT_SEED; minted += cap) {
            uint256 left = Config.VAULT_SEED - minted;
            usdc.mint(deployer, left < cap ? left : cap);
        }
        usdc.approve(address(engine), Config.VAULT_SEED);
        engine.seedVault(Usdc.wrap(Config.VAULT_SEED));
        vm.stopBroadcast();

        console.log("PerpEngine     ", address(engine));
        console.log("ConsensusFeed  ", address(feed));
        console.log("PythPriceSource", address(source));
        console.log("TestUSDC       ", address(usdc));
        console.log("vault cash     ", Usdc.unwrap(engine.vaultCash()));
        if (!vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)) {
            console.log("simulation only: addresses NOT written");
            return;
        }

        string memory j = "deployment";
        vm.serializeUint(j, "chainId", block.chainid);
        vm.serializeUint(j, "block", block.number);
        vm.serializeAddress(j, "deployer", deployer);
        vm.serializeAddress(j, "relayer", relayer);
        vm.serializeAddress(j, "pyth", PYTH_MONAD_TESTNET);
        vm.serializeBytes32(j, "btcUsdFeedId", BTC_USD);
        vm.serializeAddress(j, "testUsdc", address(usdc));
        vm.serializeAddress(j, "consensusFeed", address(feed));
        vm.serializeAddress(j, "priceSource", address(source));
        string memory json = vm.serializeAddress(j, "perpEngine", address(engine));
        vm.writeJson(json, out);
        console.log("written to     ", out);
    }
}
