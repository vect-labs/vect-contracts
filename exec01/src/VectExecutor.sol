// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {
    IWETH,
    ISignatureTransfer,
    IUniswapV2Pair,
    IUniswapV3Pool,
    IPoolManager,
    PoolKey,
    SwapParams
} from "./Interfaces.sol";

/// @title VectExecutor
/// @notice Stateless swap executor of EXEC-01 (spec v1). One user-signed transaction runs a route across Uniswap v2 /
/// v3 pools, Uniswap v4 (hookless or K-7 reviewed hooks) and the CL tick-spacing fork pools of the immutable factory
/// table. No owner, no admin, no upgrade, no pause, no delegatecall, no generic call, no approve. It holds nothing
/// between transactions.
/// @dev Security model in one paragraph. The route carries pool KEYS, never pool addresses (X-02): every pool is
/// derived here from immutable constants and checked for code in a validation pass BEFORE the Permit2 pull. Before
/// each `pool.swap` / `PoolManager.unlock` the expected callback (pool, owed token, direction, maximum amount) is
/// written to transient storage and consumed once by the callback (S-1 / X-01); nothing is read from callback `data`
/// as authority. Every amount that moves is a measured balance delta, never `balanceOf` taken as an amount; the
/// per-hop spend is bounded (I-11); the end checks compare with ENTRY balances so donated dust is inert (X-05).
/// `block.number` is never used (it is the L1 number on this chain).
contract VectExecutor {
    // ------------------------------------------------------------------ types

    uint8 public constant FAMILY_V2 = 0;
    uint8 public constant FAMILY_V3 = 1;
    uint8 public constant FAMILY_CL = 2;
    uint8 public constant FAMILY_V4 = 3;

    /// @dev Pool KEY of one hop. `tokenIn`/`tokenOut` are the hop's real currencies; the zero address is the native
    /// token and is accepted only for FAMILY_V4 hops. Field use by family:
    /// V2: index = fee = tickSpacing = hooks = 0. V3: `fee` is the tier. CL: `index` selects the factory (0..4),
    /// `tickSpacing` is the pool key. V4: `fee`, `tickSpacing`, `hooks` are the PoolKey fields (hookData is empty).
    struct Hop {
        uint8 family;
        uint8 index;
        address tokenIn;
        address tokenOut;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
    }

    struct Leg {
        uint256 amountIn;
        Hop[] hops;
    }

    struct Route {
        Leg[] legs;
    }

    struct Config {
        address weth;
        address permit2;
        address poolManager;
        address feeRecipient;
        address v3Factory;
        bytes32 v3InitCodeHash;
        address v2Factory;
        bytes32 v2InitCodeHash;
        uint256 v2FeeNumerator; // out of 1000 (997 for Uniswap v2)
        address[5] clDeployer;
        bytes32[5] clInitCodeHash;
        address[8] hook;
        bytes32[8] hookCodehash;
    }

    struct Plan {
        address[] pools; // flattened, one per hop in route order
        address[] toks; // route token set, native normalised to WETH
        uint256 nToks;
    }

    struct State {
        address inT;
        address outT;
        uint256 ethBase;
        uint256 userBefore;
        uint256 inFee;
        uint256 gross;
        uint256[] entry;
    }

    // ------------------------------------------------------------------ constants / immutables

    uint16 public constant MAX_FEE_BPS = 100;
    uint256 public constant MAX_LEGS = 3;
    uint256 public constant MAX_HOPS_PER_LEG = 4;
    uint256 public constant MAX_PERMIT_WINDOW = 1800; // 30 minutes (K-3)

    uint160 private constant MIN_SQRT_PLUS_ONE = 4295128740;
    uint160 private constant MAX_SQRT_MINUS_ONE = 1461446703485210103287273052203988822378723970341;

    address public immutable WETH;
    address public immutable PERMIT2;
    address public immutable POOL_MANAGER;
    address public immutable FEE_RECIPIENT;
    address public immutable V3_FACTORY;
    bytes32 public immutable V3_INIT_CODE_HASH;
    address public immutable V2_FACTORY;
    bytes32 public immutable V2_INIT_CODE_HASH;
    uint256 public immutable V2_FEE_NUMERATOR;

    address private immutable CL0_DEPLOYER;
    address private immutable CL1_DEPLOYER;
    address private immutable CL2_DEPLOYER;
    address private immutable CL3_DEPLOYER;
    address private immutable CL4_DEPLOYER;
    bytes32 private immutable CL0_HASH;
    bytes32 private immutable CL1_HASH;
    bytes32 private immutable CL2_HASH;
    bytes32 private immutable CL3_HASH;
    bytes32 private immutable CL4_HASH;

    address private immutable HOOK0;
    address private immutable HOOK1;
    address private immutable HOOK2;
    address private immutable HOOK3;
    address private immutable HOOK4;
    address private immutable HOOK5;
    address private immutable HOOK6;
    address private immutable HOOK7;
    bytes32 private immutable HOOK0_CODEHASH;
    bytes32 private immutable HOOK1_CODEHASH;
    bytes32 private immutable HOOK2_CODEHASH;
    bytes32 private immutable HOOK3_CODEHASH;
    bytes32 private immutable HOOK4_CODEHASH;
    bytes32 private immutable HOOK5_CODEHASH;
    bytes32 private immutable HOOK6_CODEHASH;
    bytes32 private immutable HOOK7_CODEHASH;

    // ------------------------------------------------------------------ transient state (EIP-1153)
    // Every slot is zero outside an `execute` frame and is cleared at the end of each frame (X-14).

    bool private transient _locked;
    // expected v3/CL callback (one use)
    bool private transient _expPending;
    bool private transient _expZeroForOne;
    address private transient _expPool;
    address private transient _expToken;
    uint256 private transient _expMax;
    // expected v4 unlock (one use)
    bool private transient _unlockPending;
    bytes32 private transient _unlockHash;
    // who may send ETH to `receive()` right now (WETH during withdraw, the PoolManager during a native take)
    address private transient _ethFrom;

    // ------------------------------------------------------------------ events / errors

    /// @param amountOut what the user received (recipient-side delta for ERC20 output, exact ETH for native output)
    /// @param feeAmount the fee paid to FEE_RECIPIENT, in the fee token (tokenOut or WETH-for-native if
    /// `feeOnOutput`, else tokenIn or WETH-for-native)
    /// @param routeHash keccak256(abi.encode(route))
    event Executed(
        address indexed user,
        address tokenIn,
        uint256 amountIn,
        address tokenOut,
        uint256 amountOut,
        uint256 feeAmount,
        uint16 feeBps,
        bool feeOnOutput,
        address feeRecipient,
        bytes32 routeHash
    );

    error Reentrancy();
    error Expired();
    error FeeTooHigh();
    error ZeroMinOut();
    error ZeroAmount();
    error SameToken();
    error BadValue();
    error BadRoute();
    error BadHop();
    error BadPermit();
    error BadReceived();
    error TaxedInput();
    error BadCallback();
    error BadEthSender();
    error TransferFailed();
    error BalanceCallFailed();
    error SpendBound();
    error PartialFill();
    error BadDelta();
    error LegSum();
    error MinOut();
    error Residue();
    error EthSendFailed();
    error BadConfig();

    // ------------------------------------------------------------------ construction

    constructor(Config memory c) {
        if (c.weth == address(0) || c.permit2 == address(0) || c.poolManager == address(0)) revert BadConfig();
        if (c.feeRecipient == address(0) || c.feeRecipient == address(this)) revert BadConfig();
        // E4-03: the fee recipient is the Vect Labs Safe, a contract; an EOA or an undeployed address is refused
        if (c.feeRecipient.code.length == 0) revert BadConfig();
        if (c.weth.code.length == 0 || c.permit2.code.length == 0 || c.poolManager.code.length == 0) {
            revert BadConfig();
        }
        // the optional families are either fully set (with code at the deployer) or fully empty
        if ((c.v3Factory == address(0)) != (c.v3InitCodeHash == bytes32(0))) revert BadConfig();
        if (c.v3Factory != address(0) && c.v3Factory.code.length == 0) revert BadConfig();
        if ((c.v2Factory == address(0)) != (c.v2InitCodeHash == bytes32(0))) revert BadConfig();
        if (c.v2Factory != address(0) && (c.v2Factory.code.length == 0 || c.v2FeeNumerator == 0 || c.v2FeeNumerator > 1000))
        {
            revert BadConfig();
        }
        for (uint256 i; i < 5; ++i) {
            if ((c.clDeployer[i] == address(0)) != (c.clInitCodeHash[i] == bytes32(0))) revert BadConfig();
            if (c.clDeployer[i] != address(0) && c.clDeployer[i].code.length == 0) revert BadConfig();
        }
        for (uint256 i; i < 8; ++i) {
            if ((c.hook[i] == address(0)) != (c.hookCodehash[i] == bytes32(0))) revert BadConfig();
            if (c.hook[i] != address(0) && c.hook[i].codehash != c.hookCodehash[i]) revert BadConfig();
        }

        WETH = c.weth;
        PERMIT2 = c.permit2;
        POOL_MANAGER = c.poolManager;
        FEE_RECIPIENT = c.feeRecipient;
        V3_FACTORY = c.v3Factory;
        V3_INIT_CODE_HASH = c.v3InitCodeHash;
        V2_FACTORY = c.v2Factory;
        V2_INIT_CODE_HASH = c.v2InitCodeHash;
        V2_FEE_NUMERATOR = c.v2FeeNumerator;
        CL0_DEPLOYER = c.clDeployer[0];
        CL1_DEPLOYER = c.clDeployer[1];
        CL2_DEPLOYER = c.clDeployer[2];
        CL3_DEPLOYER = c.clDeployer[3];
        CL4_DEPLOYER = c.clDeployer[4];
        CL0_HASH = c.clInitCodeHash[0];
        CL1_HASH = c.clInitCodeHash[1];
        CL2_HASH = c.clInitCodeHash[2];
        CL3_HASH = c.clInitCodeHash[3];
        CL4_HASH = c.clInitCodeHash[4];
        HOOK0 = c.hook[0];
        HOOK1 = c.hook[1];
        HOOK2 = c.hook[2];
        HOOK3 = c.hook[3];
        HOOK4 = c.hook[4];
        HOOK5 = c.hook[5];
        HOOK6 = c.hook[6];
        HOOK7 = c.hook[7];
        HOOK0_CODEHASH = c.hookCodehash[0];
        HOOK1_CODEHASH = c.hookCodehash[1];
        HOOK2_CODEHASH = c.hookCodehash[2];
        HOOK3_CODEHASH = c.hookCodehash[3];
        HOOK4_CODEHASH = c.hookCodehash[4];
        HOOK5_CODEHASH = c.hookCodehash[5];
        HOOK6_CODEHASH = c.hookCodehash[6];
        HOOK7_CODEHASH = c.hookCodehash[7];

        // EIP-1153 self-test (X-14): the chain must support transient storage or the deployment fails.
        bool ok;
        assembly ("memory-safe") {
            tstore(0x5eed, 0x2a)
            ok := eq(tload(0x5eed), 0x2a)
            tstore(0x5eed, 0)
        }
        if (!ok) revert BadConfig();
    }

    /// @notice ETH is accepted only from WETH during an unwrap and from the PoolManager during a native take (S-2).
    receive() external payable {
        address from = _ethFrom;
        if (from == address(0) || msg.sender != from) revert BadEthSender();
    }

    // ------------------------------------------------------------------ views for the post-deploy verifier

    function clDeployer(uint256 i) external view returns (address d) {
        (d,) = _cl(i);
    }

    function clInitCodeHash(uint256 i) external view returns (bytes32 h) {
        (, h) = _cl(i);
    }

    function hookAt(uint256 i) external view returns (address a) {
        (a,) = _hookPin(i);
    }

    function hookCodehash(uint256 i) external view returns (bytes32 h) {
        (, h) = _hookPin(i);
    }

    // ------------------------------------------------------------------ entry point

    /// @notice Executes `route` for `msg.sender`, who is the only possible payer and the only possible recipient.
    /// @param route legs (at most 3, each at most 4 hops) of pool keys; the sum of the leg amounts is the post-fee
    /// input, exactly (except for the single-leg taxed-input shape, see `_pull`)
    /// @param tokenIn input token; the zero address means native ETH (`msg.value == amountIn`, no Permit2)
    /// @param tokenOut output token; the zero address means native ETH
    /// @param minAmountOut must be non zero (S-6); checked on the executor net and on the recipient's balance delta
    /// @param feeBps caller-set, 0..MAX_FEE_BPS; always paid to the immutable FEE_RECIPIENT, as ERC20, last
    /// @param feeOnOutput fee base is the gross output if true, else the received input
    /// @param permit Permit2 SignatureTransfer permit: token == tokenIn, amount == amountIn, deadline <= `deadline`
    /// and <= now + 30 minutes
    function execute(
        Route calldata route,
        address tokenIn,
        uint256 amountIn,
        address tokenOut,
        uint256 minAmountOut,
        uint16 feeBps,
        bool feeOnOutput,
        ISignatureTransfer.PermitTransferFrom calldata permit,
        bytes calldata signature,
        uint256 deadline
    ) external payable returns (uint256 userOut) {
        if (_locked) revert Reentrancy();
        _locked = true;

        State memory s;
        s.inT = tokenIn == address(0) ? WETH : tokenIn;
        s.outT = tokenOut == address(0) ? WETH : tokenOut;
        _checkArgs(tokenIn, amountIn, minAmountOut, feeBps, permit, deadline, s);

        // 1. validation pass over the whole route: nothing has moved yet (X-02, X-09)
        Plan memory p = _plan(route, s.inT, s.outT);

        // 2. entry snapshot (X-05): ETH excludes msg.value, the user's tokenOut balance is the X-07 baseline
        s.ethBase = address(this).balance - msg.value;
        s.entry = new uint256[](p.nToks);
        for (uint256 i; i < p.nToks; ++i) {
            s.entry[i] = _bal(p.toks[i], address(this));
        }
        if (tokenOut != address(0)) s.userBefore = _bal(s.outT, msg.sender);

        // 3. pull exactly amountIn from msg.sender (Permit2) or wrap msg.value
        uint256 received = _pull(tokenIn, amountIn, permit, signature, route, s.inT);
        s.inFee = feeOnOutput ? 0 : (received * feeBps) / 10_000;
        uint256 netIn = received - s.inFee;

        // 4. legs
        s.gross = _runLegs(route, p, netIn, received != amountIn);

        // 5. output fee, min-out on the executor side, end check A (before any send, S-5)
        uint256 outFee = feeOnOutput ? (s.gross * feeBps) / 10_000 : 0;
        uint256 net = s.gross - outFee;
        if (net < minAmountOut) revert MinOut();
        _endCheck(p, s, true);

        // 6. payouts: user first, fee last (X-06). Native output: unwrap, fee in WETH, then the ETH send.
        if (tokenOut == address(0)) {
            _unwrap(net);
            _payFees(s, outFee, feeOnOutput);
            _sendEth(msg.sender, net);
            userOut = net;
        } else {
            _safeTransfer(s.outT, msg.sender, net);
            userOut = _bal(s.outT, msg.sender) - s.userBefore;
            if (userOut < minAmountOut) revert MinOut();
            _payFees(s, outFee, feeOnOutput);
        }

        // 7. end check B: everything is back at its entry balance (I-1), then clear the transient state (I-13)
        _endCheck(p, s, false);
        _locked = false;

        emit Executed(
            msg.sender,
            tokenIn,
            amountIn,
            tokenOut,
            userOut,
            feeOnOutput ? outFee : s.inFee,
            feeBps,
            feeOnOutput,
            FEE_RECIPIENT,
            keccak256(abi.encode(route))
        );
    }

    // ------------------------------------------------------------------ argument and permit checks

    function _checkArgs(
        address tokenIn,
        uint256 amountIn,
        uint256 minAmountOut,
        uint16 feeBps,
        ISignatureTransfer.PermitTransferFrom calldata permit,
        uint256 deadline,
        State memory s
    ) private view {
        if (block.timestamp > deadline) revert Expired();
        if (feeBps > MAX_FEE_BPS) revert FeeTooHigh();
        if (minAmountOut == 0) revert ZeroMinOut(); // S-6
        if (amountIn == 0) revert ZeroAmount();
        if (s.inT == s.outT) revert SameToken();
        if (tokenIn == address(0)) {
            if (msg.value != amountIn) revert BadValue(); // S-2
        } else {
            if (msg.value != 0) revert BadValue(); // S-2
            // X-10 / S-7: every permit field that the executor depends on
            if (permit.permitted.token != tokenIn || permit.permitted.amount != amountIn) revert BadPermit();
            if (permit.deadline > deadline || permit.deadline > block.timestamp + MAX_PERMIT_WINDOW) {
                revert BadPermit();
            }
        }
    }

    function _pull(
        address tokenIn,
        uint256 amountIn,
        ISignatureTransfer.PermitTransferFrom calldata permit,
        bytes calldata signature,
        Route calldata route,
        address inT
    ) private returns (uint256 received) {
        uint256 before = _bal(inT, address(this));
        if (tokenIn == address(0)) {
            IWETH(WETH).deposit{value: amountIn}();
        } else {
            ISignatureTransfer(PERMIT2)
                .permitTransferFrom(
                    permit,
                    ISignatureTransfer.SignatureTransferDetails({to: address(this), requestedAmount: amountIn}),
                    msg.sender,
                    signature
                );
        }
        received = _bal(inT, address(this)) - before;
        if (received != amountIn) {
            // X-08: a taxed input is accepted only in the FOT-01 shape: one leg whose first hop is a v2 pair.
            if (received == 0 || received > amountIn) revert BadReceived();
            if (route.legs.length != 1 || route.legs[0].hops[0].family != FAMILY_V2) revert TaxedInput();
        }
    }

    // ------------------------------------------------------------------ route validation (X-02, X-09)

    function _plan(Route calldata route, address inT, address outT) private view returns (Plan memory p) {
        uint256 nLegs = route.legs.length;
        if (nLegs == 0 || nLegs > MAX_LEGS) revert BadRoute();
        uint256 total;
        for (uint256 l; l < nLegs; ++l) {
            uint256 nh = route.legs[l].hops.length;
            if (nh == 0 || nh > MAX_HOPS_PER_LEG) revert BadRoute();
            total += nh;
        }
        p.pools = new address[](total);
        p.toks = new address[](2 * total + 2);
        p.nToks = _addTok(p.toks, 0, inT);
        p.nToks = _addTok(p.toks, p.nToks, outT);

        uint256 idx;
        for (uint256 l; l < nLegs; ++l) {
            Leg calldata leg = route.legs[l];
            address cur = inT;
            // visited tokens of this leg (no cycles, X-09 item 3)
            address[] memory seen = new address[](leg.hops.length + 1);
            seen[0] = inT;
            for (uint256 h; h < leg.hops.length; ++h) {
                Hop calldata hp = leg.hops[h];
                address a = _norm(hp.tokenIn);
                address b = _norm(hp.tokenOut);
                if (a != cur || a == b) revert BadRoute(); // continuity (X-09 item 1)
                for (uint256 k; k <= h; ++k) {
                    if (seen[k] == b) revert BadRoute();
                }
                seen[h + 1] = b;
                p.pools[idx++] = _derive(hp);
                p.nToks = _addTok(p.toks, p.nToks, a);
                p.nToks = _addTok(p.toks, p.nToks, b);
                cur = b;
            }
            if (cur != outT) revert BadRoute(); // every leg ends at tokenOut (X-09 item 2)
        }
    }

    function _norm(address t) private view returns (address) {
        return t == address(0) ? WETH : t;
    }

    function _addTok(address[] memory arr, uint256 n, address t) private pure returns (uint256) {
        for (uint256 i; i < n; ++i) {
            if (arr[i] == t) return n;
        }
        arr[n] = t;
        return n + 1;
    }

    /// @dev Derives the pool of one hop from the immutable constants and checks that it has code. The key fields are
    /// validated per family so that a route has exactly one encoding.
    function _derive(Hop calldata hp) private view returns (address pool) {
        address a = hp.tokenIn;
        address b = hp.tokenOut;
        uint8 f = hp.family;
        if (f == FAMILY_V4) {
            if (hp.index != 0 || hp.tickSpacing <= 0 || !_hookAllowed(hp.hooks)) revert BadHop();
            return POOL_MANAGER; // singleton, pinned in the constructor (code checked there)
        }
        // v2, v3, CL pools hold real ERC20s only
        if (a == address(0) || b == address(0) || hp.hooks != address(0)) revert BadHop();
        (address t0, address t1) = a < b ? (a, b) : (b, a);
        if (f == FAMILY_V2) {
            if (V2_FACTORY == address(0) || hp.index != 0 || hp.fee != 0 || hp.tickSpacing != 0) revert BadHop();
            pool = _create2(V2_FACTORY, keccak256(abi.encodePacked(t0, t1)), V2_INIT_CODE_HASH);
        } else if (f == FAMILY_V3) {
            if (V3_FACTORY == address(0) || hp.index != 0 || hp.tickSpacing != 0) revert BadHop();
            pool = _create2(V3_FACTORY, keccak256(abi.encode(t0, t1, hp.fee)), V3_INIT_CODE_HASH);
        } else if (f == FAMILY_CL) {
            if (hp.fee != 0 || hp.tickSpacing <= 0) revert BadHop();
            (address d, bytes32 h) = _cl(hp.index);
            if (d == address(0)) revert BadHop();
            pool = _create2(d, keccak256(abi.encode(t0, t1, hp.tickSpacing)), h);
        } else {
            revert BadHop();
        }
        if (pool.code.length == 0) revert BadHop();
    }

    function _create2(address deployer, bytes32 salt, bytes32 initCodeHash) private pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash)))));
    }

    function _cl(uint256 i) private view returns (address d, bytes32 h) {
        if (i == 0) return (CL0_DEPLOYER, CL0_HASH);
        if (i == 1) return (CL1_DEPLOYER, CL1_HASH);
        if (i == 2) return (CL2_DEPLOYER, CL2_HASH);
        if (i == 3) return (CL3_DEPLOYER, CL3_HASH);
        if (i == 4) return (CL4_DEPLOYER, CL4_HASH);
        revert BadHop();
    }

    function _hookPin(uint256 i) private view returns (address a, bytes32 h) {
        if (i == 0) return (HOOK0, HOOK0_CODEHASH);
        if (i == 1) return (HOOK1, HOOK1_CODEHASH);
        if (i == 2) return (HOOK2, HOOK2_CODEHASH);
        if (i == 3) return (HOOK3, HOOK3_CODEHASH);
        if (i == 4) return (HOOK4, HOOK4_CODEHASH);
        if (i == 5) return (HOOK5, HOOK5_CODEHASH);
        if (i == 6) return (HOOK6, HOOK6_CODEHASH);
        if (i == 7) return (HOOK7, HOOK7_CODEHASH);
        revert BadHop();
    }

    /// @dev Hookless, or a K-7 reviewed hook whose runtime code hash still equals its pin (Main decision 1).
    function _hookAllowed(address hook) private view returns (bool) {
        if (hook == address(0)) return true;
        for (uint256 i; i < 8; ++i) {
            (address a, bytes32 h) = _hookPin(i);
            if (a == hook) return hook.codehash == h;
        }
        return false;
    }

    // ------------------------------------------------------------------ legs and hops

    function _runLegs(Route calldata route, Plan memory p, uint256 netIn, bool taxed) private returns (uint256 gross) {
        // S-6: the legs add up to the post-fee input EXACTLY, checked before the first hop runs. Single-leg taxed
        // input: the declared amount cannot know the tax, so the leg takes everything post-fee.
        uint256 sum;
        for (uint256 l; l < route.legs.length; ++l) {
            uint256 amt = taxed ? netIn : route.legs[l].amountIn;
            if (amt == 0) revert ZeroAmount();
            sum += amt;
        }
        if (sum != netIn) revert LegSum();

        uint256 idx;
        for (uint256 l; l < route.legs.length; ++l) {
            Leg calldata leg = route.legs[l];
            uint256 cur = taxed ? netIn : leg.amountIn;
            for (uint256 h; h < leg.hops.length; ++h) {
                cur = _runHop(leg.hops[h], p.pools[idx++], cur);
            }
            gross += cur;
        }
    }

    /// @dev Returns the MEASURED output of the hop in the normalised (ERC20) form. The hop spends at most `amt` of its
    /// input token (I-11).
    function _runHop(Hop calldata hp, address pool, uint256 amt) private returns (uint256) {
        uint8 f = hp.family;
        if (f == FAMILY_V2) return _hopV2(pool, hp.tokenIn, hp.tokenOut, amt);
        if (f == FAMILY_V4) return _hopV4(hp, amt);
        return _hopV3(pool, hp.tokenIn, hp.tokenOut, amt);
    }

    function _hopV2(address pair, address tokenIn, address tokenOut, uint256 amt) private returns (uint256 out) {
        bool zeroForOne = tokenIn < tokenOut;
        (uint112 r0, uint112 r1,) = IUniswapV2Pair(pair).getReserves();
        (uint256 rIn, uint256 rOut) = zeroForOne ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
        uint256 inBefore = _bal(tokenIn, address(this));
        uint256 outBefore = _bal(tokenOut, address(this));

        _safeTransfer(tokenIn, pair, amt);
        // measured received amount: supports a taxed input (FOT-01)
        uint256 inActual = _bal(tokenIn, pair) - rIn;
        if (inActual == 0) revert BadDelta();
        uint256 inWithFee = inActual * V2_FEE_NUMERATOR;
        uint256 quoted = (inWithFee * rOut) / (rIn * 1000 + inWithFee);
        if (quoted == 0) revert BadDelta();
        // S-4: empty data, so the pair never calls back; this contract implements no uniswapV2Call
        IUniswapV2Pair(pair).swap(zeroForOne ? 0 : quoted, zeroForOne ? quoted : 0, address(this), "");

        if (inBefore - _bal(tokenIn, address(this)) > amt) revert SpendBound();
        out = _bal(tokenOut, address(this)) - outBefore;
    }

    function _hopV3(address pool, address tokenIn, address tokenOut, uint256 amt) private returns (uint256 out) {
        bool zeroForOne = tokenIn < tokenOut;
        uint256 inBefore = _bal(tokenIn, address(this));
        uint256 outBefore = _bal(tokenOut, address(this));

        // S-1: the one callback this call may trigger, and nothing else
        _expPool = pool;
        _expToken = tokenIn;
        _expZeroForOne = zeroForOne;
        _expMax = amt;
        _expPending = true;

        (int256 a0, int256 a1) = IUniswapV3Pool(pool)
            .swap(
                address(this),
                zeroForOne,
                _toInt(amt),
                zeroForOne ? MIN_SQRT_PLUS_ONE : MAX_SQRT_MINUS_ONE,
                "" // no authority and no data is taken from the callback payload
            );

        // exactly one callback was consumed; clear the slots (I-13)
        if (_expPending) revert BadCallback();
        _expPool = address(0);
        _expToken = address(0);
        _expMax = 0;
        _expZeroForOne = false;

        (int256 dIn, int256 dOut) = zeroForOne ? (a0, a1) : (a1, a0);
        if (dIn != int256(amt) || dOut > 0) revert PartialFill(); // X-13: the hop consumed exactly its input
        if (inBefore - _bal(tokenIn, address(this)) > amt) revert SpendBound(); // I-11
        out = _bal(tokenOut, address(this)) - outBefore;
    }

    /// @notice v3 / CL callback. Accepted only from the pool of the hop in progress, once, for the expected token and
    /// within the expected amount (S-1, X-01). `data` is ignored.
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        if (!_expPending || msg.sender != _expPool) revert BadCallback();
        _expPending = false; // one use
        (int256 owed, int256 other) = _expZeroForOne ? (amount0Delta, amount1Delta) : (amount1Delta, amount0Delta);
        if (owed <= 0 || other > 0 || uint256(owed) > _expMax) revert BadCallback();
        _safeTransfer(_expToken, msg.sender, uint256(owed));
    }

    // ---- v4

    function _hopV4(Hop calldata hp, uint256 amt) private returns (uint256 out) {
        address cIn = hp.tokenIn; // zero address = native currency of the pool
        address cOut = hp.tokenOut;
        bool zeroForOne = cIn < cOut;
        PoolKey memory key = PoolKey({
            currency0: zeroForOne ? cIn : cOut,
            currency1: zeroForOne ? cOut : cIn,
            fee: hp.fee,
            tickSpacing: hp.tickSpacing,
            hooks: hp.hooks
        });

        if (cIn == address(0)) _unwrap(amt); // held form is WETH
        uint256 inBefore = cIn == address(0) ? address(this).balance : _bal(cIn, address(this));
        uint256 outBefore = cOut == address(0) ? address(this).balance : _bal(cOut, address(this));

        bytes memory data = abi.encode(key, zeroForOne, amt);
        _unlockHash = keccak256(data);
        _unlockPending = true;
        IPoolManager(POOL_MANAGER).unlock(data);
        if (_unlockPending) revert BadCallback(); // the unlock was consumed exactly once
        _unlockHash = bytes32(0);

        uint256 inAfter = cIn == address(0) ? address(this).balance : _bal(cIn, address(this));
        if (inBefore - inAfter > amt) revert SpendBound(); // I-11
        uint256 outAfter = cOut == address(0) ? address(this).balance : _bal(cOut, address(this));
        out = outAfter - outBefore;
        if (cOut == address(0) && out > 0) IWETH(WETH).deposit{value: out}(); // back to the held form
    }

    /// @notice v4 unlock callback. Accepted only from the PoolManager, once, for the data this contract hashed (S-1).
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != POOL_MANAGER || !_unlockPending || keccak256(data) != _unlockHash) revert BadCallback();
        _unlockPending = false; // one use
        (PoolKey memory key, bool zeroForOne, uint256 amt) = abi.decode(data, (PoolKey, bool, uint256));

        int256 d = IPoolManager(POOL_MANAGER)
            .swap(
                key,
                SwapParams({
                    zeroForOne: zeroForOne,
                    amountSpecified: -_toInt(amt), // exact input
                    sqrtPriceLimitX96: zeroForOne ? MIN_SQRT_PLUS_ONE : MAX_SQRT_MINUS_ONE
                }),
                "" // hookData is always empty
            );
        int256 d0 = int128(d >> 128);
        int256 d1 = int128(d);
        (int256 dIn, int256 dOut) = zeroForOne ? (d0, d1) : (d1, d0);
        // X-03 / X-13: the input delta is exactly -amt (so within [-amt, 0] and no partial fill); output delta >= 0
        if (dIn != -int256(amt) || dOut < 0) revert BadDelta();

        address cIn = zeroForOne ? key.currency0 : key.currency1;
        address cOut = zeroForOne ? key.currency1 : key.currency0;
        if (cIn == address(0)) {
            IPoolManager(POOL_MANAGER).settle{value: amt}();
        } else {
            IPoolManager(POOL_MANAGER).sync(cIn);
            _safeTransfer(cIn, POOL_MANAGER, amt);
            IPoolManager(POOL_MANAGER).settle();
        }
        if (dOut > 0) {
            // no ERC-6909 mint or burn: always a real take. Native takes need the receive() window.
            if (cOut == address(0)) _ethFrom = POOL_MANAGER;
            IPoolManager(POOL_MANAGER).take(cOut, address(this), uint256(dOut));
            if (cOut == address(0)) _ethFrom = address(0);
        }
        // every currency delta of this contract must be zero when `unlock` returns: the PoolManager reverts otherwise
        return "";
    }

    // ------------------------------------------------------------------ payouts and end checks

    function _payFees(State memory s, uint256 outFee, bool feeOnOutput) private {
        if (feeOnOutput) {
            if (outFee > 0) _safeTransfer(s.outT, FEE_RECIPIENT, outFee);
        } else if (s.inFee > 0) {
            _safeTransfer(s.inT, FEE_RECIPIENT, s.inFee);
        }
    }

    /// @dev I-1 / X-05 / S-5. `beforeSend`: the executor holds entry + the pending outputs (gross tokenOut and the
    /// input fee); afterwards everything is back at the entry balance. ETH is always at its base.
    function _endCheck(Plan memory p, State memory s, bool beforeSend) private view {
        for (uint256 i; i < p.nToks; ++i) {
            address t = p.toks[i];
            uint256 expected = s.entry[i];
            if (beforeSend) {
                if (t == s.outT) expected += s.gross;
                if (t == s.inT) expected += s.inFee;
            }
            if (_bal(t, address(this)) != expected) revert Residue();
        }
        // native output: before the send the unwrap has not happened yet (WETH form), so ETH is at base in both phases
        // except after `_unwrap` + before `_sendEth`, which is never checked.
        if (address(this).balance != s.ethBase) revert Residue();
    }

    function _unwrap(uint256 amount) private {
        _ethFrom = WETH;
        IWETH(WETH).withdraw(amount);
        _ethFrom = address(0);
    }

    function _sendEth(address to, uint256 amount) private {
        bool ok;
        assembly ("memory-safe") {
            ok := call(gas(), to, amount, 0, 0, 0, 0)
        }
        if (!ok) revert EthSendFailed();
    }

    // ------------------------------------------------------------------ token helpers

    function _toInt(uint256 x) private pure returns (int256) {
        if (x > uint256(type(int256).max)) revert BadDelta();
        return int256(x);
    }

    /// @dev balanceOf through a bounded staticcall; reverts if the token has no code or returns less than a word.
    function _bal(address token, address who) private view returns (uint256 r) {
        bool ok;
        assembly ("memory-safe") {
            mstore(0x00, 0x70a0823100000000000000000000000000000000000000000000000000000000)
            mstore(0x04, who)
            ok := staticcall(gas(), token, 0x00, 0x24, 0x00, 0x20)
            ok := and(ok, gt(returndatasize(), 0x1f))
            r := mload(0x00)
        }
        if (!ok) revert BalanceCallFailed();
    }

    /// @dev ERC20 transfer that reverts on a false return, accepts no-return tokens only when the token has code,
    /// and copies at most one word of return data. Never approve.
    function _safeTransfer(address token, address to, uint256 amount) private {
        bool ok;
        assembly ("memory-safe") {
            let m := mload(0x40)
            mstore(m, 0xa9059cbb00000000000000000000000000000000000000000000000000000000)
            mstore(add(m, 0x04), to)
            mstore(add(m, 0x24), amount)
            ok := call(gas(), token, 0, m, 0x44, 0x00, 0x20)
            switch returndatasize()
            case 0 { ok := and(ok, gt(extcodesize(token), 0)) }
            default { ok := and(ok, and(gt(returndatasize(), 0x1f), eq(mload(0x00), 1))) }
        }
        if (!ok) revert TransferFailed();
    }
}
