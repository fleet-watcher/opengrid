// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {HyperCore} from "./HyperCore.sol";
import {SpcxdToken} from "./SpcxdToken.sol";

interface IERC20 {
    function approve(address spender, uint256 value) external returns (bool);
    function transfer(address to, uint256 value) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/// @dev Minimal Uniswap-V3-style position manager (Hyperswap NFPM).
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

    function createAndInitializePoolIfNecessary(address token0, address token1, uint24 fee, uint160 sqrtPriceX96)
        external
        payable
        returns (address pool);

    function mint(MintParams calldata params)
        external
        payable
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);

    function collect(CollectParams calldata params) external returns (uint256 amount0, uint256 amount1);
}

/// @dev Minimal Uniswap-V3-style swap router (Hyperswap SwapRouter).
interface ISwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

/// @title SpcxdManager — LP custody + harvest→buy→deliver pipeline for HYPEX
/// @notice Holds the locked launch LP and runs the reward pipeline. There is NO
///         function to withdraw USDC / SPCXD / HYPE to the owner — every unit the
///         manager collects can only end up as a holder reward. The owner (a) seeds
///         the pool once and (b) prices/triggers the orderbook buy.
///
/// @dev Pipeline: harvest() (permissionless) collects 1% fees → swaps to USDC →
///      bridges to Core. buySpcxd() (owner/keeper) crosses the SPCXD/USDC book.
///      deliverToToken() (permissionless) spot-sends the bought SPCXD to the token
///      and books it for holders. Fills and bridges are async (settle 1–2 blocks).
contract SpcxdManager {
    // --------------------------------------------------------------- core ids

    uint64 internal constant SPCXD_CORE_ID = 610;
    uint32 internal constant SPCXD_SPOT_ASSET = 10465; // 10000 + pair index 465
    uint64 internal constant USDC_CORE_ID = 0;

    // --------------------------------------------------------------- immutables

    SpcxdToken public immutable token;
    address public immutable whype;
    address public immutable usdc; // EVM USDC (6 dec)
    INonfungiblePositionManager public immutable nfpm;
    ISwapRouter public immutable router;
    uint24 public immutable launchPoolFee; // 1% pool = 10000
    uint24 public immutable whypeUsdcFee; // fee tier of the WHYPE/USDC pool

    // --------------------------------------------------------------- state

    address public owner;
    address public keeper;
    address public pool;
    uint256 public positionId; // the locked V3 LP NFT
    bool public seeded;

    // --------------------------------------------------------------- events

    event Seeded(address indexed pool, uint256 positionId, uint256 tokenLiquidity);
    event Harvested(uint256 collected0, uint256 collected1, uint256 usdcBridged);
    event BoughtSpcxd(uint64 px1e8, uint64 sz1e8);
    event Delivered(uint64 amount);
    event KeeperSet(address indexed keeper);

    // --------------------------------------------------------------- modifiers

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    modifier onlyOwnerOrKeeper() {
        require(msg.sender == owner || msg.sender == keeper, "not owner/keeper");
        _;
    }

    constructor(
        SpcxdToken token_,
        address whype_,
        address usdc_,
        INonfungiblePositionManager nfpm_,
        ISwapRouter router_,
        uint24 launchPoolFee_,
        uint24 whypeUsdcFee_
    ) {
        require(
            address(token_) != address(0) && whype_ != address(0) && usdc_ != address(0)
                && address(nfpm_) != address(0) && address(router_) != address(0),
            "zero address"
        );
        token = token_;
        whype = whype_;
        usdc = usdc_;
        nfpm = nfpm_;
        router = router_;
        launchPoolFee = launchPoolFee_;
        whypeUsdcFee = whypeUsdcFee_;
        owner = msg.sender;
    }

    // ----------------------------------------------------------------- seed

    /// @notice One-shot: create the token/WHYPE pool and mint the manager's full token
    ///         balance as a single-sided (token-only) position. The position NFT stays
    ///         here forever — there is no withdraw path, so the LP is locked by construction.
    /// @param sqrtPriceX96 initial pool price (token vs WHYPE), Q64.96
    /// @param tickLower    lower bound of the single-sided range
    /// @param tickUpper    upper bound of the single-sided range
    /// @dev `tickLower`/`tickUpper` must sit entirely on the token side of the current
    ///      price so the mint consumes only token and zero WHYPE. They are derived
    ///      off-chain from the desired launch price.
    function seed(uint160 sqrtPriceX96, int24 tickLower, int24 tickUpper) external onlyOwner {
        require(!seeded, "seeded");
        seeded = true;

        uint256 supply = token.balanceOf(address(this));
        require(supply > 0, "no tokens to seed");

        (address token0, address token1) =
            address(token) < whype ? (address(token), whype) : (whype, address(token));

        pool = nfpm.createAndInitializePoolIfNecessary(token0, token1, launchPoolFee, sqrtPriceX96);

        token.approve(address(nfpm), supply);
        (uint256 amount0Desired, uint256 amount1Desired) =
            address(token) == token0 ? (supply, uint256(0)) : (uint256(0), supply);

        (uint256 tokenId,,,) = nfpm.mint(
            INonfungiblePositionManager.MintParams({
                token0: token0,
                token1: token1,
                fee: launchPoolFee,
                tickLower: tickLower,
                tickUpper: tickUpper,
                amount0Desired: amount0Desired,
                amount1Desired: amount1Desired,
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(this),
                deadline: block.timestamp
            })
        );
        positionId = tokenId;
        emit Seeded(pool, tokenId, supply);
    }

    // -------------------------------------------------------------- step 1: harvest

    /// @notice Collect the accrued 1% fees, route everything to USDC, and bridge it to Core.
    /// @dev Permissionless. Leaves USDC queued in the manager's Core account for the next buy.
    ///      Swaps currently use `amountOutMinimum = 0`; add slippage bounds before real size.
    function harvest() external {
        // 1. Collect accrued fees (WHYPE + launch token) from the locked position.
        (uint256 collected0, uint256 collected1) = nfpm.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: positionId,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );

        // 2. Swap the launch-token side → WHYPE in the launch pool.
        uint256 tokenBal = token.balanceOf(address(this));
        if (tokenBal > 0) {
            token.approve(address(router), tokenBal);
            router.exactInputSingle(
                ISwapRouter.ExactInputSingleParams({
                    tokenIn: address(token),
                    tokenOut: whype,
                    fee: launchPoolFee,
                    recipient: address(this),
                    deadline: block.timestamp,
                    amountIn: tokenBal,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: 0
                })
            );
        }

        // 3. Swap all WHYPE → USDC.
        uint256 whypeBal = IERC20(whype).balanceOf(address(this));
        if (whypeBal > 0) {
            IERC20(whype).approve(address(router), whypeBal);
            router.exactInputSingle(
                ISwapRouter.ExactInputSingleParams({
                    tokenIn: whype,
                    tokenOut: usdc,
                    fee: whypeUsdcFee,
                    recipient: address(this),
                    deadline: block.timestamp,
                    amountIn: whypeBal,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: 0
                })
            );
        }

        // 4. Bridge USDC EVM→Core (transfer to the USDC system address credits our Core account).
        uint256 usdcBal = IERC20(usdc).balanceOf(address(this));
        if (usdcBal > 0) {
            IERC20(usdc).transfer(HyperCore.systemAddress(USDC_CORE_ID), usdcBal);
        }

        emit Harvested(collected0, collected1, usdcBal);
    }

    // -------------------------------------------------------------- step 2: buy

    /// @notice IOC ("market-style") buy on the SPCXD/USDC book using the Core USDC balance.
    /// @param px1e8 limit price, human × 1e8 (priced off-chain from the live book)
    /// @param sz1e8 size, human × 1e8
    /// @dev Owner/keeper-gated because it needs live market data and dStock off-hours.
    ///      Async — the fill settles 1–2 blocks later; re-read the balance before delivering.
    function buySpcxd(uint64 px1e8, uint64 sz1e8) external onlyOwnerOrKeeper {
        (uint64 usdcTotal,,) = HyperCore.spotBalance(address(this), USDC_CORE_ID);
        require(usdcTotal > 0, "no core usdc");
        HyperCore.limitOrder(SPCXD_SPOT_ASSET, true, px1e8, sz1e8);
        emit BoughtSpcxd(px1e8, sz1e8);
    }

    // ------------------------------------------------------------ step 3: deliver

    /// @notice Move the bought SPCXD from the manager's Core account to the token's Core
    ///         account and book it as a reward for holders.
    /// @dev Permissionless.
    function deliverToToken() external {
        (uint64 amount,,) = HyperCore.spotBalance(address(this), SPCXD_CORE_ID);
        require(amount > 0, "nothing to deliver");
        HyperCore.spotSend(address(token), SPCXD_CORE_ID, amount);
        token.notifyReward(amount);
        emit Delivered(amount);
    }

    // ----------------------------------------------------------------- views

    /// @notice USDC queued in the manager's Core account, core 8-dec units.
    function coreUsdc() external view returns (uint64 total) {
        (total,,) = HyperCore.spotBalance(address(this), USDC_CORE_ID);
    }

    /// @notice SPCXD held in the manager's Core account (pre-delivery), core 8-dec units.
    function coreSpcxd() external view returns (uint64 total) {
        (total,,) = HyperCore.spotBalance(address(this), SPCXD_CORE_ID);
    }

    // ----------------------------------------------------------------- admin

    /// @notice Set the keeper bot allowed to call {buySpcxd}. (No fund-withdraw power.)
    function setKeeper(address keeper_) external onlyOwner {
        keeper = keeper_;
        emit KeeperSet(keeper_);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "zero address");
        owner = newOwner;
    }
}
