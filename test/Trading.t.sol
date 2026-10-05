// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ConsensusFeed} from "../src/ConsensusFeed.sol";
import {PerpEngine} from "../src/PerpEngine.sol";
import {TestUSDC} from "../src/TestUSDC.sol";
import {Usdc, UsdWad, MarginStatic, MarginDynamic} from "../src/lib/Units.sol";
import {MockPriceSource} from "./harness/MockPriceSource.sol";
import {TestParams} from "./Params.sol";

/// Trading flows: commit and settle opens and closes, add margin, liquidate.
/// T2, T5, T6, T8, T11, T12, T13 and an end-to-end settlement.
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
    uint64 constant DELAY = 2; // Config: settleDelay

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

    function _commitOpen(address who, int256 size, uint256 margin) internal {
        vm.prank(who);
        eng.commitOpen(size, Usdc.wrap(margin));
    }

    function _commitClose(address who) internal {
        vm.prank(who);
        eng.commitClose();
    }

    /// Moves time to the order's fill time if needed, then a keeper settles it at the mock's price.
    function _settle(address who) internal {
        (,, uint64 t,) = eng.orders(who);
        if (block.timestamp < t + DELAY) vm.warp(t + DELAY);
        vm.prank(keeper);
        eng.settle(who, none);
    }

    function _open(address who, int256 size, uint256 margin) internal {
        _commitOpen(who, size, margin);
        _settle(who);
    }

    function _close(address who) internal {
        _commitClose(who);
        _settle(who);
    }

    /// Settles and asserts the open was rejected with `sel`, its margin refunded and no position created.
    function _settleExpectRejected(address who, bytes4 sel) internal {
        (, Usdc margin,,) = eng.orders(who);
        uint256 b0 = _bal(who);
        vm.recordLogs();
        _settle(who);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes4 got;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == PerpEngine.OrderRejected.selector) {
                got = bytes4(abi.decode(logs[i].data, (bytes)));
            }
        }
        assertEq(got, sel, "rejection reason");
        assertEq(_bal(who) - b0, Usdc.unwrap(margin), "margin refunded");
        assertEq(_size(who), 0, "no position");
        assertEq(Usdc.unwrap(eng.escrowCash()), 0, "escrow released");
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
        _commitOpen(traders[0], 1e18, 10_100e6); // long 1 BTC, fee 50
        _commitOpen(traders[1], -1e18, 10_100e6); // short 1 BTC, same second
        _settle(traders[0]);
        _settle(traders[1]); // both fill in the same second: skew 0, so p stays 0
        uint256 vaultAfterOpen = _vault();
        assertEq(vaultAfterOpen, SEED + 100e6);

        vm.warp(block.timestamp + 1 days);
        _post(5 * APR_1PCT); // keep the feed fresh at the same rate
        _price(P0, 0);
        uint256 a0 = _bal(traders[0]);
        uint256 b0 = _bal(traders[1]);
        _commitClose(traders[0]);
        _commitClose(traders[1]);
        _settle(traders[0]);
        _settle(traders[1]);

        // funding per BTC for one day plus the 2 s settlement delay at 5% APR on 100,000 USD
        uint256 fundingWad = uint256(100_000 * 5 * APR_1PCT * (86_400 + 2));
        uint256 up = (fundingWad + 1e12 - 1) / 1e12;
        uint256 down = fundingWad / 1e12;
        assertEq(_bal(traders[0]) - a0, 10_050e6 - 50e6 - up, "long pays c (rounded against the trader)");
        assertEq(_bal(traders[1]) - b0, 10_050e6 - 50e6 + down, "short receives c (rounded down)");
        assertEq(_vault(), vaultAfterOpen + 100e6 + (up - down), "vault: close fees plus rounding dust");
        assertEq(eng.longOI() + eng.shortOI(), 0);
    }

    // Without this, a liquidation could pay the liquidator from nowhere or hide bad debt.
    function test_liquidationPaysRewardAndRecordsShortfall() public {
        _open(traders[0], 1e18, 10_050e6); // 10x long, deposit 10,000
        _price(85_000e18, 0); // -15% in the second it filled: no funding, so equity is exactly -5,000
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
        eng.poke(none);

        px.set(P0, 0, uint64(block.timestamp - 6)); // older than the price the open filled at
        vm.expectRevert(
            abi.encodeWithSelector(
                PerpEngine.PriceOlderThanLast.selector, uint64(block.timestamp - 6), uint64(block.timestamp - 5)
            )
        );
        vm.prank(keeper);
        eng.liquidate(traders[0], none);

        _price(P0, 0);
        _commitClose(traders[0]);
        (,, uint64 t,) = eng.orders(traders[0]);
        px.setPinnedAt(t + DELAY - 1); // a print from before the fill time
        vm.warp(t + DELAY);
        vm.expectRevert(abi.encodeWithSelector(PerpEngine.PriceOutsideWindow.selector, t + 1, t + 2, t + 2 + 60));
        eng.settle(traders[0], none);
        px.setPinnedAt(0);

        vm.expectRevert(PerpEngine.NoPosition.selector);
        _commitClose(traders[1]);
        vm.expectRevert(PerpEngine.NoPosition.selector);
        eng.liquidate(traders[1], none);
        vm.expectRevert(PerpEngine.NoOrder.selector);
        eng.settle(traders[1], none);
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
        _commitOpen(traders[2], 1e18, 10_050e6);
        eng.setOpensPaused(true);
        vm.expectRevert(PerpEngine.OpensArePaused.selector);
        _commitOpen(traders[2], 1e18, 10_050e6);

        _close(traders[0]); // close still works
        _price(80_000e18, 0);
        vm.prank(keeper);
        eng.liquidate(traders[1], none); // liquidation still works
        assertEq(eng.longOI(), 0);
    }

    // Without this, an open could be priced off a wide-confidence (uncertain) print, or a bad fill would
    // revert and leave the order stuck: it is rejected at settlement and the margin goes back.
    function test_T6_wideConfidenceRejectsOpenAtSettlement() public {
        _commitOpen(traders[0], 1e18, 10_050e6);
        _price(P0, P0 / 100 + 1); // conf just above 1% of price at the fill time
        _settleExpectRejected(traders[0], PerpEngine.ConfidenceTooWide.selector);
    }

    // Without this, a pause or a dead feed between commit and fill would still let the open through.
    function test_T6_pauseBetweenCommitAndFillRejects() public {
        _commitOpen(traders[0], 1e18, 10_050e6);
        eng.setOpensPaused(true);
        _settleExpectRejected(traders[0], PerpEngine.OpensArePaused.selector);
    }

    // ───────────── T11 / T13: prices for bots, pinned prices for orders ─────────────

    // F6 regression. Without this, the latest-price window could drift and a liquidator could pick a wick
    // several seconds old. Liquidate and poke take a price at most 3 s old.
    function test_T11_ageWindows() public {
        _open(traders[0], 1e18, 10_050e6);
        vm.warp(block.timestamp + 20);
        px.set(80_000e18, 0, uint64(block.timestamp - 4));
        vm.expectRevert(abi.encodeWithSelector(PerpEngine.PriceTooOld.selector, uint64(block.timestamp - 4), uint64(3)));
        eng.liquidate(traders[0], none);
        px.set(80_000e18, 0, uint64(block.timestamp - 3));
        eng.liquidate(traders[0], none); // 3 s is allowed

        vm.warp(block.timestamp + 5); // past the price just used, so only the age check can fire
        px.set(P0, 0, uint64(block.timestamp - 4));
        vm.expectRevert(abi.encodeWithSelector(PerpEngine.PriceTooOld.selector, uint64(block.timestamp - 4), uint64(3)));
        eng.poke(none);
        px.set(P0, 0, uint64(block.timestamp - 3));
        eng.poke(none);
    }

    // T13. Without this, an order nobody settles would lock the trader's margin forever, or an order could be
    // filled long after the fact. After the window it can only be cancelled, and the margin comes back.
    function test_T13_expiredOrderCanOnlyBeCancelled() public {
        uint256 b0 = _bal(traders[0]);
        _commitOpen(traders[0], 1e18, 10_050e6);
        (,, uint64 t,) = eng.orders(traders[0]);
        vm.expectRevert(abi.encodeWithSelector(PerpEngine.OrderNotExpired.selector, t + DELAY + 60));
        eng.cancelExpired(traders[0]);
        vm.warp(t + DELAY + 61);
        vm.expectRevert(abi.encodeWithSelector(PerpEngine.OrderExpired.selector, t + DELAY + 60));
        eng.settle(traders[0], none);
        eng.cancelExpired(traders[0]);
        assertEq(_bal(traders[0]), b0, "margin back");
        assertEq(Usdc.unwrap(eng.escrowCash()), 0);
    }

    // T13. Without this, two orders from one account could race, or a stale close order could act on a
    // position that was liquidated in the meantime.
    function test_T13_oneOrderAtATimeAndLiquidationClearsAPendingClose() public {
        _commitOpen(traders[0], 1e18, 10_050e6);
        vm.expectRevert(PerpEngine.OrderPending.selector);
        _commitOpen(traders[0], 1e18, 10_050e6);
        _settle(traders[0]);

        _commitClose(traders[0]);
        _price(80_000e18, 0);
        eng.liquidate(traders[0], none);
        (,, uint64 t,) = eng.orders(traders[0]);
        assertEq(t, 0, "the pending close went with the position");
        vm.expectRevert(PerpEngine.NoOrder.selector);
        eng.settle(traders[0], none);
    }

    // T13. Without this, a trader settling their own order could refuse an unfavourable fill by giving the
    // call too little gas, so the open fails inside and is "rejected" with a refund: the free option again.
    // No gas limit may turn a valid order into a rejection; the call either fills it or reverts whole.
    function test_T13_noGasLimitTurnsAFillIntoARejection() public {
        _commitOpen(traders[0], 1e18, 10_050e6);
        (,, uint64 t,) = eng.orders(traders[0]);
        vm.warp(t + DELAY);
        uint256 snap = vm.snapshotState();
        uint256 fills;
        for (uint256 g = 100_000; g <= 700_000; g += 5_000) {
            try eng.settle{gas: g}(traders[0], none) {
                assertEq(_size(traders[0]), 1e18, "a settle that returns has filled the order");
                fills++;
            } catch {
                (,, uint64 still,) = eng.orders(traders[0]);
                assertEq(still, t, "a settle that fails leaves the order pending");
            }
            vm.revertToState(snap);
        }
        assertGt(fills, 0, "some gas limit is enough");
    }

    // F4. Without this, trades would execute at the oracle mid, and a trader who opens on a print up to 3 s old
    // and closes on the latest one would pocket any fast move from the vault. Execution is moved by the
    // confidence interval against the trader, a spread that widens exactly when the oracle is unsure.
    function test_F4_tradesExecuteAtConfidenceAgainstTheTrader() public {
        _price(P0, 30e18);
        _commitOpen(traders[0], 1e18, 10_100e6);
        _commitOpen(traders[1], -1e18, 10_100e6);
        _settle(traders[0]);
        _settle(traders[1]); // same second, skew 0: no funding moves
        (,,, uint256 longEntry) = eng.positions(traders[0]);
        assertEq(longEntry, P0 + 30e18, "long buys at price + conf");
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
        _commitOpen(traders[0], 1, 1e6);
    }

    // F1 + F3 regression. Without this, open interest could be stacked on one side by opening hedge legs and
    // closing them (closes are never capped), until a small move drains the vault and winners cannot close.
    // Each open must leave the vault solvent after a 25% move with the larger side unhedged.
    function test_F1F3_vaultCapacityBoundsEachSide() public {
        // 1,000,000 vault / (100,000 x 25%) = 40 BTC per side
        _open(traders[0], 40e18, 402_000e6);
        _commitOpen(traders[1], 1e18, 10_100e6); // one more long: over capacity
        _settleExpectRejected(traders[1], PerpEngine.VaultCapacityExceeded.selector);
        _open(traders[1], -40e18, 402_000e6); // the other side may grow to the same size
        _close(traders[1]); // the hedge leaves: skew is now +40, still covered
        _commitOpen(traders[2], 1e18, 10_100e6);
        _settleExpectRejected(traders[2], PerpEngine.VaultCapacityExceeded.selector);
    }

    // F3. Without this, unrealised profit already owed to traders would count as vault capacity: after a rally,
    // the vault's cash is still there but much of it is spoken for.
    function test_F3_capacityIsNetOfProfitAlreadyOwed() public {
        _open(traders[0], 30e18, 301_600e6);
        vm.warp(block.timestamp + 1);
        _post(0);
        _price(120_000e18, 0); // longs are up 600,000
        // 30 BTC x 120,000 x 25% = 900,000 of stress > 1,000,000 + fees - 600,000 owed
        _commitOpen(traders[1], -1e18, 12_100e6);
        _settleExpectRejected(traders[1], PerpEngine.VaultCapacityExceeded.selector);
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
        big.commitOpen(isLong ? int256(sizeWei) : -int256(sizeWei), Usdc.wrap(margin));
        vm.warp(block.timestamp + DELAY);
        big.settle(traders[3], none);
        assertEq(big.longOI() + big.shortOI(), sizeWei, "filled");
        big.commitClose();
        vm.warp(block.timestamp + DELAY);
        big.settle(traders[3], none); // the trader settling their own orders gains nothing either
        vm.stopPrank();
        assertLe(_bal(traders[3]), margin, "trader never gains from rounding");
        assertEq(usdc.balanceOf(address(big)), Usdc.unwrap(big.vaultCash()), "everything left is vault cash");
        assertEq(big.entryNotional(), 0, "the unrealised-PnL basis returns to zero");
    }

    // ───────────── T2: conservation under random histories ─────────────

    // Without this, a bookkeeping slip (OI not reduced on liquidation, entry index taken before accrual,
    // cash moved without a ledger entry) would leave the protocol quietly insolvent or mispricing p.
    // Checks after every step: (1) USDC held == vaultCash + escrow + deposits; (2) longOI/shortOI equal the
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
            if (action <= 1 && _size(who) == 0) {
                int256 size = int256(1e17 + (r >> 48) % 5e18) * ((r >> 120) % 2 == 0 ? int256(1) : int256(-1));
                uint256 margin = uint256(size > 0 ? size : -size) * (price / 1e18) / 1e12 / (2 + (r >> 128) % 8) + 1e6;
                _commitOpen(who, size, margin);
                _checkInvariants(); // the margin sits in escrow
                vm.warp(block.timestamp + DELAY);
            } else if (action == 2 && _size(who) != 0) {
                _commitClose(who);
                vm.warp(block.timestamp + DELAY);
            }
            int256 skewBefore = eng.skew();
            int256 iBefore = eng.fundingIndex();
            (,, uint64 pending, bool isClose) = eng.orders(who);
            if (pending != 0 && !isClose) {
                _settle(who);
                if (_size(who) != 0) _checkCapacity(price);
            } else if (pending != 0) {
                _recordExit(who, true);
                _settle(who);
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
        uint256 escrow;
        for (uint256 i = 0; i < traders.length; i++) {
            (, Usdc m,,) = eng.orders(traders[i]);
            escrow += Usdc.unwrap(m);
        }
        assertEq(Usdc.unwrap(eng.escrowCash()), escrow, "escrow equals the open orders");
        assertEq(usdc.balanceOf(address(eng)), _vault() + Usdc.unwrap(eng.escrowCash()) + deposits, "cash ledger");
        assertEq(eng.longOI(), longs, "longOI");
        assertEq(eng.shortOI(), shorts, "shortOI");
        assertEq(vaultSide36, -(closedSide36 + openSide36), "funding attribution");
    }
}
