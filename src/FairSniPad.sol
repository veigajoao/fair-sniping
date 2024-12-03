// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IUniswapV3Factory, INonfungiblePositionManager} from "./Interfaces.sol";

contract FairSniPad {
    IUniswapV3Factory public immutable uniswapV3Factory;
    INonfungiblePositionManager public immutable nonfungiblePositionManager;
    address public immutable weth;

    uint24 public immutable FEE;

    mapping(address => FairSnipe) public fairSnipes;

    struct FairSnipe {
        address token;
        uint256 tokenAmount;
        int24 initialTick;
        uint256 launchTimestamp;
        // supports at most 3 trenches of snipers
        SnipeConditions[3] snipeTrenches;
        bool executed;
    }

    struct SnipeConditions {
        INonfungiblePositionManager.MintParams mintParams;
        uint256 maxLockedTime;
    }

    mapping(bytes32 => TrenchTracking) public trenchTracking;
    // Shares are tracked combining the owner, token, trench index, and quote amount
    mapping(bytes32 => SnipePositionTracking) public snipePositionTracking;

    struct TrenchTracking {
        uint256 totalQuoteAmount;
        uint256 totalAccruedRewardsToken;
        uint256 totalAccruedRewardsQuote;
        bool unlocked;
    }

    struct SnipePositionTracking {
        uint256 quoteAmount;
        uint256 rewardsTokenTracker;
        uint256 rewardsQuoteTracker;
        bool unlocked;
    }

    function deriveSnipeIntentTrackingKey(address owner, address token, uint256 trenchIndex, uint256 quoteAmount)
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(owner, token, trenchIndex, quoteAmount));
    }

    function deriveTrenchTrackingKey(address token, uint256 trenchIndex) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(token, trenchIndex));
    }

    function addFairSnipe(FairSnipe memory fairSnipe) public {
        // check if fairSnipe already exists
        if (fairSnipes[fairSnipe.token].token != address(0)) {
            revert("FairSnipe already exists");
        }
        // create fairSnipe
        fairSnipes[fairSnipe.token] = fairSnipe;
        // transfer fairSnipe.tokenAmount worth of token to this contract
        IERC20(fairSnipe.token).transferFrom(msg.sender, address(this), fairSnipe.tokenAmount);
    }

    function addSnipeIntent(address token, uint256 trenchIndex, uint256 quoteAmount) public {
        FairSnipe memory _fairSnipe = fairSnipes[token];
        // check if fairSnipe exists
        if (_fairSnipe.token == address(0)) {
            revert("FairSnipe does not exist");
        }
        // check not executed and launchTimestamp is in the past
        if (_fairSnipe.executed) {
            revert("FairSnipe already executed");
        }
        if (_fairSnipe.launchTimestamp < block.timestamp) {
            revert("FairSnipe already launched");
        }
        // check trenchIndex is valid
        if (trenchIndex >= 3) {
            revert("Invalid trench index");
        }
        trenchTracking[deriveTrenchTrackingKey(token, trenchIndex)].totalQuoteAmount += quoteAmount;
        snipePositionTracking[deriveSnipeIntentTrackingKey(msg.sender, token, trenchIndex, quoteAmount)].quoteAmount +=
            quoteAmount;
        // transfer quoteAmount worth of token to this contract
        IERC20(token).transferFrom(msg.sender, address(this), quoteAmount);
    }

    function executeFairSnipe(address token) public {
        FairSnipe memory _fairSnipe = fairSnipes[token];
        // check if fairSnipe exists
        if (_fairSnipe.token == address(0)) {
            revert("FairSnipe does not exist");
        }
        // check not executed and launchTimestamp is in the past
        if (_fairSnipe.executed) {
            revert("FairSnipe already executed");
        }
        if (_fairSnipe.launchTimestamp > block.timestamp) {
            revert("FairSnipe timestamp not reached yet");
        }
        // create pool
        uint160 sqrtPriceX96 = _fairSnipe.initialTick.getSqrtRatioAtTick();
        address pool = uniswapV3Factory.createPool(address(token), weth, FEE);
        IUniswapV3Factory(pool).initialize(sqrtPriceX96);

        // add initial liquidity

        // loop over tranches
            // execute snipe intents
            // lock snipe intents
    }
}
