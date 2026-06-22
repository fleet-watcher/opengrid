// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {SpcxdToken} from "../src/SpcxdToken.sol";
import {SpcxdManager, INonfungiblePositionManager, ISwapRouter} from "../src/SpcxdManager.sol";

/// Integration test against REAL HyperSwap V3 contracts on a mainnet fork.
/// Run with:
///   forge test --fork-url https://rpc.hyperliquid.xyz/evm --match-contract HypexFork -vvv
/// Without a fork the HyperSwap addresses have no code, so the test no-ops.
///
/// NOTE: only the EVM side can be fork-tested. HyperCore actions (buySpcxd,
/// spot-send, precompiles) are system-level and not present in EVM fork state.
contract HypexForkTest is Test {
    address constant WHYPE = 0x5555555555555555555555555555555555555555;
    // The deep WHYPE stable pool on HyperSwap V3 is WHYPE/USD₮0 @ 0.05% (~$4.8M liq),
    // NOT USDC: Circle USDC (0xb88339…) has no WHYPE V3 pool, and the spec's 0x6B9E…0A24
    // reverts on all ERC20 calls (it is not a usable token). USD₮0 is 6 dec.
    address constant USDT0 = 0xB8CE59FC3717ada4C02eaDF9682A9e934F625ebb;
    uint24 constant WHYPE_USDT0_FEE = 500;
    address constant NFPM = 0x6eDA206207c09e5428F281761DdC0D300851fBC8;
    address constant ROUTER = 0x4E2960a8cd19B467b82d26D83fAcb0fAE26b094D;

    // sqrtPriceX96 for price 1.0 (tick 0): 2^96.
    uint160 constant SQRT_PRICE_1 = 79228162514264337593543950336;

    function test_fork_seedSingleSided() public {
        if (NFPM.code.length == 0) {
            emit log("not a fork (NFPM has no code) - skipping integration test");
            return;
        }

        SpcxdToken token = new SpcxdToken("HYPEX", "HYPEX", 10_000e18, address(this));
        SpcxdManager manager = new SpcxdManager(
            token, WHYPE, USDT0, INonfungiblePositionManager(NFPM), ISwapRouter(ROUTER), 10_000, WHYPE_USDT0_FEE
        );
        token.setManager(address(manager));
        token.transfer(address(manager), 10_000e18);

        // Single-sided range on the token's side of the initial (tick 0) price.
        // 1% fee tier => tick spacing 200; max usable tick (spacing-aligned) = 887200.
        int24 tickLower;
        int24 tickUpper;
        if (address(token) < WHYPE) {
            // token is token0 -> provide only token0 with a range ABOVE current price
            (tickLower, tickUpper) = (int24(200), int24(887200));
        } else {
            // token is token1 -> provide only token1 with a range BELOW current price
            (tickLower, tickUpper) = (int24(-887200), int24(-200));
        }

        manager.seed(SQRT_PRICE_1, tickLower, tickUpper);

        assertGt(manager.positionId(), 0, "no position minted");
        assertTrue(manager.pool() != address(0), "pool not created");
        assertLt(token.balanceOf(address(manager)), 10_000e18, "no token deposited");

        emit log_named_address("pool", manager.pool());
        emit log_named_uint("positionId", manager.positionId());
        emit log_named_uint("token deposited", 10_000e18 - token.balanceOf(address(manager)));
        emit log_named_uint("token left in manager", token.balanceOf(address(manager)));
    }

    /// Validates the harvest stable leg + bridge transfer against the REAL router and
    /// the real WHYPE/USD₮0 0.05% pool: swap WHYPE→USD₮0, then transfer to the bridge.
    function test_fork_swapWhypeToStableAndBridge() public {
        if (ROUTER.code.length == 0) {
            emit log("not a fork - skipping");
            return;
        }

        SpcxdToken token = new SpcxdToken("HYPEX", "HYPEX", 10_000e18, address(this));
        SpcxdManager manager = new SpcxdManager(
            token, WHYPE, USDT0, INonfungiblePositionManager(NFPM), ISwapRouter(ROUTER), 10_000, WHYPE_USDT0_FEE
        );
        address bridge = address(uint160(0x20) << 152); // systemAddress(0)

        uint256 whypeIn = 0.1e18;
        deal(WHYPE, address(manager), whypeIn);

        uint256 bridgeBefore = IBal(USDT0).balanceOf(bridge);
        manager.swapAndBridge(0, 0); // no launch-token side here, so only the stable leg runs
        uint256 stableOut = IBal(USDT0).balanceOf(bridge) - bridgeBefore;

        emit log_named_uint("USD0 bridged (6dec)", stableOut);
        assertGt(stableOut, 0, "no stable out");
        assertEq(IBal(WHYPE).balanceOf(address(manager)), 0, "WHYPE not fully swapped");
        assertEq(IBal(USDT0).balanceOf(address(manager)), 0, "stable not fully bridged");
    }
}

interface IBal {
    function balanceOf(address) external view returns (uint256);
}
