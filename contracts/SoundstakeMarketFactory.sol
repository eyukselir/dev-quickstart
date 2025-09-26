// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/proxy/Clones.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

interface ISoundStakePredictionMarketClone {
    function initialize(
        string memory _pairName,
        address _collateralToken,
        bytes memory _customAncillaryData,
        address _finder,
        address _owner,
        bytes32 _priceIdentifier,
        uint256 _proposerReward
    ) external;
}

contract MarketFactoryClones is Ownable {
    using Clones for address;

    address public implementation; // address of the master contract
    address[] public markets;

    event MarketCreated(address indexed market, address indexed creator, string pairName);

    constructor(address _implementation) {
        implementation = _implementation;
    }

    function setImplementation(address _imp) external onlyOwner {
        implementation = _imp;
    }

    function createMarket(
        string calldata _pairName,
        address _collateralToken,
        bytes calldata _customAncillaryData,
        address _finder,
        bytes32 _priceIdentifier,
        uint256 _proposerReward
    ) external returns (address) {
        address clone = implementation.clone(); // non-deterministic
        // initialize the clone
        ISoundStakePredictionMarketClone(clone).initialize(
            _pairName,
            _collateralToken,
            _customAncillaryData,
            _finder,
            msg.sender,           // owner of the clone = caller
            _priceIdentifier,
            _proposerReward
        );

        markets.push(clone);
        emit MarketCreated(clone, msg.sender, _pairName);
        return clone;
    }

    // Optionally: deterministic clone via CREATE2
    function createMarketDeterministic(/* include salt param */) external returns (address) {
        // use implementation.cloneDeterministic(salt)
        // then initialize
    }

    function getMarkets() external view returns (address[] memory) {
        return markets;
    }
}


