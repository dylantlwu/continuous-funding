// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IPyth} from "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import {PythStructs} from "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";
import {IPriceSource} from "./interfaces/IPriceSource.sol";
import {IPythUnique} from "./interfaces/IPythUnique.sol";

/// Adapter over the Pyth pull oracle for one feed.
/// Freshness and monotonicity are enforced by the engine (it knows the last price it used);
/// this adapter only applies the update and converts units. Pyth itself never lets an older
/// update overwrite a newer stored price.
contract PythPriceSource is IPriceSource {
    IPyth public immutable pyth;
    bytes32 public immutable feedId;

    error NonPositivePrice(int64 price);
    error InsufficientFee(uint256 sent, uint256 fee);
    error RefundFailed();

    constructor(IPyth pyth_, bytes32 feedId_) {
        pyth = pyth_;
        feedId = feedId_;
    }

    function updateFee(bytes[] calldata updateData) public view returns (uint256) {
        return updateData.length == 0 ? 0 : pyth.getUpdateFee(updateData);
    }

    function update(bytes[] calldata updateData)
        external
        payable
        returns (uint256 priceWad, uint256 confWad, uint64 publishTime)
    {
        uint256 fee = _takeFee(updateData);
        if (updateData.length > 0) pyth.updatePriceFeeds{value: fee}(updateData);
        (priceWad, confWad, publishTime) = _convert(pyth.getPriceUnsafe(feedId));
        _refundExcess(fee);
    }

    function firstPriceAfter(bytes[] calldata updateData, uint64 minTime, uint64 maxTime)
        external
        payable
        returns (uint256 priceWad, uint256 confWad, uint64 publishTime)
    {
        uint256 fee = _takeFee(updateData);
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = feedId;
        PythStructs.PriceFeed[] memory feeds =
            IPythUnique(address(pyth)).parsePriceFeedUpdatesUnique{value: fee}(updateData, ids, minTime, maxTime);
        (priceWad, confWad, publishTime) = _convert(feeds[0].price);
        _refundExcess(fee);
    }

    function _takeFee(bytes[] calldata updateData) private view returns (uint256 fee) {
        fee = updateFee(updateData);
        if (msg.value < fee) revert InsufficientFee(msg.value, fee);
    }

    function _convert(PythStructs.Price memory p)
        private
        pure
        returns (uint256 priceWad, uint256 confWad, uint64 publishTime)
    {
        if (p.price <= 0) revert NonPositivePrice(p.price);
        priceWad = _toWad(uint256(uint64(p.price)), p.expo);
        confWad = _toWad(uint256(p.conf), p.expo);
        publishTime = uint64(p.publishTime);
    }

    function _refundExcess(uint256 fee) private {
        if (msg.value > fee) {
            (bool ok,) = msg.sender.call{value: msg.value - fee}("");
            if (!ok) revert RefundFailed();
        }
    }

    function _toWad(uint256 v, int32 expo) private pure returns (uint256) {
        int256 shift = 18 + int256(expo);
        return shift >= 0 ? v * 10 ** uint256(shift) : v / 10 ** uint256(-shift);
    }
}
