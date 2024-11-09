// SPDX-License-Identifier: MIT

// What are our invariants
/**
 * 1. The totall value of collateral should be more than the total value of DSC supply
 * 2. OUR GETTER VIEW FUNCTION SHOULD NERVER REVERT
 * 3. and many more that can be an invariant property
 *  
 */

pragma solidity ^0.8.24;

import {console2, Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {DecentralizedStableCoin} from "src/DecentralizedStableCoin.sol";
import {DSCEngine} from "src/DSCEngine.sol";
import {DeployDSC} from "script/DeployDSC.s.sol";
import {HelperConfig} from "script/HelperConfig.s.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Handler} from "./Handler.t.sol";

contract InvariantsTest is StdInvariant, Test {
    DecentralizedStableCoin dsc;
    DSCEngine dscEngine;
    DeployDSC deployer;
    HelperConfig helperConfig;
    address weth;
    address wbtc;
    Handler handler;

    function setUp() external {
        deployer = new DeployDSC();
        (dsc, dscEngine, helperConfig) = deployer.run();
        (,, weth, wbtc,) = helperConfig.activeNetworkConfig();
        handler = new Handler(dscEngine, dsc);
        // The following line of code tells foundry to go wild on the specified contract 
        // but with respect how the handler specifies  
        targetContract(address(handler));
    }

    function invariant_protocolMustHaveMoreValueThanTotallSupply() public view {
        // get the value all the collateral in the protocol
        // and compare it to all the dept (dsc)

        uint256 totalSupply = dsc.totalSupply();
        uint256 totalWethDeposited = IERC20(weth).balanceOf(address(dsc));
        uint256 totalWbtcDeposited = IERC20(wbtc).balanceOf(address(dsc));
        uint256 wethValueInUsd = dscEngine.getUsdValue(weth, totalWethDeposited);
        uint256 wbtcValueInUsd = dscEngine.getUsdValue(wbtc, totalWbtcDeposited);

        console2.log("weth value in USD", wethValueInUsd);
        console2.log("wbtc value in USD", wbtcValueInUsd);
        console2.log("total supply value in USD", totalSupply);
        console2.log("weth address in Invariant", weth);
        console2.log("wbtc address in Invariant", wbtc);
        console2.log("Time mint is called: ", handler.timeMintIscalled());

        assert((wethValueInUsd + wbtcValueInUsd) >= totalSupply);
    }

    function invariant_gettersShouldNotRevert() public view {
        dscEngine.getAccountCollateralValue(msg.sender);
        dscEngine.getAccountInformation(msg.sender);
        dscEngine.getAdditionalFeedPrecision();
        dscEngine.getCollateralBalanceOfUser(msg.sender, weth);
        dscEngine.getCollateralTokenPriceFeed(weth);
        dscEngine.getCollateralTokens();
        dscEngine.getDsc();
        dscEngine.getDscMinted(msg.sender);
        dscEngine.getHealthFactor(msg.sender);
        dscEngine.getLiquidationBonus();
        dscEngine.getLiquidationPrecision();
        dscEngine.getLiquidationThreshold();
        dscEngine.getMinHealthFactor();
        dscEngine.getPrecision();
        // dscEngine.getTokenAmountFromUsd(); // takes 2 args(addressToken, amountToken)
        // dscEngine.getUsdValue(); // takes 2 args(addressToken, amountToken)
    }
}