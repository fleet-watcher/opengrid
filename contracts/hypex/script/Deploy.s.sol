// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {SpcxdToken} from "../src/SpcxdToken.sol";
import {SpcxdManager, INonfungiblePositionManager, ISwapRouter} from "../src/SpcxdManager.sol";

/// Deploys the HYPEX token + manager and wires them together.
///
/// Defaults below are the VERIFIED HyperSwap V3 addresses on HyperEVM mainnet
/// (chain 999), labelled on hyperevmscan.io. Override any via env if needed.
///
///   WHYPE        0x5555555555555555555555555555555555555555
///   SwapRouter1  0x4E2960a8cd19B467b82d26D83fAcb0fAE26b094D  (V3, has deadline arg)
///   NFPM         0x6eDA206207c09e5428F281761DdC0D300851fBC8  (V3 position manager)
///
/// The reward pipeline takes the HYPE route: harvest → unwrap WHYPE to HYPE →
/// bridge HYPE to Core → sell HYPE for USDC on the Core orderbook → buy SPCXD/USDC.
/// No EVM USDC token is touched (token-0 USDC is system-managed and unswappable),
/// so the manager needs no USDC/stable address.
///
/// Usage:
///   export PRIVATE_KEY=0x...
///   # optional overrides: WHYPE, NFPM, SWAP_ROUTER, TOTAL_SUPPLY, LAUNCH_POOL_FEE (1%=10000)
///   forge script script/Deploy.s.sol --rpc-url hyperevm --broadcast
///
/// After deploy: airdrop HYLD holders 1:1 from the deployer balance, transfer the
/// LP allocation to the manager, then call `manager.seed(...)` once.
contract Deploy is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        address whype = vm.envOr("WHYPE", 0x5555555555555555555555555555555555555555);
        address nfpm = vm.envOr("NFPM", 0x6eDA206207c09e5428F281761DdC0D300851fBC8);
        address swapRouter = vm.envOr("SWAP_ROUTER", 0x4E2960a8cd19B467b82d26D83fAcb0fAE26b094D);
        uint256 supplyWhole = vm.envOr("TOTAL_SUPPLY", uint256(10_000));
        uint24 launchPoolFee = uint24(vm.envOr("LAUNCH_POOL_FEE", uint256(10_000)));

        vm.startBroadcast(pk);

        SpcxdToken token = new SpcxdToken("HYPEX", "HYPEX", supplyWhole * 1e18, deployer);
        SpcxdManager manager = new SpcxdManager(
            token, whype, INonfungiblePositionManager(nfpm), ISwapRouter(swapRouter), launchPoolFee
        );
        token.setManager(address(manager));

        vm.stopBroadcast();

        console.log("SpcxdToken   :", address(token));
        console.log("SpcxdManager :", address(manager));
    }
}
