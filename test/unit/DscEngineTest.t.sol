// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {DecentralizedStableCoin} from "src/DecentralizedStableCoin.sol";
import {DSCEngine} from "src/DSCEngine.sol";
import {DeployDSC} from "script/DeployDSC.s.sol";
import {HelperConfig} from "script/HelperConfig.s.sol";
import {ERC20Mock} from "test/mocks/ERC20Mock.sol";

contract DscEngineTest is Test {
    DecentralizedStableCoin dsc;
    DSCEngine dscEngine;
    DeployDSC deployer;
    HelperConfig helperConfig;
    address ethUsdPriceFeed;
    address btcUsdPriceFeed;
    address weth;
    address wbtc;

    address public USER = makeAddr("user");
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant STARTING_USER_BALANCE = 10 ether;
    uint256 private constant LIQUIDATION_TRESHOLD = 50; // 200% over collaterized
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant PRECISION = 1e18;
    address[] public priceFeedAddresses;
    address[] public tokenAddresses;

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, dscEngine, helperConfig) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth, wbtc,) = helperConfig.activeNetworkConfig();
        ERC20Mock(weth).mint(USER, STARTING_USER_BALANCE);
        ERC20Mock(wbtc).mint(USER, STARTING_USER_BALANCE);
    }

    /**
     * CONSTRUCTOR TEST
     */
    function testRevertIfTokenLengthDoesNotMatchPriceFeed() public {
        tokenAddresses.push(weth);
        priceFeedAddresses.push(ethUsdPriceFeed);
        priceFeedAddresses.push(btcUsdPriceFeed);

        vm.expectRevert(DSCEngine.DSCEngine__TokenAddressAndPriceFeedAddressMustBeSAmeLength.selector);
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }
    /**
     * PRICE TEST
     */

    function testGetUsdValue() public view {
        uint256 ethAmount = 30e18;
        // 30e18 * 2500/ETH = 75,000e18;
        uint256 expectedUsd = 75_000e18;
        // uint256 expectedUsd = 75743710424100000000000; // When running for sepolia network for now need to keep changing thr expected price with respect to the console out from real world price

        uint256 actualUsd = dscEngine.getUsdValue(weth, ethAmount);
        console2.log("the actual ETH price is: {}", actualUsd);
        console2.log("Sender address", msg.sender);
        assertEq(expectedUsd, actualUsd);
    }

    function testGetTokenAmountFromUsd() public view {
        uint256 usdAmount = 100 ether;
        // 100 / 2500 = 0.04
        uint256 expectedWeth = 0.04 ether;
        uint256 actualWeth = dscEngine.getTokenAmountFromUsd(weth, usdAmount);
        assertEq(expectedWeth, actualWeth);
    }

    /**
     * DEPOSITE COLLATERAL TEST
     */
    modifier depositCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositeColateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    function testRevertsIfCollateralZerro() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);

        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZerro.selector);
        dscEngine.depositeColateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertWithUnapprovedCollateral() public {
        ERC20Mock randomToken = new ERC20Mock("RDT", "RDT", USER, AMOUNT_COLLATERAL);
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__TokenNotAllowed.selector);
        dscEngine.depositeColateral(address(randomToken), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function testCanDepositeCollateralAndGetAccountInfomation() public depositCollateral {
        (uint256 totalDscMinted, uint256 CollateralValueInUsd) = dscEngine.getAccountInformation(USER);
        uint256 expectedTotalDscMinted = 0;
        uint256 expectedCollateralValueInUsd = dscEngine.getTokenAmountFromUsd(weth, CollateralValueInUsd);

        assertEq(expectedTotalDscMinted, totalDscMinted);
        assertEq(expectedCollateralValueInUsd, AMOUNT_COLLATERAL);
    }

    function testHealthFactor() public {
        // Set up initial conditions
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositeColateral(weth, AMOUNT_COLLATERAL);

        uint256 totalDscMinted = AMOUNT_COLLATERAL / 2;
        dscEngine.mintDsc(totalDscMinted);

        // Calculate health factor
        uint256 collateralValueInUsd = dscEngine.getUsdValue(weth, AMOUNT_COLLATERAL);
        uint256 collateralAdjustmentForTreshold = (collateralValueInUsd * LIQUIDATION_TRESHOLD) / LIQUIDATION_PRECISION;
        uint256 expectedHealthFactor = (collateralAdjustmentForTreshold * PRECISION) / totalDscMinted;
        console2.log("User expected health factor", expectedHealthFactor);

        // Assert health factor calculation
        uint256 actualHealthFactor = dscEngine.getHealthFactor(USER);
        console2.log("User actual health factor  ", actualHealthFactor);
        assertEq(actualHealthFactor, expectedHealthFactor, "Incorrect health factor calculation");
    }

    function testLiquidation() public {
        // Set up initial conditions
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositeColateral(weth, AMOUNT_COLLATERAL);

        // Mint DSC to reduce health factor
        uint256 amountToMint = AMOUNT_COLLATERAL / 2;
        dscEngine.mintDsc(amountToMint);

        // Liquidate user
        uint256 debtToCover = AMOUNT_COLLATERAL / 4;
        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorOk.selector);
        dscEngine.liquidate(weth, USER, debtToCover);

        // Increase debt to cover threshold
        debtToCover = AMOUNT_COLLATERAL * LIQUIDATION_TRESHOLD / LIQUIDATION_PRECISION;
        vm.expectRevert(DSCEngine.DSCEngine__BreaksHealthFactor.selector);
        dscEngine.liquidate(weth, USER, debtToCover);

        // Test successful liquidation
        dscEngine.burnDsc(debtToCover);
        dscEngine.redeemCollateral(weth, AMOUNT_COLLATERAL);

        // Assert that health factor has improved
        uint256 endingUserHealthFactor = dscEngine.getHealthFactor(USER);
        assertEq(endingUserHealthFactor > MIN_HEALTH_FACTOR, true);
    }

    //     function testLiquidation() public {
    //     // Set up initial conditions
    //     vm.startPrank(USER);

    //     // Increase the initial balance of weth
    //     ERC20Mock(weth).mint(USER, AMOUNT_COLLATERAL * 2);

    //     // Approve DSCEngine to spend double the collateral amount
    //     ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL * 2);

    //     // Deposit collateral
    //     dscEngine.depositeColateral(weth, AMOUNT_COLLATERAL * 2);

    //     // Mint DSC to reduce health factor
    //     uint256 amountToMint = AMOUNT_COLLATERAL;
    //     dscEngine.mintDsc(amountToMint);

    //     // Liquidate user
    //     uint256 debtToCover = AMOUNT_COLLATERAL / 2;
    //     // vm.expectRevert(DSCEngine.DSCEngine__HealthFactorOk.selector);
    //     // dscEngine.liquidate(weth, USER, debtToCover);

    //     // Increase debt to cover threshold
    //     debtToCover = AMOUNT_COLLATERAL * LIQUIDATION_TRESHOLD / LIQUIDATION_PRECISION;
    //     vm.expectRevert(DSCEngine.DSCEngine__BreaksHealthFactor.selector);
    //     dscEngine.liquidate(weth, USER, debtToCover);

    //     // Test successful liquidation
    //     dscEngine.burnDsc(debtToCover);
    //     dscEngine.redeemCollateral(weth, AMOUNT_COLLATERAL);

    //     // Assert that health factor has improved
    //     uint256 endingUserHealthFactor = dscEngine.getHealthFactor(USER);
    //     assertEq(endingUserHealthFactor > MIN_HEALTH_FACTOR, true);
    // }

    function testMultipleCollateralTypes() public {
        // Set up initial conditions
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        ERC20Mock(wbtc).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositeColateral(weth, AMOUNT_COLLATERAL);
        dscEngine.depositeColateral(wbtc, AMOUNT_COLLATERAL);

        // Mint DSC using both collaterals
        uint256 wethAmount = AMOUNT_COLLATERAL / 2;
        uint256 wbtcAmount = AMOUNT_COLLATERAL / 2;
        dscEngine.mintDsc(wethAmount);
        dscEngine.mintDsc(wbtcAmount);

        // Assert that DSC balance reflects both collaterals
        uint256 totalDscMinted = wethAmount + wbtcAmount;
        assertEq(dscEngine.getDscMinted(USER), totalDscMinted, "Expected total DSC minted to reflect both collaterals");
    }

    function testBurnDsc() public {
        // Set up initial conditions
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositeColateral(weth, AMOUNT_COLLATERAL);
        uint256 amountToBurn = AMOUNT_COLLATERAL / 2;
        // dscEngine.mintDsc(amountToBurn);

        // Burn DSC
        dscEngine.burnDsc(amountToBurn);

        // Assert that DSC balance has decreased
        uint256 newDscBalance = dscEngine.getDscMinted(USER);
        assertEq(newDscBalance, amountToBurn, "Expected DSC balance to decrease");
    }
}
