// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {HyperCore} from "../src/HyperCore.sol";
import {SpcxdToken} from "../src/SpcxdToken.sol";
import {SpcxdManager, INonfungiblePositionManager, ISwapRouter} from "../src/SpcxdManager.sol";

/// Records every CoreWriter action so tests can assert the exact wire encoding.
/// Etched at the system address 0x33…33.
contract MockCoreWriter {
    bytes public lastData;

    function sendRawAction(bytes calldata data) external {
        lastData = data;
    }
}

/// Minimal mintable ERC20 for the WHYPE/USDC legs of the EVM pipeline.
contract MockERC20 {
    string public name;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory name_) {
        name = name_;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 value) external returns (bool) {
        allowance[msg.sender][spender] = value;
        return true;
    }

    function transfer(address to, uint256 value) external returns (bool) {
        balanceOf[msg.sender] -= value;
        balanceOf[to] += value;
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - value;
        balanceOf[from] -= value;
        balanceOf[to] += value;
        return true;
    }

    // WHYPE-style unwrap: burn wrapped balance, pay out native HYPE (mock must hold ETH).
    function withdraw(uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "withdraw fail");
    }

    receive() external payable {}
}

/// Position manager stub: `collect` mints the configured WHYPE fee to the caller;
/// `mint`/`createAndInitializePoolIfNecessary` back the seed path.
contract MockNFPM {
    MockERC20 public whype;
    uint256 public whypeFee;
    uint256 public nextId = 1;

    function setWhype(MockERC20 w) external {
        whype = w;
    }

    function setWhypeFee(uint256 amount) external {
        whypeFee = amount;
    }

    function createAndInitializePoolIfNecessary(address, address, uint24, uint160)
        external
        pure
        returns (address)
    {
        return address(0xBEEF);
    }

    function mint(INonfungiblePositionManager.MintParams calldata p)
        external
        returns (uint256, uint128, uint256, uint256)
    {
        // Pull whichever side carries the single-sided token amount.
        uint256 amt = p.amount0Desired + p.amount1Desired;
        address tok = p.amount0Desired > 0 ? p.token0 : p.token1;
        MockERC20Like(tok).transferFrom(msg.sender, address(this), amt);
        return (nextId++, 0, 0, 0);
    }

    function collect(INonfungiblePositionManager.CollectParams calldata p)
        external
        returns (uint256, uint256)
    {
        if (whypeFee > 0) whype.mint(p.recipient, whypeFee);
        return (whypeFee, 0);
    }

    address public lastTransferTo;
    uint256 public lastTransferId;

    function safeTransferFrom(address, address to, uint256 tokenId) external {
        lastTransferTo = to;
        lastTransferId = tokenId;
    }
}

interface MockERC20Like {
    function transferFrom(address, address, uint256) external returns (bool);
}

/// Swap router stub with a fixed tokenIn→tokenOut rate (1e18-scaled). Enforces minOut.
contract MockSwapRouter {
    mapping(address => mapping(address => uint256)) public rate; // rate[in][out], 1e18

    function setRate(address tokenIn, address tokenOut, uint256 rateE18) external {
        rate[tokenIn][tokenOut] = rateE18;
    }

    function exactInputSingle(ISwapRouter.ExactInputSingleParams calldata p)
        external
        returns (uint256 amountOut)
    {
        MockERC20Like(p.tokenIn).transferFrom(msg.sender, address(this), p.amountIn);
        amountOut = (p.amountIn * rate[p.tokenIn][p.tokenOut]) / 1e18;
        require(amountOut >= p.amountOutMinimum, "slippage");
        MockERC20(payable(p.tokenOut)).mint(p.recipient, amountOut);
    }
}

contract HypexTest is Test {
    address internal constant CORE_WRITER = 0x3333333333333333333333333333333333333333;
    address internal constant SPOT_BALANCE = 0x0000000000000000000000000000000000000801;
    uint64 internal constant SPCXD = 610;
    uint64 internal constant USDC_CORE = 0;
    uint64 internal constant HYPE_CORE = 150;
    uint32 internal constant SPCXD_ASSET = 10465;
    uint32 internal constant HYPE_ASSET = 10107;
    address internal constant HYPE_SYSTEM = 0x2222222222222222222222222222222222222222;

    SpcxdToken token;
    SpcxdManager manager;

    MockERC20 whype;
    MockNFPM nfpm;
    MockSwapRouter swapRouter;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        whype = new MockERC20("WHYPE");
        nfpm = new MockNFPM();
        swapRouter = new MockSwapRouter();
        nfpm.setWhype(whype);

        // 10,000 HYPEX, full supply to this test contract (acts as deployer/treasury).
        token = new SpcxdToken("HYPEX", "HYPEX", 10_000e18, address(this));
        manager = new SpcxdManager(
            token,
            address(whype),
            INonfungiblePositionManager(address(nfpm)),
            ISwapRouter(address(swapRouter)),
            10_000 // 1% launch pool
        );
        token.setManager(address(manager));

        // Install the CoreWriter recorder at the system address.
        vm.etch(CORE_WRITER, address(new MockCoreWriter()).code);
    }

    function _coreData() internal view returns (bytes memory) {
        return MockCoreWriter(CORE_WRITER).lastData();
    }

    function _mockSpot(address user, uint64 core, uint64 total) internal {
        vm.mockCall(
            SPOT_BALANCE, abi.encode(user, core), abi.encode(total, uint64(0), uint64(0))
        );
    }

    // 1. Distribution math: rewards split pro-rata across non-excluded holders.
    function test_distributionMath() public {
        token.transfer(alice, 3_000e18);
        token.transfer(bob, 1_000e18);
        // This contract keeps 6,000; totalShares = 10,000.

        vm.prank(address(manager));
        token.notifyReward(1_000e8); // 1,000 SPCXD (core 8-dec)

        assertEq(token.totalShares(), 10_000e18);
        // Per-share division truncates, so each holder rounds DOWN by ≤1 core unit
        // (the dust stays as backing — distribution never over-pays). 1 unit = 1e-8 SPCXD.
        assertApproxEqAbs(token.withdrawableSpcxd(alice), 300e8, 1); // 30%
        assertApproxEqAbs(token.withdrawableSpcxd(bob), 100e8, 1); // 10%
        assertApproxEqAbs(token.withdrawableSpcxd(address(this)), 600e8, 1); // 60%

        // Owed survives a transfer: Alice moves all her tokens but keeps her accrued SPCXD.
        uint256 aliceOwed = token.withdrawableSpcxd(alice);
        uint256 bobOwed = token.withdrawableSpcxd(bob);
        vm.prank(alice);
        token.transfer(bob, 3_000e18);
        assertEq(token.withdrawableSpcxd(alice), aliceOwed);
        assertEq(token.withdrawableSpcxd(bob), bobOwed);
    }

    // 2. Claim spot-sends SPCXD (core id 610) to the caller's own Core account.
    function test_claimSpotSend() public {
        token.transfer(alice, 5_000e18);
        vm.prank(address(manager));
        token.notifyReward(500e8);

        uint256 owed = token.withdrawableSpcxd(alice); // ~250 SPCXD (rounds down ≤1 unit)
        assertApproxEqAbs(owed, 250e8, 1);

        vm.prank(alice);
        token.claimSpcxd();

        // The spot-send carries exactly what was owed, to Alice's own Core account.
        bytes memory expected = abi.encodePacked(
            uint8(1), uint8(0), uint8(0), uint8(HyperCore.ACTION_SPOT_SEND),
            abi.encode(alice, SPCXD, uint64(owed))
        );
        assertEq(keccak256(_coreData()), keccak256(expected));
        assertEq(token.withdrawnSpcxd(alice), owed);
        assertEq(token.withdrawableSpcxd(alice), 0);
    }

    // 3. Buy emits an IOC limit order on the SPCXD/USDC book with the right encoding.
    function test_buyOrderEncoding() public {
        _mockSpot(address(manager), USDC_CORE, 1_000e8); // USDC sitting on Core

        manager.buySpcxd(123e8, 5e8); // px 123, size 5 (human ×1e8)

        bytes memory expected = abi.encodePacked(
            uint8(1), uint8(0), uint8(0), uint8(HyperCore.ACTION_LIMIT_ORDER),
            abi.encode(SPCXD_ASSET, true, uint64(123e8), uint64(5e8), false, uint8(3), uint128(0))
        );
        assertEq(keccak256(_coreData()), keccak256(expected));
    }

    // 3b. Sell HYPE for USDC emits an IOC SELL on the HYPE/USDC book (asset 10107).
    function test_sellHypeOrderEncoding() public {
        _mockSpot(address(manager), HYPE_CORE, 1_000e8); // HYPE sitting on Core

        manager.sellHypeForUsdc(44e8, 9e8);

        bytes memory expected = abi.encodePacked(
            uint8(1), uint8(0), uint8(0), uint8(HyperCore.ACTION_LIMIT_ORDER),
            abi.encode(HYPE_ASSET, false, uint64(44e8), uint64(9e8), false, uint8(3), uint128(0))
        );
        assertEq(keccak256(_coreData()), keccak256(expected));
    }

    // 4. Deliver spot-sends bought SPCXD to the token and books it as a reward.
    function test_deliver() public {
        token.transfer(alice, 10_000e18); // all shares to alice
        _mockSpot(address(manager), SPCXD, 800e8); // 800 SPCXD bought, sitting on Core

        manager.deliverToToken();

        // spot-send manager Core → token Core, full bought amount
        bytes memory expected = abi.encodePacked(
            uint8(1), uint8(0), uint8(0), uint8(HyperCore.ACTION_SPOT_SEND),
            abi.encode(address(token), SPCXD, uint64(800e8))
        );
        assertEq(keccak256(_coreData()), keccak256(expected));
        // booked for holders (alice holds all shares; rounds down ≤1 unit)
        assertApproxEqAbs(token.withdrawableSpcxd(alice), 800e8, 1);
    }

    // 5. Buffer: rewards booked with no shares roll into the next distribution.
    function test_buffer() public {
        // Park the whole supply in the manager (excluded) → totalShares == 0.
        token.transfer(address(manager), 10_000e18);
        assertEq(token.totalShares(), 0);

        vm.prank(address(manager));
        token.notifyReward(100e8); // buffered, nobody to pay
        assertEq(token.buffered(), 100e8);
        assertEq(token.magSpcxdPerShare(), 0);

        // Give Alice all the shares, then distribute again.
        vm.prank(address(manager));
        token.transfer(alice, 10_000e18);

        vm.prank(address(manager));
        token.notifyReward(50e8); // 50 new + 100 buffered

        assertEq(token.buffered(), 0);
        assertApproxEqAbs(token.withdrawableSpcxd(alice), 150e8, 1);
    }

    // 6. Only the registered manager can book rewards.
    function test_managerGating() public {
        vm.prank(alice);
        vm.expectRevert("not manager");
        token.notifyReward(1e8);

        // The owner is not the manager either.
        vm.expectRevert("not manager");
        token.notifyReward(1e8);
    }

    // 7. System address packs the token index big-endian under the 0x20 top byte.
    function test_systemAddress() public pure {
        assertEq(HyperCore.systemAddress(0), 0x2000000000000000000000000000000000000000);
        // 610 = 0x262
        assertEq(HyperCore.systemAddress(610), 0x2000000000000000000000000000000000000262);
    }

    // 8. Pipeline: harvest (collect) → bridgeToCore (token→WHYPE, unwrap, HYPE→Core).
    function test_harvestPipeline() public {
        // 100 HYPEX (token side) already in the manager; collect() mints 50 WHYPE.
        token.transfer(address(manager), 100e18);
        nfpm.setWhypeFee(50e18);
        swapRouter.setRate(address(token), address(whype), 0.5e18); // 100 HYPEX → 50 WHYPE
        // Fund the WHYPE mock with native HYPE so withdraw() can pay out (50 + 50 = 100).
        vm.deal(address(whype), 100e18);

        manager.harvest(); // permissionless collect
        manager.bridgeToCore(0);

        // 100 WHYPE unwrapped → 100 HYPE bridged to the HYPE system address.
        assertEq(HYPE_SYSTEM.balance, 100e18);
        assertEq(whype.balanceOf(address(manager)), 0);
        assertEq(token.balanceOf(address(manager)), 0);
        assertEq(address(manager).balance, 0);
    }

    // 9. bridgeToCore enforces the slippage floor and is owner/keeper-gated; harvest is open.
    function test_harvestSlippageAndGating() public {
        token.transfer(address(manager), 100e18);
        swapRouter.setRate(address(token), address(whype), 0.5e18);
        vm.deal(address(whype), 100e18);

        // Anyone can collect.
        vm.prank(alice);
        manager.harvest();

        // Floor above achievable output reverts the swap.
        vm.expectRevert("slippage");
        manager.bridgeToCore(999e18);

        // A random caller can't bridge.
        vm.prank(alice);
        vm.expectRevert("not owner/keeper");
        manager.bridgeToCore(0);

        // The keeper can.
        manager.setKeeper(alice);
        vm.prank(alice);
        manager.bridgeToCore(0);
    }

    // 10. Seed: single-sided mint deposits the full token balance into one V3 position.
    function test_seedSingleSided() public {
        token.transfer(address(manager), 5_060e18); // LP allocation
        manager.seed(uint160(1 << 96), 100, 200);

        assertTrue(manager.seeded());
        assertEq(manager.positionId(), 1);
        assertEq(manager.pool(), address(0xBEEF));
        // tokens left the manager into the (mock) position — no withdraw path exists.
        assertEq(token.balanceOf(address(manager)), 0);

        // One-shot.
        vm.expectRevert("seeded");
        manager.seed(uint160(1 << 96), 100, 200);
    }

    // 11. LP is withdrawable only by the hardcoded LP_WITHDRAWER (TRUSTED design — not locked).
    function test_withdrawLiquidity() public {
        token.transfer(address(manager), 5_060e18);
        manager.seed(uint160(1 << 96), 100, 200);
        uint256 id = manager.positionId();

        address withdrawer = manager.LP_WITHDRAWER();

        // Not even the owner (this test contract) can pull it.
        vm.expectRevert("not lp withdrawer");
        manager.withdrawLiquidity(bob);

        // A random address can't either.
        vm.prank(alice);
        vm.expectRevert("not lp withdrawer");
        manager.withdrawLiquidity(alice);

        // Only LP_WITHDRAWER can.
        vm.prank(withdrawer);
        manager.withdrawLiquidity(bob);
        assertEq(nfpm.lastTransferTo(), bob);
        assertEq(nfpm.lastTransferId(), id);
        assertEq(manager.positionId(), 0);

        // Nothing left to withdraw.
        vm.prank(withdrawer);
        vm.expectRevert("no position");
        manager.withdrawLiquidity(bob);
    }

    // 12. After renounce: deployer loses all power; keeper still runs; LP withdrawer intact.
    function test_renounceOwnership() public {
        // Launch order: seed, then hand the pipeline to a keeper, then renounce.
        manager.setKeeper(alice);
        manager.renounceOwnership();
        assertEq(manager.owner(), address(0));

        // Deployer (this contract) can no longer touch owner-gated functions.
        vm.expectRevert("not owner");
        manager.setKeeper(bob);
        vm.expectRevert("not owner");
        manager.seed(uint160(1 << 96), 100, 200);

        // The keeper can still run the pipeline.
        _mockSpot(address(manager), HYPE_CORE, 1_000e8);
        vm.prank(alice);
        manager.sellHypeForUsdc(40e8, 5e8); // no revert

        // The LP withdrawer is unaffected by renounce.
        assertEq(manager.LP_WITHDRAWER(), 0x5DdDEa56774f01fc9d207BBD7B7633596a2f4A0b);
    }
}
