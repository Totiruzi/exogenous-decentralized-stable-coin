// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {DecentralizedStableCoin} from "src/DecentralizedStableCoin.sol";
import {DSCEngine} from "src/DSCEngine.sol";
import {DeployDSC} from "script/DeployDSC.s.sol";
import {HelperConfig} from "script/HelperConfig.s.sol";
import {ERC20Mock} from "test/mocks/ERC20Mock.sol";
import {MockV3Aggregator} from "test/mocks/MockV3Aggregator.sol"; 
import { MockFailedTransferFrom } from "test/mocks/MockFailedTransferFrom.sol";
import { MockFailedMintDSC } from "test/mocks/MockFailedMintDSC.sol";



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
    uint256 public amount_to_mint = 100 ether;
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
        dscEngine.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    function testRevertsIfTransferFromFails() public {
        // Arrange - Setup
        address owner = msg.sender;
        vm.prank(owner);
        MockFailedTransferFrom mockDsc = new MockFailedTransferFrom();
        tokenAddresses = [address(mockDsc)];
        priceFeedAddresses = [ethUsdPriceFeed];
        vm.prank(owner);
        DSCEngine mockDsce = new DSCEngine(tokenAddresses, priceFeedAddresses, address(mockDsc));
        mockDsc.mint(USER, AMOUNT_COLLATERAL);

        vm.prank(owner);
        mockDsc.transferOwnership(address(mockDsce));
        // Arrange - User
        vm.startPrank(USER);
        ERC20Mock(address(mockDsc)).approve(address(mockDsce), AMOUNT_COLLATERAL);
        // Act / Assert
        vm.expectRevert(DSCEngine.DSCEngine__TransferFailed.selector);
        mockDsce.depositCollateral(address(mockDsc), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function testRevertsIfCollateralZerro() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);

        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZerro.selector);
        dscEngine.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertWithUnapprovedCollateral() public {
        ERC20Mock randomToken = new ERC20Mock("RDT", "RDT", USER, AMOUNT_COLLATERAL);
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__TokenNotAllowed.selector);
        dscEngine.depositCollateral(address(randomToken), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function testCanDepositCollateralWithoutMinting() public depositCollateral {
        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance, 0);
    }

    function testCanDepositeCollateralAndGetAccountInfomation() public depositCollateral {
        (uint256 totalDscMinted, uint256 CollateralValueInUsd) = dscEngine.getAccountInformation(USER);
        uint256 expectedTotalDscMinted = 0;
        uint256 expectedCollateralValueInUsd = dscEngine.getTokenAmountFromUsd(weth, CollateralValueInUsd);

        assertEq(expectedTotalDscMinted, totalDscMinted);
        assertEq(expectedCollateralValueInUsd, AMOUNT_COLLATERAL);
    }

    /**
     * DEPOSITE COLLATERAL AND MINT USD TEST
     */

    modifier depositedCollateralAndMintedDsc() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, amount_to_mint);
        vm.stopPrank();
        _;
    }

    function testRevertsIfMintedUsdBreaksHealtFactor() public {
        (, int256 price,,,) = MockV3Aggregator(ethUsdPriceFeed).latestRoundData();
        amount_to_mint = (AMOUNT_COLLATERAL * (uint256(price)) * dscEngine.getAdditionalFeedPrecition()) / dscEngine.getPrecision();

        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);

        uint256 expectedHealthFactor = dscEngine.calculateHealthFactor(amount_to_mint, dscEngine.getUsdValue(weth, AMOUNT_COLLATERAL));
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, expectedHealthFactor));
        dscEngine.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, amount_to_mint);
        vm.stopPrank();
    }

    function testCanMintWithDepositedCollateral() public depositedCollateralAndMintedDsc {
        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance, amount_to_mint);
    }

    /**
     * MINT DSC TEST
     */

    function testRevertsIfMintFails() public {
        // Arrange - Setup
        MockFailedMintDSC mockDsc = new MockFailedMintDSC();
        tokenAddresses = [weth];
        priceFeedAddresses = [ethUsdPriceFeed];
        address owner = msg.sender;
        vm.prank(owner);
        DSCEngine mockDscEngine = new DSCEngine(tokenAddresses, priceFeedAddresses, address(mockDsc));
        mockDsc.transferOwnership(address(mockDscEngine));

        // Arrange - USER
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(mockDscEngine), AMOUNT_COLLATERAL);
        vm.expectRevert(DSCEngine.DSCEngine__MintFailed.selector);
        mockDscEngine.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, amount_to_mint);
        vm.stopPrank();
    }

    function testRevertsIfMintAmountIsZerro() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositCollateralAndMintDsc(weth,AMOUNT_COLLATERAL, amount_to_mint);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZerro.selector);
        dscEngine.mintDsc(0);
        vm.stopPrank();
    }

    function testRevertsIfMintAmountBreaksHealthFactor() public depositCollateral {
        (, int256 price,,,) = MockV3Aggregator(ethUsdPriceFeed).latestRoundData();
        amount_to_mint = (AMOUNT_COLLATERAL * (uint256 (price)) * dscEngine.getAdditionalFeedPrecision()) / dscEngine.getPrecision();

        vm.startPrank(USER);
        uint256 expectedHealthFActor = dscEngine.calculateHealthFactor(amount_to_mint, dscEngine.getUsdValue(weth, AMOUNT_COLLATERAL));
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, expectedHealthFActor));
        dscEngine.mintDsc(amount_to_mint);
        vm.stopPrank();
    }

    function testCanMintDsc() public depositCollateral {
        vm.startPrank(USER);
        dscEngine.mintDsc(amount_to_mint);

        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance, amount_to_mint);
    }


    /**
     * BURN DSC TEST
     */

    function testRevertsIfBurnAmountIsZerro() public depositCollateral {
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZerro.selector);
        dscEngine.burnDsc(0);
    }

    function testCAntBurnMoreThanUserHas() public {
        vm.prank(USER);
        vm.expectRevert();
        dscEngine.burnDsc(20);
    }

    /**
     * Below test failed with error
     * [FAIL: ERC20InsufficientBalance(0x6CA6d1e2D5347Bfab1d91e883F1915560e09129D, 0, 10000000000000000000 [1e19])] testBurnDsc()
     */
    // function testBurnDsc() public {
    //     // Set up initial conditions
    //     vm.startPrank(USER);
    //     ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
    //     dscEngine.depositCollateral(weth, AMOUNT_COLLATERAL);
    //     // uint256 amountToBurn = AMOUNT_COLLATERAL;
    //     dscEngine.mintDsc(AMOUNT_COLLATERAL);
    //     vm.stopPrank();


    //     vm.startPrank(USER);
    //     ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
    //     dscEngine.depositCollateral(weth, AMOUNT_COLLATERAL);
    //     // Burn DSC
    //     // ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
    //     dscEngine.burnDsc(AMOUNT_COLLATERAL);

    //      // Approve DSCEngine to spend the tokens

    //     // Assert that DSC balance has decreased
    //     uint256 newDscBalance = dsc.balanceOf(USER);
    //     console2.log("newDscBalance: ", newDscBalance);
    //     assertEq(newDscBalance, 0, "Expected DSC balance to decrease");
    // }


     function testCanBurnDsc() public depositedCollateralAndMintedDsc {
        vm.startPrank(USER);
        dsc.approve(address(dscEngine), amount_to_mint);
        dscEngine.burnDsc(amount_to_mint);
        vm.stopPrank();

        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance, 0);
    }

    function testHealthFactor() public {
        // Set up initial conditions
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositCollateral(weth, AMOUNT_COLLATERAL);

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

    

    function testMultipleCollateralTypes() public {
        // Set up initial conditions
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        ERC20Mock(wbtc).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositCollateral(weth, AMOUNT_COLLATERAL);
        dscEngine.depositCollateral(wbtc, AMOUNT_COLLATERAL);

        // Mint DSC using both collaterals
        uint256 wethAmount = AMOUNT_COLLATERAL / 2;
        uint256 wbtcAmount = AMOUNT_COLLATERAL / 2;
        dscEngine.mintDsc(wethAmount);
        dscEngine.mintDsc(wbtcAmount);

        // Assert that DSC balance reflects both collaterals
        uint256 totalDscMinted = wethAmount + wbtcAmount;
        assertEq(dscEngine.getDscMinted(USER), totalDscMinted, "Expected total DSC minted to reflect both collaterals");
    }

    

    // function testLiquidation() public {
    //     // Set up initial conditions
    //     vm.startPrank(USER);
    //     ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
    //     dscEngine.depositeColateral(weth, AMOUNT_COLLATERAL);

    //     // Mint DSC to reduce health factor
    //     uint256 amountToMint = AMOUNT_COLLATERAL / 2;
    //     dscEngine.mintDsc(amountToMint);

    //     // Liquidate user
    //     uint256 debtToCover = AMOUNT_COLLATERAL / 4;
    //     vm.expectRevert(DSCEngine.DSCEngine__HealthFactorOk.selector);
    //     dscEngine.liquidate(weth, USER, debtToCover);

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


    // Example from EngrPips on how he implemented his liquidation test
    //   user_deposited_wETH_and_minted_appropriate_DSC
    //   modifier user_deposited_wETH_and_minted_appropriate_DSC() {
    //     vm.startPrank(EngrPips);
    //     ERC20Mock(wETH_token_address).approve(address(dsc_engine), wETH_test_amount);
    //     dsc_engine.depositCollateral(wETH_token_address, wETH_test_amount);
    //     dsc_engine.mintDSC(appropriate_DSC_to_mint);
    //     vm.stopPrank();
    //     _;
    // }

    // Patrics Modifier

    // modifier depositedCollateralAndMintedDsc() {
    //     vm.startPrank(user);
    //     ERC20Mock(weth).approve(address(dsce), amountCollateral);
    //     dsce.depositCollateralAndMintDsc(weth, amountCollateral, amountToMint);
    //     vm.stopPrank();
    //     _;
    // }

    // test_DSCEngine_properly_liquidate_a_user
    // function test_DSCEngine_properly_liquidate_a_user() public user_deposited_wETH_and_minted_appropriate_DSC{
    //     setUpLiquidator(Patrick);
    //     address price_feed_address_for_wETH_token = dsc_engine.get_the_price_feed_address_for_token(wETH_token_address);
    //     MockV3Aggregator(price_feed_address_for_wETH_token).updateAnswer(wETH_price_that_cause_liquidation);
    //     vm.prank(Patrick);
    //     dsc_engine.liquidate(wETH_token_address, EngrPips, appropriate_DSC_to_mint);
    //     uint256 expected_amount_of_DSC_minted_by_liquidatee = 0;
    //     uint256 actual_amount_of_DSC_minted_by_liquidatee = dsc_engine.get_amount_of_DSC_minted_by_user(EngrPips);
        
    //     assertEq(actual_amount_of_DSC_minted_by_liquidatee, expected_amount_of_DSC_minted_by_liquidatee);
       
    // }

    //     modifier user_deposited_wETH_and_minted_appropriate_DSC() {
    //     vm.startPrank(EngrPips);
    //     ERC20Mock(wETH_token_address).approve(address(dsc_engine), wETH_test_amount);
    //     dsc_engine.depositCollateral(wETH_token_address, wETH_test_amount);
    //     dsc_engine.mintDSC(appropriate_DSC_to_mint);
    //     vm.stopPrank();
    //     _;
    // }

    // modifier set_up_DSC_that_returns_false_on_transfer_from() {
    //     decentralized_stable_coin_that_returns_false_on_transfer_from = new MockReturnFalseOnTransferFrom();

    //     address_of_collateral_tokens.push(wETH_token_address);
    //     address_of_collateral_tokens.push(wBTC_token_address);

    //     address_of_collateral_token_price_feeds.push(wETH_token_addres_price_feed);
    //     address_of_collateral_token_price_feeds.push(wBTC_token_addres_price_feed);

    //     dsc_engine = new DSCEngine(address_of_collateral_tokens, address_of_collateral_token_price_feeds, address(decentralized_stable_coin_that_returns_false_on_transfer_from));
    //     MockFailedTransferFrom(address(decentralized_stable_coin_that_returns_false_on_transfer_from)).transferOwnership(address(dsc_engine));
    
    //     _;
    // }

    // function test_DSCEngine_reverts_when_user_tries_to_burn_zero_DSC() public user_deposited_wETH_and_minted_appropriate_DSC {
    //     vm.prank(EngrPips);
    //     vm.expectRevert(DSCEngine.DSCEngine__transaction_amount_needs_to_be_greater_than_zero.selector);
    //     dsc_engine.burnDSC(0);
    // }

    // function test_DSCEngine_appropriately_burn_decentralized_stable_coin() public user_deposited_wETH_and_minted_appropriate_DSC {
    //     vm.prank(EngrPips);
    //     DecentralizedStableCoin(address(decentralized_stable_coin)).approve(address(dsc_engine), appropriate_DSC_to_burn);
    //     vm.prank(EngrPips);
    //     dsc_engine.burnDSC(appropriate_DSC_to_burn);
    //     uint256 expected_DSC_balance_of_user = 0.1 ether;
    //     uint256 actual_DSC_balance_of_user = dsc_engine.get_amount_of_DSC_minted_by_user(EngrPips);
    //     assertEq(actual_DSC_balance_of_user, expected_DSC_balance_of_user);
    // }

    // function test_DSCEngine_revert_when_decentralized_stable_coin_returns_false_on_transfer_from() public set_up_DSC_that_returns_false_on_transfer_from user_deposited_weth {
    //     vm.prank(EngrPips);
    //     dsc_engine.mintDSC(appropriate_DSC_to_mint);
    //     MockReturnFalseOnTransferFrom(address(decentralized_stable_coin_that_returns_false_on_transfer_from)).approve(address(dsc_engine), appropriate_DSC_to_burn);
    //     vm.prank(EngrPips);
    //     vm.expectRevert(DSCEngine.DSCEngine__transfer_failed_when_user_try_to_burn_DSC.selector);
    //     dsc_engine.burnDSC(appropriate_DSC_to_burn);
    // }
}
