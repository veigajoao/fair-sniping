// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TickMath} from "./lib/TickMath.sol";
import {
    IUniswapV3Factory,
    INonfungiblePositionManager,
    ExactInputSingleParams,
    ISwapRouter,
    IMultiLpLocker
} from "./lib/Interfaces.sol";

// All code is written supposing token < weth
// We need to write tests for it
// Test different launch setups
contract FairSnipeSimpleBuy {
    using TickMath for int24;

    IUniswapV3Factory public immutable uniswapV3Factory;
    INonfungiblePositionManager public immutable nonfungiblePositionManager;
    ISwapRouter public immutable swapRouter;
    IMultiLpLocker public immutable multiLpLocker;

    address public immutable weth;
    uint24 public immutable POOL_FEE;

    uint256 public immutable LOCK_DURATION = 5 * 12 * 30 days;

    mapping(address => FairSnipeLaunch) public fairSnipes;
    mapping(address => mapping(address => FairSnipeBuyIn)) public fairSnipeBalances;

    struct FairSnipeLaunch {
        address token;
        address positionOwner;
        uint256 totalLiquidityLockDuration; // how long all token liquidity is locked for
        uint256 totalCollectedWethAmount;
        int24 initialTick;
        uint256 launchTimestamp;
        INonfungiblePositionManager.MintParams[] launchParams;
        // SnipeCondition snipeCondition;
        uint256 amountOut;
        bool executed;
    }

    struct FairSnipeBuyIn {
        uint256 wethAmount;
        bool withdrawn;
    }

    // struct SnipeCondition {
    //     INonfungiblePositionManager.MintParams mintParams;
    //     uint256 maxLockedTime;
    // }

    constructor(
        address _uniswapV3Factory,
        address _nonfungiblePositionManager,
        address _swapRouter,
        address _multiLpLocker,
        address _weth,
        uint24 _fee
    ) {
        uniswapV3Factory = IUniswapV3Factory(_uniswapV3Factory);
        nonfungiblePositionManager = INonfungiblePositionManager(_nonfungiblePositionManager);
        swapRouter = ISwapRouter(_swapRouter);
        multiLpLocker = IMultiLpLocker(_multiLpLocker);
        weth = _weth;
        POOL_FEE = _fee;
    }

    function createFairSnipe(
        address _token,
        address _positionOwner,
        uint256 _tokenAmount,
        int24 _initialTick,
        uint256 _launchTimestamp,
        INonfungiblePositionManager.MintParams[] memory _launchParams
    ) external {
        require(_launchTimestamp > block.timestamp, "FairSnipe: Launch timestamp must be in the future");

        // Get storage reference
        FairSnipeLaunch storage newLaunch = fairSnipes[_token];

        // Copy basic fields
        newLaunch.token = _token;
        newLaunch.positionOwner = _positionOwner;
        newLaunch.totalLiquidityLockDuration = LOCK_DURATION;
        newLaunch.totalCollectedWethAmount = 0;
        newLaunch.initialTick = _initialTick;
        newLaunch.launchTimestamp = _launchTimestamp;
        newLaunch.amountOut = 0;
        newLaunch.executed = false;

        // Initialize the array with the correct length
        INonfungiblePositionManager.MintParams[] storage launchParams = newLaunch.launchParams;
        // Copy each struct element by element
        for (uint256 i = 0; i < _launchParams.length; i++) {
            launchParams.push(
                INonfungiblePositionManager.MintParams({
                    token0: _launchParams[i].token0,
                    token1: _launchParams[i].token1,
                    fee: _launchParams[i].fee,
                    tickLower: _launchParams[i].tickLower,
                    tickUpper: _launchParams[i].tickUpper,
                    amount0Desired: _launchParams[i].amount0Desired,
                    amount1Desired: _launchParams[i].amount1Desired,
                    amount0Min: _launchParams[i].amount0Min,
                    amount1Min: _launchParams[i].amount1Min,
                    recipient: _launchParams[i].recipient,
                    deadline: _launchParams[i].deadline
                })
            );
        }

        // check token supply
        uint256 tokenSupply = IERC20(_token).totalSupply();
        require(_tokenAmount == tokenSupply, "FairSnipe: Token amount must be equal to total supply");

        IERC20(_token).transferFrom(msg.sender, address(this), _tokenAmount);
    }

    function buyInFairSnipe(address _token) external payable {
        require(fairSnipes[_token].token == _token, "FairSnipe not created");
        require(fairSnipes[_token].launchTimestamp > block.timestamp, "FairSnipe: Launch already executed");

        fairSnipeBalances[msg.sender][_token].wethAmount += msg.value;
        fairSnipes[_token].totalCollectedWethAmount += msg.value;
    }

    function executeFairSnipe(address _token) external {
        require(fairSnipes[_token].launchTimestamp < block.timestamp, "FairSnipe: Launch not executed yet");
        require(fairSnipes[_token].executed == false, "FairSnipe: Already executed");

        // create pool
        uint160 sqrtPriceX96 = fairSnipes[_token].initialTick.getSqrtRatioAtTick();
        address pool = uniswapV3Factory.createPool(fairSnipes[_token].token, weth, POOL_FEE);
        IUniswapV3Factory(pool).initialize(sqrtPriceX96);

        IERC20(fairSnipes[_token].token).approve(address(nonfungiblePositionManager), type(uint256).max);

        // mint positions
        uint256[] memory tokenIds = new uint256[](fairSnipes[_token].launchParams.length);
        for (uint256 i = 0; i < fairSnipes[_token].launchParams.length; i++) {
            (uint256 tokenId,,,) = nonfungiblePositionManager.mint(fairSnipes[_token].launchParams[i]);
            tokenIds[i] = tokenId;

            nonfungiblePositionManager.safeTransferFrom(address(this), address(multiLpLocker), tokenId);
        }

        // lock positions
        IMultiLpLocker(multiLpLocker).lock(
            IMultiLpLocker.LpLock({
                token: fairSnipes[_token].token,
                pool: address(0),
                tokenIds: tokenIds,
                duration: fairSnipes[_token].totalLiquidityLockDuration,
                positionOwner: fairSnipes[_token].positionOwner
            })
        );

        // execute snipe purchase
        ExactInputSingleParams memory swapParams = ExactInputSingleParams({
            tokenIn: weth,
            tokenOut: fairSnipes[_token].token,
            fee: POOL_FEE,
            recipient: msg.sender,
            amountIn: fairSnipes[_token].totalCollectedWethAmount,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });

        // The call to `exactInputSingle` executes the swap.
        uint256 amountOut = swapRouter.exactInputSingle{value: fairSnipes[_token].totalCollectedWethAmount}(swapParams);

        fairSnipes[_token].executed = true;
        fairSnipes[_token].amountOut = amountOut;
    }

    function withdrawFromFairSnipe(address _token) external {
        require(fairSnipes[_token].executed == true, "FairSnipe: Not executed");
        require(fairSnipeBalances[msg.sender][_token].withdrawn == false, "FairSnipe: Already withdrawn");

        uint256 amountWeth = fairSnipeBalances[msg.sender][_token].wethAmount;
        uint256 amountToken = (amountWeth * fairSnipes[_token].amountOut) / fairSnipes[_token].totalCollectedWethAmount;

        IERC20(fairSnipes[_token].token).transfer(msg.sender, amountToken);
        fairSnipeBalances[msg.sender][_token].withdrawn = true;
    }
}
