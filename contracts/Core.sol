// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { INonfungiblePositionManager } from "./interfaces/periphery/INonfungiblePositionManager.sol";
import { ISwapRouter } from "./interfaces/periphery/ISwapRouter.sol";

import { IERC721Receiver } from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

contract Core is IERC721Receiver {
	// After understand IERC20 as SafeERC20
	using SafeERC20 for IERC20;

	// NonfungiblePositionManager and SwapRouter as a immutable vairable
	INonfungiblePositionManager public immutable POSITION_MANAGER;
	ISwapRouter public immutable ROUTER;

	// Set the fee as 0.3% constant
	uint24 public constant POOL_FEE = 3000;

	/// @notice Represents the deposit of an NFT
	struct Deposit {
		address owner;
		uint128 liquidity;
		address token1;
		address token2;
	}
	/// @dev deposits[tokenId] => Deposit
	mapping(uint256 => Deposit) public deposits;

	/// Constructor of this contract
	constructor(
		INonfungiblePositionManager _positionManager,
		ISwapRouter _router
	) {
		POSITION_MANAGER = _positionManager;
		ROUTER = _router;
	}

	// Implementing `onERC721Received` so this contract can receive custody of erc721 tokens
	function onERC721Received(
		address operator,
		address,
		uint256 tokenId,
		bytes calldata
	) external override returns (bytes4) {
		// get position information

		_createDeposit(operator, tokenId);

		return this.onERC721Received.selector;
	}

	function _createDeposit(address owner, uint256 tokenId) internal {
		(
			,
			,
			address token1,
			address token2,
			,
			,
			,
			uint128 liquidity,
			,
			,
			,

		) = POSITION_MANAGER.positions(tokenId);

		// set the owner and data for position
		// operator is msg.sender
		deposits[tokenId] = Deposit({
			owner: owner,
			liquidity: liquidity,
			token1: token1,
			token2: token2
		});
	}

	/// @notice Calls the mint function defined in periphery, mints the specified amount of each token
	/// @return tokenId The id of the newly minted ERC721
	/// @return liquidity The amount of liquidity for the position
	/// @return amount1 The amount of token0
	/// @return amount2 The amount of token1
	function mintNewPosition(
		IERC20 token1,
		IERC20 token2,
		uint256 amountIn1,
		uint256 amountIn2,
		int24 priceLower,
		int24 priceUpper
	)
		external
		returns (
			uint256 tokenId,
			uint128 liquidity,
			uint256 amount1,
			uint256 amount2
		)
	{
		// Transfer tokens to contract
		token1.safeTransferFrom(msg.sender, address(this), amountIn1);
		token2.safeTransferFrom(msg.sender, address(this), amountIn2);

		// Approve the position manager
		token1.approve(address(POSITION_MANAGER), amountIn1);
		token2.approve(address(POSITION_MANAGER), amountIn2);

		// Mint New position
		INonfungiblePositionManager.MintParams
			memory params = INonfungiblePositionManager.MintParams({
				token0: address(token1),
				token1: address(token2),
				fee: POOL_FEE,
				tickLower: priceLower,
				tickUpper: priceUpper,
				amount0Desired: amountIn1,
				amount1Desired: amountIn2,
				amount0Min: 0,
				amount1Min: 0,
				recipient: address(this),
				deadline: block.timestamp
			});

		(tokenId, liquidity, amount1, amount2) = POSITION_MANAGER.mint(params);

		// Create a deposit
		_createDeposit(msg.sender, tokenId);

		// Remove allowance and refund in both assets
		if (amount1 < amountIn1) {
			token1.approve(address(POSITION_MANAGER), 0);
			token1.safeTransferFrom(
				address(this),
				msg.sender,
				amountIn1 - amount1
			);
		}
		if (amount2 < amountIn2) {
			token2.approve(address(POSITION_MANAGER), 0);
			token2.safeTransferFrom(
				address(this),
				msg.sender,
				amountIn2 - amount2
			);
		}
	}

	/// @notice Collects the fees associated with provided liquidity
	/// @dev The contract must hold the erc721 token before it can collect fees
	/// @param tokenId The id of the erc721 token
	/// @return amount1 The amount of fees collected in token0
	/// @return amount2 The amount of fees collected in token1
	function collectAllFees(
		uint256 tokenId
	) external returns (uint256 amount1, uint256 amount2) {
		// Caller must own the ERC721 position, meaning it must be a deposit

		// Set amount0Max and amount1Max to uint256.max to collect all fees
		// Alternatively can set recipient to msg.sender and avoid another transaction in `sendToOwner`
		INonfungiblePositionManager.CollectParams
			memory params = INonfungiblePositionManager.CollectParams({
				tokenId: tokenId,
				recipient: address(this),
				amount0Max: type(uint128).max,
				amount1Max: type(uint128).max
			});

		(amount1, amount2) = POSITION_MANAGER.collect(params);

		// Send collected feed back to owner
		_sendToOwner(tokenId, amount1, amount1);
	}

	/// @notice A function that decreases the current liquidity by half. An example to show how to call the `decreaseLiquidity` function defined in periphery.
	/// @param tokenId The id of the erc721 token
	/// @return amount1 The amount received back in token0
	/// @return amount2 The amount returned back in token1
	function decreaseLiquidityInHalf(
		uint256 tokenId
	) external returns (uint256 amount1, uint256 amount2) {
		// Caller must be the owner of the NFT
		require(msg.sender == deposits[tokenId].owner, "Not the owner");

		// Get liquidity data for tokenId
		uint128 liquidity = deposits[tokenId].liquidity;
		uint128 halfLiquidity = liquidity / 2;

		// Amount1Min and amount2Min are price slippage checks
		// If the amount received after burning is not greater than these minimums, transaction will fail
		INonfungiblePositionManager.DecreaseLiquidityParams
			memory params = INonfungiblePositionManager
				.DecreaseLiquidityParams({
					tokenId: tokenId,
					liquidity: halfLiquidity,
					amount0Min: 0,
					amount1Min: 0,
					deadline: block.timestamp
				});

		(amount1, amount2) = POSITION_MANAGER.decreaseLiquidity(params);

		//send liquidity back to owner
		_sendToOwner(tokenId, amount1, amount2);
	}

	/// @notice Increases liquidity in the current range
	/// @dev Pool must be initialized already to add liquidity
	/// @param tokenId The id of the erc721 token
	/// @param amount1 The amount to add of token0
	/// @param amount2 The amount to add of token1
	function increaseLiquidityCurrentRange(
		uint256 tokenId,
		uint256 amountAdd1,
		uint256 amountAdd2
	) external returns (uint128 liquidity, uint256 amount1, uint256 amount2) {
		// Transfer tokens to contract
		IERC20(deposits[tokenId].token1).safeTransferFrom(
			msg.sender,
			address(this),
			amountAdd1
		);
		IERC20(deposits[tokenId].token2).safeTransferFrom(
			msg.sender,
			address(this),
			amountAdd2
		);

		// Approve the position manager
		IERC20(deposits[tokenId].token1).approve(
			address(POSITION_MANAGER),
			amountAdd1
		);
		IERC20(deposits[tokenId].token2).approve(
			address(POSITION_MANAGER),
			amountAdd2
		);

		// Increase liquidity
		INonfungiblePositionManager.IncreaseLiquidityParams
			memory params = INonfungiblePositionManager
				.IncreaseLiquidityParams({
					tokenId: tokenId,
					amount0Desired: amountAdd1,
					amount1Desired: amountAdd2,
					amount0Min: 0,
					amount1Min: 0,
					deadline: block.timestamp
				});

		(liquidity, amount1, amount2) = POSITION_MANAGER.increaseLiquidity(
			params
		);
	}

	/// @notice Transfers funds to owner of NFT
	/// @param tokenId The id of the erc721
	/// @param amount1 The amount of token0
	/// @param amount2 The amount of token1
	function _sendToOwner(
		uint256 tokenId,
		uint256 amount1,
		uint256 amount2
	) internal {
		// Send collected fees to owner
		IERC20(deposits[tokenId].token1).safeTransferFrom(
			address(this),
			deposits[tokenId].owner,
			amount1
		);
		IERC20(deposits[tokenId].token2).safeTransferFrom(
			address(this),
			deposits[tokenId].owner,
			amount2
		);
	}

	/// @notice Transfers the NFT to the owner
	/// @param tokenId The id of the erc721
	function retrieveNFT(uint256 tokenId) external {
		// Must be the owner of the NFT
		require(msg.sender == deposits[tokenId].owner, "Not the owner");

		// Transfer ownership to original owner
		POSITION_MANAGER.safeTransferFrom(address(this), msg.sender, tokenId);

		// Remove information related to tokenId
		delete deposits[tokenId];
	}

	/// @notice swapExactInputSingle swaps a fixed amount of token1 for a maximum possible amount of token2
	/// @dev The calling address must approve this contract to spend at least `amountIn` worth of its token1 for this function to succeed.
	/// @param amountIn The exact amount of token1 that will be swapped for token2.
	/// @return amountOut The amount of token2 received.
	function swapExactInputSingle(
		IERC20 token1,
		IERC20 token2,
		uint256 amountIn
	) external returns (uint256 amountOut) {
		// Transfer tokens to contract
		token1.safeTransferFrom(msg.sender, address(this), amountIn);

		// Approve the router to spend token1
		token1.approve(address(ROUTER), amountIn);

		// Naively set amountOutMinimum to 0. In production, use an oracle or other data source to choose a safer value for amountOutMinimum.
		// We also set the sqrtPriceLimitx96 to be 0 to ensure we swap our exact input amount.
		ISwapRouter.ExactInputSingleParams memory params = ISwapRouter
			.ExactInputSingleParams({
				tokenIn: address(token1),
				tokenOut: address(token2),
				fee: POOL_FEE,
				recipient: msg.sender,
				deadline: block.timestamp,
				amountIn: amountIn,
				amountOutMinimum: 0,
				sqrtPriceLimitX96: 0
			});

		// The call to `exactInputSingle` executes the swap.
		amountOut = ROUTER.exactInputSingle(params);
	}
}
