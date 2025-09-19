// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.17;

/*
  Clone-ready EventBasedPredictionMarketSoundStake
  - Converted constructor -> initialize(...) so clones can be used.
  - Uses OpenZeppelin upgradeable base patterns for initializer support.
  - NOTE: Do NOT call initialize() on the implementation (template) contract itself.
*/

import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import "@uma/core/contracts/common/implementation/ExpandedERC20.sol";
import "@uma/core/contracts/common/implementation/Testable.sol";
import "@uma/core/contracts/common/implementation/AddressWhitelist.sol";
import "@uma/core/contracts/oracle/implementation/Constants.sol";

import "@uma/core/contracts/oracle/interfaces/OptimisticOracleV2Interface.sol";
import "@uma/core/contracts/oracle/interfaces/IdentifierWhitelistInterface.sol";
import "@uma/core/contracts/oracle/interfaces/FinderInterface.sol";

contract EventBasedPredictionMarketSoundStakeUpgradeable is Initializable, OwnableUpgradeable, ReentrancyGuardUpgradeable, PausableUpgradeable {
    using SafeERC20Upgradeable for IERC20;
    using SafeERC20Upgradeable for ExpandedERC20;

    // Market state
    bool public priceRequested;
    bool public receivedSettlementPrice;
    uint256 public requestTimestamp; // used to identify this price request to the OO
    uint256 public marketResolutionTimestamp; // human-friendly deadline you pass in (unix)
    string public pairName;

    // settlementPrice 0 .. 1e18 (UMA format)
    uint256 public settlementPrice;
    bytes32 public priceIdentifier; // set in initialize
    int256 public expiryPrice;

    // Contracts / tokens
    ExpandedERC20 public collateralToken;     // EUROC on Sepolia (or mock)
    ExpandedERC20 public longToken;
    ExpandedERC20 public shortToken;
    FinderInterface public finder;

    // Optimistic Oracle params (keep defaults but admin can tune)
    bytes public customAncillaryData;
    uint256 public proposerReward;               // default 0 (safe); can set >0
    uint256 public optimisticOracleLivenessTime; // liveness
    uint256 public optimisticOracleProposerBond; // proposer bond

    // SoundStake fee config
    address public treasury;
    uint256 public feeBps; // basis points; 100 bps = 1%

    // Limits
    uint256 public constant MAX_FEE_BPS = 1000; // safety: <= 10%

    // Events
    event MarketInitialized(uint256 requestTimestamp, bytes ancillaryData);
    event TokensCreated(address indexed sponsor, uint256 collateralIn, uint256 netMinted, uint256 feeTaken);
    event TokensRedeemed(address indexed sponsor, uint256 collateralOut, uint256 tokensRedeemed);
    event PositionSettled(address indexed sponsor, uint256 collateralReturned, uint256 longTokens, uint256 shortTokens);
    event FeeUpdated(uint256 oldBps, uint256 newBps);
    event TreasuryUpdated(address oldTreasury, address newTreasury);

    modifier hasPrice() {
        require(getOptimisticOracle().hasPrice(address(this), priceIdentifier, requestTimestamp, customAncillaryData), "no price");
        _;
    }

    modifier requestInitialized() {
        require(priceRequested, "Price not requested");
        _;
    }

    /// @notice Initializer for clones
    /// @param _pairName human readable market name
    /// @param _collateralToken EUROC or mock (address)
    /// @param _customAncillaryData bytes describing the question (must match proposer later)
    /// @param _finder UMA Finder address for this chain
    /// @param _timerAddress test timer (set to 0x0 in production)
    /// @param _resolutionTimestamp unix timestamp for resolution (e.g., now + 30 days)
    /// @param _treasury address receiving fees (Gnosis Safe recommended)
    /// @param _feeBps commission in bps (<= MAX_FEE_BPS)
    /// @param _owner owner (who will be the contract owner after initialize)
    function initialize(
        string memory _pairName,
        address _collateralToken,
        bytes memory _customAncillaryData,
        address _finder,
        address _timerAddress,
        uint256 _resolutionTimestamp,
        address _treasury,
        uint256 _feeBps,
        address _owner
    ) external initializer {
        require(_treasury != address(0), "treasury 0");
        require(_feeBps <= MAX_FEE_BPS, "fee too high");
        // init OZ upgradeable parents
        __Ownable_init();
        __ReentrancyGuard_init();
        __Pausable_init();

        // set state
        finder = FinderInterface(_finder);
        collateralToken = ExpandedERC20(_collateralToken);
        customAncillaryData = _customAncillaryData;
        pairName = _pairName;

        // resolution timestamp
        require(_resolutionTimestamp >= Testable(_timerAddress).getCurrentTime() || _timerAddress == address(0) || _resolutionTimestamp >= block.timestamp, "resolution in past");
        marketResolutionTimestamp = _resolutionTimestamp;
        requestTimestamp = _resolutionTimestamp; // use resolution timestamp as request id for OO

        treasury = _treasury;
        feeBps = _feeBps;

        // defaults
        proposerReward = 0;
        optimisticOracleLivenessTime = 3600;
        optimisticOracleProposerBond = 0;

        // default identifier
        priceIdentifier = bytes32("YES_OR_NO_QUERY");

        // Create long & short tokens with this contract as minter/burner
        longToken = new ExpandedERC20(string(abi.encodePacked(_pairName, " Long Token")), "PLT", 18);
        shortToken = new ExpandedERC20(string(abi.encodePacked(_pairName, " Short Token")), "PST", 18);

        longToken.addMinter(address(this));
        shortToken.addMinter(address(this));
        longToken.addBurner(address(this));
        shortToken.addBurner(address(this));

        // transfer ownership (if provided)
        if (_owner != address(0)) {
            transferOwnership(_owner);
        }
    }

    /* ========== ADMIN FUNCTIONS (onlyOwner) ========== */

    function setFeeBps(uint256 _feeBps) external onlyOwner {
        require(_feeBps <= MAX_FEE_BPS, "fee cap");
        emit FeeUpdated(feeBps, _feeBps);
        feeBps = _feeBps;
    }

    function setTreasury(address _treasury) external onlyOwner {
        require(_treasury != address(0), "treasury 0");
        emit TreasuryUpdated(treasury, _treasury);
        treasury = _treasury;
    }

    function setProposerReward(uint256 _reward) external onlyOwner { proposerReward = _reward; }
    function setLiveness(uint256 _secs) external onlyOwner { optimisticOracleLivenessTime = _secs; }
    function setProposerBond(uint256 _bond) external onlyOwner { optimisticOracleProposerBond = _bond; }

    function pauseMarket() external onlyOwner { _pause(); }
    function unpauseMarket() external onlyOwner { _unpause(); }

    /// @notice Rescue ERC20 tokens accidentally sent to this contract, but never allow rescue of the collateral token.
    function rescueToken(address token, uint256 amount, address to) external onlyOwner {
        require(token != address(collateralToken), "cannot rescue collateral");
        IERC20(token).safeTransfer(to, amount);
    }

    /* ========== MARKET LIFECYCLE ========== */

    function initializeMarket() external whenNotPaused nonReentrant {
        // pull proposerReward if set (keeps OO incentives funded)
        if (proposerReward > 0) {
            collateralToken.safeTransferFrom(msg.sender, address(this), proposerReward);
        }
        _requestOraclePrice();
        emit MarketInitialized(requestTimestamp, customAncillaryData);
    }

    function create(uint256 tokensToCreate) external whenNotPaused nonReentrant requestInitialized {
        require(tokensToCreate > 0, "zero amount");
        require(getCurrentTime() < marketResolutionTimestamp, "market closed");

        // Pull full amount from user in a single ERC20 transfer (user must approve market for this amount)
        collateralToken.safeTransferFrom(msg.sender, address(this), tokensToCreate);

        // Compute fee & net
        uint256 fee = (tokensToCreate * feeBps) / 10000;
        uint256 net = tokensToCreate - fee;
        require(net > 0, "net zero after fee");

        // Forward fee to treasury (immediate, on-chain)
        if (fee > 0) {
            collateralToken.safeTransfer(treasury, fee);
        }

        // Mint net long & short tokens for user
        require(longToken.mint(msg.sender, net));
        require(shortToken.mint(msg.sender, net));

        emit TokensCreated(msg.sender, tokensToCreate, net, fee);
    }

    function redeem(uint256 tokensToRedeem) external whenNotPaused nonReentrant {
        require(longToken.burnFrom(msg.sender, tokensToRedeem));
        require(shortToken.burnFrom(msg.sender, tokensToRedeem));
        collateralToken.safeTransfer(msg.sender, tokensToRedeem);
        emit TokensRedeemed(msg.sender, tokensToRedeem, tokensToRedeem);
    }

    function settle(uint256 longTokensToRedeem, uint256 shortTokensToRedeem) external whenNotPaused nonReentrant returns (uint256 collateralReturned) {
        require(receivedSettlementPrice, "not resolved");
        require(longToken.burnFrom(msg.sender, longTokensToRedeem));
        require(shortToken.burnFrom(msg.sender, shortTokensToRedeem));

        uint256 longCollateralRedeemed = (longTokensToRedeem * settlementPrice) / (1e18);
        uint256 shortCollateralRedeemed = (shortTokensToRedeem * (1e18 - settlementPrice)) / (1e18);

        collateralReturned = longCollateralRedeemed + shortCollateralRedeemed;
        collateralToken.safeTransfer(msg.sender, collateralReturned);

        emit PositionSettled(msg.sender, collateralReturned, longTokensToRedeem, shortTokensToRedeem);
    }

    /* ========== UMA CALLBACKS & HELPERS ========== */

    function priceSettled(bytes32 identifier, uint256 timestamp, bytes memory ancillaryData, int256 price) external {
        OptimisticOracleV2Interface optimisticOracle = getOptimisticOracle();
        require(msg.sender == address(optimisticOracle), "not authorized");
        require(identifier == priceIdentifier, "identifier mismatch");
        require(keccak256(ancillaryData) == keccak256(customAncillaryData), "ancillary mismatch");
        if (timestamp != requestTimestamp) return; // different request (ignore)

        // Map price to 0, 0.5, 1 e18 as UMA examples do
        if (price >= 1e18) {
            settlementPrice = 1e18;
        } else if (price == 5e17) {
            settlementPrice = 5e17;
        } else {
            settlementPrice = 0;
        }
        receivedSettlementPrice = true;
    }

    function priceDisputed(bytes32 identifier, uint256 timestamp, bytes memory ancillaryData, uint256 refund) external {
        OptimisticOracleV2Interface optimisticOracle = getOptimisticOracle();
        require(msg.sender == address(optimisticOracle), "not authorized");
        require(timestamp == requestTimestamp, "timestamp mismatch");
        require(identifier == priceIdentifier, "identifier mismatch");
        require(keccak256(ancillaryData) == keccak256(customAncillaryData), "ancillary mismatch");
        require(refund == proposerReward, "refund mismatch");

        // On dispute we re-create a new request timestamp (simple retry pattern)
        requestTimestamp = getCurrentTime();
        _requestOraclePrice();
    }

    function _requestOraclePrice() internal {
        OptimisticOracleV2Interface optimisticOracle = getOptimisticOracle();

        // Approve proposerReward for OO
        if (proposerReward > 0) {
            collateralToken.safeApprove(address(optimisticOracle), proposerReward);
        }

        optimisticOracle.requestPrice(
            priceIdentifier,
            requestTimestamp,
            customAncillaryData,
            IERC20(address(collateralToken)),
            proposerReward
        );

        optimisticOracle.setCustomLiveness(priceIdentifier, requestTimestamp, customAncillaryData, optimisticOracleLivenessTime);
        optimisticOracle.setBond(priceIdentifier, requestTimestamp, customAncillaryData, optimisticOracleProposerBond);
        optimisticOracle.setEventBased(priceIdentifier, requestTimestamp, customAncillaryData);
        optimisticOracle.setCallbacks(priceIdentifier, requestTimestamp, customAncillaryData, false, true, true);

        priceRequested = true;
    }

    function getOptimisticOracle() internal view returns (OptimisticOracleV2Interface) {
        return OptimisticOracleV2Interface(finder.getImplementationAddress(OracleInterfaces.OptimisticOracleV2));
    }

    function _getIdentifierWhitelist() internal view returns (IdentifierWhitelistInterface) {
        return IdentifierWhitelistInterface(finder.getImplementationAddress(OracleInterfaces.IdentifierWhitelist));
    }

    function _getAddressWhitelist() internal view returns (AddressWhitelist) {
        return AddressWhitelist(finder.getImplementationAddress(OracleInterfaces.CollateralWhitelist));
    }

    // helper to get current time (wrap Testable if needed)
    function getCurrentTime() public view returns (uint256) {
        // If finder/timer pattern required, we fallback to block.timestamp
        return block.timestamp;
    }
}
