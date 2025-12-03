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
    uint256 SEND_VALUE = 1e5;

    uint256 sepoliaFork;
    uint256 arbSepoliaFork;

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
        sepoliaFork = vm.createSelectFork("sepolia"); //Creates Fork and selects it
        arbSepoliaFork = vm.createFork("arb-seoplia"); //Create Fork

        ccipLocalSimulatorFork = new CCIPLocalSimulatorFork();
        vm.makePersistent(address(ccipLocalSimulatorFork)); //This cheatcode enables ccipLocalSimulatorFork to be available on both chains

        //===== Deploy and configure on Seoplia =====
        sepoliaNetworkDetails = ccipLocalSimulatorFork.getNetworkDetails(block.chainid); //Struct that stores network details of Seoplia
        vm.startPrank(owner);

        // 1. Deploy and configure on the source chain: Sepolia
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
        TokenAdminRegistry(sepoliaNetworkDetails.tokenAdminRegistryAddress).acceptAdminRole(address(sepoliaToken));

        // 4. Link Tokens to Pools
        TokenAdminRegistry(sepoliaNetworkDetails.tokenAdminRegistryAddress).setPool(
            address(sepoliaToken), address(sepoliaTokenPool)
        );

        vm.stopPrank();

        //===== Deploy and configure on Arbitrum Seoplia =====
        vm.selectFork(arbSepoliaFork); //Change fork we are working on to Arbitrum
        arbSepoliaNetworkDetails = ccipLocalSimulatorFork.getNetworkDetails(block.chainid); //Struct that stores network details of Arbitrium Seoplia
        vm.startPrank(owner);

        // 1. Deploy and configure on the destination chain: Arbitrum Sepolia
        arbSepoliaToken = new RebaseToken(); //Deploying on chain
        arbSepoliaTokenPool = new RebaseTokenPool(
            IERC20(address(arbSepoliaToken)),
            new address[](0), //empty allowList address array to allow anyone to transfer cross chain
            arbSepoliaNetworkDetails.rmnProxyAddress,
            arbSepoliaNetworkDetails.routerAddress
        );

        // 2. Grant role to enable burning and minting to TokenPool Contracts
        arbSepoliaToken.grantMintAndBurnRole(address(arbSepoliaTokenPool));

        // 3. Register EOA as the token admin. This role is required to enable token in CCIP.
        RegistryModuleOwnerCustom(arbSepoliaNetworkDetails.registryModuleOwnerCustomAddress).registerAdminViaOwner(
            address(arbSepoliaToken)
        );

        // 3a. Complete token admin registration process
        TokenAdminRegistry(arbSepoliaNetworkDetails.tokenAdminRegistryAddress).acceptAdminRole(address(arbSepoliaToken));

        // 4. Link Tokens to Pools
        TokenAdminRegistry(arbSepoliaNetworkDetails.tokenAdminRegistryAddress).setPool(
            address(arbSepoliaToken), address(arbSepoliaTokenPool)
        );

        vm.stopPrank();

        // 5. Configuring Token Pools - Configure each pool by setting cross-chain transfer parameters, such as token pool rate limits and enabled destination chains.
        configureTokenPools(
            sepoliaFork,
            address(sepoliaTokenPool),
            arbSepoliaNetworkDetails.chainSelector,
            address(arbSepoliaTokenPool),
            address(arbSepoliaToken)
        );

        configureTokenPools(
            arbSepoliaFork,
            address(arbSepoliaTokenPool),
            sepoliaNetworkDetails.chainSelector,
            address(sepoliaTokenPool),
            address(sepoliaToken)
        );
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
        vm.startPrank(owner);

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
        vm.stopPrank();
    }

    /**
     *
     * @notice This function enables the bridging of tokens from source chain to destination chain. This function does the following
     * 1. Creates the message
     * 2. Gets the fee needed to send message
     * 3. Approve router to pay fee with Link Tokens
     * 3. Approve router to bridge the tokens
     * 4. Sends message
     * @param amountToBridge The amount of tokens to bridge
     * @param localFork The native source blockchain that the token is on
     * @param remoteFork The destination blockcahin to receive the token
     * @param localNetworkDetails The network deatils of the source blockchain
     * @param remoteNetworkDetails The network details of the destination blockchain
     * @param localToken The native source blockchain currency
     * @param remoteToken The native destinaion blockchain currency
     * @dev Contains assertions to check that tokens were bridged
     */
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
        console2.log("amountToBridge: ", amountToBridge);

        //1. Create Message
        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: abi.encode(user),
            data: "",
            tokenAmounts: tokenAmounts,
            feeToken: localNetworkDetails.linkAddress, //Link Token, used to pay the fee
            extraArgs: Client._argsToBytes(Client.EVMExtraArgsV2({gasLimit: 500_000, allowOutOfOrderExecution: false})) //Chainlink Local requires us to pass a gas limit to be able to call the pools to perform actions. In real world, this gas limit is not needed for it to work.
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

        //3b. Approve the Router to spend local tokens on contract's behalf (the amount to bridge)
        vm.prank(user);
        IERC20(address(localToken)).approve(localNetworkDetails.routerAddress, amountToBridge);

        uint256 localBalanceBefore = IERC20(address(localToken)).balanceOf(user);
        console2.log("localBalanceBefore: ", localBalanceBefore);

        //4. Send Tokens cross chain
        vm.prank(user);
        IRouterClient(localNetworkDetails.routerAddress).ccipSend(remoteNetworkDetails.chainSelector, message);

        uint256 localBalanceAfter = IERC20(address(localToken)).balanceOf(user);
        console2.log("localBalanceAfter: ", localBalanceAfter);

        assertEq(localBalanceAfter, localBalanceBefore - amountToBridge); //assert that the bridge amount has sucessfully been sent
        uint256 localUserInterestRate = localToken.getUserInterestRate(user);

        //Here checks if message is propogated on other chain
        vm.selectFork(remoteFork);
        vm.warp(block.timestamp + 20 minutes); //Warp as it might take a little bit of time for message to bridge cross chain
        uint256 remoteBalanceBefore = IERC20(address(remoteToken)).balanceOf(user);
        console2.log("remoteBalanceBefore: ", remoteBalanceBefore);
        vm.selectFork(localFork); // in the latest version of chainlink-local, it assumes you are currently on the local fork before calling switchChainAndRouteMessage

        ccipLocalSimulatorFork.switchChainAndRouteMessage(remoteFork); //Switches chain and propogate the message cross chain

        uint256 remoteBalanceAfter = IERC20(address(remoteToken)).balanceOf(user);
        console2.log("remoteBalanceAfter: ", remoteBalanceAfter);
        console2.log("amountToBridge: ", amountToBridge);

        assertEq(remoteBalanceAfter, remoteBalanceBefore + amountToBridge); //assert that the bridge amount has sucessfully been received

        uint256 remoteUserInterestRate = remoteToken.getUserInterestRate(user);
        assertEq(localUserInterestRate, remoteUserInterestRate); //assert that the address receiving tokens has inherited the destination address's interest rate
    }

    function testBridgeAllTokens() public {
        vm.selectFork(sepoliaFork);
        vm.deal(user, SEND_VALUE);
        vm.prank(user);
        Vault(payable(address(vault))).deposit{value: SEND_VALUE}();
        assertEq(sepoliaToken.balanceOf(user), SEND_VALUE);

        //Bridge from Sepolia to Arbitrum Sepolia
        bridgeTokens(
            SEND_VALUE,
            sepoliaFork,
            arbSepoliaFork,
            sepoliaNetworkDetails,
            arbSepoliaNetworkDetails,
            sepoliaToken,
            arbSepoliaToken
        );

        vm.selectFork(arbSepoliaFork);
        vm.warp(block.timestamp + 20 minutes);

        //Bridge from Arbitrum Sepolia to Sepolia
        bridgeTokens(
            SEND_VALUE,
            arbSepoliaFork,
            sepoliaFork,
            arbSepoliaNetworkDetails,
            sepoliaNetworkDetails,
            arbSepoliaToken,
            sepoliaToken
        );
    }
}
