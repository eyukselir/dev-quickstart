// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/proxy/Clones.sol";

interface IEventMarket {
    function initialize(
        string calldata _pairName,
        address _collateralToken,
        bytes calldata _customAncillaryData,
        address _finder,
        address _timerAddress,
        uint256 _resolutionTimestamp,
        address _treasury,
        uint256 _feeBps,
        address _owner
    ) external;
}

contract SoundStakeMarketFactory {
    using Clones for address;

    address public immutable implementation; // template
    address[] public allMarkets;
    event MarketCreated(address indexed market, address indexed creator, string pairName, uint256 resolutionTimestamp);

    constructor(address _implementation) {
        require(_implementation != address(0), "impl 0");
        implementation = _implementation;
    }

    /// @notice Create a new market clone and initialize it
    function createMarket(
        string calldata pairName,
        address collateralToken,
        bytes calldata ancillaryData,
        address finder,
        address timerAddress,
        uint256 resolutionTimestamp,
        address treasury,
        uint256 feeBps,
        address owner
    ) external returns (address) {
        address clone = implementation.clone();
        IEventMarket(clone).initialize(
            pairName,
            collateralToken,
            ancillaryData,
            finder,
            timerAddress,
            resolutionTimestamp,
            treasury,
            feeBps,
            owner
        );
        allMarkets.push(clone);
        emit MarketCreated(clone, msg.sender, pairName, resolutionTimestamp);
        return clone;
    }

    function marketsCount() external view returns (uint256) {
        return allMarkets.length;
    }

    function getAllMarkets() external view returns (address[] memory) {
        return allMarkets;
    }
}
