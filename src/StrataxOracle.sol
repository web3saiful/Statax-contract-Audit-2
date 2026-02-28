// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {AggregatorV3Interface} from "./interfaces/external/AggregatorV3Interface.sol";

contract StrataxOracle {
    address public owner;

    // Mapping from token address to Chainlink price feed address
    mapping(address => address) public priceFeeds;

    event PriceFeedUpdated(address indexed token, address indexed priceFeed);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    constructor() {
        owner = msg.sender;
    }

    /**
     * @notice Sets the Chainlink price feed address for a token
     * @param _token The token address
     * @param _priceFeed The Chainlink price feed address for this token
     */
    function setPriceFeed(address _token, address _priceFeed) external onlyOwner {
        _setPriceFeed(_token, _priceFeed);
        emit PriceFeedUpdated(_token, _priceFeed);
    }

    /**
     * @notice Sets multiple price feeds at once
     * @param _tokens Array of token addresses
     * @param _priceFeeds Array of corresponding price feed addresses
     */
    function setPriceFeeds(address[] calldata _tokens, address[] calldata _priceFeeds) external onlyOwner {
        require(_tokens.length == _priceFeeds.length, "Array length mismatch");

        for (uint256 i = 0; i < _tokens.length; i++) {
            _setPriceFeed(_tokens[i], _priceFeeds[i]);
            emit PriceFeedUpdated(_tokens[i], _priceFeeds[i]);
        }
    }

    function _setPriceFeed(address _token, address _priceFeed) internal {
        require(_token != address(0), "Invalid token address");
        require(_priceFeed != address(0), "Invalid price feed address");

        AggregatorV3Interface priceFeed = AggregatorV3Interface(_priceFeed);
        require(priceFeed.decimals() == 8, "Price feed must have 8 decimals");

        priceFeeds[_token] = _priceFeed;
    }
    /**
     * @notice Gets the latest price for a token from Chainlink
     * @param _token The token address
     * @return price which is has 8 decimals of precision
     * @dev Chainlink price feeds that do not have 8 decimals are not supported
     */
// @audit
    function getPrice(address _token) public view returns (uint256 price) {
        address priceFeedAddress = priceFeeds[_token];
        require(priceFeedAddress != address(0), "Price feed not set for token");

        AggregatorV3Interface priceFeed = AggregatorV3Interface(priceFeedAddress);

        (, int256 answer,,,) = priceFeed.latestRoundData();
        require(answer > 0, "Invalid price from oracle");

        price = uint256(answer);
    }

    /**
     * @notice Gets the decimals for a token's price feed
     * @param _token The token address
     * @return decimals The number of decimals in the price feed
     */
    function getPriceDecimals(address _token) public view returns (uint8 decimals) {
        address priceFeedAddress = priceFeeds[_token];
        require(priceFeedAddress != address(0), "Price feed not set for token");

        AggregatorV3Interface priceFeed = AggregatorV3Interface(priceFeedAddress);
        decimals = priceFeed.decimals();
    }

    /**
     * @notice Gets the full round data for a token's price feed
     * @param _token The token address
     * @return roundId The round ID
     * @return answer The price
     * @return startedAt Timestamp when the round started
     * @return updatedAt Timestamp when the round was updated
     * @return answeredInRound The round ID in which the answer was computed
     */
    function getRoundData(address _token)
        public
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        address priceFeedAddress = priceFeeds[_token];
        require(priceFeedAddress != address(0), "Price feed not set for token");

        AggregatorV3Interface priceFeed = AggregatorV3Interface(priceFeedAddress);
        (roundId, answer, startedAt, updatedAt, answeredInRound) = priceFeed.latestRoundData();
    }


    /**
     * @notice Transfers ownership of the contract
     * @param _newOwner The address of the new owner
     */
    function transferOwnership(address _newOwner) external onlyOwner {
        require(_newOwner != address(0), "Invalid address");
        address previousOwner = owner;
        owner = _newOwner;
        emit OwnershipTransferred(previousOwner, _newOwner);
    }
}
