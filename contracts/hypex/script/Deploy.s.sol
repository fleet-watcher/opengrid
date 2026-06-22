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
///   USDC         0x6B9E773128f453f5c2C60935Ee2DE2CBc5390A24  (Hyperliquid USDC, bridges to Core token 0)
///                ^ NOTE: Circle's *native* USDC is 0xb88339CB7199b77E23DB6E890353E22632Ba630f.
///                  Use whichever USDC is (a) linked to HyperCore token 0 for the bridge and
///                  (b) has a liquid WHYPE/USDC V3 pool. Confirm before mainnet.
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
        address usdc = vm.envOr("USDC", 0x6B9E773128f453f5c2C60935Ee2DE2CBc5390A24);
        address nfpm = vm.envOr("NFPM", 0x6eDA206207c09e5428F281761DdC0D300851fBC8);
        address swapRouter = vm.envOr("SWAP_ROUTER", 0x4E2960a8cd19B467b82d26D83fAcb0fAE26b094D);
        uint256 supplyWhole = vm.envOr("TOTAL_SUPPLY", uint256(10_000));
        uint24 launchPoolFee = uint24(vm.envOr("LAUNCH_POOL_FEE", uint256(10_000)));
        uint24 whypeUsdcFee = uint24(vm.envOr("WHYPE_USDC_FEE", uint256(500)));

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
