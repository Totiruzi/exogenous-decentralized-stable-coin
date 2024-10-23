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

    /**
     * STATE VARIABLES
     */
    DecentralizedStableCoin private immutable i_dsc;
    mapping(address collateralToken => address priceFeed) private s_priceFeeds;
    mapping(address token => address priceFeed) private priceFeeds; // tokenToPriceFeed
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;

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
        }
        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    /**
     * EXTERNAL FUNCTIONS
     */
    function depositeCollateralAndMintDsc() external {}

    /**
     * @notice follows CEI (Checks Effecte Interactions)
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

    function mintDsc() external {}

    function burnDsc() external {}

    function liquidate() external {}

    function getHealth() external {}
}
