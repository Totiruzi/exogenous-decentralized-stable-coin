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

import {ERC20, ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title DecentralizedStableCoin
 * @author Oyemechi Chris
 * Collateral: Exogenous
 * Miniting (Stability Mechanism): Decentralized (Algorithmic)
 * Value (Relative Stability): Anchored (Pegged to USD)
 * Collateral Type: Crypto (ETH, BTC)
 * 
 * This is the contract meant to be owned by DSCEngine. It is a ERC20 token that cam be minted and burned by the DSCEngine smart contract
 */

contract DecentralizedStableCoin is ERC20Burnable, Ownable {
    error DecentralizedStableCoin__AmountMustBeMoreThanZerro();
    error DecentralizedStableCoin__BurnAmountExceedBalance();
    error DecentralizedStableCoin__NotZerroAddress();

constructor() ERC20("DecentralizedStableCoin", "DCS") Ownable(msg.sender) {
        
    }

    function burn(uint256 _amount) public override onlyOwner {
        uint256 balance = balanceOf(msg.sender);

        if(_amount <= 0) {
            revert DecentralizedStableCoin__AmountMustBeMoreThanZerro();
        }

        if (balance < _amount) {
            revert DecentralizedStableCoin__BurnAmountExceedBalance();
        }

        super.burn(_amount);
    }

    function mint(address _to, uint256 _amount) external onlyOwner returns(bool) {
        if(_to == address(0)) {
            revert DecentralizedStableCoin__NotZerroAddress();
        }

        if (_amount <= 0) {
            revert DecentralizedStableCoin__AmountMustBeMoreThanZerro();
        }

        _mint(_to, _amount);

        return true;
    }
}