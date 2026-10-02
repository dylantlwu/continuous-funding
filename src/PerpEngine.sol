// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ConsensusFeed} from "./ConsensusFeed.sol";
import {IPriceSource} from "./interfaces/IPriceSource.sol";
import {Funding} from "./lib/Funding.sol";
import {Usdc, UsdWad, MarginStatic, MarginDynamic, Units, Margin, SafeCast, WadMath} from "./lib/Units.sol";

/// One oracle-priced perpetual market (BTC) against an owner-seeded vault.
///
/// Funding rate = c + p, both per second (1e18), positive = longs pay:
///   c  cross-venue consensus, posted to ConsensusFeed by a relayer (integral read from the feed);
///   p  own-imbalance premium: dp/dt = V * clamp(skew / skewScale, -1, 1), |p| <= w.
/// Every touch accrues both with closed-form integrals on one clock (seconds), so how often the
/// market is touched does not change what is owed. All funding settles against the vault.
///
/// Cash ledger: USDC held = vaultCash + sum of position deposits. Nothing else.
contract PerpEngine is ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Params {
        int256 w;                       // |p| <= w, per second, 1e18
        int256 velocity;                // dp/dt at full imbalance, per second^2, 1e18
        uint256 skewScale;              // |skew| at which imbalance is "full" (base units, 1e18)
        uint256 skewCap;                // opens may not push |skew| above this, unless they reduce it
        uint256 oiCap;                  // opens may not push longOI + shortOI above this
        uint256 initialMarginRate;      // of notional, 1e18 (0.1e18 = 10x)
        uint256 maintenanceMarginRate;  // of notional, 1e18
        uint256 tradeFeeRate;           // of notional, open and close, to the vault, 1e18
        uint256 liquidationFeeRate;     // of notional, to the liquidator, 1e18
        uint256 maxOpenConfRate;        // opens revert if conf > price * this, 1e18
        uint64 maxTradePriceAge;        // seconds
        uint64 maxLiquidationPriceAge;  // seconds
    }

    struct Position {
        int256 size;           // base units, 1e18; positive = long
        MarginStatic deposit;  // what the trader put in (after the open fee)
        int256 entryIndex;     // fundingIndex at open
        uint256 entryPrice;    // 1e18
    }

    uint256 private constant WAD = 1e18;

    IERC20 public immutable usdc;
    ConsensusFeed public immutable feed;
    uint8 public immutable feedMarket;
    IPriceSource public immutable priceSource;
    address public immutable owner;

    int256 public immutable w;
    int256 public immutable velocity;
    uint256 public immutable skewScale;
    uint256 public immutable skewCap;
    uint256 public immutable oiCap;
    uint256 public immutable initialMarginRate;
    uint256 public immutable maintenanceMarginRate;
    uint256 public immutable tradeFeeRate;
    uint256 public immutable liquidationFeeRate;
    uint256 public immutable maxOpenConfRate;
    uint64 public immutable maxTradePriceAge;
    uint64 public immutable maxLiquidationPriceAge;

    // market state
    uint256 public longOI;
    uint256 public shortOI;
    int256 public premium;          // p at lastTime
    uint64 public lastTime;
    int256 public fundingIndex;     // cumulative funding per base unit, USD 1e18
    uint256 public lastPrice;       // price at the last touch, prices the next accrual interval
    int256 public cCumAtLast;       // feed.cumulative() read at lastTime
    uint64 public lastPublishTime;  // newest oracle publish time used; prices may not go back

    Usdc public vaultCash;
    bool public opensPaused;
    mapping(address => Position) public positions;

    event MarketUpdated(uint64 time, int256 premium, int256 fundingIndex, uint256 price, int256 consensusRate);
    event Opened(address indexed account, int256 size, uint256 price, Usdc deposit, Usdc fee);
    event Closed(address indexed account, int256 size, uint256 price, UsdWad pnl, UsdWad funding, Usdc fee, Usdc payout);
    event Liquidated(
        address indexed account, address indexed liquidator, int256 size, uint256 price, uint256 conf, Usdc reward
    );
    event Shortfall(address indexed account, UsdWad amount);
    event MarginAdded(address indexed account, Usdc amount);
    event VaultSeeded(Usdc amount);
    event VaultWithdrawn(Usdc amount);
    event OpensPaused(bool paused);

    error NotOwner();
    error ZeroSize();
    error OpensArePaused();
    error FeedStale();
    error PositionExists();
    error NoPosition();
    error PriceOlderThanLast(uint64 publishTime, uint64 last);
    error PriceTooOld(uint64 publishTime, uint64 maxAge);
    error ConfidenceTooWide(uint256 price, uint256 conf);
    error OiCapExceeded(uint256 oi, uint256 cap);
    error SkewCapExceeded(int256 skew, uint256 cap);
    error MarginBelowFee(Usdc margin, Usdc fee);
    error InsufficientMargin(MarginStatic deposit, MarginDynamic required);
    error NotLiquidatable(UsdWad equity, MarginDynamic maintenance);
    error VaultInsolvent(Usdc needed, Usdc available);
    error OpenInterestNotZero();
    error RefundFailed();
    error InsufficientOracleFee(uint256 sent, uint256 fee);

    constructor(IERC20 usdc_, ConsensusFeed feed_, uint8 feedMarket_, IPriceSource priceSource_, Params memory p) {
        usdc = usdc_;
        feed = feed_;
        feedMarket = feedMarket_;
        priceSource = priceSource_;
        owner = msg.sender;
        w = p.w;
        velocity = p.velocity;
        skewScale = p.skewScale;
        skewCap = p.skewCap;
        oiCap = p.oiCap;
        initialMarginRate = p.initialMarginRate;
        maintenanceMarginRate = p.maintenanceMarginRate;
        tradeFeeRate = p.tradeFeeRate;
        liquidationFeeRate = p.liquidationFeeRate;
        maxOpenConfRate = p.maxOpenConfRate;
        maxTradePriceAge = p.maxTradePriceAge;
        maxLiquidationPriceAge = p.maxLiquidationPriceAge;
        lastTime = uint64(block.timestamp);
        cCumAtLast = feed_.cumulative(feedMarket_);
    }

    // ───────────────────────────── trading ─────────────────────────────

    /// Open a new isolated position. `margin` includes the open fee, which is taken first.
    function open(int256 size, Usdc margin, bytes[] calldata priceUpdate) external payable nonReentrant {
        if (size == 0) revert ZeroSize();
        if (opensPaused) revert OpensArePaused();
        if (feed.isStale(feedMarket)) revert FeedStale();
        Position storage pos = positions[msg.sender];
        if (pos.size != 0) revert PositionExists();

        (uint256 price, uint256 conf, uint256 oracleFee) = _readPrice(priceUpdate, maxTradePriceAge);
        if (conf * WAD > price * maxOpenConfRate) revert ConfidenceTooWide(price, conf);
        _touch(price);

        _addOpenInterest(size);
        (MarginStatic deposit, Usdc fee) = _depositAfterFee(_abs(size), price, margin);

        pos.size = size;
        pos.deposit = deposit;
        pos.entryIndex = fundingIndex;
        pos.entryPrice = price;
        vaultCash = vaultCash + fee;

        usdc.safeTransferFrom(msg.sender, address(this), Usdc.unwrap(margin));
        emit Opened(msg.sender, size, price, Units.cash(deposit), fee);
        _refund(oracleFee);
    }

    /// Close the whole position. Never blocked by the feed, the pause or the caps: it reduces risk.
    function close(bytes[] calldata priceUpdate) external payable nonReentrant {
        Position memory pos = positions[msg.sender];
        if (pos.size == 0) revert NoPosition();
        (uint256 price,, uint256 oracleFee) = _readPrice(priceUpdate, maxTradePriceAge);
        _touch(price);

        (UsdWad pnl, UsdWad funding) = _pnlAndFunding(pos, price);
        int256 notional = _notionalUp(_abs(pos.size), price);
        UsdWad feeWad = UsdWad.wrap(WadMath.mulDivCeil(notional, SafeCast.toInt(tradeFeeRate), WAD));
        UsdWad equity = Units.staticWad(pos.deposit) + pnl - funding - feeWad;
        Usdc payout = UsdWad.unwrap(equity) > 0 ? Units.toUsdcDown(equity) : Usdc.wrap(0);

        _removePosition(msg.sender, pos);
        _settleWithVault(pos.deposit, payout);
        if (UsdWad.unwrap(equity) < 0) emit Shortfall(msg.sender, UsdWad.wrap(-UsdWad.unwrap(equity)));

        if (Usdc.unwrap(payout) > 0) usdc.safeTransfer(msg.sender, Usdc.unwrap(payout));
        emit Closed(msg.sender, pos.size, price, pnl, funding, Units.toUsdcUp(feeWad), payout);
        _refund(oracleFee);
    }

    function addMargin(Usdc amount) external nonReentrant {
        Position storage pos = positions[msg.sender];
        if (pos.size == 0) revert NoPosition();
        pos.deposit = Units.addCash(pos.deposit, amount);
        usdc.safeTransferFrom(msg.sender, address(this), Usdc.unwrap(amount));
        emit MarginAdded(msg.sender, amount);
    }

    /// Permissionless. Health is checked at the confidence-adjusted price in the trader's favour
    /// (long: price + conf, short: price - conf), so a wide-confidence wick cannot liquidate a healthy
    /// position. Reverts NotLiquidatable rather than ever liquidating on a doubtful computation.
    function liquidate(address account, bytes[] calldata priceUpdate) external payable nonReentrant {
        Position memory pos = positions[account];
        if (pos.size == 0) revert NoPosition();
        (uint256 price, uint256 conf, uint256 oracleFee) = _readPrice(priceUpdate, maxLiquidationPriceAge);
        if (pos.size < 0 && conf >= price) revert ConfidenceTooWide(price, conf);
        _touch(price);

        uint256 checkPrice = pos.size > 0 ? price + conf : price - conf;
        (UsdWad pnl, UsdWad funding) = _pnlAndFunding(pos, checkPrice);
        int256 notional = _notionalUp(_abs(pos.size), checkPrice);
        MarginDynamic maintenance =
            Units.required(UsdWad.wrap(WadMath.mulDivCeil(notional, SafeCast.toInt(maintenanceMarginRate), WAD)));
        UsdWad equity = Units.staticWad(pos.deposit) + pnl - funding;
        if (!Margin.isLiquidatable(pos.deposit, pnl, funding, maintenance)) revert NotLiquidatable(equity, maintenance);

        Usdc reward = Units.toUsdcDown(
            UsdWad.wrap(WadMath.mulDivFloor(_notionalDown(_abs(pos.size), checkPrice), SafeCast.toInt(liquidationFeeRate), WAD))
        );
        UsdWad left = equity - Units.toWad(reward);

        _removePosition(account, pos);
        _settleWithVault(pos.deposit, reward); // the trader's remaining equity, if any, stays with the vault
        if (UsdWad.unwrap(left) < 0) emit Shortfall(account, UsdWad.wrap(-UsdWad.unwrap(left)));

        if (Usdc.unwrap(reward) > 0) usdc.safeTransfer(msg.sender, Usdc.unwrap(reward));
        emit Liquidated(account, msg.sender, pos.size, price, conf, reward);
        _refund(oracleFee);
    }

    /// Anyone may bring the market up to date with a fresh price (keeps the accrual price recent).
    function poke(bytes[] calldata priceUpdate) external payable nonReentrant {
        (uint256 price,, uint256 oracleFee) = _readPrice(priceUpdate, maxTradePriceAge);
        _touch(price);
        _refund(oracleFee);
    }

    // ───────────────────────────── vault (owner) ─────────────────────────────

    function seedVault(Usdc amount) external {
        _onlyOwner();
        vaultCash = vaultCash + amount;
        usdc.safeTransferFrom(msg.sender, address(this), Usdc.unwrap(amount));
        emit VaultSeeded(amount);
    }

    /// Only with no open interest: the owner cannot pull cash ahead of traders' unrealised profits.
    function withdrawVault(Usdc amount) external {
        _onlyOwner();
        if (longOI + shortOI != 0) revert OpenInterestNotZero();
        vaultCash = vaultCash - amount;
        usdc.safeTransfer(msg.sender, Usdc.unwrap(amount));
        emit VaultWithdrawn(amount);
    }

    function setOpensPaused(bool paused) external {
        _onlyOwner();
        opensPaused = paused;
        emit OpensPaused(paused);
    }

    // ───────────────────────────── views ─────────────────────────────

    function skew() public view returns (int256) {
        return SafeCast.toInt(longOI) - SafeCast.toInt(shortOI);
    }

    /// Rate right now (per second, 1e18): consensus c, premium p, and c + p.
    function currentRate() external view returns (int256 c, int256 p, int256 total) {
        (, p,) = _project();
        c = feed.rate(feedMarket);
        total = c + p;
    }

    /// fundingIndex as if the market were touched now (at lastPrice).
    function fundingIndexNow() external view returns (int256 index) {
        (index,,) = _project();
    }

    /// PnL and funding owed (as of now, at lastPrice-based accrual) for `account` at `price`.
    function positionValue(address account, uint256 price) external view returns (UsdWad pnl, UsdWad funding) {
        Position memory pos = positions[account];
        (int256 index,,) = _project();
        pnl = UsdWad.wrap(WadMath.mulDivFloor(pos.size, SafeCast.toInt(price) - SafeCast.toInt(pos.entryPrice), WAD));
        funding = UsdWad.wrap(WadMath.mulDivCeil(pos.size, index - pos.entryIndex, WAD));
    }

    /// Price at which equity equals maintenance, given funding owed as of now. 0 if there is none.
    /// Solves deposit + size*(P - entry) - funding = mmr * |size| * P for P.
    /// Display only: liquidation itself is decided by `liquidate`, at the confidence-adjusted price.
    function liquidationPrice(address account) external view returns (uint256) {
        Position memory pos = positions[account];
        if (pos.size == 0) return 0;
        (int256 index,,) = _project();
        int256 funding = WadMath.mulDivCeil(pos.size, index - pos.entryIndex, WAD);
        int256 num = WadMath.mulDivFloor(pos.size, SafeCast.toInt(pos.entryPrice), WAD)
            - UsdWad.unwrap(Units.staticWad(pos.deposit)) + funding;
        int256 den = pos.size - WadMath.mulDivFloor(SafeCast.toInt(_abs(pos.size)), SafeCast.toInt(maintenanceMarginRate), WAD);
        if (den == 0) return 0;
        int256 px = WadMath.mulDivFloor(num, int256(WAD), uint256(den > 0 ? den : -den));
        if (den < 0) px = -px;
        return px > 0 ? uint256(px) : 0;
    }

    // ───────────────────────────── internals ─────────────────────────────

    /// Accrue funding up to now at the PREVIOUS price, then record the new price for the next interval.
    /// The caller picks the new price (within the age window), so it must not price time already passed.
    function _touch(uint256 newPrice) internal {
        (int256 index, int256 p, int256 cCum) = _project();
        fundingIndex = index;
        premium = p;
        cCumAtLast = cCum;
        lastTime = uint64(block.timestamp);
        lastPrice = newPrice;
        emit MarketUpdated(uint64(block.timestamp), p, index, newPrice, feed.rate(feedMarket));
    }

    function _project() internal view returns (int256 index, int256 p, int256 cCum) {
        cCum = feed.cumulative(feedMarket);
        (int256 pIntegral, int256 p1) = Funding.premium(premium, _slope(), w, block.timestamp - lastTime);
        int256 cIntegral = cCum - cCumAtLast;
        index = fundingIndex + WadMath.mulDivFloor(SafeCast.toInt(lastPrice), cIntegral + pIntegral, WAD);
        p = p1;
    }

    /// s = V * clamp(skew / skewScale, -1, 1), per second^2. Constant between touches because skew is.
    function _slope() internal view returns (int256) {
        int256 k = skew();
        int256 scale = SafeCast.toInt(skewScale);
        if (k >= scale) return velocity;
        if (k <= -scale) return -velocity;
        return velocity * k / scale;
    }

    function _readPrice(bytes[] calldata update, uint64 maxAge)
        internal
        returns (uint256 price, uint256 conf, uint256 oracleFee)
    {
        oracleFee = priceSource.updateFee(update);
        if (msg.value < oracleFee) revert InsufficientOracleFee(msg.value, oracleFee);
        uint64 publishTime;
        (price, conf, publishTime) = priceSource.update{value: oracleFee}(update);
        if (publishTime < lastPublishTime) revert PriceOlderThanLast(publishTime, lastPublishTime);
        // a publish time slightly ahead of block.timestamp (clock skew) counts as age 0
        if (block.timestamp > publishTime && block.timestamp - publishTime > maxAge) {
            revert PriceTooOld(publishTime, maxAge);
        }
        lastPublishTime = publishTime;
    }

    /// Caps apply to opens only. A trade that reduces |skew| is allowed even above the skew cap.
    function _addOpenInterest(int256 size) internal {
        int256 oldSkew = skew();
        if (size > 0) longOI += uint256(size);
        else shortOI += uint256(-size);
        if (longOI + shortOI > oiCap) revert OiCapExceeded(longOI + shortOI, oiCap);
        int256 newSkew = skew();
        if (_abs(newSkew) > skewCap && _abs(newSkew) >= _abs(oldSkew)) revert SkewCapExceeded(newSkew, skewCap);
    }

    /// Open fee first, then the rest must cover initial margin (both rounded against the trader).
    function _depositAfterFee(uint256 absSize, uint256 price, Usdc margin)
        internal
        view
        returns (MarginStatic deposit, Usdc fee)
    {
        int256 notional = _notionalUp(absSize, price);
        fee = Units.toUsdcUp(UsdWad.wrap(WadMath.mulDivCeil(notional, SafeCast.toInt(tradeFeeRate), WAD)));
        if (margin < fee) revert MarginBelowFee(margin, fee);
        deposit = Units.deposit(margin - fee);
        MarginDynamic initial =
            Units.required(UsdWad.wrap(WadMath.mulDivCeil(notional, SafeCast.toInt(initialMarginRate), WAD)));
        if (!Margin.canOpen(deposit, initial)) revert InsufficientMargin(deposit, initial);
    }

    function _pnlAndFunding(Position memory pos, uint256 price) internal view returns (UsdWad pnl, UsdWad funding) {
        // both rounded against the trader
        pnl = UsdWad.wrap(WadMath.mulDivFloor(pos.size, SafeCast.toInt(price) - SafeCast.toInt(pos.entryPrice), WAD));
        funding = UsdWad.wrap(WadMath.mulDivCeil(pos.size, fundingIndex - pos.entryIndex, WAD));
    }

    function _removePosition(address account, Position memory pos) internal {
        if (pos.size > 0) longOI -= uint256(pos.size);
        else shortOI -= uint256(-pos.size);
        delete positions[account];
    }

    /// The position's deposit joins the vault, then the vault pays `out`. Reverts if it cannot.
    function _settleWithVault(MarginStatic deposit, Usdc out) internal {
        Usdc available = vaultCash + Units.cash(deposit);
        if (out > available) revert VaultInsolvent(out, available);
        vaultCash = available - out;
    }

    function _notionalUp(uint256 absSize, uint256 price) internal pure returns (int256) {
        return WadMath.mulDivCeil(SafeCast.toInt(absSize), SafeCast.toInt(price), WAD);
    }

    function _notionalDown(uint256 absSize, uint256 price) internal pure returns (int256) {
        return WadMath.mulDivFloor(SafeCast.toInt(absSize), SafeCast.toInt(price), WAD);
    }

    function _refund(uint256 oracleFee) internal {
        if (msg.value > oracleFee) {
            (bool ok,) = msg.sender.call{value: msg.value - oracleFee}("");
            if (!ok) revert RefundFailed();
        }
    }

    function _onlyOwner() internal view {
        if (msg.sender != owner) revert NotOwner();
    }

    function _abs(int256 x) internal pure returns (uint256) {
        return x >= 0 ? uint256(x) : uint256(-x);
    }
}
