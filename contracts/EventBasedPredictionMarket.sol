// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@uma/core/contracts/common/implementation/ExpandedERC20.sol";
import "@uma/core/contracts/common/implementation/Testable.sol";
import "@uma/core/contracts/common/implementation/AddressWhitelist.sol";
import "@uma/core/contracts/oracle/implementation/Constants.sol";
import "@uma/core/contracts/oracle/interfaces/OptimisticOracleV2Interface.sol";
import "@uma/core/contracts/oracle/interfaces/IdentifierWhitelistInterface.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/proxy/utils/Initializable.sol";

contract SoundStakePredictionMarket is Initializable,Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for ExpandedERC20;

    // --- Oracle / market state ---
    bool public priceRequested;
    bool public receivedSettlementPrice;
    uint256 public requestTimestamp;
    string public pairName;
    address private _timerAddress;
    // settlementPrice encoding: 0 => NO, 0.5e18 => TIE, 1e18 => YES
    uint256 public settlementPrice;
    bytes32 public priceIdentifier = "YES_OR_NO_QUERY";
    bytes public customAncillaryData;

    // Tokens / external
    ExpandedERC20 public collateralToken;
    FinderInterface public finder;

    // UMA params (defaults can be changed by owner)
    uint256 public proposerReward = 10e18;
    uint256 public optimisticOracleLivenessTime = 3600;
    uint256 public optimisticOracleProposerBond = 500e18;

    // SoundStake params
    uint256 public feeBps; // basis points
    address public treasury;

    // Betting pools
    uint256 public totalYes;
    uint256 public totalNo;

    // Per-user accounting
    mapping(address => uint256) public betsYes;
    mapping(address => uint256) public betsNo;
    mapping(address => bool) public claimed;

    // Betting window (lock)
    uint256 public bettingWindowEnd; // timestamp after which betting is closed
    bool public marketInitialized;

    // Events
    event MarketInitialized(uint256 requestTimestamp, uint256 bettingWindowEnd);
    event BetPlaced(address indexed user, bool indexed isYes, uint256 amount);
    event FeeCollected(address indexed payer, uint256 amount);
    event PriceRequested(bytes32 identifier, uint256 timestamp);
    event PriceSettled(uint256 settlementPrice);
    event WinningsClaimed(address indexed user, uint256 amount);
    event TreasurySwept(uint256 amount);

    modifier onlyWhenBettingOpen() {
        require(marketInitialized, "market not initialized");
        require(block.timestamp <= bettingWindowEnd, "betting closed");
        _;
    }

    modifier onlyAfterSettlement() {
        require(receivedSettlementPrice, "not settled yet");
        _;
    }

   

    // initializer — set what constructor previously set + owner
    function initialize(
        string memory _pairName,
        address _collateralToken,
        bytes memory _customAncillaryData,
        address _finder,
        address _owner,
        bytes32 _priceIdentifier,
        uint256 _proposerReward
    ) external initializer {

    

        // set state
        pairName = _pairName;
        collateralToken = ExpandedERC20(_collateralToken);
        customAncillaryData = _customAncillaryData;
        finder = FinderInterface(_finder);
        priceIdentifier = _priceIdentifier;
        proposerReward = _proposerReward;
        
        // default params (owner can change later)
        optimisticOracleLivenessTime = 3600;
        optimisticOracleProposerBond = 500e18;
        feeBps = 0;
        treasury = address(0);

        // transfer ownership to provided owner
        _transferOwnership(_owner);
    }

    // --- Admin setters ---
    function setFeeBps(uint256 _feeBps) external onlyOwner {
        require(_feeBps <= 1000, "fee too high"); // max 10%
        feeBps = _feeBps;
    }

    function setTreasury(address _treasury) external onlyOwner {
        require(_treasury != address(0), "zero treasury");
        treasury = _treasury;
    }
function getCurrentTime() public view returns (uint256) {
    
        return block.timestamp;
    
}
    function setProposerReward(uint256 _r) external onlyOwner {
        proposerReward = _r;
    }

    function setOptimisticParams(uint256 _liveness, uint256 _bond) external onlyOwner {
        optimisticOracleLivenessTime = _liveness;
        optimisticOracleProposerBond = _bond;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @notice Initialize market: request price from OO and open betting window for `bettingWindowSeconds`.
     * Caller must fund proposerReward (if >0).
     */
    function initializeMarket(uint256 bettingWindowSeconds) external whenNotPaused {
        require(!marketInitialized, "already initialized");

        // fund proposerReward
        if (proposerReward > 0) {
            collateralToken.safeTransferFrom(msg.sender, address(this), proposerReward);
        }

        requestTimestamp = getCurrentTime();
        _requestOraclePrice();

        bettingWindowEnd = block.timestamp + bettingWindowSeconds;
        marketInitialized = true;

        emit MarketInitialized(requestTimestamp, bettingWindowEnd);
    }

    /**
     * @notice place a YES bet
     */
    function betYes(uint256 amount) external whenNotPaused onlyWhenBettingOpen nonReentrant {
        require(amount > 0, "amount=0");
        _collectStake(msg.sender, amount);
        betsYes[msg.sender] += amount;
        totalYes += amount;
        emit BetPlaced(msg.sender, true, amount);
    }

    /**
     * @notice place a NO bet
     */
    function betNo(uint256 amount) external whenNotPaused onlyWhenBettingOpen nonReentrant {
        require(amount > 0, "amount=0");
        _collectStake(msg.sender, amount);
        betsNo[msg.sender] += amount;
        totalNo += amount;
        emit BetPlaced(msg.sender, false, amount);
    }

    // internal helper to pull stake and fee
    function _collectStake(address from, uint256 amount) internal {
        uint256 fee = (amount * feeBps) / 10000;
        uint256 net = amount;
        if (fee > 0) {
            net = amount - fee;
            collateralToken.safeTransferFrom(from, treasury, fee);
            emit FeeCollected(from, fee);
        }
        // transfer net amount to contract (note: require approval)
        collateralToken.safeTransferFrom(from, address(this), net);
    }

    /**
     * @notice Oracle callback when price is settled
     */
    function priceSettled(
        bytes32 identifier,
        uint256 timestamp,
        bytes memory ancillaryData,
        int256 price
    ) external {
        OptimisticOracleV2Interface optimisticOracle = getOptimisticOracle();
        require(msg.sender == address(optimisticOracle), "not authorized");
        require(identifier == priceIdentifier, "identifier mismatch");
        require(keccak256(ancillaryData) == keccak256(customAncillaryData), "ancillary mismatch");
        if (timestamp != requestTimestamp) return;

        if (price >= 1e18) {
            settlementPrice = 1e18; // YES
        } else if (price == 5e17) {
            settlementPrice = 5e17; // TIE
        } else {
            settlementPrice = 0; // NO
        }

        receivedSettlementPrice = true;
        emit PriceSettled(settlementPrice);
    }

    /**
     * @notice Oracle callback when price disputed (we re-request)
     */
    function priceDisputed(
        bytes32 identifier,
        uint256 timestamp,
        bytes memory ancillaryData,
        uint256 refund
    ) external {
        OptimisticOracleV2Interface optimisticOracle = getOptimisticOracle();
        require(msg.sender == address(optimisticOracle), "not authorized");
        require(timestamp == requestTimestamp, "different timestamps");
        require(identifier == priceIdentifier, "identifier mismatch");
        require(keccak256(ancillaryData) == keccak256(customAncillaryData), "ancillary mismatch");
        require(refund == proposerReward, "proposerReward mismatch");

        // bump the request timestamp and re-request
        requestTimestamp = getCurrentTime();
        _requestOraclePrice();
    }

    /**
     * @notice Claim winnings after settlement
     */
    function claimWinnings() external whenNotPaused nonReentrant onlyAfterSettlement {
        require(!claimed[msg.sender], "already claimed");
        uint256 payout = 0;

        // TIE: refund stakes (no change)
        if (settlementPrice == 5e17) {
            uint256 r1 = betsYes[msg.sender];
            uint256 r2 = betsNo[msg.sender];
            payout = r1 + r2;
        } else if (settlementPrice == 1e18) {
            // YES wins
            uint256 userYes = betsYes[msg.sender];
            require(userYes > 0, "no winning stake");
            uint256 winningPool = totalYes;
            uint256 losingPool = totalNo;

            if (winningPool == 0) {
                // no winners -> sweep losingPool to treasury
                if (losingPool > 0) {
                    collateralToken.safeTransfer(treasury, losingPool);
                    emit TreasurySwept(losingPool);
                    totalNo = 0;
                }
                payout = 0;
            } else {
                // payout = userYes * (totalYes + totalNo) / totalYes
                uint256 totalPot = totalYes + totalNo;
                payout = (userYes * totalPot) / winningPool;
            }
        } else { // settlementPrice == 0 => NO wins
            uint256 userNo = betsNo[msg.sender];
            require(userNo > 0, "no winning stake");
            uint256 winningPool = totalNo;
            uint256 losingPool = totalYes;

            if (winningPool == 0) {
                if (losingPool > 0) {
                    collateralToken.safeTransfer(treasury, losingPool);
                    emit TreasurySwept(losingPool);
                    totalYes = 0;
                }
                payout = 0;
            } else {
                uint256 totalPot = totalYes + totalNo;
                payout = (userNo * totalPot) / winningPool;
            }
        }

        // mark claimed for both sides to prevent double claim
        claimed[msg.sender] = true;

        // clear user bets to save gas and avoid reclaims (optional)
        betsYes[msg.sender] = 0;
        betsNo[msg.sender] = 0;

        if (payout > 0) {
            collateralToken.safeTransfer(msg.sender, payout);
            emit WinningsClaimed(msg.sender, payout);
        } else {
            emit WinningsClaimed(msg.sender, 0);
        }
    }

    // --- Internal helpers for Optimistic Oracle interactions ---
    function _requestOraclePrice() internal {
        OptimisticOracleV2Interface optimisticOracle = getOptimisticOracle();

        collateralToken.safeApprove(address(optimisticOracle), proposerReward);

        optimisticOracle.requestPrice(
            priceIdentifier,
            requestTimestamp,
            customAncillaryData,
            collateralToken,
            proposerReward
        );

        optimisticOracle.setCustomLiveness(
            priceIdentifier,
            requestTimestamp,
            customAncillaryData,
            optimisticOracleLivenessTime
        );

        optimisticOracle.setBond(priceIdentifier, requestTimestamp, customAncillaryData, optimisticOracleProposerBond);

        optimisticOracle.setEventBased(priceIdentifier, requestTimestamp, customAncillaryData);

        // priceDisputed = true, priceSettled = true, priceProposed = false
        optimisticOracle.setCallbacks(priceIdentifier, requestTimestamp, customAncillaryData, false, true, true);

        priceRequested = true;
        emit PriceRequested(priceIdentifier, requestTimestamp);
    }

    function getOptimisticOracle() internal view returns (OptimisticOracleV2Interface) {
        return OptimisticOracleV2Interface(finder.getImplementationAddress("OptimisticOracleV2"));
    }

    function _getIdentifierWhitelist() internal view returns (IdentifierWhitelistInterface) {
        return IdentifierWhitelistInterface(finder.getImplementationAddress(OracleInterfaces.IdentifierWhitelist));
    }

    function _getAddressWhitelist() internal view returns (AddressWhitelist) {
        return AddressWhitelist(finder.getImplementationAddress(OracleInterfaces.CollateralWhitelist));
    }

    // --- Emergency admin actions ---
    /**
     * @notice Owner can sweep stuck ERC20 collateral (careful).
     */
    function sweepToken(address token, address to, uint256 amount) external onlyOwner {
        require(to != address(0), "zero dest");
        IERC20(token).transfer(to, amount);
    }
}


