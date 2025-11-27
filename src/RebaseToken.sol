// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @title RebaseToken
 * @author Ronald Koh
 * @notice This contract is a cross-chain rebase token that incentivises users to deposit into a vault to gain interest and rewards
 * @notice The interest rate in the smart contract can only decrease
 * @notice Each user will have their own interst rate that is the global rate at the time of depositing
 */
contract RebaseToken is ERC20, Ownable, AccessControl {
    ////////////
    // Errors //
    ////////////
    error RebaseToken__InterestRateCanOnlyDecrease(uint256 oldInterestRate, uint256 newInterestRate);

    //////////////////////
    // State Variables //
    /////////////////////
    uint256 private constant PRECISION_FACTOR = 1e18; //This is 1, with 27 decimals precision, so, 1,000,000,000,000,000,000,000,000,000
    bytes32 private constant MINT_AND_BURN_ROLE = keccak256("MINT_AND_BURN_ROLE");
    uint256 private s_interestRate = (5 * PRECISION_FACTOR) / 1e8;
    mapping(address => uint256) private s_userInterestRate;
    mapping(address => uint256) private s_userLastUpdatedTimestamp;

    ////////////
    // Events //
    ////////////
    event InterestRateSet(uint256 newInterestRate);

    constructor() ERC20("Rebase Token", "RBT") Ownable(msg.sender) {}

    function grantMintAndBurnRole(address _account) external onlyOwner {
        _grantRole(MINT_AND_BURN_ROLE, _account);
    }

    //Function Pattern: Checks, Effects, Interactions

    /**
     * @notice Sets the interest rate in the contract
     * @param _newInterestRate The new interest rate to set
     * @dev The interest rate can only decrease
     */
    function setInterestRate(uint256 _newInterestRate) external onlyOwner {
        if (_newInterestRate >= s_interestRate) {
            revert RebaseToken__InterestRateCanOnlyDecrease(s_interestRate, _newInterestRate);
        }
        s_interestRate = _newInterestRate;
        emit InterestRateSet(_newInterestRate);
    }

    /**
     * @notice Get the principle balance of a user. This is the aamount of tokens that have currently been minted to the user, not inclduing any interest that has accured since the last tinme the user interacted with the protocol
     * @param _user The user to get the principle balance for
     * @return The principle balance of the user
     */
    function principleBalanceOf(address _user) external view returns (uint256) {
        return super.balanceOf(_user);
    }

    /**
     * @notice Mints rebase token for the user when they deposit into vault
     * @notice Mints any existing interest first(if any) before minting more, and updating interest rate to global rate
     * @param _to The address of the user to mint to
     * @param _amount The amount of rebase token that the user is minting
     * @dev Update timestamp of user latest minting
     * @dev Maps user address to current global interest rate at the time of minting
     */
    function mint(address _to, uint256 _amount) external onlyRole(MINT_AND_BURN_ROLE) {
        _mintAccruedInterest(_to);
        s_userInterestRate[_to] = s_interestRate;
        _mint(_to, _amount); //_mint inherited from ERC20.sol
    }

    /**
     * @notice This burns the user token when they withdrawl from the vault
     * @param _from The user to burn the tokens from
     * @param _amount The amount of tokens to burn
     * @dev If check to mitigate against dust, where dust is the accureud interest earn when the burn function is already called and is awaiting finality
     */
    function burn(address _from, uint256 _amount) external onlyRole(MINT_AND_BURN_ROLE) {
        _mintAccruedInterest(_from);
        _burn(_from, _amount);
    }

    /**
     * @notice Calculate the balance for the user including the interest that has accumulated since the last update
     * (Principle balance) + some interest that has accrued
     * @param _user The address of the user
     * @dev super keyword - Call the balanceOf() of the parent contract that it is inheriting instead of the overriden function
     * @return The balance of the user including the interest rate that has accumulated since the last update
     */
    function balanceOf(address _user) public view override returns (uint256) {
        // get current principle balance of the user (number of tokens that have actually been minted to user)
        // multiply principle balance by the interest that has accumulated in the time since the balance was last updated
        // afer all the multipliation, we divide with PRECISION_FACTOR(1e18) to normalize the result back to 18 decimals because Solidity does not support floating-point values
        return super.balanceOf(_user) * _calculateUserAccumulatedInterestRateSinceLastUpdate(_user) / PRECISION_FACTOR;
    }

    /**
     * @notice Transfers tokens from one user to another
     * @param _recipient The address to transfer the tokens to
     * @param _amount The amount of tokens to transfer
     * @return Returns true if transfer was successful
     * @dev Mints accrued interest for both sender and recipient before transferring
     * @dev If check to mitigate against dust
     */
    function transfer(address _recipient, uint256 _amount) public override returns (bool) {
        _mintAccruedInterest(msg.sender);
        _mintAccruedInterest(_recipient);

        if (_amount == type(uint256).max) {
            _amount = balanceOf(msg.sender);
        }
        // if the recipient has not yet interacted with the protocol then they inherit the interest rate of the sender
        if (balanceOf(_recipient) == 0) {
            s_userInterestRate[_recipient] = s_userInterestRate[msg.sender];
        }
        return super.transfer(_recipient, _amount);
    }

    /**
     * @notice Transfers tokens from one user to another
     * @param _sender The address to transfer the tokens from
     * @param _recipient The address to transfer the tokens to
     * @param _amount The amount of tokens to transfer
     * @return Returns true if transfer was successful
     * @dev Mints accrued interest for both sender and recipient before transferring
     * @dev If check to mitigate against dust
     */
    function transferFrom(address _sender, address _recipient, uint256 _amount) public override returns (bool) {
        _mintAccruedInterest(_sender);
        _mintAccruedInterest(_recipient);

        if (_amount == type(uint256).max) {
            _amount = balanceOf(_sender);
        }

        // if the recipient has not yet interacted with the protocol then they inherit the interest rate of the sender
        if (balanceOf(_recipient) == 0) {
            s_userInterestRate[_recipient] = s_userInterestRate[_sender];
        }

        return super.transferFrom(_sender, _recipient, _amount);
    }

    /**
     * @notice Calculate the interest that has accumulated since the last update
     * @param _user The user to calculate the interest accumulated for
     * @return linearInterest The interest that has accumulated since the last update
     */
    function _calculateUserAccumulatedInterestRateSinceLastUpdate(address _user) internal view returns (uint256) {
        // we need to calculate the interest rate that has accumulated since the last update
        // this is going to be linear growth with time
        // 1. calculate the time since the last update
        // 2. calculate the time of linear growth
        // 2a. Formula: (principle amount) + (principle amount * interest rate * time)
        // 2b. Simplifed as: principle amount(1 + (interest rate * time)
        // deposit: 10 tokens
        // interest rate: 0.5 tokens/s
        // time elapsed: 2 secs
        // 10 + (10 * 0.5 * 2) = 10 + (10) = 20
        uint256 timeElapsed = block.timestamp - s_userLastUpdatedTimestamp[_user];
        uint256 linearInterest = PRECISION_FACTOR + (s_userInterestRate[_user] * timeElapsed); //Principle(1 + Interest * Time), Principle is multiplied in the super.balanceOf(_user) in the balanceOf()
        return linearInterest;
    }

    /**
     * @notice Here calculate and mints the interest accrued since the last time user interacted with the protocol (eg. burn, mint, transfer)
     * @notice after minting, user timestamp will be updated
     * @param _user The user to mint the accured interest to
     */
    function _mintAccruedInterest(address _user) internal {
        // (1) find user current balance of rebase tokens that have been minted to the user -> Principle balance
        uint256 previousPrincipleBalance = super.balanceOf(_user);
        // (2) calculate their current balance including any interest -> (Principle balance + interest) balanceOf
        uint256 currentBalance = balanceOf(_user);
        // calculate the number of tokens that need to be minted to the user -> (2) - (1)
        uint256 balanceIncrease = currentBalance - previousPrincipleBalance;
        // set the user last updated timestamp
        s_userLastUpdatedTimestamp[_user] = block.timestamp;
        // call _mint to mint the tokens to the user
        _mint(_user, balanceIncrease);
    }

    /////////////
    // Getters //
    /////////////

    /**
     * @notice Gets global interest rate that is currently set for the contract. Any future depositers will receive this interest rate.
     * @return The global interest rate of the contract
     */
    function getGlobalInterestRate() external view returns (uint256) {
        return s_interestRate;
    }

    /**
     * @notice Gets interest rate for the user
     * @param _user The user to get the interest rate for
     * @return The interest rate of the user
     */
    function getUserInterestRate(address _user) external view returns (uint256) {
        return s_userInterestRate[_user];
    }
}
