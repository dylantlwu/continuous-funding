// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ConsensusFeed} from "../src/ConsensusFeed.sol";
import {PerpEngine} from "../src/PerpEngine.sol";
import {TestUSDC} from "../src/TestUSDC.sol";
import {Usdc, UsdWad, MarginStatic, MarginDynamic} from "../src/lib/Units.sol";
import {MockPriceSource} from "./harness/MockPriceSource.sol";
import {TestParams} from "./Params.sol";

/// Trading flows: open, close, add margin, liquidate. T2, T5, T6, T8, T11 and an end-to-end settlement.
contract TradingTest is Test {
    TestUSDC usdc;
    ConsensusFeed feed;
    MockPriceSource px;
    PerpEngine eng;
    address relayer = address(0xBEEF);
    address[4] traders = [address(0xA11CE), address(0xB0B), address(0xCA401), address(0xD0D0)];
    address keeper = address(0x4EE9);
    bytes[] none;
    int256 constant APR_1PCT = TestParams.APR_1PCT;
    uint256 constant P0 = 100_000e18;
    uint256 constant SEED = 1_000_000e6;

    function setUp() public {
        vm.warp(1_000_000 - 120); // opening post 2 minutes early: tests may post a full step at 1_000_000
        usdc = new TestUSDC();
        feed = TestParams.newFeed(relayer);
        px = new MockPriceSource();
        eng = new PerpEngine(IERC20(address(usdc)), feed, 0, px, TestParams.defaults());
        deal(address(usdc), address(this), SEED);
        usdc.approve(address(eng), type(uint256).max);
        eng.seedVault(Usdc.wrap(SEED));
        for (uint256 i = 0; i < traders.length; i++) {
            deal(address(usdc), traders[i], 10_000_000e6);
            vm.prank(traders[i]);
            usdc.approve(address(eng), type(uint256).max);
        }
        _post(0);
        vm.warp(1_000_000);
        _price(P0, 0);
    }

    // ───────────── helpers ─────────────

    function _post(int256 r) internal {
        vm.prank(relayer);
        feed.post(0, uint64(block.timestamp), TestParams.venues(r));
    }

    function _price(uint256 p, uint256 c) internal {
        px.set(p, c, uint64(block.timestamp));
    }

    function _open(address who, int256 size, uint256 margin) internal {
        vm.prank(who);
        eng.open(size, Usdc.wrap(margin), none);
    }

    function _close(address who) internal {
        vm.prank(who);
        eng.close(none);
    }

    function _deposit(address who) internal view returns (uint256 d) {
        (, MarginStatic m,,) = eng.positions(who);
        d = MarginStatic.unwrap(m);
    }

    function _size(address who) internal view returns (int256 s) {
        (s,,,) = eng.positions(who);
    }

    function _vault() internal view returns (uint256) {
        return Usdc.unwrap(eng.vaultCash());
    }

    function _bal(address who) internal view returns (uint256) {
        return usdc.balanceOf(who);
    }

    // ───────────── end to end ─────────────

    // Without this, the pieces could each be right and still move money wrongly together: a balanced book
    // pays exactly c from longs to shorts, fees go to the vault, and the vault's net funding is zero.
    function test_balancedBookPaysConsensusLongToShort() public {
        _post(5 * APR_1PCT); // one step: the feed moves at most 5% APR per post
        _open(traders[0], 1e18, 10_100e6); // long 1 BTC, fee 50
        _open(traders[1], -1e18, 10_100e6); // short 1 BTC: skew 0, so p stays 0
        uint256 vaultAfterOpen = _vault();
        assertEq(vaultAfterOpen, SEED + 100e6);

        vm.warp(block.timestamp + 1 days);
        _post(5 * APR_1PCT); // keep the feed fresh at the same rate
        _price(P0, 0);
        uint256 a0 = _bal(traders[0]);
        uint256 b0 = _bal(traders[1]);
        _close(traders[0]);
        _close(traders[1]);

        // funding per BTC for one day at 5% APR on 100k: 100000 * 5 * APR_1PCT * 86400 / 1e18 USD
        uint256 fundingWad = uint256(100_000 * 5 * APR_1PCT * 86_400);
        uint256 funding6 = fundingWad / 1e12; // 13.698630 USD
        assertEq(_bal(traders[0]) - a0, 10_050e6 - 50e6 - funding6 - 1, "long pays c (ceil against trader)");
        assertEq(_bal(traders[1]) - b0, 10_050e6 - 50e6 + funding6, "short receives c (floor)");
        assertEq(_vault(), vaultAfterOpen + 100e6 + 1, "vault: close fees, plus 1 micro-USDC of rounding dust");
        assertEq(eng.longOI() + eng.shortOI(), 0);
    }

    // Without this, a liquidation could pay the liquidator from nowhere or hide bad debt.
    function test_liquidationPaysRewardAndRecordsShortfall() public {
        _open(traders[0], 1e18, 10_050e6); // 10x long, deposit 10,000
        _price(85_000e18, 0); // same second: no funding, so the numbers are exact                 // -15%: equity -5,000
        uint256 v0 = _vault();
        vm.expectEmit(true, false, false, true);
        emit PerpEngine.Shortfall(traders[0], UsdWad.wrap(5_425e18)); // 5,000 bad debt + 425 reward not covered
        vm.prank(keeper);
        eng.liquidate(traders[0], none);
        assertEq(_bal(keeper), 425e6, "0.5% of 85,000 notional");
        assertEq(_vault(), v0 + 10_000e6 - 425e6, "vault keeps the deposit, pays the reward");
        assertEq(_size(traders[0]), 0);
        assertEq(eng.longOI(), 0);
    }

    // ───────────── T6: bad data reverts; global problems never block risk reduction ─────────────

    // Without this, a zero, stale or rewound price could value a position (the production near-miss).
    function test_T6_badPriceDataReverts() public {
        _open(traders[0], 1e18, 10_050e6);
        vm.warp(block.timestamp + 5);

        px.set(0, 0, uint64(block.timestamp));
        vm.expectRevert(PerpEngine.ZeroPrice.selector);
        vm.prank(keeper);
        eng.liquidate(traders[0], none);

        px.set(P0, 0, uint64(block.timestamp - 4));
        vm.expectRevert(abi.encodeWithSelector(PerpEngine.PriceTooOld.selector, uint64(block.timestamp - 4), uint64(3)));
        _close(traders[0]);

        px.set(P0, 0, uint64(block.timestamp - 6)); // older than the price used at open
        vm.expectRevert(
            abi.encodeWithSelector(
                PerpEngine.PriceOlderThanLast.selector, uint64(block.timestamp - 6), uint64(block.timestamp - 5)
            )
        );
        vm.prank(keeper);
        eng.liquidate(traders[0], none);

        _price(P0, 0);
        vm.expectRevert(PerpEngine.NoPosition.selector);
        _close(traders[1]);
        vm.expectRevert(PerpEngine.NoPosition.selector);
        eng.liquidate(traders[1], none);
    }

    // Without this, a dead feed or an owner pause could trap traders in positions or block liquidations,
    // turning a data outage into vault losses. Global problems pause new opens only.
    function test_T6_globalProblemsBlockOpensOnly() public {
        _open(traders[0], 1e18, 10_050e6);
        _open(traders[1], 1e18, 10_050e6);
        vm.warp(block.timestamp + 301); // feed stale
        _price(P0, 0);
        assertTrue(feed.isStale(0));
        vm.expectRevert(PerpEngine.FeedStale.selector);
        _open(traders[2], 1e18, 10_050e6);
        eng.setOpensPaused(true);
        vm.expectRevert(PerpEngine.OpensArePaused.selector);
        _open(traders[2], 1e18, 10_050e6);

        _close(traders[0]); // close still works
        _price(80_000e18, 0);
        vm.prank(keeper);
        eng.liquidate(traders[1], none); // liquidation still works
        assertEq(eng.longOI(), 0);
    }

    // Without this, an open could be priced off a wide-confidence (uncertain) print.
    function test_T6_wideConfidenceBlocksOpens() public {
        _price(P0, P0 / 100 + 1); // conf just above 1% of price
        vm.expectRevert(abi.encodeWithSelector(PerpEngine.ConfidenceTooWide.selector, P0, P0 / 100 + 1));
        _open(traders[0], 1e18, 10_050e6);
    }

    // ───────────── T11: the free oracle option is closed ─────────────

    // Without this, a trader could open, wait, and close against whichever signed price pays best,
    // including one older than the price already used. That is a free option written by the vault.
    function test_T11_cannotCloseOnAnOlderPrice() public {
        uint64 tOpen = uint64(block.timestamp);
        _open(traders[0], 1e18, 10_050e6);
        vm.warp(block.timestamp + 2);
        _price(98_000e18, 0);
        eng.poke(none); // someone uses the newer, lower price
        px.set(P0, 0, tOpen); // trader tries to close on the older, better print
        vm.expectRevert(abi.encodeWithSelector(PerpEngine.PriceOlderThanLast.selector, tOpen, tOpen + 2));
        _close(traders[0]);
    }

    // F6 regression. Without this, the age windows could drift: a liquidator could pick a wick several seconds
    // old (an option the trader does not have), or a trade could use a stale print. One 3-second window for all.
    function test_T11_ageWindows() public {
        _open(traders[0], 1e18, 10_050e6);
        vm.warp(block.timestamp + 20);
        px.set(80_000e18, 0, uint64(block.timestamp - 4));
        vm.expectRevert(abi.encodeWithSelector(PerpEngine.PriceTooOld.selector, uint64(block.timestamp - 4), uint64(3)));
        eng.liquidate(traders[0], none);
        px.set(80_000e18, 0, uint64(block.timestamp - 3));
        eng.liquidate(traders[0], none); // 3 s is allowed

        vm.warp(block.timestamp + 5); // past the price just used, so only the age check can fire
        _post(0);
        px.set(P0, 0, uint64(block.timestamp - 4));
        vm.expectRevert(abi.encodeWithSelector(PerpEngine.PriceTooOld.selector, uint64(block.timestamp - 4), uint64(3)));
        _open(traders[1], 1e18, 10_050e6);
        px.set(P0, 0, uint64(block.timestamp - 3));
        _open(traders[1], 1e18, 10_050e6);
    }

    // F4. Without this, trades would execute at the oracle mid, and a trader who opens on a print up to 3 s old
    // and closes on the latest one would pocket any fast move from the vault. Execution is moved by the
    // confidence interval against the trader, a spread that widens exactly when the oracle is unsure.
    function test_F4_tradesExecuteAtConfidenceAgainstTheTrader() public {
        _price(P0, 30e18);
        _open(traders[0], 1e18, 10_100e6);
        (,,, uint256 longEntry) = eng.positions(traders[0]);
        assertEq(longEntry, P0 + 30e18, "long buys at price + conf");
        _open(traders[1], -1e18, 10_100e6);
        (,,, uint256 shortEntry) = eng.positions(traders[1]);
        assertEq(shortEntry, P0 - 30e18, "short sells at price - conf");

        uint256 b0 = _bal(traders[0]);
        _close(traders[0]); // same price and conf: pays the 60 USD spread plus two fees
        uint256 back = _bal(traders[0]) - b0;
        assertEq(back, 10_100e6 - 50_015_000 - 60e6 - 49_985_000, "deposit - open fee - spread - close fee");
    }

    // F5 regression. Without this, a 1-wei position that is healthy and cannot be liquidated would block
    // vault withdrawals forever.
    function test_F5_belowMinSizeReverts() public {
        vm.expectRevert(abi.encodeWithSelector(PerpEngine.BelowMinSize.selector, 1, 0.001e18));
        _open(traders[0], 1, 1e6);
    }

    // F1 + F3 regression. Without this, open interest could be stacked on one side by opening hedge legs and
    // closing them (closes are never capped), until a small move drains the vault and winners cannot close.
    // Each open must leave the vault solvent after a 25% move with the larger side unhedged.
    function test_F1F3_vaultCapacityBoundsEachSide() public {
        // 1,000,000 vault / (100,000 x 25%) = 40 BTC per side
        _open(traders[0], 40e18, 402_000e6);
        vm.expectPartialRevert(PerpEngine.VaultCapacityExceeded.selector);
        _open(traders[1], 1e18, 10_100e6); // one more long: over capacity
        _open(traders[1], -40e18, 402_000e6); // the other side may grow to the same size
        _close(traders[1]); // the hedge leaves: skew is now +40, still covered
        vm.expectPartialRevert(PerpEngine.VaultCapacityExceeded.selector);
        _open(traders[2], 1e18, 10_100e6);
    }

    // F3. Without this, unrealised profit already owed to traders would count as vault capacity: after a rally,
    // the vault's cash is still there but much of it is spoken for.
    function test_F3_capacityIsNetOfProfitAlreadyOwed() public {
        _open(traders[0], 30e18, 301_600e6);
        vm.warp(block.timestamp + 1);
        _post(0);
        _price(120_000e18, 0); // longs are up 600,000
        // 30 BTC x 120,000 x 25% = 900,000 of stress > 1,000,000 + fees - 600,000 owed
        vm.expectPartialRevert(PerpEngine.VaultCapacityExceeded.selector);
        _open(traders[1], -1e18, 12_100e6);
    }

    // ───────────── T5: a healthy position can never be liquidated ─────────────

    // Without this, a rounding or sign slip in the health check could liquidate a healthy account (the
    // production near-miss this project is built around). Also checks the converse, so a contract that
    // never liquidates cannot pass: clearly unhealthy positions must be liquidatable.
    function testFuzz_T5_healthyNeverLiquidated(
        bool isLong,
        uint256 sizeMilli,
        uint256 lev,
        int256 moveBp,
        uint256 confBp,
        uint256 elapsed,
        int256 cPct
    ) public {
        sizeMilli = bound(sizeMilli, 1, 40_000); // 0.001 to 40 BTC (the vault's capacity per side)
        lev = bound(lev, 1, 10);
        moveBp = bound(moveBp, -3000, 3000);
        confBp = bound(confBp, 0, 200);
        elapsed = bound(elapsed, 0, 30 days);
        cPct = bound(cPct, -5, 5);
        int256 size = int256(sizeMilli * 1e15) * (isLong ? int256(1) : int256(-1));

        _post(cPct * APR_1PCT);
        uint256 notional6 = sizeMilli * 1e15 * (P0 / 1e18) / 1e12;
        _open(traders[0], size, notional6 / lev + notional6 / 1000 + 1);

        vm.warp(block.timestamp + elapsed);
        uint256 p1 = uint256(int256(P0) * (10_000 + moveBp) / 10_000);
        uint256 conf = p1 * confBp / 10_000;
        _price(p1, conf);
        _assertLiquidationMatchesExactHealth(size, size > 0 ? p1 + conf : p1 - conf);
    }

    /// Exact arithmetic, everything scaled to 1e36, at the trader-favourable price `pf`.
    function _assertLiquidationMatchesExactHealth(int256 size, uint256 pf) internal {
        int256 indexNow = eng.fundingIndexNow();
        (,, int256 entryIndex, uint256 entryPrice) = eng.positions(traders[0]);
        int256 equity36 = int256(_deposit(traders[0])) * 1e30 + size * (int256(pf) - int256(entryPrice)) - size
            * (indexNow - entryIndex);
        uint256 absSize = uint256(size > 0 ? size : -size);
        int256 maint36 = int256(absSize * pf / 1e18) * 0.05e18; // |size| x pf is exact for these inputs

        if (equity36 >= maint36) {
            vm.expectPartialRevert(PerpEngine.NotLiquidatable.selector);
            vm.prank(keeper);
            eng.liquidate(traders[0], none);
        } else if (equity36 < maint36 - 1e30 - 1e19) {
            // beyond 1 micro-USDC plus a few wei of rounding
            vm.prank(keeper);
            eng.liquidate(traders[0], none);
            assertEq(_size(traders[0]), 0);
        }
    }

    // T5 at the exact boundary. Without this, rounding the maintenance requirement UP to a whole
    // micro-USDC (the "against the trader" default) would liquidate a position whose equity equals its
    // maintenance margin exactly; random fuzzing almost never lands on this boundary, so it is pinned here.
    // Numbers from: P = 20 (E - D) / 19 for a 1 BTC long, so equity == 5% of notional to the wei.
    function test_T5_exactBoundaryIsNotLiquidated() public {
        uint256 entry = 100_000e18 + 4; // odd wei: maintenance is not a whole micro-USDC
        uint256 boundary = 94_735_789_473_684_210_526_320;
        _price(entry, 0);
        _open(traders[0], 1e18, 10_001e6 + 50e6 + 1); // deposit 10,001 after the rounded-up fee
        assertEq(_deposit(traders[0]), 10_001e6);
        _price(boundary, 0);
        vm.expectRevert(
            abi.encodeWithSelector(
                PerpEngine.NotLiquidatable.selector,
                UsdWad.wrap(4_736_789_473_684_210_526_316),
                MarginDynamic.wrap(4_736_789_473)
            )
        );
        eng.liquidate(traders[0], none);
    }

    // ───────────── T8: extremes and rounding direction ─────────────

    // Without this, rounding could let a zero-move round trip pull dust out of the vault, which a bot can
    // repeat without limit; and extreme sizes or prices could overflow.
    function testFuzz_T8_roundTripNeverExtractsFromVault(uint256 sizeWei, uint256 priceWei, bool isLong) public {
        PerpEngine big = new PerpEngine(IERC20(address(usdc)), feed, 0, px, TestParams.defaults());
        deal(address(usdc), address(this), 1e36);
        usdc.approve(address(big), 1e36);
        big.seedVault(Usdc.wrap(1e36)); // enough capacity for any size below
        sizeWei = bound(sizeWei, 0.001e18, 1e30); // min size to 1e12 BTC
        priceWei = bound(priceWei, 1, 1e30); // 1e-18 USD to 1e12 USD
        px.set(priceWei, 0, uint64(block.timestamp));
        uint256 notional6 = sizeWei * priceWei / 1e30 + 1;
        uint256 margin = notional6 / 5 + 2; // 5x plus the rounded-up fee
        deal(address(usdc), traders[3], margin);
        vm.startPrank(traders[3]);
        usdc.approve(address(big), margin);
        big.open(isLong ? int256(sizeWei) : -int256(sizeWei), Usdc.wrap(margin), none);
        big.close(none);
        vm.stopPrank();
        assertLe(_bal(traders[3]), margin, "trader never gains from rounding");
        assertEq(usdc.balanceOf(address(big)), Usdc.unwrap(big.vaultCash()), "everything left is vault cash");
        assertEq(big.entryNotional(), 0, "the unrealised-PnL basis returns to zero");
    }

    // ───────────── T2: conservation under random histories ─────────────

    // Without this, a bookkeeping slip (OI not reduced on liquidation, entry index taken before accrual,
    // cash moved without a ledger entry) would leave the protocol quietly insolvent or mispricing p.
    // Checks after every step: (1) USDC held == vaultCash + sum of deposits; (2) longOI/shortOI equal the
    // positions; (3) funding attribution: the vault side, integrated by the test as -skew x dIndex at
    // every touch, equals minus the sum over positions of size x (exitIndex or now - entryIndex).
    int256 vaultSide36;
    int256 closedSide36;

    function testFuzz_T2_randomHistories(uint256 seed) public {
        uint256 price = P0;
        int256 c;
        for (uint256 step = 0; step < 30; step++) {
            uint256 r = uint256(keccak256(abi.encode(seed, step)));
            vm.warp(block.timestamp + 1 + r % 2000); // the feed needs a newer second per post
            c += int256((r >> 8) % 11) * APR_1PCT - 5 * APR_1PCT; // the relayer posts every step
            _post(c);
            c = feed.rate(0);
            price = price * (9_700 + (r >> 16) % 600) / 10_000;
            _price(price, 0);
            address who = traders[(r >> 32) % 4];
            uint256 action = (r >> 40) % 5;
            int256 skewBefore = eng.skew();
            int256 iBefore = eng.fundingIndex();
            if (action <= 1 && _size(who) == 0) {
                int256 size = int256(1e17 + (r >> 48) % 5e18) * ((r >> 120) % 2 == 0 ? int256(1) : int256(-1));
                uint256 margin = uint256(size > 0 ? size : -size) * (price / 1e18) / 1e12 / (2 + (r >> 128) % 8) + 1e6;
                vm.prank(who);
                try eng.open(size, Usdc.wrap(margin), none) {
                    _checkCapacity(price);
                } catch {
                    continue;
                }
            } else if (action == 2 && _size(who) != 0) {
                _recordExit(who, true);
                _close(who);
                _finishExit();
            } else if (action == 3 && _size(who) != 0) {
                _recordExit(who, false);
                vm.prank(keeper);
                try eng.liquidate(who, none) {
                    _finishExit();
                } catch {
                    _pendingSize = 0;
                }
            } else if (action == 4 && _size(who) != 0) {
                vm.prank(who);
                eng.addMargin(Usdc.wrap(1e6 + (r >> 56) % 1_000e6));
            } else {
                eng.poke(none);
            }
            vaultSide36 += -skewBefore * (eng.fundingIndex() - iBefore);
            _checkInvariants();
        }
    }

    int256 _pendingSize;
    int256 _pendingEntry;

    function _recordExit(address who, bool) internal {
        (int256 s,, int256 e,) = eng.positions(who);
        _pendingSize = s;
        _pendingEntry = e;
    }

    function _finishExit() internal {
        closedSide36 += _pendingSize * (eng.fundingIndex() - _pendingEntry);
        _pendingSize = 0;
    }

    /// After every successful open: the vault survives a 25% move against the larger side, net of profit owed.
    function _checkCapacity(uint256 price) internal view {
        uint256 maxSide = eng.longOI() > eng.shortOI() ? eng.longOI() : eng.shortOI();
        int256 stress = int256(maxSide * price / 1e18 / 4);
        int256 owed = eng.skew() * int256(price) / 1e18 - eng.entryNotional();
        assertGe(int256(_vault()) * 1e12 - (owed > 0 ? owed : int256(0)), stress, "vault capacity after open");
    }

    function _floorMul(int256 s, uint256 p) internal pure returns (int256) {
        int256 x = s * int256(p);
        return x >= 0 ? x / 1e18 : -((-x + 1e18 - 1) / 1e18);
    }

    function _checkInvariants() internal view {
        uint256 deposits;
        uint256 longs;
        uint256 shorts;
        int256 openSide36;
        int256 basis;
        int256 idx = eng.fundingIndex();
        for (uint256 i = 0; i < traders.length; i++) {
            (int256 s, MarginStatic d, int256 e,) = eng.positions(traders[i]);
            deposits += MarginStatic.unwrap(d);
            if (s > 0) longs += uint256(s);
            if (s < 0) shorts += uint256(-s);
            openSide36 += s * (idx - e);
            (,,, uint256 ep) = eng.positions(traders[i]);
            basis += _floorMul(s, ep);
        }
        assertEq(eng.entryNotional(), basis, "unrealised-PnL basis equals the positions");
        assertEq(usdc.balanceOf(address(eng)), _vault() + deposits, "cash ledger");
        assertEq(eng.longOI(), longs, "longOI");
        assertEq(eng.shortOI(), shorts, "shortOI");
        assertEq(vaultSide36, -(closedSide36 + openSide36), "funding attribution");
    }
}
