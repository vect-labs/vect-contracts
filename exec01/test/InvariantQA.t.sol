// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {ExecBase} from "./Base.t.sol";
import {VectExecutor} from "../src/VectExecutor.sol";
import {ISignatureTransfer, PoolKey} from "../src/Interfaces.sol";
import {
    MockERC20,
    MockV3Factory,
    MockV3Pool,
    MockV2Factory,
    MockV2Pair,
    MockPoolManager,
    Attacker
} from "./mocks/Mocks.sol";

/// @dev Fuzz handler: random routes (single hop, two hop, splits across v3 / CL / v2 / v4), random fees, random
/// donations, forced ETH, and attacker behaviours (pool misbehaviour modes, taxed and hooked tokens, a hostile
/// PoolManager). Violations are recorded in ghost flags because reverts inside handlers are ignored by the runner.
contract ExecHandlerQA is ExecBase {
    MockERC20 public A;
    MockERC20 public B;
    MockERC20 public C;
    MockV3Pool public v3AB;
    MockV3Pool public clAB;
    MockV2Pair public v2BC;
    MockV3Pool public v3BC;
    MockPoolManager public pm;
    Attacker public attacker;
    Reenterer public reenterer;
    address public constant BYSTANDER = address(0xBEEF1);

    bool public violation;
    string public why;
    uint256 public successes;
    uint256 public failures;
    // donated dust per token (A, B, C, WETH) and ETH: inert by design, so they define the expected residue
    mapping(address => uint256) public dust;
    uint256 public dustEth;
    // ghost totals
    uint256 public maxFeeBpsSeen;

    constructor(
        VectExecutor e,
        address u,
        uint256 k,
        MockERC20 a,
        MockERC20 b,
        MockERC20 c,
        MockV3Pool p1,
        MockV3Pool p2,
        MockV2Pair p3,
        MockV3Pool p4,
        MockPoolManager m,
        Attacker at
    ) {
        exec = e;
        user = u;
        userKey = k;
        A = a;
        B = b;
        C = c;
        v3AB = p1;
        clAB = p2;
        v2BC = p3;
        v3BC = p4;
        pm = m;
        attacker = at;
    }

    function setReenterer(Reenterer r) external {
        reenterer = r;
    }

    // QA extension: I-7 (a hostile token hook calls execute again as an EIP-1271 wallet WITH funds: must never succeed)
    function armReenter(uint8 which, bool on) external {
        MockERC20 t = which % 3 == 0 ? A : which % 3 == 1 ? B : C;
        if (on) t.setHook(address(reenterer), abi.encodeCall(Reenterer.fire, ()));
        else t.setHook(address(0), "");
    }

    // QA extension: I-11 (a token that burns more than it was asked to send from the sender)
    function setExtraBurn(uint8 which, uint16 bps) external {
        MockERC20 t = which % 3 == 0 ? A : which % 3 == 1 ? B : C;
        t.setExtraBurn(bound(uint256(bps), 0, 1500));
    }

    // QA extension: I-9 / S-6 / S-7 (expired deadline, permit window over 30 minutes, min-out zero must revert)
    function bad(uint8 kind, uint96 amtRaw) external {
        uint256 amt = bound(uint256(amtRaw), 1e3, 1000 ether);
        VectExecutor.Route memory r = _route1(_leg1(amt, _v3(address(A), address(B), 3000)));
        r.legs[0].hops = new VectExecutor.Hop[](2);
        r.legs[0].hops[0] = _v3(address(A), address(B), 3000);
        r.legs[0].hops[1] = _v3(address(B), address(C), 3000);
        A.mint(user, amt);
        vm.prank(user);
        A.approve(PERMIT2, type(uint256).max);
        uint256 k = kind % 3;
        uint256 dl = k == 0 ? block.timestamp - 1 : block.timestamp + 5000;
        uint256 pdl = k == 1 ? block.timestamp + 1801 : (k == 0 ? block.timestamp - 1 : block.timestamp + 100);
        uint256 minOut = k == 2 ? 0 : 1;
        (ISignatureTransfer.PermitTransferFrom memory permit, bytes memory sig) =
            _signPermit(userKey, address(A), amt, uint256(keccak256(abi.encode("bad", successes, failures, amt, kind))), pdl, address(exec));
        vm.prank(user);
        try exec.execute(r, address(A), amt, address(C), minOut, 0, false, permit, sig, dl) returns (uint256) {
            _flag("I-9/S-6/S-7 an invalid call succeeded");
        } catch {}
        if (A.balanceOf(address(exec)) != dust[address(A)]) _flag("I-1 A residue after bad call");
    }

    function _flag(string memory m) internal {
        if (!violation) {
            violation = true;
            why = m;
        }
    }

    function _hostile() internal view returns (bool) {
        return A.extraBurnBps() != 0 || B.extraBurnBps() != 0 || C.extraBurnBps() != 0 || v3AB.mode() != MockV3Pool.Mode.NORMAL || clAB.mode() != MockV3Pool.Mode.NORMAL
            || v3BC.mode() != MockV3Pool.Mode.NORMAL || pm.mode() != MockPoolManager.Mode.NORMAL || A.taxBps() != 0
            || B.taxBps() != 0 || C.taxBps() != 0;
    }

    // ---------------------------------------------------------------- environment actions

    function donate(uint8 which, uint96 amt) external {
        uint256 a = bound(uint256(amt), 1, 1e24);
        MockERC20 t = which % 3 == 0 ? A : which % 3 == 1 ? B : C;
        t.mint(address(exec), a);
        dust[address(t)] += a;
    }

    function forceEth(uint96 amt) external {
        uint256 a = bound(uint256(amt), 1, 10 ether);
        vm.deal(address(exec), address(exec).balance + a);
        dustEth += a;
    }

    function setPoolMode(uint8 which, uint8 mode) external {
        MockV3Pool.Mode m = MockV3Pool.Mode(mode % 10);
        if (which % 3 == 0) v3AB.setMode(m);
        else if (which % 3 == 1) clAB.setMode(m);
        else v3BC.setMode(m);
    }

    function setManagerMode(uint8 mode) external {
        pm.setMode(MockPoolManager.Mode(mode % 11));
    }

    function setTax(uint8 which, uint16 bps) external {
        MockERC20 t = which % 3 == 0 ? A : which % 3 == 1 ? B : C;
        t.setTax(bound(uint256(bps), 0, 2000));
    }

    function setHook(uint8 which, uint8 style) external {
        MockERC20 t = which % 3 == 0 ? A : which % 3 == 1 ? B : C;
        if (style % 4 == 0) {
            t.setHook(address(0), "");
        } else if (style % 4 == 1) {
            // reenter execute
            ISignatureTransfer.PermitTransferFrom memory permit;
            VectExecutor.Route memory r = _route1(_leg1(1, _v3(address(A), address(B), 3000)));
            t.setHook(address(exec), abi.encodeCall(VectExecutor.execute, (r, address(0), uint256(1), address(B), uint256(1), uint16(0), false, permit, bytes(""), block.timestamp + 1)));
        } else if (style % 4 == 2) {
            t.setHook(address(exec), abi.encodeCall(VectExecutor.uniswapV3SwapCallback, (int256(1), int256(-1), "")));
        } else {
            t.setHook(address(exec), abi.encodeCall(VectExecutor.unlockCallback, (bytes(""))));
        }
    }

    function restoreHonest() external {
        v3AB.setMode(MockV3Pool.Mode.NORMAL);
        clAB.setMode(MockV3Pool.Mode.NORMAL);
        v3BC.setMode(MockV3Pool.Mode.NORMAL);
        pm.setMode(MockPoolManager.Mode.NORMAL);
        A.setTax(0);
        B.setTax(0);
        C.setTax(0);
        A.setHook(address(0), "");
        B.setHook(address(0), "");
        C.setHook(address(0), "");
        A.setExtraBurn(0);
        B.setExtraBurn(0);
        C.setExtraBurn(0);
    }

    // ---------------------------------------------------------------- the swap action

    function swap(uint8 routeId, uint96 amtRaw, uint16 feeRaw, bool feeOnOutput, uint16 minSlack, uint8 splitSeed)
        external
    {
        uint256 amt = bound(uint256(amtRaw), 1e3, 100_000 ether);
        uint16 feeBps = uint16(feeRaw % 101);
        // router-style: fee on input shrinks the post-fee amount that the legs add up to
        uint256 netIn = feeOnOutput ? amt : amt - (amt * feeBps) / 10_000;
        if (netIn == 0) return;

        VectExecutor.Route memory r = _build(routeId % 8, netIn, splitSeed);
        A.mint(user, amt);
        vm.prank(user);
        A.approve(PERMIT2, type(uint256).max);

        uint256 minOut = 1 + (uint256(minSlack) % 1000);
        uint256 dl = block.timestamp + 600;
        (ISignatureTransfer.PermitTransferFrom memory permit, bytes memory sig) =
            _signPermit(userKey, address(A), amt, uint256(keccak256(abi.encode(successes, failures, amt, routeId))), dl, address(exec));

        uint256 userA0 = A.balanceOf(user);
        uint256 userC0 = C.balanceOf(user);
        uint256 feeA0 = A.balanceOf(FEE_RECIPIENT);
        uint256 feeC0 = C.balanceOf(FEE_RECIPIENT);
        uint256 supply0 = A.totalSupply() + B.totalSupply() + C.totalSupply();
        bool hostile = _hostile();

        vm.prank(user);
        try exec.execute(r, address(A), amt, address(C), minOut, feeBps, feeOnOutput, permit, sig, dl) returns (uint256 out) {
            successes++;
            uint256 userA1 = A.balanceOf(user);
            uint256 userC1 = C.balanceOf(user);
            // I-2: the user paid at most amountIn of tokenIn
            if (userA0 - userA1 > amt + (amt * A.extraBurnBps()) / 10_000 + 1) _flag("I-2 pulled more than amountIn (+ the token's own extra burn)");
            // I-3 / I-4: the user (only) received at least min-out of tokenOut, and out is the real delta
            if (userC1 - userC0 != out) _flag("I-4 out != recipient delta");
            if (out < minOut) _flag("I-4 out < minAmountOut");
            // I-8: the fee never exceeds the cap of the fee base
            uint256 feeA = A.balanceOf(FEE_RECIPIENT) - feeA0;
            uint256 feeC = C.balanceOf(FEE_RECIPIENT) - feeC0;
            if (feeA > (amt * 100) / 10_000) _flag("I-8 input fee above cap");
            if (feeA > 0 && feeOnOutput) _flag("I-8 input fee charged on output mode");
            if (feeC > 0 && !feeOnOutput) _flag("I-8 output fee charged on input mode");
            // the cap is checked against gross = user + fee as RECEIVED, which is exact only when tokenOut does not tax
            // its own transfers (a tax rounds the two receipts down independently, by a few wei)
            if (C.taxBps() == 0 && feeC > ((out + feeC) * 100) / 10_000) _flag("I-8 output fee above cap");
            if (feeBps == 0 && (feeA > 0 || feeC > 0)) _flag("I-8 fee with feeBps = 0");
            // conservation: tokens only leave the system through the mock's tax burn
            if (!hostile && A.totalSupply() + B.totalSupply() + C.totalSupply() != supply0) _flag("supply changed without tax");
        } catch {
            failures++;
            // a failed execute changed nothing (atomic): user balances unchanged
            if (A.balanceOf(user) != userA0 || C.balanceOf(user) != userC0) _flag("failed execute changed user balances");
        }
        // I-1 / X-05: residue is exactly the donated dust, success or failure
        // I-3: no bystander (and not the attacker or the hooker) ever holds a route token
        if (A.balanceOf(BYSTANDER) + B.balanceOf(BYSTANDER) + C.balanceOf(BYSTANDER) != 0) _flag("I-3 bystander got tokens");
        if (A.balanceOf(address(attacker)) + B.balanceOf(address(attacker)) + C.balanceOf(address(attacker)) != 0) _flag("I-3 attacker got tokens");
        if (violation == false && reenterer.succeeded()) _flag("I-7 a reentrant execute succeeded");
        if (A.balanceOf(address(exec)) != dust[address(A)]) _flag("I-1 A residue");
        if (B.balanceOf(address(exec)) != dust[address(B)]) _flag("I-1 B residue");
        if (C.balanceOf(address(exec)) != dust[address(C)]) _flag("I-1 C residue");
        if (address(exec).balance != dustEth) _flag("I-1 ETH residue");
    }

    /// @dev route templates over the mock pools. tokenIn = A, tokenOut = C always.
    /// pools: v3(A,B) cl(A,B) v2(B,C) v3(B,C) v4(A,C)
    function _build(uint8 id, uint256 netIn, uint8 seed) internal view returns (VectExecutor.Route memory r) {
        address a = address(A);
        address b = address(B);
        address c = address(C);
        VectExecutor.Hop memory v3ab = _v3(a, b, 3000);
        VectExecutor.Hop memory clab = _cl(0, a, b, 60);
        VectExecutor.Hop memory v2bc = _v2(b, c);
        VectExecutor.Hop memory v3bc = _v3(b, c, 3000);
        VectExecutor.Hop memory v4ac = _hop(3, a, c);
        v4ac.fee = 3000;
        v4ac.tickSpacing = 60;
        if (id == 0) return _route1(_leg1(netIn, v4ac));
        if (id == 1) return _route1(_leg2(netIn, v3ab, v2bc));
        if (id == 2) return _route1(_leg2(netIn, clab, v3bc));
        uint256 w1 = 1 + (uint256(seed) % 7);
        uint256 x = (netIn * w1) / 8;
        if (x == 0) x = 1;
        if (x >= netIn) x = netIn - (netIn > 1 ? 1 : 0);
        if (netIn == 1) return _route1(_leg1(netIn, v4ac));
        if (id == 3) return _route2(_leg1(x, v4ac), _leg2(netIn - x, v3ab, v2bc));
        if (id == 4) return _route2(_leg2(x, clab, v2bc), _leg2(netIn - x, v3ab, v3bc));
        if (id == 5) {
            if (netIn < 3) return _route1(_leg1(netIn, v4ac));
            uint256 y = (netIn - x) / 2;
            if (y == 0) y = 1;
            if (x + y >= netIn) {
                x = 1;
                y = 1;
            }
            VectExecutor.Route memory r3;
            r3.legs = new VectExecutor.Leg[](3);
            r3.legs[0] = _leg1(x, v4ac);
            r3.legs[1] = _leg2(y, v3ab, v2bc);
            r3.legs[2] = _leg2(netIn - x - y, clab, v3bc);
            return r3;
        }
        if (id == 6) return _route2(_leg1(x, v4ac), _leg1(netIn - x, v4ac));
        // id == 7: deliberately broken sum (must always revert)
        return _route2(_leg1(x, v4ac), _leg1(netIn - x + 1, v4ac));
    }
}

/// @dev EIP-1271 wallet with funds: the token hook makes it call execute again. If the lock were missing this would succeed.
contract Reenterer {
    VectExecutor internal exec;
    MockERC20 internal A;
    MockERC20 internal B;
    bool internal busy;
    bool public succeeded;
    uint256 internal n;

    constructor(VectExecutor e, MockERC20 a, MockERC20 b) {
        exec = e;
        A = a;
        B = b;
        A.mint(address(this), 1e30);
        A.approve(0x000000000022D473030F116dDEE9F6B43aC78BA3, type(uint256).max);
    }

    function isValidSignature(bytes32, bytes calldata) external pure returns (bytes4) {
        return 0x1626ba7e;
    }

    function fire() external {
        if (busy) return;
        busy = true;
        VectExecutor.Route memory r;
        r.legs = new VectExecutor.Leg[](1);
        r.legs[0].amountIn = 1 ether;
        r.legs[0].hops = new VectExecutor.Hop[](1);
        r.legs[0].hops[0].family = 1;
        r.legs[0].hops[0].tokenIn = address(A);
        r.legs[0].hops[0].tokenOut = address(B);
        r.legs[0].hops[0].fee = 3000;
        ISignatureTransfer.PermitTransferFrom memory permit = ISignatureTransfer.PermitTransferFrom(
            ISignatureTransfer.TokenPermissions(address(A), 1 ether), uint256(keccak256(abi.encode("re", ++n))), block.timestamp + 100
        );
        try exec.execute(r, address(A), 1 ether, address(B), 1, 0, false, permit, hex"01", block.timestamp + 100) returns (uint256) {
            succeeded = true;
        } catch {}
        busy = false;
    }
}

contract InvariantQATest is StdInvariant, ExecBase {
    ExecHandlerQA internal h;
    MockERC20 internal A;
    MockERC20 internal B;
    MockERC20 internal C;
    MockV3Pool internal v3AB;
    MockV3Pool internal clAB;
    MockV2Pair internal v2BC;
    MockV3Pool internal v3BC;
    MockPoolManager internal pm;

    function setUp() public {
        _forkOrLocal();
        _setUpUser();
        MockV3Factory v3f = new MockV3Factory();
        MockV3Factory clf = new MockV3Factory();
        MockV2Factory v2f = new MockV2Factory();
        pm = new MockPoolManager();
        Attacker hook = new Attacker();
        Attacker at = new Attacker();
        A = new MockERC20("A");
        B = new MockERC20("B");
        C = new MockERC20("C");
        // tokens must be ordered consistently with their addresses only inside the pools; the route builders pass
        // (tokenIn, tokenOut) and the executor sorts
        VectExecutor.Config memory cfg = _realConfig();
        cfg.poolManager = address(pm);
        cfg.v3Factory = address(v3f);
        cfg.v3InitCodeHash = keccak256(type(MockV3Pool).creationCode);
        cfg.v2Factory = address(v2f);
        cfg.v2InitCodeHash = keccak256(type(MockV2Pair).creationCode);
        cfg.clDeployer = [address(clf), address(0), address(0), address(0), address(0)];
        cfg.clInitCodeHash = [keccak256(type(MockV3Pool).creationCode), bytes32(0), bytes32(0), bytes32(0), bytes32(0)];
        cfg.hook = [address(hook), address(0), address(0), address(0), address(0), address(0), address(0), address(0)];
        cfg.hookCodehash = [address(hook).codehash, bytes32(0), bytes32(0), bytes32(0), bytes32(0), bytes32(0), bytes32(0), bytes32(0)];
        exec = new VectExecutor(cfg);

        uint256 liq = 10_000_000 ether;
        v3AB = MockV3Pool(v3f.createPool(address(A), address(B), 3000, false));
        clAB = MockV3Pool(clf.createPool(address(A), address(B), 60, true));
        v3BC = MockV3Pool(v3f.createPool(address(B), address(C), 3000, false));
        v2BC = MockV2Pair(v2f.createPair(address(B), address(C)));
        MockV3Pool[3] memory ps = [v3AB, clAB, v3BC];
        for (uint256 i; i < 3; ++i) {
            A.mint(address(ps[i]), liq);
            B.mint(address(ps[i]), liq);
            C.mint(address(ps[i]), liq);
        }
        B.mint(address(v2BC), liq);
        C.mint(address(v2BC), liq);
        v2BC.sync();
        // v4: A / C
        PoolKey memory k;
        (k.currency0, k.currency1) = address(A) < address(C) ? (address(A), address(C)) : (address(C), address(A));
        k.fee = 3000;
        k.tickSpacing = 60;
        A.mint(address(pm), liq);
        C.mint(address(pm), liq);
        pm.seed(k, liq, liq);

        h = new ExecHandlerQA(exec, user, userKey, A, B, C, v3AB, clAB, v2BC, v3BC, pm, at);
        Reenterer re = new Reenterer(exec, A, B);
        h.setReenterer(re);
        targetContract(address(h));
        bytes4[] memory sels = new bytes4[](16);
        sels[0] = ExecHandlerQA.swap.selector;
        sels[1] = ExecHandlerQA.swap.selector; // weight the swap action
        sels[2] = ExecHandlerQA.donate.selector;
        sels[3] = ExecHandlerQA.forceEth.selector;
        sels[4] = ExecHandlerQA.setPoolMode.selector;
        sels[5] = ExecHandlerQA.setManagerMode.selector;
        sels[6] = ExecHandlerQA.setTax.selector;
        sels[7] = ExecHandlerQA.restoreHonest.selector;
        sels[8] = ExecHandlerQA.setHook.selector;
        sels[9] = ExecHandlerQA.armReenter.selector;
        sels[10] = ExecHandlerQA.setExtraBurn.selector;
        sels[11] = ExecHandlerQA.bad.selector;
        sels[12] = ExecHandlerQA.swap.selector;
        sels[13] = ExecHandlerQA.restoreHonest.selector;
        sels[14] = ExecHandlerQA.swap.selector;
        sels[15] = ExecHandlerQA.restoreHonest.selector;
        targetSelector(FuzzSelector({addr: address(h), selectors: sels}));
        excludeSender(address(exec));
    }

    /// @dev I-1, I-2, I-3, I-4, I-8 and the atomicity of failures, checked inside the handler after every call
    function invariant_no_violation() public view {
        assertFalse(h.violation(), h.why());
    }

    /// @dev I-1 / X-05 at rest: the executor holds exactly the donated dust, nothing else
    function invariant_residue_is_only_donations() public view {
        assertEq(A.balanceOf(address(exec)), h.dust(address(A)));
        assertEq(B.balanceOf(address(exec)), h.dust(address(B)));
        assertEq(C.balanceOf(address(exec)), h.dust(address(C)));
        assertEq(address(exec).balance, h.dustEth());
    }

    /// @dev I-5 / I-13 at rest: no callback is pending between transactions, for any of the pools
    function invariant_no_callback_is_pending() public {
        address[4] memory pools = [address(v3AB), address(clAB), address(v3BC), address(pm)];
        for (uint256 i; i < pools.length; ++i) {
            vm.prank(pools[i]);
            vm.expectRevert(VectExecutor.BadCallback.selector);
            exec.uniswapV3SwapCallback(1, -1, "");
        }
        vm.prank(address(pm));
        vm.expectRevert(VectExecutor.BadCallback.selector);
        exec.unlockCallback("");
    }

    function invariant_executor_never_holds_an_allowance_or_approves() public view {
        // I-1 (allowances): the executor never calls approve; its allowance toward every pool and Permit2 is zero
        address[5] memory spenders = [address(v3AB), address(clAB), address(v3BC), address(pm), PERMIT2];
        for (uint256 i; i < spenders.length; ++i) {
            assertEq(A.allowance(address(exec), spenders[i]), 0);
            assertEq(B.allowance(address(exec), spenders[i]), 0);
            assertEq(C.allowance(address(exec), spenders[i]), 0);
        }
    }

    function invariant_i7_no_reentrant_execute_ever_succeeded() public view {
        assertFalse(h.reenterer().succeeded());
    }

    function afterInvariant() public {
        // printed so that a reader can see that the run exercised both outcomes (the invariants are not vacuous)
        emit log_named_uint("swap executes succeeded", h.successes());
        emit log_named_uint("swap executes reverted", h.failures());
    }
}
