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

    /**
     * STATE VARIABLES
     */
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_TRESHOLD = 50; // 200% over collaterized
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1;

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
    function depositeCollateralAndMintDsc() external {}

    /**
     * @notice follows CEI pattern (Checks Effecte Interactions)
     * @param _tokenCollateralAddress The address of the token to deposite as collateral
     * @param _amountCollateral The Amount of collateral to deposite
     */
    function depositeColateral(address _tokenCollateralAddress, uint256 _amountCollateral)
        external
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

        if(!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    function redeemCollateralForDsc() external {}

    function redeemCollateral() external {}

    /**
     * @notice follows CEI pattern (Checks Effecte Interactions)
     * @param _amountDscToMint The amount of decentralized stable coin to mint.
     * @notice They must have more collateral value than the treshhold
     */
    function mintDsc(uint256 _amountDscToMint) external moreThanZerro(_amountDscToMint) nonReentrant {
        s_DscMinted[msg.sender] += _amountDscToMint;

        // if they minted too much eg ($140 DSC, has $100 ETH)
        _revertIfHealthFactorIsBroken(msg.sender);

        bool minted = i_dsc.mint(msg.sender, _amountDscToMint);
        if(!minted) {
            revert DSCEngine__MintFailed();
        }
    }

    function burnDsc() external {}

    function liquidate() external {}

    function getHealth() external {}


    /**
     * Internal & Private View Functions
     */

    function _getAccountInformation(address user) private view returns(uint256 totalDscMinted, uint256 collateralValueInUsd) {
        totalDscMinted = s_DscMinted[user];
        collateralValueInUsd = getAccountCollateralValue(user);
    }

    /**
     * Returns how close a user is to liqi=uidation
     * If a user goes beyond 1, they can be liquidated
     */
    function _healthFactor(address user) private view  returns (uint256) {
        // total DSC minted
        // total collateral VALUE
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
        /**
         * Making sure the user still has enough collateral to with-hold liquidation
         * below we are checking if the collateral value is 200% compared to holdings
         * eg user has 100 ETH his collateral value should be 
         * => 100 * 50 = 5000 / 100 = 50 (His collateral Value can only allow for 50 DSC)
         */
        uint256 collateralAdjustmentForTreshold = (collateralValueInUsd * LIQUIDATION_TRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustmentForTreshold * PRECISION) / totalDscMinted;
    }

    // 1. Check the health factor (Has enough collateral)
    // 2. If not revert
    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);

        if(userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreaksHealthFactor(userHealthFactor);
        }
    }

    /**
     * PUBLIC & EXTERNAL FUNCTIONS
     */

    function getAccountCollateralValue(address user) public view returns(uint256 totalCollateralValueInUsd) {
        // loop through each collateral token, get the amount they have deposited
        // and map it to the price, to get the USD value
        for(uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueInUsd += getUsdValue(token, amount);
        }
        return totalCollateralValueInUsd;
    }

    function getUsdValue(address _token, uint256 _amount) public view returns(uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[_token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        // eg if ETH is $1000
        // the returned value from chainlink will be 1000 * 1e8
        // to get a precision we have to first multiply the returne price by additional 10 zerros to equall 1e18
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * _amount) / PRECISION; // (1000 * 1e8 * (1e10))
    }
}
