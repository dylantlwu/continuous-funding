// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ConsensusFeed} from "../src/ConsensusFeed.sol";
import {Funding} from "../src/lib/Funding.sol";
import {PerpEngineHarness} from "./harness/PerpEngineHarness.sol";
import {TestParams} from "./Params.sol";

/// Funding core: T1, T3, T7, T10.
contract FundingCoreTest is Test {
    ConsensusFeed feed;
    PerpEngineHarness eng;
    address relayer = address(0xBEEF);
    int256[5] venues;
    int256 constant APR_1PCT = TestParams.APR_1PCT;
    int256 constant W = TestParams.W;
    int256 constant V = TestParams.V;
    uint256 constant PRICE = 100_000e18;

    function setUp() public {
        vm.warp(1_000_000);
        feed = new ConsensusFeed(relayer, 100 * APR_1PCT, 5 * APR_1PCT, 120, 300);
        eng = new PerpEngineHarness(feed, TestParams.defaults());
    }

    function _post(int256 r) internal {
        vm.prank(relayer);
        feed.post(0, r, uint64(block.timestamp), venues);
    }

    // T1. Without this, a units or clock error (hours vs seconds, a missing 1e18) in the index would go
    // unnoticed: with c and p constant, funding per BTC over N seconds must be price x (c + p) x N exactly.
    function test_T1_constantRateAccruesExactly() public {
        _post(10 * APR_1PCT);
        eng.h_setPremium(3 * APR_1PCT);   // skew 0, so p stays where it is
        eng.h_touch(PRICE);
        int256 i0 = eng.fundingIndex();
        uint256 n = 86_400;
        vm.warp(block.timestamp + n);
        eng.h_touch(PRICE);
        assertEq(eng.premium(), 3 * APR_1PCT);
        assertEq(eng.fundingIndex() - i0, int256(PRICE) * 13 * APR_1PCT * int256(n) / 1e18);
    }

    // T1 (bound branch). Without this, a saturated premium could keep growing past w or be integrated
    // as if it were still moving.
    function test_T1_saturatedPremiumAccruesAtW() public {
        _post(0);
        eng.h_setOI(500e18, 0);           // beyond full imbalance: slope is +V
        eng.h_setPremium(W);
        eng.h_touch(PRICE);
        int256 i0 = eng.fundingIndex();
        vm.warp(block.timestamp + 7 days);
        eng.h_touch(PRICE);
        assertEq(eng.premium(), W);
        assertEq(eng.fundingIndex() - i0, int256(PRICE) * W * 7 days / 1e18);
    }

    // T3. Without this, how often someone pokes the market could change what traders owe (a keeper or a
    // trader could game funding by touching or not touching). Feed posts land between touches.
    function testFuzz_T3_touchPathIndependence(uint16[8] memory gaps, int8[8] memory moves, int16 skewBtc) public {
        PerpEngineHarness lazy = new PerpEngineHarness(feed, TestParams.defaults());
        uint256 l = skewBtc > 0 ? uint256(int256(skewBtc)) * 1e18 : 0;
        uint256 s = skewBtc < 0 ? uint256(-int256(skewBtc)) * 1e18 : 0;
        _post(2 * APR_1PCT);
        eng.h_touch(PRICE);
        lazy.h_touch(PRICE);
        eng.h_setOI(l, s);
        lazy.h_setOI(l, s);
        int256 c = 2 * APR_1PCT;
        uint256 touches;
        for (uint256 i = 0; i < 8; i++) {
            vm.warp(block.timestamp + uint256(gaps[i]) + 1);
            c += int256(moves[i]) % 6 * APR_1PCT;                // within the 5%-per-post step cap
            _post(c);
            c = feed.rate(0);
            if (gaps[i] % 3 != 0) {
                eng.h_touch(PRICE);                                // only one engine is touched in between
                touches++;
            }
        }
        vm.warp(block.timestamp + 1234);
        eng.h_touch(PRICE);
        lazy.h_touch(PRICE);
        assertEq(eng.premium(), lazy.premium(), "premium path is exact");
        // dust: each touch truncates the p-integral (< 1 x price/1e18) and floors the index step (< 1)
        uint256 dust = (touches + 2) * (PRICE / 1e18 + 1);
        assertApproxEqAbs(eng.fundingIndex(), lazy.fundingIndex(), dust);
    }

    // T7. Without this, the premium could escape the ±w band (vault risk unbounded) or jump faster than
    // the velocity allows (a trader could be charged a rate nobody saw coming).
    function testFuzz_T7_premiumBoundsAndSpeed(int256 p0, int256 s, uint32 dt) public pure {
        p0 = bound(p0, -W, W);
        s = bound(s, -V, V);
        (int256 integral, int256 p1) = Funding.premium(p0, s, W, dt);
        assertLe(p1 < 0 ? -p1 : p1, W, "|p| <= w");
        int256 moved = p1 - p0;
        assertLe(moved < 0 ? -moved : moved, (s < 0 ? -s : s) * int256(uint256(dt)), "|dp| <= V dt");
        // the integral lies between the path's extremes x dt (p is monotone between touches)
        int256 lo = (p0 < p1 ? p0 : p1) * int256(uint256(dt));
        int256 hi = (p0 > p1 ? p0 : p1) * int256(uint256(dt));
        assertGe(integral, lo - 1);
        assertLe(integral, hi + 1);
    }

    // T7 through the engine. Without this, the engine could feed the library a slope from the wrong skew.
    function test_T7_engineSlopeFollowsSkew() public {
        _post(0);
        eng.h_touch(PRICE);
        eng.h_setOI(0, 50e18);              // half imbalance, shorts heavy: p falls at V/2
        vm.warp(block.timestamp + 3600);
        eng.h_touch(PRICE);
        assertEq(eng.premium(), -(V / 2) * 3600);
        vm.warp(block.timestamp + 30 days); // long enough to hit the bound
        eng.h_touch(PRICE);
        assertEq(eng.premium(), -W);
    }

    struct Golden {
        uint256[] t;
        uint256[] kind;
        int256[] value;
        uint256[] longOI;
        uint256[] shortOI;
        int256[] expIndex;
        int256[] expP;
        uint256[] tol;
    }

    // T10. Without this, the contract could silently diverge from the specification the simulation
    // results rest on. The reference integrates second by second with exact rationals (a different
    // algorithm), so a wrong branch, sign or clock in the closed form would show up here.
    function test_T10_goldenVectors() public {
        string memory j = vm.readFile("test/golden/funding_vectors.json");
        Golden memory g;
        g.t = vm.parseJsonUintArray(j, ".t");
        g.kind = vm.parseJsonUintArray(j, ".kind");
        g.value = vm.parseJsonIntArray(j, ".value");
        g.longOI = vm.parseJsonUintArray(j, ".longOI");
        g.shortOI = vm.parseJsonUintArray(j, ".shortOI");
        g.expIndex = vm.parseJsonIntArray(j, ".expIndex");
        g.expP = vm.parseJsonIntArray(j, ".expP");
        g.tol = vm.parseJsonUintArray(j, ".tol");

        PerpEngineHarness e = new PerpEngineHarness(feed, TestParams.defaults());
        uint256 k;
        for (uint256 i = 0; i < g.t.length; i++) {
            vm.warp(g.t[i]);
            if (g.kind[i] == 0) {
                _post(g.value[i]);
                assertEq(feed.rate(0), g.value[i], "scenario stays inside the feed bounds");
                continue;
            }
            e.h_touch(uint256(g.value[i]));
            e.h_setOI(g.longOI[i], g.shortOI[i]);
            assertEq(e.premium(), g.expP[k], "premium matches exactly");
            assertApproxEqAbs(e.fundingIndex(), g.expIndex[k], g.tol[k], "index within rounding dust");
            k++;
        }
        assertEq(k, g.expIndex.length);
    }
}
