// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test, console2} from "../lib/forge-std/src/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
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
        vm.stopPrank();
    }

    function addRewardsToVault(uint256 rewardAmount) public {
        (bool success,) = payable(address(vault)).call{value: rewardAmount}("");
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

    function testRedeemStraightAway(uint256 amount) public {
        amount = bound(amount, 1e5, type(uint96).max);
        //1. Deposit
        vm.startPrank(user);
        vm.deal(user, amount);
        vault.deposit{value: amount}();
        assertEq(rebaseToken.balanceOf(user), amount);

        //2. Redeem
        vault.redeem(type(uint256).max);
        assertEq(rebaseToken.balanceOf(user), 0);
        assertEq(address(user).balance, amount);
        vm.stopPrank();
    }

    function testRedeemAfterTimePassed(uint256 depositAmount, uint256 time) public {
        time = bound(time, 1000, type(uint96).max); //time frame is seconds
        depositAmount = bound(depositAmount, 1e5, type(uint96).max);

        //1. Deposit
        vm.prank(user);
        vm.deal(user, depositAmount);
        vault.deposit{value: depositAmount}();

        //2. Warp time
        vm.warp(block.timestamp + time);
        uint256 balanceAfterSomeTime = rebaseToken.balanceOf(user);

        //2b. Add rewards to vault
        vm.prank(owner);
        vm.deal(owner, balanceAfterSomeTime - depositAmount);
        addRewardsToVault(balanceAfterSomeTime - depositAmount);

        //3. Redeem
        vm.prank(user);
        vault.redeem(type(uint256).max);

        uint256 userBalanceBeforeRedeem = address(user).balance;

        assertEq(userBalanceBeforeRedeem, balanceAfterSomeTime);
        assertGt(userBalanceBeforeRedeem, depositAmount);
    }

    function testTransfer(uint256 amount, uint256 amountToSend) public {
        amount = bound(amount, 1e5 + 1e5, type(uint96).max);
        amountToSend = bound(amountToSend, 1e5, amount - 1e5);

        //1. Deposit
        vm.prank(user);
        vm.deal(user, amount);
        vault.deposit{value: amount}();

        address user2 = makeAddr("user2");
        uint256 userBalance = rebaseToken.balanceOf(user);
        uint256 user2Balance = rebaseToken.balanceOf(user2);
        assertEq(userBalance, amount);
        assertEq(user2Balance, 0);

        //Owner reduces Interest rate
        vm.prank(owner);
        rebaseToken.setInterestRate(4e10);

        //2. Transfer
        vm.prank(user);
        rebaseToken.transfer(user2, amountToSend);
        uint256 userBalanceAfterTransfer = rebaseToken.balanceOf(user);
        uint256 user2BalanceAfterTransfer = rebaseToken.balanceOf(user2);
        assertEq(userBalanceAfterTransfer, userBalance - amountToSend);
        assertEq(user2BalanceAfterTransfer, amountToSend);

        // Check user2 interest rate has been inherited from user (5e10 and not 4e10)
        // Initial interest rate was 5e10
        assertEq(rebaseToken.getUserInterestRate(user), 5e10);
        assertEq(rebaseToken.getUserInterestRate(user2), 5e10);
    }

    /*
    * In here, expectPartialRevert is used over expectRevert. We are telling foundry to check that the selector
    * matches and ignore the rest of the encoded arugments, which are causing failure due to "Error != expected error" 
    */
    function testCannotSetInterestRateIfNotOwner(uint256 newInterestRate) public {
        vm.prank(user);
        vm.expectPartialRevert(Ownable.OwnableUnauthorizedAccount.selector);
        rebaseToken.setInterestRate(newInterestRate);
    }

    function testCannotCallMintAndBurnIfNotOwner() public {
        vm.prank(user);
        vm.expectPartialRevert(IAccessControl.AccessControlUnauthorizedAccount.selector);
        rebaseToken.mint(user, 100);
        vm.expectPartialRevert(IAccessControl.AccessControlUnauthorizedAccount.selector);
        rebaseToken.burn(user, 100);
    }

    function testGetPrincipleAmount(uint256 amount) public {
        amount = bound(amount, 1e5, type(uint96).max);

        //1. Deposit
        vm.prank(user);
        vm.deal(user, amount);
        vault.deposit{value: amount}();
        assertEq(rebaseToken.principleBalanceOf(user), amount);

        //2. Warp Time
        vm.warp(block.timestamp + 24 hours);
        assertEq(rebaseToken.principleBalanceOf(user), amount);
    }

    function testGetRebaseTokenAddress() public view {
        assertEq(vault.getRebaseTokenAddress(), address(rebaseToken));
    }

    function testInterestRateCanOnlyCanDecrease(uint256 newInterestRate) public {
        uint256 initialInterestRate = rebaseToken.getGlobalInterestRate();
        newInterestRate = bound(newInterestRate, initialInterestRate, type(uint96).max);

        vm.prank(owner);
        vm.expectPartialRevert(RebaseToken.RebaseToken__InterestRateCanOnlyDecrease.selector);
        rebaseToken.setInterestRate(newInterestRate);
        assertEq(rebaseToken.getGlobalInterestRate(), initialInterestRate);
    }

    function testOnlyOwnerCanGrantRole() public {
        vm.expectEmit(true, true, true, true);
        emit IAccessControl.RoleGranted(keccak256("MINT_AND_BURN_ROLE"), user, owner);

        vm.prank(owner);
        rebaseToken.grantMintAndBurnRole(user);
    }

    function testNonOwnerCannotGrantRole() public {
        vm.prank(user);
        vm.expectPartialRevert(Ownable.OwnableUnauthorizedAccount.selector);
        rebaseToken.grantMintAndBurnRole(owner);
    }
}
