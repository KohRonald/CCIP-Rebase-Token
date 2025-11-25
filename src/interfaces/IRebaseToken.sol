// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

interface IRebaseToken {
    function mint(address _from, uint256 _amount) external;
    function burn(address _from, uint256 _amount) external;
}
