// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {CCIPLocalSimulatorFork, Register} from "@chainlink/local/src/ccip/CCIPLocalSimulatorFork.sol";
import {IERC20} from "@ccip/contracts/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/token/ERC20/IERC20.sol";
import {RegistryModuleOwnerCustom} from "@ccip/contracts/src/v0.8/ccip/tokenAdminRegistry/RegistryModuleOwnerCustom.sol";
import {TokenAdminRegistry} from "@ccip/contracts/src/v0.8/ccip/tokenAdminRegistry/TokenAdminRegistry.sol";
import {TokenPool} from "@ccip/contracts/src/v0.8/ccip/pools/TokenPool.sol";
import {RateLimiter} from "@ccip/contracts/src/v0.8/ccip/libraries/RateLimiter.sol";

import {RebaseToken} from "src/RebaseToken.sol";
import {RebaseTokenPool} from "src/RebaseTokenPool.sol";
import {Vault} from "src/Vault.sol";
import {IRebaseToken} from "src/interfaces/IRebaseToken.sol";

contract CrossChainTest is Test {
    address owner = makeAddr("owner");
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

    /*
      struct ChainUpdate {
    uint64 remoteChainSelector; // ──╮ Remote chain selector
    bool allowed; // ────────────────╯ Whether the chain should be enabled
    bytes remotePoolAddress; //        Address of the remote pool, ABI encoded in the case of a remote EVM chain.
    bytes remoteTokenAddress; //       Address of the remote token, ABI encoded in the case of a remote EVM chain.
    RateLimiter.Config outboundRateLimiterConfig; // Outbound rate limited config, meaning the rate limits for all of the onRamps for the given chain
    RateLimiter.Config inboundRateLimiterConfig; // Inbound rate limited config, meaning the rate limits for all of the offRamps for the given chain
    }

    struct Config {
    bool isEnabled; // Indication whether the rate limiting should be enabled
    uint128 capacity; // ────╮ Specifies the capacity of the rate limiter
    uint128 rate; //  ───────╯ Specifies the rate of the rate limiter
    }
    */
}
