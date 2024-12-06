// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Context.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

interface INonfungiblePositionManager is IERC721 {
    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }

    function collect(CollectParams calldata params) external payable returns (uint256 amount0, uint256 amount1);

    function positions(uint256 tokenId)
        external
        view
        returns (
            uint96 nonce,
            address operator,
            address token0,
            address token1,
            uint24 fee,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        );
}

contract MultiLpLocker is Ownable, IERC721Receiver {
    // maps created tokens to their position manager token ids
    mapping(address => LpLock) public tokenIds;

    struct LpLock {
        // token address of locked token
        address token;
        // address of liquidity pool
        address pool;
        // array of token ids from NFT position manager
        uint256[] tokenIds;
        // duration of lock
        uint256 duration;
        // owner address
        address positionOwner;
    }

    address public feeRecipient;
    uint256 public fee; // base 10_000 percentage - how much of fees to send to fee recipient
    uint256 public constant FEE_DENOMINATOR = 10000;

    event ERC721Released(address indexed pool, uint256 positionManagerTokenId);
    event Received(address indexed from, uint256 tokenId);

    event Locked(address indexed token, address indexed pool, uint256[] tokenIds, uint256 duration, uint256 fee);

    event ClaimedFees(
        address indexed positionOwner,
        address indexed token0,
        address indexed token1,
        uint256 amount0User,
        uint256 amount1User,
        uint256 amount0Protocol,
        uint256 amount1Protocol
    );

    INonfungiblePositionManager public nonFungiblePositionManager;

    /**
     * @dev Sets initial values for the contract
     */
    constructor(address _owner, address _positionManager, uint256 _fee, address _feeRecipient)
        payable
        Ownable(_owner)
    {
        require(_positionManager != address(0), "position manager cannot be zero address");
        require(_fee < FEE_DENOMINATOR, "fee cannot be greater than 100%");
        require(_feeRecipient != address(0), "fee recipient cannot be zero address");

        nonFungiblePositionManager = INonfungiblePositionManager(_positionManager);
        fee = _fee;
        feeRecipient = _feeRecipient;
    }

    /**
     * @dev Locks a pool of tokens with N different LP positions
     */
    function lock(LpLock memory _lock) public {
        // check if there is already a lock for this pool
        require(tokenIds[_lock.token].token == address(0), "lock already exists");
        // check that lock includes tokens
        require(_lock.tokenIds.length > 0, "lock must include tokens");
        // transfer tokens to this contract
        for (uint256 i = 0; i < _lock.tokenIds.length; i++) {
            require(
                nonFungiblePositionManager.ownerOf(_lock.tokenIds[i]) == address(this),
                "token not owned by this contract"
            );
        }
        tokenIds[_lock.token] = _lock;

        emit Locked(_lock.token, _lock.pool, _lock.tokenIds, _lock.duration, fee);
    }

    /**
     * @dev The contract should be able to receive ETH.
     */
    receive() external payable {}

    /**
     * @dev Release the token that have already vested.
     *
     * Emits a {ERC721Released} event for each LP.
     */
    function release(address _token) public {
        LpLock memory _lock = tokenIds[_token];
        // revert if lock not over
        require(block.timestamp >= _lock.duration, "lock not over");
        // collect fees
        collectFees(_token);
        // loop over token ids
        for (uint256 i = 0; i < _lock.tokenIds.length; i++) {
            nonFungiblePositionManager.transferFrom(address(this), owner(), _lock.tokenIds[i]);
            emit ERC721Released(_lock.pool, _lock.tokenIds[i]);
        }
    }

    /**
     * @dev Withdraws ERC20 tokens from the contract. In case someone deposits ERC20 tokens to the contract, they can be withdrawn.
     */
    function withdrawERC20(address _token) public onlyOwner {
        require(_token != address(nonFungiblePositionManager), "cannot withdraw locked tokens");
        IERC20 token = IERC20(_token);
        token.transfer(owner(), token.balanceOf(address(this)));
    }

    /**
     * @dev Withdraws ETH from the contract. In case someone deposits ETH to the contract, it can be withdrawn.
     */
    function withdrawEth() public onlyOwner {
        payable(owner()).transfer(address(this).balance);
    }

    /**
     * @dev Collects fees from the contract for a specific token.
     */
    function collectFees(address _token) public onlyOwner {
        LpLock memory _lock = tokenIds[_token];
        require(_lock.token != address(0), "lock does not exist");
        // loop over different token ids
        for (uint256 i = 0; i < _lock.tokenIds.length; i++) {
            _collectFees(_lock.positionOwner, _lock.tokenIds[i]);
        }
    }

    /**
     * @dev Internal fee collection implementation for each LP position.
     *      feeRecipient fees are transferred to the fee recipient
     *      user fees are stored in the contract for offchain users to claim
     */
    function _collectFees(address _positionOwner, uint256 _tokenId) internal {
        (uint256 amount0, uint256 amount1) = nonFungiblePositionManager.collect(
            INonfungiblePositionManager.CollectParams({
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max,
                tokenId: _tokenId
            })
        );

        (,, address token0, address token1,,,,,,,,) = nonFungiblePositionManager.positions(_tokenId);

        IERC20 feeToken0 = IERC20(token0);
        IERC20 feeToken1 = IERC20(token1);

        // calculate protocol and user shares of fees
        uint256 protocolFee0 = (amount0 * fee) / FEE_DENOMINATOR;
        uint256 protocolFee1 = (amount1 * fee) / FEE_DENOMINATOR;

        uint256 userFee0 = amount0 - protocolFee0;
        uint256 userFee1 = amount1 - protocolFee1;

        // transfer protocol fees to fee recipient
        feeToken0.transfer(feeRecipient, protocolFee0);
        feeToken1.transfer(feeRecipient, protocolFee1);

        // internal transfer of user fees
        feeToken0.transfer(_positionOwner, userFee0);
        feeToken1.transfer(_positionOwner, userFee1);

        emit ClaimedFees(_positionOwner, token0, token1, userFee0, userFee1, protocolFee0, protocolFee1);
    }

    function onERC721Received(address, address from, uint256 id, bytes calldata) external override returns (bytes4) {
        emit Received(from, id);

        return IERC721Receiver.onERC721Received.selector;
    }

    function getLock(address token) public view returns (LpLock memory) {
        return tokenIds[token];
    }
}
