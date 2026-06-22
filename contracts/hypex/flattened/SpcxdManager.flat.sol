// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// src/HyperCore.sol

/// @dev CoreWriter sink — the only way an EVM contract pushes actions onto HyperCore.
///      Lives at the fixed system address 0x33...33 on HyperEVM mainnet (chain 999).
interface ICoreWriter {
    function sendRawAction(bytes calldata data) external;
}

/// @title HyperCore — EVM↔Core bridge primitives for HyperEVM
/// @notice Thin, allocation-free wrappers around the HyperCore system contracts:
///         the CoreWriter action sink, the spot-balance precompile, and the
///         token bridge system addresses. Every helper here has been exercised
///         against mainnet primitives (EVM→Core bridge, CoreWriter limit order
///         that filled, CoreWriter spot-send, precompile read).
///
/// @dev Action wire format is `0x01` (encoding version) + a 3-byte big-endian
///      action id + `abi.encode(params)`. Prices and sizes are human × 1e8.
///
///      CRITICAL (validated on mainnet): CoreWriter actions only execute when the
///      `msg.sender` is a contract, never an EOA. The token bridge (a plain
///      transfer to a system address) works for both EOAs and contracts.
library HyperCore {
    // --------------------------------------------------------------- system addresses

    /// @dev CoreWriter action sink.
    ICoreWriter internal constant CORE_WRITER = ICoreWriter(0x3333333333333333333333333333333333333333);

    /// @dev Read-only precompile returning a user's spot balance for a core token.
    address internal constant SPOT_BALANCE_PRECOMPILE = 0x0000000000000000000000000000000000000801;

    // --------------------------------------------------------------- action ids

    uint24 internal constant ACTION_LIMIT_ORDER = 1;
    uint24 internal constant ACTION_SPOT_SEND = 6;

    /// @dev Time-in-force: 1 = ALO, 2 = GTC, 3 = IOC. We use IOC for "market-style" fills.
    uint8 internal constant TIF_IOC = 3;

    // --------------------------------------------------------------- actions

    /// @notice Place a spot limit order on a HyperCore orderbook.
    /// @param asset   spot-pair order asset = 10000 + pairIndex
    /// @param isBuy   true to buy the base asset with quote
    /// @param px1e8   limit price, human × 1e8
    /// @param sz1e8   size, human × 1e8
    /// @dev IOC + reduceOnly=false + cloid=0. Caller must be a contract.
    function limitOrder(uint32 asset, bool isBuy, uint64 px1e8, uint64 sz1e8) internal {
        bytes memory params = abi.encode(asset, isBuy, px1e8, sz1e8, false, TIF_IOC, uint128(0));
        _sendAction(ACTION_LIMIT_ORDER, params);
    }

    /// @notice Send a core spot token from this contract's Core account to `dest`'s Core account.
    /// @param dest   recipient Core account (EVM address == Core address)
    /// @param token  core token id
    /// @param amount amount in core units (token's `weiDecimals`)
    /// @dev Async — the transfer settles 1–2 blocks later. Caller must be a contract.
    function spotSend(address dest, uint64 token, uint64 amount) internal {
        bytes memory params = abi.encode(dest, token, amount);
        _sendAction(ACTION_SPOT_SEND, params);
    }

    // --------------------------------------------------------------- reads

    /// @notice Read `user`'s spot balance for `token` from the precompile.
    /// @return total balance in core units (the field callers care about)
    /// @return hold amount reserved by resting orders
    /// @return entryNtl cost basis notional
    function spotBalance(address user, uint64 token)
        internal
        view
        returns (uint64 total, uint64 hold, uint64 entryNtl)
    {
        (bool ok, bytes memory ret) = SPOT_BALANCE_PRECOMPILE.staticcall(abi.encode(user, token));
        require(ok, "spot balance read failed");
        (total, hold, entryNtl) = abi.decode(ret, (uint64, uint64, uint64));
    }

    // --------------------------------------------------------------- bridge

    /// @notice System address that bridges a core token to/from the EVM.
    /// @dev Top byte 0x20, the rest is the token index big-endian. Index 0 (USDC)
    ///      => 0x2000…0000. A plain ERC20 `transfer` to this address credits the
    ///      sender's Core account; a Core→EVM withdrawal sends back out of it.
    function systemAddress(uint64 index) internal pure returns (address) {
        return address((uint160(0x20) << 152) | uint160(index));
    }

    // --------------------------------------------------------------- internal

    function _sendAction(uint24 actionId, bytes memory params) private {
        // 0x01 version byte + 3-byte big-endian action id + encoded params
        bytes memory data = abi.encodePacked(
            uint8(1), uint8(actionId >> 16), uint8(actionId >> 8), uint8(actionId), params
        );
        CORE_WRITER.sendRawAction(data);
    }
}

// src/SpcxdToken.sol

/// @title SpcxdToken (HYPEX) — fixed-supply ERC20 that pays SPCXD dividends
/// @notice The HYPEX launch token. 0% transfer tax. Every non-excluded holder
///         accrues a pro-rata share of SPCXD (tokenized SpaceX dStock) that the
///         manager harvests from the 1% pool fee, buys on the HyperCore orderbook,
///         and books here via {notifyReward}. Holders {claimSpcxd} and the SPCXD
///         is spot-sent straight to their own Core account.
///
/// @dev Accounting is the magnified-dividend-per-share pattern, so distribution
///      and claims are O(1) with no holder enumeration. Shares track balances
///      (excluded accounts hold 0 shares); `correction` keeps each holder's owed
///      amount exact across transfers. All SPCXD figures are core 8-dec units.
contract SpcxdToken {
    // ----------------------------------------------------------------- ERC20

    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public immutable totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    // ------------------------------------------------------------- dividends

    /// @dev SPCXD core token id on HyperCore mainnet.
    uint64 public constant SPCXD_CORE_ID = 610;

    /// @dev Per-share accumulator is scaled by 2^128 to keep integer math exact.
    uint256 internal constant MAGNITUDE = 2 ** 128;

    /// @notice Accumulated SPCXD per share, scaled by MAGNITUDE, in SPCXD core 8-dec units.
    uint256 public magSpcxdPerShare;
    /// @notice Sum of shares of all non-excluded holders.
    uint256 public totalShares;
    /// @notice Effective dividend weight of an account (balance, or 0 if excluded).
    mapping(address => uint256) public shares;
    /// @notice Per-account correction that keeps owed SPCXD exact as shares change.
    mapping(address => int256) public correction;
    /// @notice SPCXD already claimed by an account, core 8-dec units.
    mapping(address => uint256) public withdrawnSpcxd;
    /// @notice Reward booked while there were no shares; rolled into the next distribution.
    uint256 public buffered;

    mapping(address => bool) public excludedFromDividends;

    // --------------------------------------------------------------- ownership

    address public owner;
    /// @notice The SpcxdManager — the only address allowed to book rewards.
    address public manager;

    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    // --------------------------------------------------------------- events

    event RewardNotified(uint256 amount, uint256 distributed, uint256 buffered);
    event Claimed(address indexed account, uint256 amount);
    event ExcludedFromDividends(address indexed account, bool excluded);
    event ManagerSet(address indexed manager);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    // --------------------------------------------------------------- modifiers

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    modifier onlyManager() {
        require(msg.sender == manager, "not manager");
        _;
    }

    /// @param recipient receives the entire fixed supply at deploy (deployer/treasury,
    ///        which then airdrops holders and funds the manager's LP seed).
    constructor(string memory name_, string memory symbol_, uint256 supply_, address recipient) {
        require(recipient != address(0), "zero recipient");
        name = name_;
        symbol = symbol_;
        totalSupply = supply_;
        owner = msg.sender;

        // The dead address never earns dividends.
        excludedFromDividends[DEAD] = true;

        balanceOf[recipient] = supply_;
        emit Transfer(address(0), recipient, supply_);
        _updateShares(recipient);
        emit OwnershipTransferred(address(0), msg.sender);
    }

    // ----------------------------------------------------------------- ERC20

    function transfer(address to, uint256 value) external returns (bool) {
        return _transfer(msg.sender, to, value);
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            require(allowed >= value, "ERC20: insufficient allowance");
            allowance[from][msg.sender] = allowed - value;
        }
        return _transfer(from, to, value);
    }

    function approve(address spender, uint256 value) external returns (bool) {
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function _transfer(address from, address to, uint256 value) internal returns (bool) {
        require(to != address(0), "ERC20: transfer to zero");
        uint256 bal = balanceOf[from];
        require(bal >= value, "ERC20: insufficient balance");
        unchecked {
            balanceOf[from] = bal - value;
            balanceOf[to] += value;
        }
        emit Transfer(from, to, value);

        // 0% tax. Recompute both sides' shares and shift their corrections so no
        // accrued SPCXD is lost or created — this is what keeps claims O(1).
        _updateShares(from);
        _updateShares(to);
        return true;
    }

    // ------------------------------------------------------------- dividends

    /// @notice Book `amount` of SPCXD (core 8-dec units) as a reward for holders.
    /// @dev Manager-only. The SPCXD itself is already in this contract's Core account
    ///      (delivered via spot-send before this call). If there are no shares yet the
    ///      reward is buffered and distributed on the next call.
    function notifyReward(uint64 amount) external onlyManager {
        uint256 distributed;
        if (totalShares == 0) {
            buffered += amount;
        } else {
            distributed = uint256(amount) + buffered;
            magSpcxdPerShare += (distributed * MAGNITUDE) / totalShares;
            buffered = 0;
        }
        emit RewardNotified(amount, distributed, buffered);
    }

    /// @notice SPCXD currently owed to `account`, core 8-dec units.
    function withdrawableSpcxd(address account) public view returns (uint256) {
        return accumulativeSpcxd(account) - withdrawnSpcxd[account];
    }

    /// @notice Lifetime SPCXD accrued to `account` (claimed + claimable), core 8-dec units.
    function accumulativeSpcxd(address account) public view returns (uint256) {
        int256 acc = int256(magSpcxdPerShare * shares[account]) + correction[account];
        return uint256(acc) / MAGNITUDE;
    }

    /// @notice Claim owed SPCXD; it is spot-sent to the caller's Core account.
    /// @dev Async — the SPCXD arrives at the caller's Core account 1–2 blocks later.
    function claimSpcxd() external returns (uint256 owed) {
        owed = withdrawableSpcxd(msg.sender);
        require(owed > 0, "nothing to claim");
        require(owed <= type(uint64).max, "amount overflows core");
        withdrawnSpcxd[msg.sender] += owed;
        HyperCore.spotSend(msg.sender, SPCXD_CORE_ID, uint64(owed));
        emit Claimed(msg.sender, owed);
    }

    /// @notice SPCXD held by this contract on Core — the backing for unclaimed rewards.
    function spcxdOnCore() external view returns (uint64 total) {
        (total,,) = HyperCore.spotBalance(address(this), SPCXD_CORE_ID);
    }

    // ----------------------------------------------------------------- admin

    /// @notice Wire the manager once. The manager is excluded from dividends.
    function setManager(address manager_) external onlyOwner {
        require(manager == address(0), "manager set");
        require(manager_ != address(0), "zero manager");
        manager = manager_;
        _setExcluded(manager_, true);
        emit ManagerSet(manager_);
    }

    /// @notice Exclude/include an account (pool, reserve, etc.) from earning dividends.
    function setExcludedFromDividends(address account, bool excluded) external onlyOwner {
        _setExcluded(account, excluded);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    function renounceOwnership() external onlyOwner {
        emit OwnershipTransferred(owner, address(0));
        owner = address(0);
    }

    // --------------------------------------------------------------- internal

    function _setExcluded(address account, bool excluded) internal {
        if (excludedFromDividends[account] == excluded) return;
        excludedFromDividends[account] = excluded;
        _updateShares(account);
        emit ExcludedFromDividends(account, excluded);
    }

    /// @dev Resync `account`'s shares with its balance/exclusion and shift its
    ///      correction so its already-accrued SPCXD is preserved across the change.
    function _updateShares(address account) internal {
        uint256 newShares = excludedFromDividends[account] ? 0 : balanceOf[account];
        uint256 oldShares = shares[account];
        if (newShares == oldShares) return;

        if (newShares > oldShares) {
            uint256 delta = newShares - oldShares;
            totalShares += delta;
            correction[account] -= int256(magSpcxdPerShare * delta);
        } else {
            uint256 delta = oldShares - newShares;
            totalShares -= delta;
            correction[account] += int256(magSpcxdPerShare * delta);
        }
        shares[account] = newShares;
    }
}

// src/SpcxdManager.sol

interface IERC20 {
    function approve(address spender, uint256 value) external returns (bool);
    function transfer(address to, uint256 value) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/// @dev WHYPE is WHYPE (wrapped HYPE), WETH9-style: `withdraw` unwraps to native HYPE.
interface IWHYPE {
    function withdraw(uint256 amount) external;
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

    // ERC721 — the position is held as an NFT.
    function safeTransferFrom(address from, address to, uint256 tokenId) external;
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
/// @notice Holds the launch LP and runs the reward pipeline. A single hardcoded
///         address, {LP_WITHDRAWER}, can withdraw the LP position at any time via
///         {withdrawLiquidity} — the LP is NOT locked; this is a TRUSTED design and
///         holders must trust that address not to pull it. The owner/keeper cannot
///         touch the LP. The funds in flight (HYPE/USDC/SPCXD on Core) have no
///         withdraw path and can only become holder rewards. The owner (a) seeds the
///         pool once and (b) prices/triggers the Core orderbook orders.
///
/// @dev Pipeline (HYPE route — uses only mainnet-validated primitives):
///      1. harvest()           collect the 1% fees                        (permissionless)
///      2. bridgeToCore(min)   launch-token→WHYPE, unwrap WHYPE→HYPE,
///                             send HYPE to the HYPE system address        (owner/keeper)
///      3. sellHypeForUsdc()   sell Core HYPE for USDC on HYPE/USDC book   (owner/keeper)
///      4. buySpcxd()          buy SPCXD on the SPCXD/USDC book            (owner/keeper)
///      5. deliverToToken()    spot-send SPCXD to the token, book reward   (permissionless)
///
///      Token-0 USDC on HyperCore is system-managed (its EVM ERC20 reverts for non-system
///      callers and has no DEX pool), so USDC is acquired by SELLING on the Core orderbook
///      — never by swapping/bridging an EVM USDC token. Fills/bridges settle 1–2 blocks later.
contract SpcxdManager {
    // --------------------------------------------------------------- core ids / assets

    uint64 internal constant SPCXD_CORE_ID = 610;
    uint32 internal constant SPCXD_SPOT_ASSET = 10465; // SPCXD/USDC, 10000 + pair index 465
    uint64 internal constant USDC_CORE_ID = 0;
    uint64 internal constant HYPE_CORE_ID = 150;
    uint32 internal constant HYPE_USDC_ASSET = 10107; // HYPE/USDC, 10000 + pair index 107

    /// @dev Native HYPE bridges EVM→Core by a plain value transfer to this system address.
    address internal constant HYPE_SYSTEM = 0x2222222222222222222222222222222222222222;

    /// @notice The ONLY address allowed to withdraw the LP. Hardcoded and immutable —
    ///         not even the owner can change it or call the withdraw. Keep this a secure
    ///         (cold/multisig) wallet, separate from the operational owner/keeper keys.
    address public constant LP_WITHDRAWER = 0x5DdDEa56774f01fc9d207BBD7B7633596a2f4A0b;

    // --------------------------------------------------------------- immutables

    SpcxdToken public immutable token;
    address public immutable whype;
    INonfungiblePositionManager public immutable nfpm;
    ISwapRouter public immutable router;
    uint24 public immutable launchPoolFee; // 1% pool = 10000

    // --------------------------------------------------------------- state

    address public owner;
    address public keeper;
    address public pool;
    uint256 public positionId; // the LP NFT
    bool public seeded;

    // --------------------------------------------------------------- events

    event Seeded(address indexed pool, uint256 positionId, uint256 tokenLiquidity);
    event Harvested(uint256 collected0, uint256 collected1);
    event BridgedToCore(uint256 hypeBridged);
    event SoldHypeForUsdc(uint64 px1e8, uint64 sz1e8);
    event BoughtSpcxd(uint64 px1e8, uint64 sz1e8);
    event Delivered(uint64 amount);
    event KeeperSet(address indexed keeper);
    event LiquidityWithdrawn(address indexed to, uint256 positionId);

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
        INonfungiblePositionManager nfpm_,
        ISwapRouter router_,
        uint24 launchPoolFee_
    ) {
        require(
            address(token_) != address(0) && whype_ != address(0) && address(nfpm_) != address(0)
                && address(router_) != address(0),
            "zero address"
        );
        token = token_;
        whype = whype_;
        nfpm = nfpm_;
        router = router_;
        launchPoolFee = launchPoolFee_;
        owner = msg.sender;
    }

    /// @dev Accept native HYPE produced by unwrapping WHYPE.
    receive() external payable {}

    // ----------------------------------------------------------------- seed

    /// @notice One-shot: create the token/WHYPE pool and mint the manager's full token
    ///         balance as a single-sided (token-only) position. The position NFT is held
    ///         by the manager; {LP_WITHDRAWER} can withdraw it any time via {withdrawLiquidity}.
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

    /// @notice Collect the accrued 1% fees from the locked position into the manager.
    /// @dev Permissionless. Slippage-free (no swap), so anyone may pull fees in.
    ///      Pair with {bridgeToCore}, which the keeper calls with a fresh slippage floor.
    function harvest() external returns (uint256 collected0, uint256 collected1) {
        (collected0, collected1) = nfpm.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: positionId,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );
        emit Harvested(collected0, collected1);
    }

    // ------------------------------------------------------------ step 2: bridge to Core

    /// @notice Convert the manager's launch-token + WHYPE balance to native HYPE and bridge
    ///         it to the manager's Core account (a value transfer to the HYPE system address).
    /// @param minWhypeOut minimum WHYPE out of the launch-token→WHYPE swap (slippage floor)
    /// @dev Owner/keeper-gated: the floor must come from a fresh quote so the swap can't be
    ///      sandwiched. No fund-withdraw path — the HYPE only lands in the manager's Core
    ///      account. Pass `0` when there is no launch-token side to swap this run.
    function bridgeToCore(uint256 minWhypeOut) external onlyOwnerOrKeeper {
        // 1. Swap the launch-token side → WHYPE in the launch pool.
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
                    amountOutMinimum: minWhypeOut,
                    sqrtPriceLimitX96: 0
                })
            );
        }

        // 2. Unwrap all WHYPE → native HYPE.
        uint256 whypeBal = IERC20(whype).balanceOf(address(this));
        if (whypeBal > 0) {
            IWHYPE(whype).withdraw(whypeBal);
        }

        // 3. Bridge native HYPE EVM→Core (value transfer to the HYPE system address).
        uint256 hypeBal = address(this).balance;
        if (hypeBal > 0) {
            (bool ok,) = HYPE_SYSTEM.call{value: hypeBal}("");
            require(ok, "hype bridge failed");
        }
        emit BridgedToCore(hypeBal);
    }

    // ------------------------------------------------------------- step 3: sell for USDC

    /// @notice IOC sell of Core HYPE for USDC on the HYPE/USDC book — gets the USDC the
    ///         SPCXD buy needs (token-0 USDC can only be acquired by trading on Core).
    /// @param px1e8 limit price, human × 1e8 (priced off the live book by the keeper)
    /// @param sz1e8 size, human × 1e8
    function sellHypeForUsdc(uint64 px1e8, uint64 sz1e8) external onlyOwnerOrKeeper {
        (uint64 hypeTotal,,) = HyperCore.spotBalance(address(this), HYPE_CORE_ID);
        require(hypeTotal > 0, "no core hype");
        HyperCore.limitOrder(HYPE_USDC_ASSET, false, px1e8, sz1e8); // isBuy=false: sell HYPE for USDC
        emit SoldHypeForUsdc(px1e8, sz1e8);
    }

    // -------------------------------------------------------------- step 4: buy SPCXD

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

    // ------------------------------------------------------------- step 5: deliver

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

    /// @notice HYPE queued in the manager's Core account, core 8-dec units.
    function coreHype() external view returns (uint64 total) {
        (total,,) = HyperCore.spotBalance(address(this), HYPE_CORE_ID);
    }

    /// @notice USDC queued in the manager's Core account, core 8-dec units.
    function coreUsdc() external view returns (uint64 total) {
        (total,,) = HyperCore.spotBalance(address(this), USDC_CORE_ID);
    }

    /// @notice SPCXD held in the manager's Core account (pre-delivery), core 8-dec units.
    function coreSpcxd() external view returns (uint64 total) {
        (total,,) = HyperCore.spotBalance(address(this), SPCXD_CORE_ID);
    }

    // ----------------------------------------------------------------- admin

    /// @notice Withdraw the LP position NFT to `to`. Callable ONLY by {LP_WITHDRAWER},
    ///         at any time. The owner/keeper cannot call this.
    /// @dev TRUSTED design: the LP is NOT locked — the dedicated withdrawer can pull
    ///      liquidity whenever. Transferring the NFT hands over the whole position
    ///      (its tokens + accrued fees).
    function withdrawLiquidity(address to) external {
        require(msg.sender == LP_WITHDRAWER, "not lp withdrawer");
        require(to != address(0), "zero address");
        uint256 id = positionId;
        require(id != 0, "no position");
        positionId = 0;
        nfpm.safeTransferFrom(address(this), to, id);
        emit LiquidityWithdrawn(to, id);
    }

    /// @notice Set the keeper bot allowed to run the pipeline orders. (No fund-withdraw power.)
    function setKeeper(address keeper_) external onlyOwner {
        keeper = keeper_;
        emit KeeperSet(keeper_);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "zero address");
        owner = newOwner;
    }
}
