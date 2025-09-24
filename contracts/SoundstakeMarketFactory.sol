// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.17;

import "./SoundStakePredictionMarket.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract MarketFactory is Ownable {
    address[] public markets;

    event MarketCreated(
        address indexed market,
        address indexed creator,
        string pairName
    );

    /**
     * @notice Create a new SoundStakePredictionMarket
     * @param _pairName readable name for market
     * @param _collateralToken address of collateral ERC20
     * @param _customAncillaryData the UMA question bytes
     * @param _finder UMA Finder contract on that network
     * @param _timerAddress usually address(0) in production
     */
    function createMarket(
        string calldata _pairName,
        address _collateralToken,
        bytes calldata _customAncillaryData,
        address _finder,
        address _timerAddress
    ) external returns (address) {
        SoundStakePredictionMarket m = new SoundStakePredictionMarket(
            _pairName,
            ExpandedERC20(_collateralToken),
            _customAncillaryData,
            FinderInterface(_finder),
            _timerAddress
        );

        // Ownership çağırana devrediliyor (opsiyonel)
        m.transferOwnership(msg.sender);

        markets.push(address(m));
        emit MarketCreated(address(m), msg.sender, _pairName);
        return address(m);
    }

    function getMarkets() external view returns (address[] memory) {
        return markets;
    }
}

