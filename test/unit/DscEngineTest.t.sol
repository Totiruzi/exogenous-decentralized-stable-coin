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
    address weth;

    address public USER = makeAddr("user");
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant STARTING_ERC20_BALANCE = 10 ether;


    function setUp() public {
        deployer = new DeployDSC();
        (dsc, dscEngine, helperConfig) = deployer.run();
        (ethUsdPriceFeed, , weth, ,) = helperConfig.activeNetworkConfig();
        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);
    }

    /**
     * PRICE TEST
     */

    function testGetUsdValue() public view {
        uint256 ethAmount = 30e18;
        // 30e18 * 2500/ETH = 75,000e18;
        uint256 expectedUsd = 75_000e18;
        uint256 actualUsd = dscEngine.getUsdValue(weth, ethAmount);
        console2.log("the actual ETH price is: {}", actualUsd);
        assertEq(expectedUsd, actualUsd);
    }

    /**
     * DEPOSITE COLLATERAL TEST
     */

    function testRevertsIfCollateralZerro() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);

        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZerro.selector);
        dscEngine.depositeColateral(weth,0);
        vm.stopPrank();
    }
}