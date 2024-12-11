// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {FairSnipeSimpleBuy, INonfungiblePositionManager} from "@src/FairSnipeSimpleBuy.sol";
import {MultiLpLocker} from "@src/MultiLpLocker.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract TestToken is ERC20 {
    constructor() ERC20("Test Token", "TEST") {
        _mint(msg.sender, 1_000_000 * 10 ** 18);
    }
}

contract FairSnipeTest is Test {
    FairSnipeSimpleBuy public fairSnipe;
    MultiLpLocker public locker;
    TestToken public token;

    string BASE_RPC_URL = "https://base-rpc.publicnode.com";
    uint256 FORK_BLOCK = 22918216;

    address public constant WETH = 0x4200000000000000000000000000000000000006;
    address public constant UNISWAP_V3_FACTORY = 0x33128a8fC17869897dcE68Ed026d694621f6FDfD;
    address public constant NONFUNGIBLE_POSITION_MANAGER = 0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1;
    address public constant SWAP_ROUTER = 0x2626664c2603336E57B271c5C0b26F421741e481;

    address public owner;
    address public alice;
    address public bob;

    uint24 public constant POOL_FEE = 10000;

    function setUp() public {
        vm.createSelectFork(BASE_RPC_URL, FORK_BLOCK);

        owner = makeAddr("owner");
        alice = makeAddr("alice");
        bob = makeAddr("bob");

        vm.startPrank(owner);

        for (uint256 i = 0; i < 1000; i++) {
            token = new TestToken();
            if (address(token) < address(WETH)) {
                break;
            }
        }

        require(address(token) < address(WETH), "Token address should be less than or equal to WETH");
        locker = new MultiLpLocker(
            owner,
            NONFUNGIBLE_POSITION_MANAGER,
            500, // 5% fee
            owner
        );

        fairSnipe = new FairSnipeSimpleBuy(
            UNISWAP_V3_FACTORY, NONFUNGIBLE_POSITION_MANAGER, SWAP_ROUTER, address(locker), WETH, POOL_FEE
        );

        vm.stopPrank();
    }

    function testFairSnipeLaunch() public {
        // Setup launch parameters
        int24 initialTick = -887220; // Price of 1:1
        uint256 launchTimestamp = block.timestamp + 1 days;

        INonfungiblePositionManager.MintParams[] memory launchParams = new INonfungiblePositionManager.MintParams[](1);
        launchParams[0] = INonfungiblePositionManager.MintParams({
            token0: address(token),
            token1: WETH,
            fee: POOL_FEE,
            tickLower: -887200, // Price range ~0.5 to ~2
            tickUpper: 887200,
            amount0Desired: 500_000 * 10 ** 18,
            amount1Desired: 0,
            amount0Min: 0,
            amount1Min: 0,
            recipient: address(fairSnipe),
            deadline: block.timestamp + 2 days
        });

        // Create fair snipe
        vm.startPrank(owner);
        token.approve(address(fairSnipe), type(uint256).max);
        fairSnipe.createFairSnipe(
            address(token), owner, 1_000_000 * 10 ** 18, initialTick, launchTimestamp, launchParams
        );
        vm.stopPrank();

        // Alice and Bob buy in
        vm.deal(alice, 100 ether);
        vm.deal(bob, 200 ether);

        vm.prank(alice);
        fairSnipe.buyInFairSnipe{value: 100 ether}(address(token));

        vm.prank(bob);
        fairSnipe.buyInFairSnipe{value: 200 ether}(address(token));

        // Advance time and execute launch
        vm.warp(launchTimestamp + 1);
        fairSnipe.executeFairSnipe(address(token));

        // Check results
        vm.prank(alice);
        fairSnipe.withdrawFromFairSnipe(address(token));
        assertGt(token.balanceOf(alice), 0, "Alice should have received tokens");

        vm.prank(bob);
        fairSnipe.withdrawFromFairSnipe(address(token));
        assertGt(token.balanceOf(bob), 0, "Bob should have received tokens");

        // Bob should have received twice as many tokens as Alice
        assertEq(
            token.balanceOf(bob) / token.balanceOf(alice), 2, "Bob should have received twice as many tokens as Alice"
        );

        // Check locker
        MultiLpLocker.LpLock memory lock = locker.getLock(address(token));
        assertEq(lock.token, address(token), "Token address should match");
        assertEq(lock.positionOwner, owner, "Position owner should match");
        assertEq(lock.duration, 5 * 12 * 30 days, "Lock duration should match");
        assertGt(lock.tokenIds.length, 0, "Should have locked position");
    }

    function testCannotBuyAfterLaunch() public {
        // Setup and create fair snipe like in previous test
        int24 initialTick = 0;
        uint256 launchTimestamp = block.timestamp + 1 days;

        INonfungiblePositionManager.MintParams[] memory launchParams = new INonfungiblePositionManager.MintParams[](1);
        launchParams[0] = INonfungiblePositionManager.MintParams({
            token0: address(token),
            token1: WETH,
            fee: POOL_FEE,
            tickLower: -887220,
            tickUpper: 887220,
            amount0Desired: 500_000 * 10 ** 18,
            amount1Desired: 500 ether,
            amount0Min: 0,
            amount1Min: 0,
            recipient: address(fairSnipe),
            deadline: block.timestamp + 2 days
        });

        vm.startPrank(owner);
        token.approve(address(fairSnipe), type(uint256).max);
        fairSnipe.createFairSnipe(
            address(token), owner, 1_000_000 * 10 ** 18, initialTick, launchTimestamp, launchParams
        );
        vm.stopPrank();

        // Advance time past launch
        vm.warp(launchTimestamp + 1);

        // Try to buy in after launch time
        vm.deal(alice, 100 ether);
        vm.prank(alice);
        vm.expectRevert("FairSnipe: Launch already executed");
        fairSnipe.buyInFairSnipe{value: 100 ether}(address(token));
    }

    function testCannotExecuteBeforeLaunch() public {
        // Setup and create fair snipe
        int24 initialTick = 0;
        uint256 launchTimestamp = block.timestamp + 1 days;

        INonfungiblePositionManager.MintParams[] memory launchParams = new INonfungiblePositionManager.MintParams[](1);
        launchParams[0] = INonfungiblePositionManager.MintParams({
            token0: address(token),
            token1: WETH,
            fee: POOL_FEE,
            tickLower: -887220,
            tickUpper: 887220,
            amount0Desired: 500_000 * 10 ** 18,
            amount1Desired: 500 ether,
            amount0Min: 0,
            amount1Min: 0,
            recipient: address(fairSnipe),
            deadline: block.timestamp + 2 days
        });

        vm.startPrank(owner);
        token.approve(address(fairSnipe), type(uint256).max);
        fairSnipe.createFairSnipe(
            address(token), owner, 1_000_000 * 10 ** 18, initialTick, launchTimestamp, launchParams
        );
        vm.stopPrank();

        // Try to execute before launch time
        vm.expectRevert("FairSnipe: Launch not executed yet");
        fairSnipe.executeFairSnipe(address(token));
    }

    function testCannotWithdrawBeforeExecution() public {
        // Setup and create fair snipe
        int24 initialTick = 0;
        uint256 launchTimestamp = block.timestamp + 1 days;

        INonfungiblePositionManager.MintParams[] memory launchParams = new INonfungiblePositionManager.MintParams[](1);
        launchParams[0] = INonfungiblePositionManager.MintParams({
            token0: address(token),
            token1: WETH,
            fee: POOL_FEE,
            tickLower: -887220,
            tickUpper: 887220,
            amount0Desired: 500_000 * 10 ** 18,
            amount1Desired: 500 ether,
            amount0Min: 0,
            amount1Min: 0,
            recipient: address(fairSnipe),
            deadline: block.timestamp + 2 days
        });

        vm.startPrank(owner);
        token.approve(address(fairSnipe), type(uint256).max);
        fairSnipe.createFairSnipe(
            address(token), owner, 1_000_000 * 10 ** 18, initialTick, launchTimestamp, launchParams
        );
        vm.stopPrank();

        // Alice buys in
        vm.deal(alice, 100 ether);
        vm.prank(alice);
        fairSnipe.buyInFairSnipe{value: 100 ether}(address(token));

        // Try to withdraw before execution
        vm.prank(alice);
        vm.expectRevert("FairSnipe: Not executed");
        fairSnipe.withdrawFromFairSnipe(address(token));
    }
}
