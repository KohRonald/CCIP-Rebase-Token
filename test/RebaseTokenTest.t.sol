// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test, console2} from "../lib/forge-std/src/Test.sol";
import {RebaseToken} from "src/RebaseToken.sol";
import {Vault} from "src/Vault.sol";

import {IRebaseToken} from "src/interfaces/IRebaseToken.sol";

contract RebaseTokenTest is Test {
    RebaseToken private rebaseToken;
    Vault private vault;

    address public owner = makeAddr("owner");
    address public user = makeAddr("user");

    function setUp() public {
        vm.startPrank(owner);
        rebaseToken = new RebaseToken();
        vault = new Vault(IRebaseToken(address(rebaseToken)));
        rebaseToken.grantMintAndBurnRole(address(vault));
        (bool success,) = payable(address(vault)).call{value: 1e18}("");
        vm.stopPrank();
    }

    function testDepositLinear(uint256 amount) public {
        amount = bound(amount, 1e5, type(uint96).max); //bound used to ensure fuzzing amount is within range, so as to maximize the test cases

        //1. Deposit
        vm.startPrank(user);
        vm.deal(user, amount);
        vault.deposit{value: amount}();

        //2. Check rebase token balance
        uint256 startingBalance = rebaseToken.balanceOf(user);
        console2.log("Starting Balance: ", startingBalance);
        assertEq(startingBalance, amount);

        //3. warp time and check balance again
        vm.warp(block.timestamp + 1 hours);
        uint256 middleBalance = rebaseToken.balanceOf(user);
        assertGt(middleBalance, startingBalance);

        //4. warp time again by same amount and check balance again
        vm.warp(block.timestamp + 1 hours);
        uint256 endBalance = rebaseToken.balanceOf(user);
        assertGt(endBalance, middleBalance);

        //5. Assert that the increase in interest is linear
        //assertApproxEqAbs(), 3rd argument is the tolerance at which the left and right is allowed to differ
        //1 in this case is 1 wei
        //truncation is the reason why both side will not be exactly the same
        assertApproxEqAbs((middleBalance - startingBalance), (endBalance - middleBalance), 1);

        vm.stopPrank();
    }
}
