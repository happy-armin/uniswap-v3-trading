import { expect } from "chai"
import { Signer, parseEther } from "ethers"
import { ethers } from "hardhat"
import { Core, TestToken, INonfungiblePositionManager, ISwapRouter } from "typechain-types"

describe("Core", () => {
	const ADDRESS__UNISWAP_V3_POSITION_MANAGER = "0xC36442b4a4522E871399CD717aBDD847Ab11FE88"
	const ADDRESS__UNISWAP_V3_SWAP_ROUTER = "0xE592427A0AEce92De3Edee1F18E0157C05861564"

	const POOL_FEE = 3000
	const MIN_TICK = -887272
	const MAX_TICK = -MIN_TICK
	const MIN_SQRT_RATIO = 4295128739
	const MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342

	let deployer: Signer, alice: Signer
	let token1: TestToken
	let token2: TestToken
	let core: Core
	let positionManager: INonfungiblePositionManager
	let swapRouter: ISwapRouter

	before(async () => {
		// Deploy contracts
		;[deployer, alice] = await ethers.getSigners()

		// Deploy the TestToken contract
		const TestTokenFactory = await ethers.getContractFactory("TestToken")
		token1 = await TestTokenFactory.deploy("TT1", "TT1")
		token2 = await TestTokenFactory.deploy("TT2", "TT2")

		// Get UniswapV3 core
		positionManager = await ethers.getContractAt(
			"INonfungiblePositionManager",
			ADDRESS__UNISWAP_V3_POSITION_MANAGER
		)
		swapRouter = await ethers.getContractAt("ISwapRouter", ADDRESS__UNISWAP_V3_SWAP_ROUTER)

		// Deploy Core contract
		const CoreFactory = await ethers.getContractFactory("Core")
		core = await CoreFactory.deploy(ADDRESS__UNISWAP_V3_POSITION_MANAGER, ADDRESS__UNISWAP_V3_SWAP_ROUTER)

		// Create UniswapV3 pool
		positionManager.createAndInitializePoolIfNecessary(token1, token2, POOL_FEE, MIN_SQRT_RATIO)
	})

	it("test after construction", async () => {
		expect(await core.POSITION_MANAGER()).to.equal(ADDRESS__UNISWAP_V3_POSITION_MANAGER)
		expect(await core.ROUTER()).to.equal(ADDRESS__UNISWAP_V3_SWAP_ROUTER)
	})

	it("test mintNewPosition", async () => {
		// Transfer tokens to Alice
		await token1.connect(deployer).transfer(alice, parseEther("100"))
		await token2.connect(deployer).transfer(alice, parseEther("100"))

		// Approve Alice's tokens for swap
		await token1.connect(alice).approve(core, parseEther("100"))
		await token2.connect(alice).approve(core, parseEther("100"))

		// Mint new position
		const tx = await core
			.connect(alice)
			.mintNewPosition(token1, token2, parseEther("50"), parseEther("50"), MIN_TICK, MAX_TICK)

		await tx.wait()
	})
})
