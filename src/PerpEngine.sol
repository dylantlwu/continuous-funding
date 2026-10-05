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
/// Trades are two-step: commit (no price), then anyone settles at the first oracle price after a fixed
/// delay, which the oracle proves is the first. Liquidation and poke use the latest price (bots).
///
/// Cash ledger: USDC held = vaultCash + escrowCash + sum of position deposits. Nothing else.
contract PerpEngine is ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Params {
        int256 w; // |p| <= w, per second, 1e18
        int256 velocity; // dp/dt at full imbalance, per second^2, 1e18
        uint256 skewScale; // |skew| at which imbalance is "full" (base units, 1e18)
        uint256 stressMove; // opens must leave the vault solvent after this adverse move, 1e18
        uint256 minSize; // smallest position (base units, 1e18)
        uint256 maxSize; // largest position per account (base units, 1e18)
        uint256 initialMarginRate; // of notional, 1e18 (0.1e18 = 10x)
        uint256 maintenanceMarginRate; // of notional, 1e18
        uint256 tradeFeeRate; // of notional, open and close, to the vault, 1e18
        uint256 liquidationFeeRate; // of notional, to the liquidator, 1e18
        uint256 maxOpenConfRate; // opens revert if conf > price * this, 1e18
        uint64 maxPriceAge; // seconds, for the latest-price paths (liquidate, poke)
        uint64 settleDelay; // orders fill at the first oracle price this many seconds after commit
        uint64 orderTtl; // an order not settled within this many seconds may be cancelled
    }

    /// A committed order, waiting for the first oracle price after `commitTime + settleDelay`.
    struct Order {
        int256 size; // open: signed size; close: 0
        Usdc margin; // open: cash held in escrow until settlement
        uint64 commitTime; // 0 = no order
        bool isClose;
    }

    struct Position {
        int256 size; // base units, 1e18; positive = long
        MarginStatic deposit; // what the trader put in (after the open fee)
        int256 entryIndex; // fundingIndex at open
        uint256 entryPrice; // execution price at open, 1e18
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
    uint256 public immutable stressMove;
    uint256 public immutable minSize;
    uint256 public immutable maxSize;
    uint256 public immutable initialMarginRate;
    uint256 public immutable maintenanceMarginRate;
    uint256 public immutable tradeFeeRate;
    uint256 public immutable liquidationFeeRate;
    uint256 public immutable maxOpenConfRate;
    uint64 public immutable maxPriceAge;
    uint64 public immutable settleDelay;
    uint64 public immutable orderTtl;

    // market state
    uint256 public longOI;
    uint256 public shortOI;
    int256 public premium; // p at lastTime
    uint64 public lastTime;
    int256 public fundingIndex; // cumulative funding per base unit, USD 1e18
    uint256 public lastPrice; // price at the last touch, prices the next accrual interval
    int256 public cCumAtLast; // feed.cumulative() read at lastTime
    uint64 public lastPublishTime; // newest oracle publish time used; prices may not go back
    int256 public entryNotional; // sum over positions of size x entryPrice (USD 1e18): unrealised PnL basis

    Usdc public vaultCash;
    Usdc public escrowCash; // margins of open orders not yet settled
    bool public opensPaused;
    mapping(address => Position) public positions;
    mapping(address => Order) public orders;

    event OrderCommitted(address indexed account, int256 size, Usdc margin, bool isClose, uint64 settleAt);
    event OrderRejected(address indexed account, bytes reason, Usdc feeKept);
    event OrderCancelled(address indexed account);
    event MarketUpdated(uint64 time, int256 premium, int256 fundingIndex, uint256 price, int256 consensusRate);
    event Opened(address indexed account, int256 size, uint256 price, Usdc deposit, Usdc fee);
    event Closed(
        address indexed account, int256 size, uint256 price, UsdWad pnl, UsdWad funding, Usdc fee, Usdc payout
    );
    event Liquidated(
        address indexed account, address indexed liquidator, int256 size, uint256 price, uint256 conf, Usdc reward
    );
    event Shortfall(address indexed account, UsdWad amount);
    event MarginAdded(address indexed account, Usdc amount);
    event VaultSeeded(Usdc amount);
    event VaultWithdrawn(Usdc amount);
    event OpensPaused(bool paused);

    error NotOwner();
    error OpensArePaused();
    error FeedStale();
    error PositionExists();
    error NoPosition();
    error PriceOlderThanLast(uint64 publishTime, uint64 last);
    error PriceTooOld(uint64 publishTime, uint64 maxAge);
    error ConfidenceTooWide(uint256 price, uint256 conf);
    error VaultCapacityExceeded(UsdWad stressLoss, UsdWad available);
    error BelowMinSize(uint256 size, uint256 minSize);
    error AboveMaxSize(uint256 size, uint256 maxSize);
    error MarginBelowFee(Usdc margin, Usdc fee);
    error InsufficientMargin(MarginStatic deposit, MarginDynamic required);
    error NotLiquidatable(UsdWad equity, MarginDynamic maintenance);
    error VaultInsolvent(Usdc needed, Usdc available);
    error OpenInterestNotZero();
    error RefundFailed();
    error InsufficientOracleFee(uint256 sent, uint256 fee);
    error ZeroPrice();
    error OrderPending();
    error NoOrder();
    error OrderExpired(uint64 deadline);
    error OrderNotExpired(uint64 deadline);
    error OnlySelf();
    error PriceOutsideWindow(uint64 publishTime, uint64 minTime, uint64 maxTime);
    error SettlementOutOfGas();

    constructor(IERC20 usdc_, ConsensusFeed feed_, uint8 feedMarket_, IPriceSource priceSource_, Params memory p) {
        usdc = usdc_;
        feed = feed_;
        feedMarket = feedMarket_;
        priceSource = priceSource_;
        owner = msg.sender;
        w = p.w;
        velocity = p.velocity;
        skewScale = p.skewScale;
        stressMove = p.stressMove;
        minSize = p.minSize;
        maxSize = p.maxSize;
        initialMarginRate = p.initialMarginRate;
        maintenanceMarginRate = p.maintenanceMarginRate;
        tradeFeeRate = p.tradeFeeRate;
        liquidationFeeRate = p.liquidationFeeRate;
        maxOpenConfRate = p.maxOpenConfRate;
        maxPriceAge = p.maxPriceAge;
        settleDelay = p.settleDelay;
        orderTtl = p.orderTtl;
        lastTime = uint64(block.timestamp);
        cCumAtLast = feed_.cumulative(feedMarket_);
    }

    // ───────────────────────────── trading ─────────────────────────────

    /// Step 1 of an open: commit size and margin (the margin includes the open fee), with no price.
    /// The order fills at the first oracle price published `settleDelay` seconds or more after this block,
    /// so the trader cannot know the fill price when signing and nobody can choose it afterwards.
    function commitOpen(int256 size, Usdc margin) external nonReentrant {
        if (_abs(size) < minSize) revert BelowMinSize(_abs(size), minSize);
        if (_abs(size) > maxSize) revert AboveMaxSize(_abs(size), maxSize);
        if (opensPaused) revert OpensArePaused();
        if (feed.isStale(feedMarket)) revert FeedStale();
        if (positions[msg.sender].size != 0) revert PositionExists();
        if (orders[msg.sender].commitTime != 0) revert OrderPending();
        orders[msg.sender] = Order(size, margin, uint64(block.timestamp), false);
        escrowCash = escrowCash + margin;
        usdc.safeTransferFrom(msg.sender, address(this), Usdc.unwrap(margin));
        emit OrderCommitted(msg.sender, size, margin, false, uint64(block.timestamp) + settleDelay);
    }

    /// Step 1 of a close. Never blocked by the feed, the pause or the vault capacity: it reduces risk.
    function commitClose() external nonReentrant {
        if (positions[msg.sender].size == 0) revert NoPosition();
        if (orders[msg.sender].commitTime != 0) revert OrderPending();
        orders[msg.sender] = Order(0, Usdc.wrap(0), uint64(block.timestamp), true);
        emit OrderCommitted(msg.sender, 0, Usdc.wrap(0), true, uint64(block.timestamp) + settleDelay);
    }

    /// Step 2, permissionless: fill `account`'s order at the first oracle price published at or after
    /// `commitTime + settleDelay`, which the oracle proves is the first. The settler supplies the signed
    /// update but has no choice of price. An open that fails its checks at that price (margin, vault
    /// capacity, confidence, a pause) is rejected and its margin refunded, so no order can block the queue.
    function settle(address account, bytes[] calldata priceUpdate) external payable nonReentrant {
        Order memory o = orders[account];
        if (o.commitTime == 0) revert NoOrder();
        uint64 at = o.commitTime + settleDelay;
        if (block.timestamp > at + orderTtl) revert OrderExpired(at + orderTtl);
        (uint256 price, uint256 conf, uint64 publishTime, uint256 oracleFee) =
            _pinnedPrice(priceUpdate, at, at + orderTtl);
        delete orders[account];
        _touch(price, publishTime);

        if (o.isClose) {
            _close(account, price, conf);
        } else {
            escrowCash = escrowCash - o.margin;
            try this.executeOpen(account, o.size, o.margin, price, conf) {}
            catch (bytes memory reason) {
                // An empty reason is how running out of gas looks. Rejecting then would let a trader who
                // settles their own order refuse an unfavourable fill by sending too little gas.
                if (reason.length == 0) revert SettlementOutOfGas();
                // Margin is the trader's choice: committing too little and being refunded whenever the print
                // moves against you would be a free option. That rejection keeps the open fee; rejections the
                // trader cannot cause (pause, stale feed, vault capacity, oracle confidence) refund in full.
                Usdc kept = _isMarginShortfall(reason) ? _rejectionFee(o, price, conf) : Usdc.wrap(0);
                vaultCash = vaultCash + kept;
                usdc.safeTransfer(account, Usdc.unwrap(o.margin - kept));
                emit OrderRejected(account, reason, kept);
            }
        }
        _refund(oracleFee);
    }

    /// If nobody settled the order in time, anyone may cancel it; an open order's margin goes back.
    function cancelExpired(address account) external nonReentrant {
        Order memory o = orders[account];
        if (o.commitTime == 0) revert NoOrder();
        uint64 deadline = o.commitTime + settleDelay + orderTtl;
        if (block.timestamp <= deadline) revert OrderNotExpired(deadline);
        delete orders[account];
        if (!o.isClose) {
            escrowCash = escrowCash - o.margin;
            usdc.safeTransfer(account, Usdc.unwrap(o.margin));
        }
        emit OrderCancelled(account);
    }

    /// Called only by `settle`, through an external self-call so that a failed check rolls back every
    /// change it made and `settle` can reject the order instead of reverting.
    function executeOpen(address account, int256 size, Usdc margin, uint256 price, uint256 conf) external {
        if (msg.sender != address(this)) revert OnlySelf();
        if (opensPaused) revert OpensArePaused();
        if (feed.isStale(feedMarket)) revert FeedStale();
        if (conf * WAD > price * maxOpenConfRate) revert ConfidenceTooWide(price, conf);

        uint256 exec = _execPrice(price, conf, size > 0);
        (MarginStatic deposit, Usdc fee) = _depositAfterFee(_abs(size), exec, margin);
        if (size > 0) longOI += uint256(size);
        else shortOI += uint256(-size);
        Position storage pos = positions[account];
        pos.size = size;
        pos.deposit = deposit;
        pos.entryIndex = fundingIndex;
        pos.entryPrice = exec;
        entryNotional += _entryTerm(size, exec);
        vaultCash = vaultCash + fee;
        _requireVaultCapacity(price);
        emit Opened(account, size, exec, Units.cash(deposit), fee);
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
        (uint256 price, uint256 conf, uint64 publishTime, uint256 oracleFee) = _latestPrice(priceUpdate);
        if (pos.size < 0 && conf >= price) revert ConfidenceTooWide(price, conf);
        _touch(price, publishTime);
        if (orders[account].isClose) delete orders[account]; // the position it would close is gone

        uint256 checkPrice = pos.size > 0 ? price + conf : price - conf;
        (bool liquidatable, UsdWad equity, MarginDynamic maintenance) = _liquidationCheck(pos, checkPrice);
        if (!liquidatable) revert NotLiquidatable(equity, maintenance);

        Usdc reward = Units.toUsdcDown(
            UsdWad.wrap(
                WadMath.mulDivFloor(_notionalDown(_abs(pos.size), checkPrice), SafeCast.toInt(liquidationFeeRate), WAD)
            )
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
        (uint256 price,, uint64 publishTime, uint256 oracleFee) = _latestPrice(priceUpdate);
        _touch(price, publishTime);
        _refund(oracleFee);
    }

    function _close(address account, uint256 price, uint256 conf) internal {
        Position memory pos = positions[account];
        uint256 exec = _execPrice(price, conf, pos.size < 0);
        (UsdWad pnl, UsdWad funding) = _pnlAndFunding(pos, exec);
        int256 notional = _notionalUp(_abs(pos.size), exec);
        UsdWad feeWad = UsdWad.wrap(WadMath.mulDivCeil(notional, SafeCast.toInt(tradeFeeRate), WAD));
        UsdWad equity = Units.staticWad(pos.deposit) + pnl - funding - feeWad;
        Usdc payout = UsdWad.unwrap(equity) > 0 ? Units.toUsdcDown(equity) : Usdc.wrap(0);

        _removePosition(account, pos);
        _settleWithVault(pos.deposit, payout);
        if (UsdWad.unwrap(equity) < 0) emit Shortfall(account, UsdWad.wrap(-UsdWad.unwrap(equity)));

        if (Usdc.unwrap(payout) > 0) usdc.safeTransfer(account, Usdc.unwrap(payout));
        emit Closed(account, pos.size, exec, pnl, funding, Units.toUsdcUp(feeWad), payout);
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
        int256 den =
            pos.size - WadMath.mulDivFloor(SafeCast.toInt(_abs(pos.size)), SafeCast.toInt(maintenanceMarginRate), WAD);
        if (den == 0) return 0;
        int256 px = WadMath.mulDivFloor(num, int256(WAD), uint256(den > 0 ? den : -den));
        if (den < 0) px = -px;
        return px > 0 ? uint256(px) : 0;
    }

    // ───────────────────────────── internals ─────────────────────────────

    /// Accrue funding up to now at the PREVIOUS price, then record the new price for the next interval.
    /// The caller picks the new price (within the age window), so it must not price time already passed.
    /// A settlement price can be older than the latest one already used (orders settle in any order), so
    /// it moves `lastPrice` only if it is at least as new.
    function _touch(uint256 newPrice, uint64 publishTime) internal {
        (int256 index, int256 p, int256 cCum) = _project();
        fundingIndex = index;
        premium = p;
        cCumAtLast = cCum;
        lastTime = uint64(block.timestamp);
        if (publishTime >= lastPublishTime) {
            lastPrice = newPrice;
            lastPublishTime = publishTime;
        }
        emit MarketUpdated(uint64(block.timestamp), p, index, lastPrice, feed.rate(feedMarket));
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

    /// Latest price, for bots (liquidate, poke): no older than the last price used, at most `maxPriceAge`.
    function _latestPrice(bytes[] calldata update)
        internal
        returns (uint256 price, uint256 conf, uint64 publishTime, uint256 oracleFee)
    {
        oracleFee = _oracleFee(update);
        (price, conf, publishTime) = priceSource.update{value: oracleFee}(update);
        if (price == 0) revert ZeroPrice(); // the adapter checks too; never value a position at zero
        if (publishTime < lastPublishTime) revert PriceOlderThanLast(publishTime, lastPublishTime);
        // a publish time slightly ahead of block.timestamp (clock skew) counts as age 0
        if (block.timestamp > publishTime && block.timestamp - publishTime > maxPriceAge) {
            revert PriceTooOld(publishTime, maxPriceAge);
        }
    }

    /// The first price at or after `minTime`, proven first by the oracle (order settlement).
    function _pinnedPrice(bytes[] calldata update, uint64 minTime, uint64 maxTime)
        internal
        returns (uint256 price, uint256 conf, uint64 publishTime, uint256 oracleFee)
    {
        oracleFee = _oracleFee(update);
        (price, conf, publishTime) = priceSource.firstPriceAfter{value: oracleFee}(update, minTime, maxTime);
        if (price == 0) revert ZeroPrice();
        if (publishTime < minTime || publishTime > maxTime) {
            revert PriceOutsideWindow(publishTime, minTime, maxTime); // the oracle checks too
        }
    }

    function _oracleFee(bytes[] calldata update) internal view returns (uint256 fee) {
        fee = priceSource.updateFee(update);
        if (msg.value < fee) revert InsufficientOracleFee(msg.value, fee);
    }

    /// Opens only. After the open, the vault must stay solvent through an adverse move of `stressMove` with
    /// the LARGER side unhedged (closes are never blocked, so the other side may leave at any time), net of
    /// the unrealised profit it already owes traders. Funding owed is not counted (small, disclosed).
    function _requireVaultCapacity(uint256 price) internal view {
        uint256 maxSide = longOI > shortOI ? longOI : shortOI;
        int256 stress = WadMath.mulDivCeil(_notionalUp(maxSide, price), SafeCast.toInt(stressMove), WAD);
        int256 owed = WadMath.mulDivCeil(skew(), SafeCast.toInt(price), WAD) - entryNotional;
        int256 available = UsdWad.unwrap(Units.toWad(vaultCash)) - (owed > 0 ? owed : int256(0));
        if (available < stress) revert VaultCapacityExceeded(UsdWad.wrap(stress), UsdWad.wrap(available));
    }

    /// Trades execute at the oracle price moved by its confidence AGAINST the trader: buying (open long,
    /// close short) at price + conf, selling at price - conf. A spread that widens when the oracle is unsure.
    function _execPrice(uint256 price, uint256 conf, bool buy) internal pure returns (uint256) {
        if (buy) return price + conf;
        if (conf >= price) revert ConfidenceTooWide(price, conf);
        return price - conf;
    }

    /// One position's term in `entryNotional`. Same inputs on open and removal, so it cancels exactly.
    function _entryTerm(int256 size, uint256 entryPrice) internal pure returns (int256) {
        return WadMath.mulDivFloor(size, SafeCast.toInt(entryPrice), WAD);
    }

    function _isMarginShortfall(bytes memory reason) internal pure returns (bool) {
        bytes4 sel = bytes4(reason);
        return sel == InsufficientMargin.selector || sel == MarginBelowFee.selector;
    }

    /// The open fee the order would have paid at its fill price, never more than its margin.
    function _rejectionFee(Order memory o, uint256 price, uint256 conf) internal view returns (Usdc) {
        Usdc fee = _tradeFee(_abs(o.size), _execPrice(price, conf, o.size > 0));
        return fee > o.margin ? o.margin : fee;
    }

    /// The open fee on `absSize` at `price`, rounded up to cash: the same rule for opens and for rejections.
    function _tradeFee(uint256 absSize, uint256 price) internal view returns (Usdc) {
        return
            Units.toUsdcUp(
                UsdWad.wrap(WadMath.mulDivCeil(_notionalUp(absSize, price), SafeCast.toInt(tradeFeeRate), WAD))
            );
    }

    /// Open fee first, then the rest must cover initial margin (both rounded against the trader).
    function _depositAfterFee(uint256 absSize, uint256 price, Usdc margin)
        internal
        view
        returns (MarginStatic deposit, Usdc fee)
    {
        int256 notional = _notionalUp(absSize, price);
        fee = _tradeFee(absSize, price);
        if (margin < fee) revert MarginBelowFee(margin, fee);
        deposit = Units.deposit(margin - fee);
        MarginDynamic initial =
            Units.required(UsdWad.wrap(WadMath.mulDivCeil(notional, SafeCast.toInt(initialMarginRate), WAD)));
        if (!Margin.canOpen(deposit, initial)) revert InsufficientMargin(deposit, initial);
    }

    /// Rounded in the trader's FAVOUR (pnl up, funding down, maintenance down): the protocol may fail
    /// to liquidate by dust, it can never liquidate a position that is healthy in exact arithmetic (T5).
    function _liquidationCheck(Position memory pos, uint256 price)
        internal
        view
        returns (bool liquidatable, UsdWad equity, MarginDynamic maintenance)
    {
        UsdWad pnl =
            UsdWad.wrap(WadMath.mulDivCeil(pos.size, SafeCast.toInt(price) - SafeCast.toInt(pos.entryPrice), WAD));
        UsdWad funding = UsdWad.wrap(WadMath.mulDivFloor(pos.size, fundingIndex - pos.entryIndex, WAD));
        maintenance = Units.requiredDown(
            UsdWad.wrap(
                WadMath.mulDivFloor(_notionalDown(_abs(pos.size), price), SafeCast.toInt(maintenanceMarginRate), WAD)
            )
        );
        equity = Units.staticWad(pos.deposit) + pnl - funding;
        liquidatable = Margin.isLiquidatable(pos.deposit, pnl, funding, maintenance);
    }

    /// For payouts: rounded AGAINST the trader, so rounding never pays out cash the vault does not have.
    function _pnlAndFunding(Position memory pos, uint256 price) internal view returns (UsdWad pnl, UsdWad funding) {
        pnl = UsdWad.wrap(WadMath.mulDivFloor(pos.size, SafeCast.toInt(price) - SafeCast.toInt(pos.entryPrice), WAD));
        funding = UsdWad.wrap(WadMath.mulDivCeil(pos.size, fundingIndex - pos.entryIndex, WAD));
    }

    function _removePosition(address account, Position memory pos) internal {
        if (pos.size > 0) longOI -= uint256(pos.size);
        else shortOI -= uint256(-pos.size);
        entryNotional -= _entryTerm(pos.size, pos.entryPrice);
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
