// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {PoolKey, SwapParams} from "../../src/Interfaces.sol";

// Test doubles for the adversarial and invariant suites. Nothing here is deployed anywhere.

/// @dev ERC20 with every misbehaviour the executor must survive: transfer tax, lying balances, transfer hooks,
/// false / missing return values.
contract MockERC20 {
    string public name;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) internal _bal;
    mapping(address => mapping(address => uint256)) public allowance;

    uint256 public taxBps; // burned from every transfer: the recipient receives amount * (1 - tax)
    address public lieFor; // balanceOf(lieFor) is increased by `lieBy`
    uint256 public lieBy;
    address public hookTarget; // called with `hookData` after every transfer (sender side)
    bytes public hookData;
    bool public returnFalse;
    address public taxFrom; // if set, the tax applies only to transfers FROM this address
    address public falseFrom; // transfers FROM this address return false without moving anything
    uint256 public extraBurnBps; // the SENDER is debited amount * (1 + extra): a token that burns on send
    uint256 public bonusBps; // the RECIPIENT is credited amount * (1 + bonus): an inflating token (F-3, QM11)
    bool public inHook;
    mapping(address => bool) public blocked; // transfers TO a blocked address revert (a blacklisting token)

    constructor(string memory n) {
        name = n;
    }

    function setTax(uint256 bps) external {
        taxBps = bps;
    }

    function setLie(address who, uint256 by) external {
        lieFor = who;
        lieBy = by;
    }

    function setHook(address target, bytes calldata data) external {
        hookTarget = target;
        hookData = data;
    }

    function setBlocked(address who, bool v) external {
        blocked[who] = v;
    }

    function setTaxFrom(address who) external {
        taxFrom = who;
    }

    function setFalseFrom(address who) external {
        falseFrom = who;
    }

    function setExtraBurn(uint256 bps) external {
        extraBurnBps = bps;
    }

    function setBonus(uint256 bps) external {
        bonusBps = bps;
    }

    function setReturnFalse(bool v) external {
        returnFalse = v;
    }

    function mint(address to, uint256 amount) external {
        _bal[to] += amount;
        totalSupply += amount;
    }

    function balanceOf(address a) public view returns (uint256) {
        return _bal[a] + (a == lieFor ? lieBy : 0);
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        if (msg.sender == falseFrom) return false;
        _move(msg.sender, to, amount);
        return !returnFalse;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        _move(from, to, amount);
        return !returnFalse;
    }

    function _move(address from, address to, uint256 amount) internal {
        require(!blocked[to], "blocked");
        uint256 extra = (amount * extraBurnBps) / 10_000;
        _bal[from] -= amount + extra;
        totalSupply -= extra;
        uint256 tax = (taxFrom != address(0) && from != taxFrom) ? 0 : (amount * taxBps) / 10_000;
        _bal[to] += amount - tax;
        totalSupply -= tax;
        if (bonusBps > 0) {
            uint256 bonus = (amount * bonusBps) / 10_000;
            _bal[to] += bonus;
            totalSupply += bonus;
        }
        if (hookTarget != address(0) && !inHook) {
            inHook = true;
            (bool ok, bytes memory ret) = hookTarget.call(hookData);
            if (!ok) {
                // bubble the revert of the hook so the tests can see it
                assembly ("memory-safe") {
                    revert(add(ret, 0x20), mload(ret))
                }
            }
            inHook = false;
        }
    }
}

/// @dev USDT-like token: `transfer` returns nothing.
contract MockNoReturnToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function approve(address s, uint256 a) external {
        allowance[msg.sender][s] = a;
    }

    function transferFrom(address f, address t, uint256 a) external {
        uint256 al = allowance[f][msg.sender];
        if (al != type(uint256).max) allowance[f][msg.sender] = al - a;
        balanceOf[f] -= a;
        balanceOf[t] += a;
    }

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
    }

    function transfer(address to, uint256 a) external {
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
    }
}

interface IMinBal {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

interface IV3Callback {
    function uniswapV3SwapCallback(int256 a0, int256 a1, bytes calldata data) external;
}

// ------------------------------------------------------------------------------------------------ v3 / CL mock

contract MockV3Factory {
    address public t0;
    address public t1;
    uint24 public feeP;
    int24 public tsP;

    function parameters() external view returns (address, address, uint24, int24) {
        return (t0, t1, feeP, tsP);
    }

    /// @param byTickSpacing true: salt uses an int24 tick spacing (CL family); false: uint24 fee tier (v3 family)
    function createPool(address a, address b, uint24 key, bool byTickSpacing) external returns (address pool) {
        (t0, t1) = a < b ? (a, b) : (b, a);
        feeP = key;
        tsP = int24(uint24(key));
        bytes32 salt = byTickSpacing
            ? keccak256(abi.encode(t0, t1, int24(uint24(key))))
            : keccak256(abi.encode(t0, t1, key));
        pool = address(new MockV3Pool{salt: salt}());
        t0 = address(0);
        t1 = address(0);
    }
}

contract MockV3Pool {
    enum Mode {
        NORMAL,
        TWICE,
        OVERASK,
        BOTH_POSITIVE,
        UNDER,
        PARTIAL,
        NO_CALLBACK,
        ATTACK_BEFORE_CB,
        ATTACK_AFTER_CB,
        ZERO_OWED,
        LIE_RETURN_OUT // honest callback, but `swap` returns a positive output delta
    }

    address public immutable token0;
    address public immutable token1;
    address public immutable factory;
    Mode public mode;
    address public attackTarget;
    bytes public attackData;
    uint256 public callbackCount;

    constructor() {
        factory = msg.sender;
        (token0, token1,,) = MockV3Factory(msg.sender).parameters();
    }

    function setMode(Mode m) external {
        mode = m;
    }

    function setAttack(address target, bytes calldata data) external {
        attackTarget = target;
        attackData = data;
    }

    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160, bytes calldata data)
        external
        returns (int256 a0, int256 a1)
    {
        require(amountSpecified > 0, "exact-in only");
        (address tIn, address tOut) = zeroForOne ? (token0, token1) : (token1, token0);
        uint256 rIn = IMinBal(tIn).balanceOf(address(this));
        uint256 rOut = IMinBal(tOut).balanceOf(address(this));
        uint256 amtIn = uint256(amountSpecified);
        uint256 owed = amtIn;
        if (mode == Mode.PARTIAL) owed = amtIn / 2;
        uint256 out = (owed * 997 * rOut) / (rIn * 1000 + owed * 997);
        if (mode == Mode.UNDER) out = out / 2;
        uint256 ask = mode == Mode.OVERASK ? owed + 1 : owed;
        if (mode == Mode.ZERO_OWED) ask = 0;

        require(IMinBal(tOut).transfer(recipient, out), "out");
        if (mode == Mode.ATTACK_BEFORE_CB) _attack();

        // deltas as Uniswap reports them: positive = the pool is owed
        int256 dIn = int256(ask);
        int256 dOut = -int256(out);
        if (mode == Mode.BOTH_POSITIVE) dOut = 1;
        (a0, a1) = zeroForOne ? (dIn, dOut) : (dOut, dIn);
        int256 rOut0 = a0;
        int256 rOut1 = a1;
        if (mode == Mode.LIE_RETURN_OUT) {
            if (zeroForOne) rOut1 = 5;
            else rOut0 = 5;
        }

        if (mode != Mode.NO_CALLBACK) {
            IV3Callback(msg.sender).uniswapV3SwapCallback(a0, a1, data);
            callbackCount++;
            if (mode == Mode.TWICE) {
                IV3Callback(msg.sender).uniswapV3SwapCallback(a0, a1, data);
                callbackCount++;
            }
            require(IMinBal(tIn).balanceOf(address(this)) >= rIn + ask, "not paid");
        }
        if (mode == Mode.ATTACK_AFTER_CB) _attack();
        (a0, a1) = (rOut0, rOut1);
    }

    function _attack() internal {
        (bool ok, bytes memory ret) = attackTarget.call(attackData);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }
}

// ------------------------------------------------------------------------------------------------ v2 mock

contract MockV2Factory {
    function createPair(address a, address b) external returns (address pair) {
        (address t0, address t1) = a < b ? (a, b) : (b, a);
        pair = address(new MockV2Pair{salt: keccak256(abi.encodePacked(t0, t1))}());
        MockV2Pair(pair).initialize(t0, t1);
    }
}

interface IV2Callee {
    function uniswapV2Call(address sender, uint256 a0, uint256 a1, bytes calldata data) external;
}

contract MockV2Pair {
    address public token0;
    address public token1;
    uint112 public reserve0;
    uint112 public reserve1;
    address public immutable factory;

    constructor() {
        factory = msg.sender;
    }

    function initialize(address a, address b) external {
        require(msg.sender == factory && token0 == address(0), "init");
        token0 = a;
        token1 = b;
    }

    function getReserves() external view returns (uint112, uint112, uint32) {
        return (reserve0, reserve1, 0);
    }

    function _send(address token, address to, uint256 a) internal {
        (bool ok,) = token.call(abi.encodeWithSelector(0xa9059cbb, to, a));
        require(ok, "send");
    }

    function sync() external {
        reserve0 = uint112(IMinBal(token0).balanceOf(address(this)));
        reserve1 = uint112(IMinBal(token1).balanceOf(address(this)));
    }

    function swap(uint256 o0, uint256 o1, address to, bytes calldata data) external {
        require(o0 > 0 || o1 > 0, "zero out");
        require(o0 < reserve0 && o1 < reserve1, "liq");
        if (o0 > 0) _send(token0, to, o0);
        if (o1 > 0) _send(token1, to, o1);
        if (data.length > 0) IV2Callee(to).uniswapV2Call(msg.sender, o0, o1, data);
        uint256 b0 = IMinBal(token0).balanceOf(address(this));
        uint256 b1 = IMinBal(token1).balanceOf(address(this));
        uint256 in0 = b0 > reserve0 - o0 ? b0 - (reserve0 - o0) : 0;
        uint256 in1 = b1 > reserve1 - o1 ? b1 - (reserve1 - o1) : 0;
        require(in0 > 0 || in1 > 0, "no in");
        uint256 a0 = b0 * 1000 - in0 * 3;
        uint256 a1 = b1 * 1000 - in1 * 3;
        require(a0 * a1 >= uint256(reserve0) * reserve1 * 1_000_000, "K");
        reserve0 = uint112(b0);
        reserve1 = uint112(b1);
    }
}

// ------------------------------------------------------------------------------------------------ v4 mock

interface IUnlockCb {
    function unlockCallback(bytes calldata data) external returns (bytes memory);
}

/// @dev A constant-product PoolManager with the real accounting shape: per-locker per-currency deltas, `unlock` that
/// reverts unless they are all zero, `sync/settle/take`, native settlement. Hostile behaviours are switchable.
contract MockPoolManager {
    enum Mode {
        NORMAL,
        INPUT_TOO_BIG, // the swap reports a larger input delta than specified
        NEGATIVE_OUTPUT, // the swap reports that the swapper owes the output currency
        PARTIAL_INPUT, // consumes less than the specified input
        ATTACK_IN_SWAP, // calls attackTarget in the middle of swap (a hostile hook)
        UNDERPAY_OUTPUT, // the take pays less than the delta (a hook skimming)
        REENTER_UNLOCK, // nested unlock
        PRE_UNLOCK_ATTACK, // calls attackTarget (swallowing failures) BEFORE it calls the unlock callback
        NO_CALLBACK_UNLOCK, // returns from unlock without calling back
        OTHER_DATA, // calls the callback with data that differs from what the locker passed
        DOUBLE_CALLBACK // calls the callback twice
    }

    mapping(bytes32 => uint256) public r0;
    mapping(bytes32 => uint256) public r1;
    mapping(address => mapping(address => int256)) public delta; // locker => currency => delta
    mapping(address => int256) public nonzero;
    address public locker;
    address public syncedCurrency;
    uint256 public syncedBalance;
    Mode public mode;
    address public attackTarget;
    bytes public attackData;

    function setMode(Mode m) external {
        mode = m;
    }

    function setAttack(address t, bytes calldata d) external {
        attackTarget = t;
        attackData = d;
    }

    function id(PoolKey memory k) public pure returns (bytes32) {
        return keccak256(abi.encode(k));
    }

    function seed(PoolKey memory k, uint256 a0, uint256 a1) external payable {
        bytes32 i = id(k);
        r0[i] += a0;
        r1[i] += a1;
    }

    receive() external payable {}

    function unlock(bytes calldata data) external returns (bytes memory result) {
        require(locker == address(0), "AlreadyUnlocked");
        locker = msg.sender;
        if (mode == Mode.PRE_UNLOCK_ATTACK) {
            (bool ok,) = attackTarget.call(attackData);
            ok;
        }
        if (mode == Mode.NO_CALLBACK_UNLOCK) {
            locker = address(0);
            return "";
        }
        result = IUnlockCb(msg.sender).unlockCallback(mode == Mode.OTHER_DATA ? bytes.concat(data, hex"00") : data);
        if (mode == Mode.DOUBLE_CALLBACK) IUnlockCb(msg.sender).unlockCallback(data);
        require(nonzero[msg.sender] == 0, "CurrencyNotSettled");
        locker = address(0);
    }

    function _add(address who, address c, int256 d) internal {
        int256 before = delta[who][c];
        int256 afterD = before + d;
        delta[who][c] = afterD;
        if (before == 0 && afterD != 0) nonzero[who] += 1;
        if (before != 0 && afterD == 0) nonzero[who] -= 1;
    }

    function swap(PoolKey memory k, SwapParams memory p, bytes calldata) external returns (int256 packed) {
        require(msg.sender == locker, "ManagerLocked");
        require(p.amountSpecified < 0, "exact-in only");
        bytes32 i = id(k);
        uint256 amtIn = uint256(-p.amountSpecified);
        (uint256 rIn, uint256 rOut) = p.zeroForOne ? (r0[i], r1[i]) : (r1[i], r0[i]);
        uint256 used = mode == Mode.PARTIAL_INPUT ? amtIn / 2 : amtIn;
        uint256 out = (used * 997 * rOut) / (rIn * 1000 + used * 997);
        if (p.zeroForOne) {
            r0[i] += used;
            r1[i] -= out;
        } else {
            r1[i] += used;
            r0[i] -= out;
        }
        if (mode == Mode.ATTACK_IN_SWAP) {
            (bool ok, bytes memory ret) = attackTarget.call(attackData);
            if (!ok) {
                assembly ("memory-safe") {
                    revert(add(ret, 0x20), mload(ret))
                }
            }
        }
        int256 dIn = -int256(mode == Mode.INPUT_TOO_BIG ? used + 1 : used);
        int256 dOut = mode == Mode.NEGATIVE_OUTPUT ? -int256(1) : int256(out);
        (address cIn, address cOut) = p.zeroForOne ? (k.currency0, k.currency1) : (k.currency1, k.currency0);
        _add(msg.sender, cIn, dIn);
        _add(msg.sender, cOut, dOut);
        (int256 d0, int256 d1) = p.zeroForOne ? (dIn, dOut) : (dOut, dIn);
        packed = (int256(int128(d0)) << 128) | int256(uint256(uint128(int128(d1))));
    }

    function sync(address currency) external {
        syncedCurrency = currency;
        syncedBalance = currency == address(0) ? 0 : IMinBal(currency).balanceOf(address(this));
    }

    function settle() external payable returns (uint256 paid) {
        require(msg.sender == locker, "ManagerLocked");
        if (syncedCurrency == address(0)) {
            paid = msg.value;
            _add(msg.sender, address(0), int256(paid));
        } else {
            paid = IMinBal(syncedCurrency).balanceOf(address(this)) - syncedBalance;
            _add(msg.sender, syncedCurrency, int256(paid));
            syncedCurrency = address(0);
        }
    }

    function take(address currency, address to, uint256 amount) external {
        require(msg.sender == locker, "ManagerLocked");
        _add(msg.sender, currency, -int256(amount));
        uint256 pay = mode == Mode.UNDERPAY_OUTPUT ? amount - 1 : amount;
        if (currency == address(0)) {
            (bool ok,) = to.call{value: pay}("");
            require(ok, "eth");
        } else {
            IMinBal(currency).transfer(to, pay);
        }
    }
}

// ------------------------------------------------------------------------------------------------ attackers

/// @dev Generic attacker: records and forwards calls. Used as a token hook target, a v4 hook, a fee recipient or a
/// route-builder-controlled "pool".
contract Attacker {
    address public target;
    bytes public data;
    uint256 public hits;
    bool public swallow; // ignore failures of the forwarded call

    function set(address t, bytes calldata d, bool swallow_) external {
        target = t;
        data = d;
        swallow = swallow_;
    }

    fallback() external payable {
        hits++;
        if (target != address(0)) {
            (bool ok, bytes memory ret) = target.call(data);
            if (!ok && !swallow) {
                assembly ("memory-safe") {
                    revert(add(ret, 0x20), mload(ret))
                }
            }
        }
    }

    receive() external payable {
        hits++;
    }
}

/// @dev Test-only: credits ETH to an address from inside a hook (a hostile token or hook forcing ETH into the executor).
interface IVmDeal {
    function deal(address who, uint256 newBalance) external;
}

contract EthForcer {
    IVmDeal internal constant VM = IVmDeal(address(uint160(uint256(keccak256("hevm cheat code")))));

    function poke(address to) external {
        VM.deal(to, to.balance + 1);
    }
}
