// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IRebaseToken
 * @author Ronald Koh
 * @notice Interface defining the external functions of the RebaseToken contract.
 * @dev The Vault contract uses this interface to interact with the RebaseToken
 *      without needing its full implementation. When the Vault calls a function
 *      declared in this interface, Solidity encodes the call data and sends it
 *      to the RebaseToken address provided in the Vault constructor.
 *
 *      If the target contract implements the function, it will execute normally.
 *      If the target contract does not implement the function with the same
 *      signature, the call will revert.
 */
interface IRebaseToken {
    function mint(address _from, uint256 _amount, uint256 _interestRate) external;
    function burn(address _from, uint256 _amount) external;
    function balanceOf(address _user) external view returns (uint256);
    function getUserInterestRate(address _user) external view returns (uint256);
    function getGlobalInterestRate() external view returns (uint256);
}
