// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IRebaseToken} from "src/interfaces/IRebaseToken.sol";

/**
 * @title Vault
 * @author Ronald Koh
 * @notice This contract is a vault to store all the ETH that user deposits, as well as withdrawl. Rewards will be sent from here as well.
 */
contract Vault {
    //Pass token address to constructor
    // create deposit function that mints token to user equal to the amount ETH the user has sent
    // create reedem function that burns token from user and sendS the user ETH
    // create a way to add rewards to the vault

    ////////////
    // Errors //
    ////////////
    error Vault__RedeemFailed();

    //////////////////////
    // State Variables //
    /////////////////////
    IRebaseToken private immutable i_rebaseToken; // type set as interface as opposed to address

    ////////////
    // Events //
    ////////////
    event Deposit(address indexed user, uint256 amount);
    event Redeem(address indexed user, uint256 amount);

    constructor(IRebaseToken _rebaseToken) {
        i_rebaseToken = _rebaseToken;
    }

    /**
     * @notice This is a fallback function, to send rewards to the Vault
     */
    receive() external payable {}

    /**
     * @notice Allows user to deposit ETH into the vault and mint rebase tokens in return
     */
    function deposit() external payable {
        //1. Use the amount of ETH user sent to mint tokens to user
        //2. emit event
        i_rebaseToken.mint(msg.sender, msg.value);
        emit Deposit(msg.sender, msg.value);
    }

    /**
     * @notice Allow a user to redeem their rebase tokens
     * @param _amount Amount of rebase tokens to redeem
     * @dev Follows CEI Pattern
     */
    function redeem(uint256 _amount) external {
        // Redeem everything the msg.sender has if the amount pass through is the maximum value of type uint256
        if (_amount == type(uint256).max) {
            _amount = i_rebaseToken.balanceOf(msg.sender);
        }

        // 1. Effects
        i_rebaseToken.burn(msg.sender, _amount);

        // 2. Interactions
        (bool success,) = payable(msg.sender).call{value: _amount}("");
        if (!success) revert Vault__RedeemFailed();

        emit Redeem(msg.sender, _amount);
    }

    /////////////
    // Getters //
    /////////////

    /**
     * @notice Gets the address of the rebase token
     * @return The address of the rebase token
     */
    function getRebaseTokenAddress() external view returns (address) {
        return address(i_rebaseToken);
    }
}
