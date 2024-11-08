// SPDX-License-Identifier: MIT

// This is considered an Exogenous, Decentralized, Anchored (pegged), Crypto Collateralized low volitility coin

// Layout of Contract:
// version
// imports
// interfaces, libraries, contracts
// errors
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// view & pure functions

pragma solidity ^0.8.24;

import {DecentralizedStableCoin} from "src/DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {console2} from "forge-std/Script.sol";

/**
 * @title DSCEngine
 * @author Oyemechi Chris
 *
 * This system is designed to be as minimal as possible, and have the token maintain a 1 token == $1 peg.
 * The satble coin has the properties
 * - Exogeneous Collateral
 * - Dollar Pegged
 * - Algorithmically Stable
 *
 * Our DSC system should always be "overcollateralized". At no point should all the values of our collateral <= the $ backed value of all the DSC.
 *
 * It is similar to DAO if DAO had no governance, no fee, and was only backed by WBTC and WETH.
 *
 * @notice This contract is the core of the DSC system. It handles all logic for mining and redeeming DSC, as well as depositing & withdrawing collateral.
 * @notice This contract is VERY losely and based on the MakerDAO DSS (DAI) system.
 */
contract DSCEngine is ReentrancyGuard {
    /**
     * ERRORS
     */
    error DSCEngine__NeedsMoreThanZerro();
    error DSCEngine__TokenAddressAndPriceFeedAddressMustBeSAmeLength();
    error DSCEngine__TokenNotAllowed();
    error DSCEngine__TransferFailed();
    error DSCEngine__BreaksHealthFactor(uint256 healthFactor);
    error DSCEngine__MintFailed();
    error DSCEngine__HealthFactorOk();
    error DSCEngine__HealthFactorNotImproved();

    /**
     * STATE VARIABLES
     */
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // 200% over collaterized
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_BONUS = 10; // 10% bonus

    DecentralizedStableCoin private immutable i_dsc;
    mapping(address collateralToken => address priceFeed) private s_priceFeeds;
    mapping(address token => address priceFeed) private priceFeeds; // tokenToPriceFeed
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256 amountDscMinted) private s_DscMinted;
    address[] private s_collateralTokens;

    /**
     *  EVENTS
     */
    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(address indexed redeemedFrom, address redeemedTo, address indexed token, uint256 amount);

    /**
     *
     * MODIFIERS
     */
    modifier moreThanZerro(uint256 _amount) {
        if (_amount <= 0) {
            revert DSCEngine__NeedsMoreThanZerro();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert DSCEngine__TokenNotAllowed();
        }
        _;
    }

    /**
     * FUNCTIONS
     */
    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address dscAddress) {
        // USD Price Feeds
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__TokenAddressAndPriceFeedAddressMustBeSAmeLength();
        }
        // eg ETH/USD, BTC/USD, ADA/USD
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }
        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    /**
     * EXTERNAL FUNCTIONS
     */

    /**
     *
     * @param _tokenCollateralAddress The address of the token to deposit as collateral
     * @param _amountCollateral The amount of collateral to deposit
     * @param _amountDscToMint The amount of decentralized stablecoin to mint
     * @notice This function will deposit your colateral and mint DSC in one transaction
     */
    function depositCollateralAndMintDsc(
        address _tokenCollateralAddress,
        uint256 _amountCollateral,
        uint256 _amountDscToMint
    ) external {
        depositCollateral(_tokenCollateralAddress, _amountCollateral);
        mintDsc(_amountDscToMint);
    }

    /**
     * @notice follows CEI pattern (Checks Effecte Interactions)
     * @param _tokenCollateralAddress The address of the token to deposite as collateral
     * @param _amountCollateral The Amount of collateral to deposite
     */
    function depositCollateral(address _tokenCollateralAddress, uint256 _amountCollateral)
        public
        moreThanZerro(_amountCollateral)
        isAllowedToken(_tokenCollateralAddress)
        nonReentrant
    {
        // Effects
        s_collateralDeposited[msg.sender][_tokenCollateralAddress] += _amountCollateral;
        // when we update a state we should emit an event the collateral deposited
        emit CollateralDeposited(msg.sender, _tokenCollateralAddress, _amountCollateral);

        //External Interactions
        bool success = IERC20(_tokenCollateralAddress).transferFrom(msg.sender, address(this), _amountCollateral);

        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    /**
     *
     * @param _tokenCollateralAddress The address of the collateral to redeem
     * @param _amountCollateral The amount of collateral to redeem
     * @param _amountDscToBurn The amount of DSC to burn
     * @notice this function burns DSC and redeem collateral in one transaction
     */
    function redeemCollateralForDsc(
        address _tokenCollateralAddress,
        uint256 _amountCollateral,
        uint256 _amountDscToBurn
    ) external {
        burnDsc(_amountDscToBurn);
        redeemCollateral(_tokenCollateralAddress, _amountCollateral);
        // redeemCollateral alreday checks health factor
    }

    // In other to redeem collateral:
    // 1. health factor must be more than 1 After collateral pull
    function redeemCollateral(address _tokenCollateralAddress, uint256 _amountCollateral)
        public
        moreThanZerro(_amountCollateral)
        nonReentrant
    {
        _redeemCollateral(_tokenCollateralAddress, _amountCollateral, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * @notice follows CEI pattern (Checks Effecte Interactions)
     * @param _amountDscToMint The amount of decentralized stable coin to mint.
     * @notice They must have more collateral value than the treshhold
     */
    function mintDsc(uint256 _amountDscToMint) public moreThanZerro(_amountDscToMint) nonReentrant {
        s_DscMinted[msg.sender] += _amountDscToMint;

        // if they minted too much eg ($140 DSC, has $100 ETH)
        _revertIfHealthFactorIsBroken(msg.sender);

        bool minted = i_dsc.mint(msg.sender, _amountDscToMint);
        if (!minted) {
            revert DSCEngine__MintFailed();
        }
    }

    function burnDsc(uint256 _amountToBurn) public moreThanZerro(_amountToBurn) {
        _burnDsc(_amountToBurn, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender); // This is probably not needed
    }

    /**
     *
     * @param _tokenCollateralAddress The erc20 address collateral to liquidate from the user
     * @param user The user who has broken the health factor. their _healthfactor should be below MIN_HEALTH_FACTOR
     * @param _debtToCover The amount of DSC to burn to improve the users health factor
     * @notice You can partially liquidate a user
     * @notice You will get a liquidation bonus for taken the users funds.
     * @notice The function working assumes the protocol will be atleast 200% over collateral to keep working
     * @notice A known bug would be if the protocol was 100% or less collateral, then we would not be able to be incentivize liquidators
     * @notice eg if the price of collateral falls before anyone could be liquidated
     */
    function liquidate(address _tokenCollateralAddress, address user, uint256 _debtToCover)
        external
        moreThanZerro(_debtToCover)
        nonReentrant
    {
        //need to check health factor for the user
        uint256 startingUserHealthFactor = _healthFactor(user);

        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorOk();
        }

        // We want to burn their DSC "debt" and take thier collateral
        uint256 tokenAmountFromDeptCovered = getTokenAmountFromUsd(_tokenCollateralAddress, _debtToCover);

        // Give liquidator 10%
        uint256 bonusCollateral = (tokenAmountFromDeptCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        uint256 totalCollatoralToRedeem = tokenAmountFromDeptCovered + bonusCollateral;
        _redeemCollateral(_tokenCollateralAddress, totalCollatoralToRedeem, user, msg.sender);

        // Burn DSC
        _burnDsc(_debtToCover, user, msg.sender);
        uint256 endingUserHealthFactor = _healthFactor(user);

        if (endingUserHealthFactor <= startingUserHealthFactor) {
            revert DSCEngine__HealthFactorNotImproved();
        }

        // Revert if caller health factor is broken due to him trying to redeem someones else health factor.
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function getHealth() external {}

    /**
     * Internal & Private View Functions
     */
    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        totalDscMinted = s_DscMinted[user];
        collateralValueInUsd = getAccountCollateralValue(user);
    }

    /**
     * Returns how close a user is to liqi=uidation
     * If a user goes beyond 1, they can be liquidated
     */
    function _healthFactor(address user) private view returns (uint256) {
        // total DSC minted
        // total collateral VALUE
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
        if (totalDscMinted == 0) return type(uint256).max;
        /**
         * Making sure the user still has enough collateral to with-hold liquidation
         * below we are checking if the collateral value is 200% compared to holdings
         * eg user has 100 ETH his collateral value should be
         * => 100 * 50 = 5000 / 100 = 50 (His collateral Value can only allow for 50 DSC)
         */
        uint256 collateralAdjustmentForTreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustmentForTreshold * PRECISION) / totalDscMinted;
    }

    // 1. Check the health factor (Has enough collateral)
    // 2. If not revert
    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);

        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreaksHealthFactor(userHealthFactor);
        }
    }

    function _redeemCollateral(address _tokenCollateralAddress, uint256 _amountCollateral, address _from, address _to)
        private
    {
        s_collateralDeposited[_from][_tokenCollateralAddress] -= _amountCollateral;
        emit CollateralRedeemed(_from, _to, _tokenCollateralAddress, _amountCollateral);
        bool success = IERC20(_tokenCollateralAddress).transfer(_to, _amountCollateral);

        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    /**
     *
     * @param _amountDscToBurn The amount of Dsc to burn
     * @param onBahalfOf Whose token is been burnt
     * @param dscFrom Who is recieving the burnt token
     * @dev Low-level internal function. Do ot call unless the function calling it is checking for
     * "Health Factor" been broken
     */
    function _burnDsc(uint256 _amountDscToBurn, address onBahalfOf, address dscFrom) private {
        uint256 DSCMinted = s_DscMinted[onBahalfOf];
        console2.log("DSCMinted: ", DSCMinted);
        console2.log("Amount Dsc to burn before sudstraction : ", _amountDscToBurn);

        s_DscMinted[onBahalfOf] -= _amountDscToBurn;

        console2.log("Amount Dsc to burn after sudstraction : ", _amountDscToBurn);
        bool success = i_dsc.transferFrom(dscFrom, address(this), _amountDscToBurn);

        if (!success) {
            revert DSCEngine__TransferFailed();
        }

        i_dsc.burn(_amountDscToBurn);
    }

    function _calculateHealthFactor(uint256 _totalDscMinted, uint256 _collateralValueInUsd)
        internal
        pure
        returns (uint256)
    {
        if (_totalDscMinted == 0) return type(uint256).max;
        uint256 collateralAjustedForThreshold = (_collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAjustedForThreshold * PRECISION) / _totalDscMinted;
    }

    /**
     * PUBLIC & EXTERNAL FUNCTIONS
     */
    function getAccountCollateralValue(address user) public view returns (uint256 totalCollateralValueInUsd) {
        // loop through each collateral token, get the amount they have deposited
        // and map it to the price, to get the USD value
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueInUsd += getUsdValue(token, amount);
        }
        return totalCollateralValueInUsd;
    }

    function getUsdValue(address _token, uint256 _amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[_token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        // eg if ETH is $1000
        // the returned value from chainlink will be 1000 * 1e8
        // to get a precision we have to first multiply the returne price by additional 10 zerros to equall 1e18
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * _amount) / PRECISION; // (1000 * 1e8 * (1e10))
    }

    function getTokenAmountFromUsd(address _tokenAddress, uint256 usdAmountInWei) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[_tokenAddress]);
        (, int256 price,,,) = priceFeed.latestRoundData();

        return ((usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION));
    }

    function getAccountInformation(address user)
        external
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        (totalDscMinted, collateralValueInUsd) = _getAccountInformation(user);
    }

    function getCollateralBalanceOfUser(address user, address token) external view returns (uint256) {
        return s_collateralDeposited[user][token];
    }

    function getDsc() external view returns (address) {
        return address(i_dsc);
    }

    function getHealthFactor(address user) external view returns (uint256 userHealthFactor) {
        userHealthFactor = _healthFactor(user);
    }

    function getMinHealthFactor() external pure returns (uint256) {
        return MIN_HEALTH_FACTOR;
    }

    function getDscMinted(address user) external view returns (uint256 amountMinted) {
        amountMinted = s_DscMinted[user];
    }

    function getAdditionalFeedPrecition() external pure returns (uint256) {
        return ADDITIONAL_FEED_PRECISION;
    }

    function getPrecision() external pure returns (uint256) {
        return PRECISION;
    }

    function calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd)
        public
        pure
        returns (uint256)
    {
        return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
    }

    function getAdditionalFeedPrecision() external pure returns (uint256) {
        return ADDITIONAL_FEED_PRECISION;
    }

    function getLiquidationBonus() external pure returns (uint256) {
        return LIQUIDATION_BONUS;
    }

    function getLiquidationPrecision() external pure returns (uint256) {
        return LIQUIDATION_PRECISION;
    }

    function getLiquidationThreshold() external pure returns (uint256) {
        return LIQUIDATION_THRESHOLD;
    }

    function getCollateralTokens() external view returns (address[] memory) {
        return s_collateralTokens;
    }

    function getCollateralTokenPriceFeed(address token) external view returns (address) {
        return s_priceFeeds[token];
    }
}
