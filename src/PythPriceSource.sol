// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IPyth} from "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import {PythStructs} from "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";
import {IPriceSource} from "./interfaces/IPriceSource.sol";

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
        uint256 fee = updateFee(updateData);
        if (msg.value < fee) revert InsufficientFee(msg.value, fee);
        if (updateData.length > 0) pyth.updatePriceFeeds{value: fee}(updateData);
        PythStructs.Price memory p = pyth.getPriceUnsafe(feedId);
        if (p.price <= 0) revert NonPositivePrice(p.price);
        priceWad = _toWad(uint256(uint64(p.price)), p.expo);
        confWad = _toWad(uint256(p.conf), p.expo);
        publishTime = uint64(p.publishTime);
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
