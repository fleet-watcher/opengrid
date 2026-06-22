// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {SpcxdToken} from "../src/SpcxdToken.sol";
import {SpcxdManager, INonfungiblePositionManager, ISwapRouter} from "../src/SpcxdManager.sol";

/// Integration test against REAL HyperSwap V3 + WHYPE contracts on a mainnet fork.
/// Run with:
///   forge test --fork-url https://rpc.hyperliquid.xyz/evm --match-contract HypexFork -vvv
/// Without a fork the addresses have no code, so the tests no-op.
///
/// NOTE: only the EVM side can be fork-tested. HyperCore actions (sell/buy/spot-send,
/// precompiles) are system-level and not present in EVM fork state.
contract HypexForkTest is Test {
    address constant WHYPE = 0x5555555555555555555555555555555555555555;
    address constant NFPM = 0x6eDA206207c09e5428F281761DdC0D300851fBC8;
    address constant ROUTER = 0x4E2960a8cd19B467b82d26D83fAcb0fAE26b094D;
    address constant HYPE_SYSTEM = 0x2222222222222222222222222222222222222222;

    // sqrtPriceX96 for price 1.0 (tick 0): 2^96.
    uint160 constant SQRT_PRICE_1 = 79228162514264337593543950336;

    function _newManager(SpcxdToken token) internal returns (SpcxdManager) {
        return new SpcxdManager(token, WHYPE, INonfungiblePositionManager(NFPM), ISwapRouter(ROUTER), 10_000);
    }

    function test_fork_seedSingleSided() public {
        if (NFPM.code.length == 0) {
            emit log("not a fork (NFPM has no code) - skipping integration test");
            return;
        }

        SpcxdToken token = new SpcxdToken("HYPEX", "HYPEX", 10_000e18, address(this));
        SpcxdManager manager = _newManager(token);
        token.setManager(address(manager));
        token.transfer(address(manager), 10_000e18);

        // Single-sided range on the token's side of the initial (tick 0) price.
        // 1% fee tier => tick spacing 200; max usable tick (spacing-aligned) = 887200.
        int24 tickLower;
        int24 tickUpper;
        if (address(token) < WHYPE) {
            (tickLower, tickUpper) = (int24(200), int24(887200)); // token0 -> range above price
        } else {
            (tickLower, tickUpper) = (int24(-887200), int24(-200)); // token1 -> range below price
        }

        manager.seed(SQRT_PRICE_1, tickLower, tickUpper);

        assertGt(manager.positionId(), 0, "no position minted");
        assertTrue(manager.pool() != address(0), "pool not created");
        assertLt(token.balanceOf(address(manager)), 10_000e18, "no token deposited");

        emit log_named_address("pool", manager.pool());
        emit log_named_uint("positionId", manager.positionId());
        emit log_named_uint("token deposited", 10_000e18 - token.balanceOf(address(manager)));
    }

    /// Validates the HYPE-route bridge against the REAL WHYPE contract: unwrap WHYPE→HYPE
    /// and value-transfer it to the HYPE system address.
    function test_fork_bridgeWhypeToCore() public {
        if (WHYPE.code.length == 0) {
            emit log("not a fork - skipping");
            return;
        }

        SpcxdToken token = new SpcxdToken("HYPEX", "HYPEX", 10_000e18, address(this));
        SpcxdManager manager = _newManager(token);

        uint256 whypeIn = 0.1e18;
        deal(WHYPE, address(manager), whypeIn);

        uint256 sysBefore = HYPE_SYSTEM.balance;
        manager.bridgeToCore(0); // no launch-token side here, so only the unwrap+bridge runs
        uint256 bridged = HYPE_SYSTEM.balance - sysBefore;

        emit log_named_uint("HYPE bridged (wei)", bridged);
        assertEq(bridged, whypeIn, "HYPE not bridged");
        assertEq(IBal(WHYPE).balanceOf(address(manager)), 0, "WHYPE not fully unwrapped");
        assertEq(address(manager).balance, 0, "native HYPE left in manager");
    }
}

interface IBal {
    function balanceOf(address) external view returns (uint256);
}
