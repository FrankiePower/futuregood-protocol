// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {PrincipalToken} from "./PrincipalToken.sol";
import {YieldToken} from "./YieldToken.sol";
import {YieldRouter} from "./YieldRouter.sol";

/**
 * @title YieldSplitter
 * @author FutureGood Protocol
 * @notice Core contract managing yield splitting markets and Principal/Yield token operations
 * @dev Handles creation, minting, redemption of PT/YT pairs for yield-bearing assets
 *      Includes public goods mode where YT is donated to octant dragonrouter for charitable yield
 */
contract YieldSplitter {
    using SafeERC20 for IERC20;

    /**
     * @notice Yield market structure containing all market-specific information
     * @dev Used to track all parameters for a specific PT/YT pair market
     */
    struct YieldMarket {
        address yieldBearingToken; /// @dev Underlying yield-bearing token (e.g., USDC)
        address assetToken; /// @dev Base asset token (e.g., USDC)
        address principalToken; /// @dev Principal token address (e.g., FGP-USDC)
        address yieldToken; /// @dev Yield token address (e.g., FGY-USDC)
        uint256 expiry; /// @dev Timestamp when the market expires
        uint256 initialApr; /// @dev Initial APR when creating the market (in basis points)
        uint256 creationTimestamp; /// @dev Timestamp when the market was created
    }

    /// @notice Maps market ID to yield market information
    /// @dev Market ID is computed from yieldBearingToken, assetToken, and expiry
    mapping(bytes32 marketId => YieldMarket) yieldMarkets;

    /// @notice Emitted when a new yield market is created
    event MarketCreated(
        bytes32 indexed marketId, address indexed yieldBearingToken, address indexed assetToken, uint256 expiry
    );

    /// @notice Emitted when user deposits YBT to mint PT/YT tokens
    event TokensDeposited(bytes32 indexed marketId, address indexed user, uint256 ybtAmount);

    /// @notice Emitted when user redeems PT/YT tokens for YBT
    event TokensRedeemed(bytes32 indexed marketId, address indexed user, uint256 ybtAmount);

    /// @notice Emitted when user deposits in public goods mode
    event PublicGoodsDeposit(
        bytes32 indexed marketId, address indexed user, uint256 ybtAmount, uint256 ptToUser, uint256 ytToPublicGoods
    );

    /// @notice Address of the YT seller contract (receives YT in public goods mode)
    address public ytSeller;

    /// @notice Address of the YieldRouter for deploying principal funds
    YieldRouter public yieldRouter;

    /// @notice Contract constructor - no initialization required
    constructor() {}

    /**
     * @notice Set the YT seller contract address
     * @param _ytSeller Address of PublicGoodsYTSeller
     * @dev Only callable once during deployment
     */
    function setYTSeller(address _ytSeller) external {
        require(ytSeller == address(0), "already set");
        require(_ytSeller != address(0), "zero address");
        ytSeller = _ytSeller;
    }

    /**
     * @notice Set the YieldRouter contract address
     * @param _yieldRouter Address of YieldRouter for deploying funds
     * @dev Only callable once during deployment
     */
    function setYieldRouter(address _yieldRouter) external {
        require(address(yieldRouter) == address(0), "already set");
        require(_yieldRouter != address(0), "zero address");
        yieldRouter = YieldRouter(_yieldRouter);
    }

    /**
     * @notice Creates a new yield market for the given parameters
     * @dev Deploys new PT and YT token contracts and stores market information
     * @param _yieldBearingToken Address of the yield-bearing token (e.g., USDC)
     * @param _assetToken Address of the underlying asset token (e.g., USDC)
     * @param _expiry Expiration timestamp for the market
     * @param _initialApr Initial APR in basis points (e.g., 1000 = 10%)
     */
    function createYieldMarket(address _yieldBearingToken, address _assetToken, uint256 _expiry, uint256 _initialApr)
        external
    {
        bytes32 marketId = _getMarketId(_yieldBearingToken, _assetToken, _expiry);
        YieldMarket memory market = yieldMarkets[marketId];
        if (market.yieldBearingToken != address(0)) revert("already exists");

        market.yieldBearingToken = _yieldBearingToken;
        market.assetToken = _assetToken;

        string memory yieldTokenName = IERC20Metadata(_yieldBearingToken).name();
        string memory yieldTokenSymbol = IERC20Metadata(_yieldBearingToken).symbol();

        market.principalToken = address(
            new PrincipalToken(
                string.concat("FutureGood Principal ", yieldTokenName), string.concat("FGP-", yieldTokenSymbol)
            )
        );

        market.yieldToken = address(
            new YieldToken(string.concat("FutureGood Yield ", yieldTokenName), string.concat("FGY-", yieldTokenSymbol))
        );

        market.expiry = _expiry;
        market.initialApr = _initialApr;
        market.creationTimestamp = block.timestamp;

        yieldMarkets[marketId] = market;
        emit MarketCreated(marketId, _yieldBearingToken, _assetToken, _expiry);
    }

    /**
     * @notice Mints PT and YT tokens by depositing yield-bearing tokens
     * @dev User deposits YBT and receives 1:1 amounts of PT and YT tokens
     * @param _marketId Unique identifier for the yield market
     * @param _amount Amount of yield-bearing tokens to deposit
     */
    function mintPtAndYt(bytes32 _marketId, uint256 _amount) external {
        YieldMarket memory market = yieldMarkets[_marketId];
        require(market.yieldBearingToken != address(0), "!exist");
        require(block.timestamp < market.expiry, "expired");

        // Transfer yield bearing token from user to contract
        IERC20(market.yieldBearingToken).safeTransferFrom(msg.sender, address(this), _amount);

        // Mint 1:1 PT and YT tokens to user
        PrincipalToken(market.principalToken).mint(msg.sender, _amount);
        YieldToken(market.yieldToken).mint(msg.sender, _amount);

        emit TokensDeposited(_marketId, msg.sender, _amount);
    }

    /**
     * @notice Mint PT/YT in "Public Goods Mode" - User keeps PT, YT goes to charity
     * @param _marketId Market identifier
     * @param _amount Amount of YBT to deposit
     * @dev User receives PT (keeps principal), YT goes to ytSeller (donates yield)
     *
     *      CRITICAL FIX: User's funds are NOT auto-deployed to strategies here!
     *
     *      Why? The current YieldRouter strategies send ALL yield to dragonRouter.
     *      But YT buyers need to receive the yield from user deposits!
     *
     *      The correct flow:
     *      1. User deposits here (funds held in YieldSplitter)
     *      2. YT sold to buyer (Charlie) who expects yield
     *      3. User's funds should be deployed to SEPARATE strategies where yield → YT holders
     *      4. YT sale proceeds (5 USDC) → dragonRouter immediately (done in Hook)
     *
     *      TODO: In production, implement separate user strategies or track user deposits
     *      separately to ensure YT holders get the yield they paid for!
     */
    function mintPtAndYtForPublicGoods(bytes32 _marketId, uint256 _amount) external {
        YieldMarket memory market = yieldMarkets[_marketId];
        require(market.yieldBearingToken != address(0), "!exist");
        require(block.timestamp < market.expiry, "expired");
        require(ytSeller != address(0), "ytSeller not set");

        // Transfer YBT from user
        IERC20(market.yieldBearingToken).safeTransferFrom(msg.sender, address(this), _amount);

        // Mint PT to user (they keep principal, redeemable at maturity)
        PrincipalToken(market.principalToken).mint(msg.sender, _amount);

        // Mint YT to ytSeller (for auto-sale to public goods)
        YieldToken(market.yieldToken).mint(ytSeller, _amount);

        // REMOVED: Auto-deployment to YieldRouter
        // The current YieldRouter sends yield to dragonRouter, but YT buyers need that yield!
        // For now, funds stay in YieldSplitter until proper user strategy routing is implemented
        //
        // FUTURE FIX: Deploy to separate user strategies where:
        //   - User deposits (100 USDC) → userStrategies → yield goes to YT holders (Charlie)
        //   - YT sale proceeds (5 USDC) → dragonRouter directly (already fixed in Hook!)

        emit PublicGoodsDeposit(_marketId, msg.sender, _amount, _amount, _amount);
    }

    /**
     * @notice Retrieves yield market information by token addresses and expiry
     * @param _yieldBearingToken Address of the yield-bearing token
     * @param _assetToken Address of the underlying asset token
     * @param _expiry Expiration timestamp for the market
     * @return YieldMarket struct containing market information
     */
    function getYieldMarket(address _yieldBearingToken, address _assetToken, uint256 _expiry)
        external
        view
        returns (YieldMarket memory)
    {
        bytes32 marketId = _getMarketId(_yieldBearingToken, _assetToken, _expiry);
        return yieldMarkets[marketId];
    }

    /**
     * @notice Retrieves yield market information by market ID
     * @param _marketId Unique identifier for the yield market
     * @return YieldMarket struct containing market information
     */
    function getYieldMarket(bytes32 _marketId) external view returns (YieldMarket memory) {
        return yieldMarkets[_marketId];
    }

    /**
     * @notice Calculates the current price of PT tokens in terms of YBT
     * @dev Price calculation based on time to maturity and initial APR
     * @param _marketId Unique identifier for the yield market
     * @return PT price in 1e18 precision (1e18 = 1 YBT)
     */
    function getPtPriceInYbt(bytes32 _marketId) external view returns (uint256) {
        YieldMarket memory market = yieldMarkets[_marketId];
        require(market.yieldBearingToken != address(0), "!exist");

        if (block.timestamp >= market.expiry) {
            return 1e18; // At or after expiry, PT is worth exactly 1 YBT
        }

        uint256 timeToMaturity = market.expiry - block.timestamp;
        return _calculatePtPrice(market.initialApr, timeToMaturity);
    }

    /**
     * @notice Calculates the current price of YT tokens in terms of YBT
     * @dev YT price = 1 YBT - PT price, becomes 0 after expiry
     * @param _marketId Unique identifier for the yield market
     * @return YT price in 1e18 precision (1e18 = 1 YBT)
     */
    function getYtPriceInYbt(bytes32 _marketId) external view returns (uint256) {
        YieldMarket memory market = yieldMarkets[_marketId];
        require(market.yieldBearingToken != address(0), "!exist");

        if (block.timestamp >= market.expiry) {
            return 0; // After expiry, YT is worthless
        }

        uint256 ptPrice = _calculatePtPrice(market.initialApr, market.expiry - block.timestamp);
        return 1e18 - ptPrice; // YT price = 1 YBT - PT price
    }

    /**
     * @notice Calculates PT price using present value formula
     * @dev Uses formula: PT_price = 1 / (1 + r*t) where r is APR and t is time to maturity
     * @param aprBps Annual percentage rate in basis points (e.g., 1000 = 10%)
     * @param timeToMaturity Time remaining until expiry in seconds
     * @return PT price in 1e18 precision
     */
    function _calculatePtPrice(uint256 aprBps, uint256 timeToMaturity) internal pure returns (uint256) {
        if (timeToMaturity == 0) return 1e18; // At maturity, PT = 1

        // Convert APR from basis points to 1e18 fixed-point decimal
        // aprBps is in basis points (e.g., 1000 = 10%)
        // Convert to 1e18 fixed-point decimal: r = aprBps / 10000
        // => multiply by 1e18 / 10000 = 1e14
        uint256 r = aprBps * 1e14; // 1e18-scaled rate

        // Convert time to maturity from seconds to years (1e18-scaled)
        uint256 t = (timeToMaturity * 1e18) / 365 days;

        // Calculate r * t (1e18-scaled)
        uint256 rt = (r * t) / 1e18;

        // Calculate denominator = 1 + r*t
        uint256 denom = 1e18 + rt;

        // Calculate PT price = 1 / (1 + r*t)
        uint256 ptPrice = (1e18 * 1e18) / denom;

        return ptPrice;
    }

    /**
     * @notice Redeems PT (and optionally YT) tokens for underlying YBT
     * @dev Before expiry: requires both PT and YT tokens (1:1:1 ratio)
     *      After expiry: requires only PT tokens (1:1 ratio)
     *
     *      IMPORTANT: In Public Goods Mode, user deposited funds are held in this contract
     *      (not deployed to strategies) so redemption works from contract balance
     *
     * @param _marketId Unique identifier for the yield market
     * @param _yieldBearingAmount Amount of YBT to redeem
     */
    function redeemPtAndYt(bytes32 _marketId, uint256 _yieldBearingAmount) external {
        YieldMarket memory market = yieldMarkets[_marketId];
        require(market.yieldBearingToken != address(0), "!exist");

        uint256 principalTokensNeeded = _yieldBearingAmount;
        uint256 yieldTokensNeeded;

        // Determine redemption requirements based on expiry status
        if (block.timestamp >= market.expiry) {
            // After expiry: only PT tokens needed (PT -> YBT 1:1)
            principalTokensNeeded = _yieldBearingAmount;
            yieldTokensNeeded = 0;
        } else {
            // Before expiry: both PT and YT tokens needed (PT + YT -> YBT 1:1:1)
            yieldTokensNeeded = _yieldBearingAmount;
            YieldToken(market.yieldToken).burn(msg.sender, yieldTokensNeeded);
        }

        // Always burn the required principal tokens
        PrincipalToken(market.principalToken).burn(msg.sender, principalTokensNeeded);

        // Transfer yield bearing tokens to user
        IERC20(market.yieldBearingToken).safeTransfer(msg.sender, _yieldBearingAmount);

        emit TokensRedeemed(_marketId, msg.sender, _yieldBearingAmount);
    }

    /**
     * @notice Generates a unique market ID for the given parameters
     * @dev Uses keccak256 hash of encoded parameters for deterministic ID generation
     * @param _yieldBearingToken Address of the yield-bearing token
     * @param _assetToken Address of the underlying asset token
     * @param _expiry Expiration timestamp for the market
     * @return Unique bytes32 market identifier
     */
    function _getMarketId(address _yieldBearingToken, address _assetToken, uint256 _expiry)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(_yieldBearingToken, _assetToken, _expiry));
    }
}
