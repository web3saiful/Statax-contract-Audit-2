// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;


/**
 * @title AggregatorV3Interface
 * @notice Interface for Chainlink price feed aggregators
 * @dev This interface defines the standard methods for interacting with Chainlink price feeds
 */
interface AggregatorV3Interface {
    /**
     * @notice Returns the number of decimals in the price feed response
     * @return The number of decimals (typically 8 for USD pairs)
     */
    function decimals() external view returns (uint8);

    /**
     * @notice Returns a human-readable description of the aggregator
     * @return The description string (e.g., "ETH / USD")
     */
    function description() external view returns (string memory);

    /**
     * @notice Returns the version number of the aggregator
     * @return The version number
     */
    function version() external view returns (uint256);

    /**
     * @notice Returns data for a specific round
     * @param _roundId The round ID to retrieve data for
     * @return roundId The round ID
     * @return answer The price data for the round
     * @return startedAt Timestamp when the round started
     * @return updatedAt Timestamp when the round was updated
     * @return answeredInRound The round ID in which the answer was computed
     */
    function getRoundData(uint80 _roundId)
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);

    /**
     * @notice Returns data from the latest round
     * @return roundId The round ID
     * @return answer The latest price data
     * @return startedAt Timestamp when the round started
     * @return updatedAt Timestamp when the round was updated
     * @return answeredInRound The round ID in which the answer was computed
     */
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
