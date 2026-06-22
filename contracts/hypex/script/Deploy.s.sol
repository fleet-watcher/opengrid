// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {SpcxdToken} from "../src/SpcxdToken.sol";
import {SpcxdManager, INonfungiblePositionManager, ISwapRouter} from "../src/SpcxdManager.sol";

/// Deploys the HYPEX token + manager and wires them together.
///
/// Defaults below are the VERIFIED HyperSwap V3 + WHYPE/USDC addresses on HyperEVM
/// mainnet (chain 999), labelled on hyperevmscan.io. Override any via env if needed.
///
///   WHYPE        0x5555555555555555555555555555555555555555
///   SwapRouter1  0x4E2960a8cd19B467b82d26D83fAcb0fAE26b094D  (V3, has deadline arg)
///   NFPM         0x6eDA206207c09e5428F281761DdC0D300851fBC8  (V3 position manager)
///   STABLE       0xB8CE59FC3717ada4C02eaDF9682A9e934F625ebb  (USD₮0, 6 dec)
///                ^ The deep WHYPE stable pool on HyperSwap V3 is WHYPE/USD₮0 @ 0.05%
///                  (mainnet-fork verified). Circle USDC (0xb88339…) has NO WHYPE V3 pool,
///                  and the spec's 0x6B9E…0A24 reverts on every ERC20 call (unusable).
///
///   ⚠️ OPEN ITEM (HyperCore side, NOT fork-verifiable): SpcxdManager hardcodes
///      USDC_CORE_ID = 0 and the SPCXD/USDC spot asset 10465, i.e. it assumes the buy is
///      quoted in USDC on Core. If the harvested EVM stable is USD₮0, confirm whether
///      (a) SPCXD is actually quoted in USD₮0 on Core — then update those core constants —
///      or (b) a USD₮0→USDC hop on Core is needed before the SPCXD/USDC buy, and that the
///      stable's bridge system index matches USDC_CORE_ID. Resolve before mainnet.
///
/// Usage:
///   export PRIVATE_KEY=0x...
///   # optional overrides: WHYPE, USDC, NFPM, SWAP_ROUTER, TOTAL_SUPPLY,
///   #                     LAUNCH_POOL_FEE (1% = 10000), WHYPE_USDC_FEE (e.g. 500)
///   forge script script/Deploy.s.sol --rpc-url hyperevm --broadcast
///
/// After deploy: airdrop HYLD holders 1:1 from the deployer balance, transfer the
/// LP allocation to the manager, then call `manager.seed(...)` once.
contract Deploy is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        address whype = vm.envOr("WHYPE", 0x5555555555555555555555555555555555555555);
        // USD₮0 — the EVM stable that actually has a WHYPE V3 pool (see header + OPEN ITEM).
        address usdc = vm.envOr("USDC", 0xB8CE59FC3717ada4C02eaDF9682A9e934F625ebb);
        address nfpm = vm.envOr("NFPM", 0x6eDA206207c09e5428F281761DdC0D300851fBC8);
        address swapRouter = vm.envOr("SWAP_ROUTER", 0x4E2960a8cd19B467b82d26D83fAcb0fAE26b094D);
        uint256 supplyWhole = vm.envOr("TOTAL_SUPPLY", uint256(10_000));
        uint24 launchPoolFee = uint24(vm.envOr("LAUNCH_POOL_FEE", uint256(10_000)));
        uint24 whypeUsdcFee = uint24(vm.envOr("WHYPE_USDC_FEE", uint256(500))); // WHYPE/USD₮0 = 0.05%

        vm.startBroadcast(pk);

        SpcxdToken token = new SpcxdToken("HYPEX", "HYPEX", supplyWhole * 1e18, deployer);
        SpcxdManager manager = new SpcxdManager(
            token,
            whype,
            usdc,
            INonfungiblePositionManager(nfpm),
            ISwapRouter(swapRouter),
            launchPoolFee,
            whypeUsdcFee
        );
        token.setManager(address(manager));

        vm.stopBroadcast();

        console.log("SpcxdToken   :", address(token));
        console.log("SpcxdManager :", address(manager));
    }
}
