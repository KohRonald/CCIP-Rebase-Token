// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {CCIPLocalSimulatorFork, Register} from "@chainlink/local/src/ccip/CCIPLocalSimulatorFork.sol";
import {IERC20} from "@ccip/contracts/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/token/ERC20/IERC20.sol";
import {RegistryModuleOwnerCustom} from "@ccip/contracts/src/v0.8/ccip/tokenAdminRegistry/RegistryModuleOwnerCustom.sol";
import {TokenAdminRegistry} from "@ccip/contracts/src/v0.8/ccip/tokenAdminRegistry/TokenAdminRegistry.sol";
import {TokenPool} from "@ccip/contracts/src/v0.8/ccip/pools/TokenPool.sol";
import {RateLimiter} from "@ccip/contracts/src/v0.8/ccip/libraries/RateLimiter.sol";
import {Client} from "@ccip/contracts/src/v0.8/ccip/libraries/Client.sol";
import {IRouterClient} from "@ccip/contracts/src/v0.8/ccip/interfaces/IRouterClient.sol";

import {RebaseToken} from "src/RebaseToken.sol";
import {RebaseTokenPool} from "src/RebaseTokenPool.sol";
import {Vault} from "src/Vault.sol";
import {IRebaseToken} from "src/interfaces/IRebaseToken.sol";

contract CrossChainTest is Test {
    address owner = makeAddr("owner");
    address user = makeAddr("user");

    uint256 seopliaFork;
    uint256 arbSeopliaFork;

    CCIPLocalSimulatorFork public ccipLocalSimulatorFork;

    RebaseToken sepoliaToken;
    RebaseToken arbSepoliaToken;

    Vault vault; //Only needed to deploy on source address

    RebaseTokenPool sepoliaTokenPool;
    RebaseTokenPool arbSepoliaTokenPool;

    Register.NetworkDetails sepoliaNetworkDetails;
    Register.NetworkDetails arbSepoliaNetworkDetails;

    //Source Chain: RebaseToken, TokenPool, Vault
    //Destination Chain: RebaseToken, TokenPool
    function setUp() public {
        seopliaFork = vm.createSelectFork("sepolia"); //Creates Fork and selects it
        arbSeopliaFork = vm.createFork("arb-seoplia"); //Create Fork

        ccipLocalSimulatorFork = new CCIPLocalSimulatorFork();
        vm.makePersistent(address(ccipLocalSimulatorFork)); //This cheatcode enables ccipLocalSimulatorFork to be available on both chains

        //===== Deploy and configure on Seoplia =====
        sepoliaNetworkDetails = ccipLocalSimulatorFork.getNetworkDetails(block.chainid); //Struct that stores network details of Seoplia
        vm.startPrank(owner);

        // 1. Deploy contracts
        sepoliaToken = new RebaseToken(); //Deploying on chain
        vault = new Vault(IRebaseToken(address(sepoliaToken)));
        sepoliaTokenPool = new RebaseTokenPool(
            IERC20(address(sepoliaToken)),
            new address[](0), //empty allowList address array to allow anyone to transfer cross chain
            sepoliaNetworkDetails.rmnProxyAddress,
            sepoliaNetworkDetails.routerAddress
        );

        // 2. Grant role to enable burning and minting to TokenPool and Vault Contracts
        sepoliaToken.grantMintAndBurnRole(address(sepoliaTokenPool));
        sepoliaToken.grantMintAndBurnRole(address(vault));

        // 3. Register EOA as the token admin. This role is required to enable token in CCIP.
        RegistryModuleOwnerCustom(sepoliaNetworkDetails.registryModuleOwnerCustomAddress).registerAdminViaOwner(
            address(sepoliaToken)
        );

        // 3a. Complete token admin registration process
        TokenAdminRegistry(sepoliaNetworkDetails.registryModuleOwnerCustomAddress).acceptAdminRole(
            address(sepoliaToken)
        );

        // 4. Link Tokens to Pools
        TokenAdminRegistry(sepoliaNetworkDetails.registryModuleOwnerCustomAddress).setPool(
            address(sepoliaToken), address(sepoliaTokenPool)
        );

        // 5. Configuring Token Pools - Configure each pool by setting cross-chain transfer parameters, such as token pool rate limits and enabled destination chains.
        configureTokenPools(
            seopliaFork,
            address(sepoliaTokenPool),
            arbSepoliaNetworkDetails.chainSelector,
            address(arbSepoliaTokenPool),
            address(arbSepoliaToken)
        );

        vm.stopPrank();

        //===== Deploy and configure on Arbitrum Seoplia =====
        vm.selectFork(arbSeopliaFork); //Change fork we are working on to Arbitrum
        arbSepoliaNetworkDetails = ccipLocalSimulatorFork.getNetworkDetails(block.chainid); //Struct that stores network details of Arbitrium Seoplia
        vm.startPrank(owner);

        // 1. Deploy contracts
        arbSepoliaToken = new RebaseToken(); //Deploying on chain
        arbSepoliaTokenPool = new RebaseTokenPool(
            IERC20(address(sepoliaToken)),
            new address[](0), //empty allowList address array to allow anyone to transfer cross chain
            sepoliaNetworkDetails.rmnProxyAddress,
            sepoliaNetworkDetails.routerAddress
        );

        // 2. Grant role to enable burning and minting to TokenPool Contracts
        arbSepoliaToken.grantMintAndBurnRole(address(sepoliaTokenPool));

        // 3. Register EOA as the token admin. This role is required to enable token in CCIP.
        RegistryModuleOwnerCustom(arbSepoliaNetworkDetails.registryModuleOwnerCustomAddress).registerAdminViaOwner(
            address(arbSepoliaToken)
        );

        // 3a. Complete token admin registration process
        TokenAdminRegistry(arbSepoliaNetworkDetails.registryModuleOwnerCustomAddress).acceptAdminRole(
            address(arbSepoliaToken)
        );

        // 4. Link Tokens to Pools
        TokenAdminRegistry(arbSepoliaNetworkDetails.registryModuleOwnerCustomAddress).setPool(
            address(arbSepoliaToken), address(arbSepoliaTokenPool)
        );

        // 5. Configuring Token Pools - Configure each pool by setting cross-chain transfer parameters, such as token pool rate limits and enabled destination chains.
        configureTokenPools(
            arbSeopliaFork,
            address(arbSepoliaTokenPool),
            sepoliaNetworkDetails.chainSelector,
            address(sepoliaTokenPool),
            address(sepoliaToken)
        );

        vm.stopPrank();
    }

    /**
     * @notice Remote Pool in this function is the remote pool of the current chain. For example, if we are working on Sepolia, then Sepolia is
     * the Local Pool and Arbitrum is the Remote Pool, and vice versa
     */
    function configureTokenPools(
        uint256 fork,
        address localPool,
        uint64 remoteChainSelector,
        address remotePool,
        address remoteTokenAddress
    ) public {
        vm.selectFork(fork);
        vm.prank(owner);

        bytes memory remotePoolAddresses = abi.encode(remotePool);

        TokenPool.ChainUpdate[] memory chains = new TokenPool.ChainUpdate[](1);
        chains[0] = TokenPool.ChainUpdate({
            remoteChainSelector: remoteChainSelector,
            allowed: true,
            remotePoolAddress: remotePoolAddresses,
            remoteTokenAddress: abi.encode(remoteTokenAddress),
            outboundRateLimiterConfig: RateLimiter.Config({isEnabled: false, capacity: 0, rate: 0}),
            inboundRateLimiterConfig: RateLimiter.Config({isEnabled: false, capacity: 0, rate: 0})
        });
        TokenPool(localPool).applyChainUpdates(chains);
    }

    function bridgeTokens(
        uint256 amountToBridge,
        uint256 localFork,
        uint256 remoteFork,
        Register.NetworkDetails memory localNetworkDetails,
        Register.NetworkDetails memory remoteNetworkDetails,
        RebaseToken localToken,
        RebaseToken remoteToken
    ) public {
        vm.selectFork(localFork);

        Client.EVMTokenAmount[] memory tokenAmounts = new Client.EVMTokenAmount[](1);
        tokenAmounts[0] = Client.EVMTokenAmount({token: address(localToken), amount: amountToBridge});

        //1. Create Message
        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: abi.encode(user),
            data: "",
            tokenAmounts: tokenAmounts,
            feeToken: localNetworkDetails.linkAddress, //Link Token
            extraArgs: Client._argsToBytes(Client.EVMExtraArgsV1({gasLimit: 0})) //No custom gas limit set
        });

        //2. Get fees in LINK tokens needed to send cross chain message
        //Cast as IRouterClient interface to call IRouterClient function on this address
        uint256 fee =
            IRouterClient(localNetworkDetails.routerAddress).getFee(remoteNetworkDetails.chainSelector, message);

        //Similar to vm.deal(), gets LINK token to user address
        ccipLocalSimulatorFork.requestLinkFromFaucet(user, fee);

        //3. Approve the Router to transfer LINK tokens on contract's behalf
        //Cast as IERC20 interface to call IERC20 functions on this address
        vm.prank(user);
        IERC20(localNetworkDetails.linkAddress).approve(localNetworkDetails.routerAddress, fee);

        //3b. Approve the Router to spend tokens on contract's behalf
        vm.prank(user);
        IERC20(address(localToken)).approve(localNetworkDetails.routerAddress, amountToBridge);

        uint256 localBalanceBefore = localToken.balanceOf(user);

        //4. Send Tokens cross chain
        vm.prank(user);
        IRouterClient(localNetworkDetails.routerAddress).ccipSend(remoteNetworkDetails.chainSelector, message);

        uint256 localBalanceAfter = localToken.balanceOf(user);

        assertEq(localBalanceAfter - localBalanceBefore, amountToBridge); //assert that the bridge amount has sucessfully been sent
        uint256 localUserInterestRate = localToken.getUserInterestRate(user);

        //Here checks if message is propogated on other chain
        vm.selectFork(remoteFork);
        vm.warp(block.timestamp + 20 minutes); //Warp as it might take a little bit of time for message to bridge cross chain
        uint256 remoteBalanceBefore = remoteToken.balanceOf(user);
        ccipLocalSimulatorFork.switchChainAndRouteMessage(remoteFork); //Switches chain and route the message sent from source chain
        uint256 remoteBalanceAfter = remoteToken.balanceOf(user);
        assertEq(remoteBalanceAfter, remoteBalanceBefore + amountToBridge); //assert that the bridge amount has sucessfully been received

        uint256 remotelUserInterestRate = remoteToken.getUserInterestRate(user);
        assertEq(localUserInterestRate, remotelUserInterestRate); //assert that the address receiving tokens has inherited the destination address's interest rate
    }
}

/**
 *
 *  struct EVM2AnyMessage {
 *     bytes receiver; // abi.encode(receiver address) for dest EVM chains
 *     bytes data; // Data payload
 *     EVMTokenAmount[] tokenAmounts; // Token transfers
 *     address feeToken; // Address of feeToken. address(0) means you will send msg.value.
 *     bytes extraArgs; // Populate this with _argsToBytes(EVMExtraArgsV2)
 *   }
 */
