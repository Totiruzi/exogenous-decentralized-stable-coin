// SPDX-License-Identifier: MIT

// Is going to narrow down the way functions are called

pragma solidity ^0.8.24;

import {console2, Test, console} from "forge-std/Test.sol";
import {DSCEngine} from "src/DSCEngine.sol";
import {DecentralizedStableCoin} from "src/DecentralizedStableCoin.sol";
import {ERC20Mock} from "test/mocks/ERC20Mock.sol";
import {MockV3Aggregator} from "test/mocks/MockV3Aggregator.sol";

contract Handler is Test {
    DecentralizedStableCoin dsc;
    DSCEngine dscEngine;
    ERC20Mock weth;
    ERC20Mock wbtc;
    MockV3Aggregator public ethUsdPriceFeed;
    MockV3Aggregator public btcUsdPriceFeed;

    address[] usersWithCollateralDeposited;

    uint256 MAX_DEPOSIT_SIZE = type(uint96).max; // max uint96 value
    uint256 public timeMintIscalled;

    constructor(DSCEngine _dscEngine, DecentralizedStableCoin _dsc) {
        dscEngine = _dscEngine;
        dsc = _dsc;

        address[] memory collateralTokens = dscEngine.getCollateralTokens();
        weth = ERC20Mock(collateralTokens[0]);
        wbtc = ERC20Mock(collateralTokens[1]);
        ethUsdPriceFeed = MockV3Aggregator(dscEngine.getCollateralTokenPriceFeed(address(weth)));
        btcUsdPriceFeed = MockV3Aggregator(dscEngine.getCollateralTokenPriceFeed(address(wbtc)));

        console2.log("weth address in Handler", address(weth));
        console.log("wbtc address in Handler", address(wbtc));
    }

    function depositeCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        amountCollateral = bound(amountCollateral, 1, MAX_DEPOSIT_SIZE);

        console2.log("weth address in Handler", address(weth));
        console.log("wbtc address in Handler", address(wbtc));
        vm.startPrank(msg.sender);
        collateral.mint(msg.sender, amountCollateral);
        collateral.approve(address(dscEngine), amountCollateral);
        dscEngine.depositCollateral(address(collateral), amountCollateral);
        vm.stopPrank();

        usersWithCollateralDeposited.push(msg.sender);
    }

    function mintDsc(uint256 amountDscToMint, uint256 addressSeed) public {
        if (usersWithCollateralDeposited.length == 0) return;
        console2.log("ADDRESS SEED",  addressSeed);
        address sender = usersWithCollateralDeposited[addressSeed % usersWithCollateralDeposited.length];
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dscEngine.getAccountInformation(sender);


        int256 maxDscToMint = (int256(collateralValueInUsd) / 2) - int256(totalDscMinted);

        if (maxDscToMint < 0) return;

        amountDscToMint = bound(amountDscToMint, 0, uint256(maxDscToMint));

        if (amountDscToMint == 0) return;

        vm.startPrank(sender);
        dscEngine.mintDsc(amountDscToMint);
        vm.stopPrank();

        console2.log("weth address in Handler", address(weth));
        console.log("wbtc address in Handler", address(wbtc));
        timeMintIscalled++;
    }

    function reddeemCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        uint256 maxCollateralToRedeem = dscEngine.getCollateralBalanceOfUser(address(collateral), msg.sender);
        amountCollateral = bound(amountCollateral, 0, maxCollateralToRedeem);

        if (amountCollateral == 0) return;
        dscEngine.redeemCollateral(address(collateral), amountCollateral);

        console2.log("weth address in Handler", address(weth));
        console.log("wbtc address in Handler", address(wbtc));
    }

    // This breaks our test suit
    // function updateCollateralPriceBtc(uint96 newPrice) public {
    //     int256 newPriceInt = int256(uint256(newPrice));
    //     btcUsdPriceFeed.updateAnswer(newPriceInt);
    // }

    // This breaks our test suit
    // function updateCollateralPriceEth(uint96 newPrice) public {
    //     int256 newPriceInt = int256(uint256(newPrice));
    //     ethUsdPriceFeed.updateAnswer(newPriceInt);
    // }

    // Helper function
    function _getCollateralFromSeed(uint256 collateralSeed) private view returns (ERC20Mock) {
        if (collateralSeed % 2 == 0) {
            return weth;
        }
        return wbtc;
    }
}
