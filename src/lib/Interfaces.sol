// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface INonfungiblePositionManager {
    struct MintParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }

    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }

    function mint(
        MintParams calldata params
    )
        external
        payable
        returns (
            uint256 tokenId,
            uint128 liquidity,
            uint256 amount0,
            uint256 amount1
        );

    function createAndInitializePoolIfNecessary(
        address token0,
        address token1,
        uint24 fee,
        uint160 sqrtPriceX96
    ) external payable returns (address pool);

    function collect(
        CollectParams calldata params
    ) external payable returns (uint256 amount0, uint256 amount1);

    function safeTransferFrom(
        address from,
        address to,
        uint256 tokenId
    ) external;
}

interface IUniswapV3Factory {
    function initialize(uint160 sqrtPriceX96) external;

    function createPool(
        address tokenA,
        address tokenB,
        uint24 fee
    ) external returns (address pool);

    function feeAmountTickSpacing(uint24 fee) external view returns (int24);
}

interface ILockerFactory {
    function deploy(
        address token,
        address beneficiary,
        uint64 durationSeconds,
        uint256 tokenId,
        uint256 fees,
        address pool
    ) external payable returns (address);
}

interface ILocker {
    function initializer(uint256 tokenId) external;
}

struct ExactInputSingleParams {
    address tokenIn;
    address tokenOut;
    uint24 fee;
    address recipient;
    uint256 amountIn;
    uint256 amountOutMinimum;
    uint160 sqrtPriceLimitX96;
}

interface ISwapRouter {
    function exactInputSingle(
        ExactInputSingleParams calldata params
    ) external payable returns (uint256 amountOut);
}

interface IMultiLpLocker {
   struct LpLock {
        // token address of locked token
        address token;
        // address of liquidity pool
        address pool;
        // array of token ids from NFT position manager
        uint256[] tokenIds;
        // duration of lock
        uint256 duration;
        // user key
        address positionOwner;
    }

    function lock(LpLock memory _lock) external;
    function release(address _token) external;
    function withdrawERC20(address _token) external;
    function withdrawEth() external;
    function collectFees(address _token) external;
    function claimUserRewards(bytes32 _key, address _token, address _recipient) external;

}
