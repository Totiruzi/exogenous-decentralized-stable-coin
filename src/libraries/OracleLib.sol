// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/**
 * @title OracleLib
 * @author Onowu Chris
 * @notice This contract is used to check the chainLink Oracle for stale data.
 * If a price is stale, the function will revert and reder the DSCEngine unusable by design
 *
 * We want the engine to freez if the price becomes stale
 *
 * So if the chanLink network explodes and you have a lot of money in the protocal..... "you are screed hahahahah; but not funny"
 */
library OracleLib {
    error OracleLib__StalePrice();

    uint256 private constant TIMIOUT = 3 hours;

    function staleCheckLatestRoundData(AggregatorV3Interface priceFeed)
        public
        view
        returns (uint80, int256, uint256, uint256, uint80)
    {
        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            priceFeed.latestRoundData();

        uint256 secondsSinceUpdated = block.timestamp - updatedAt;

        if (secondsSinceUpdated > TIMIOUT) revert OracleLib__StalePrice();

        return (roundId, answer, startedAt, updatedAt, answeredInRound);
    }
}
