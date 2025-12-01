// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TokenPool} from "@ccip/contracts/src/v0.8/ccip/pools/TokenPool.sol";
import {Pool} from "@ccip/contracts/src/v0.8/ccip/libraries/Pool.sol";
import {IERC20} from "@ccip/contracts/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/token/ERC20/IERC20.sol";
import {IRebaseToken} from "src/interfaces/IRebaseToken.sol";

contract RebaseTokenPool is TokenPool {
    constructor(IERC20 _token, address[] memory _allowlist, address _rmnProxy, address _router)
        TokenPool(_token, _allowlist, _rmnProxy, _router)
    {}

    /**
     * @notice This function is called when we are sending tokens from the source chain that the pool is deployed to, to another chain
     * @param lockOrBurnIn Struct of Lock or Burn from Token Pool
     */
    function lockOrBurn(Pool.LockOrBurnInV1 calldata lockOrBurnIn)
        external
        returns (Pool.LockOrBurnOutV1 memory lockOrBurnOut)
    {
        _validateLockOrBurn(lockOrBurnIn); //validation always comes first to ensure cross chain messages are secure
        uint256 userInterestRate = IRebaseToken(address(i_token)).getUserInterestRate(lockOrBurnIn.originalSender); //cast to address, interface to interface requires intermediatory address casting, not able to cast an interface to an interface directly, but casting address to an interface is okay
        IRebaseToken(address(i_token)).burn(address(this), lockOrBurnIn.amount); //CCIP requires token approval and for user to send token to token pool, CCIP will then send the tokens from token pool on behalf of user. Hence why we are burning from token pool contract address instead of receiver
        lockOrBurnOut = Pool.LockOrBurnOutV1({
            destTokenAddress: getRemoteToken(lockOrBurnIn.remoteChainSelector),
            destPoolData: abi.encode(userInterestRate)
        });
    }

    /**
     * @notice This function is called when the token pool is receiving tokens
     * @param releaseOrMintIn Struct of Release or Mint from Token Pool
     */
    function releaseOrMint(Pool.ReleaseOrMintInV1 calldata releaseOrMintIn)
        external
        returns (Pool.ReleaseOrMintOutV1 memory)
    {
        _validateReleaseOrMint(releaseOrMintIn); //validation always comes first to ensure cross chain messages are secure
        uint256 userInterestRate = abi.decode(releaseOrMintIn.sourcePoolData, (uint256));
        IRebaseToken(address(i_token)).mint(releaseOrMintIn.receiver, releaseOrMintIn.amount, userInterestRate);

        return Pool.ReleaseOrMintOutV1({destinationAmount: releaseOrMintIn.amount});
    }
}
