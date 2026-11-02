// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {IERC20Min} from "./Base.t.sol";
import {MockWorld} from "./MockWorld.sol";
import {VectExecutor} from "../src/VectExecutor.sol";
import {ISignatureTransfer, IWETH, PoolKey} from "../src/Interfaces.sol";
import {
    MockERC20,
    MockNoReturnToken,
    MockV3Factory,
    MockV3Pool,
    MockV2Factory,
    MockV2Pair,
    MockPoolManager,
    Attacker,
    EthForcer
} from "./mocks/Mocks.sol";

/// @dev Spec §7 adversarial list and the Security Engineer's T-1..T-17, on mock pools / a mock PoolManager deployed
/// over the pinned fork (real Permit2 and real WETH). The honest-path behaviour on REAL pools is in Fork.t.sol.
contract AdversarialTest is MockWorld {
    // ------------------------------------------------------------------ happy paths on the mocks

    function test_v3_cl_v2_v4_single_hops() public {
        _v3Pool(A, B, 3000);
        _clPool(A, B, 60);
        _v2Pair(A, B);
        _v4Pool(address(A), address(B), address(0));
        _give(A, 4_000 ether);

        uint256 o3 = _runErc20(_route1(_leg1(1_000 ether, _v3(address(A), address(B), 3000))), address(A), 1_000 ether, address(B), 1, 0, false);
        VectExecutor.Hop memory clh = _cl(0, address(A), address(B), 60);
        uint256 oc = _runErc20(_route1(_leg1(1_000 ether, clh)), address(A), 1_000 ether, address(B), 1, 0, false);
        uint256 o2 = _runErc20(_route1(_leg1(1_000 ether, _v2(address(A), address(B)))), address(A), 1_000 ether, address(B), 1, 0, false);
        uint256 o4 = _runErc20(_route1(_leg1(1_000 ether, _v4hop(address(A), address(B), address(0)))), address(A), 1_000 ether, address(B), 1, 0, false);
        assertGt(o3, 0);
        assertEq(o3, oc);
        assertEq(o3, o2);
        assertEq(o3, o4);
        assertEq(B.balanceOf(user), o3 + oc + o2 + o4);
        address[] memory t = new address[](2);
        t[0] = address(A);
        t[1] = address(B);
        _expectResidueFree(t);
    }

    function test_two_hops_across_families_and_three_legs() public {
        _v3Pool(A, B, 3000);
        _v2Pair(B, C);
        _clPool(A, C, 60);
        _v4Pool(address(A), address(C), address(0));
        _give(A, 10_000 ether);
        // A -(v3)-> B -(v2)-> C
        uint256 o = _runErc20(_route1(_leg2(1_000 ether, _v3(address(A), address(B), 3000), _v2(address(B), address(C)))), address(A), 1_000 ether, address(C), 1, 0, false);
        assertEq(C.balanceOf(user), o);
        // three legs: two direct (cl, v4) and one two-hop; sum exact
        VectExecutor.Route memory r;
        r.legs = new VectExecutor.Leg[](3);
        r.legs[0] = _leg1(500 ether, _cl(0, address(A), address(C), 60));
        r.legs[1] = _leg1(300 ether, _v4hop(address(A), address(C), address(0)));
        r.legs[2] = _leg2(200 ether, _v3(address(A), address(B), 3000), _v2(address(B), address(C)));
        uint256 before = C.balanceOf(user);
        uint256 o3 = _runErc20(r, address(A), 1_000 ether, address(C), 1, 0, false);
        assertEq(C.balanceOf(user) - before, o3);
        address[] memory t = new address[](3);
        t[0] = address(A);
        t[1] = address(B);
        t[2] = address(C);
        _expectResidueFree(t);
    }

    function test_native_in_and_out_through_weth_pools() public {
        MockERC20 w = MockERC20(WETH); // pools hold the real WETH
        // fund pools with real WETH and token A
        vm.deal(address(this), 3_000 ether);
        IWETH(WETH).deposit{value: 2_000 ether}();
        MockV3Pool p = MockV3Pool(v3f.createPool(WETH, address(A), 3000, false));
        IERC20Min(WETH).transfer(address(p), 1_000 ether);
        A.mint(address(p), LIQ);
        // native in -> A
        VectExecutor.Route memory r = _route1(_leg1(10 ether, _v3(WETH, address(A), 3000)));
        uint256 got = _runNativeIn(r, 10 ether, address(A), 1, 0, false);
        assertEq(A.balanceOf(user), got);
        assertEq(address(exec).balance, 0);
        // A -> native out
        vm.prank(user);
        A.approve(PERMIT2, type(uint256).max);
        uint256 ethBefore = user.balance;
        VectExecutor.Route memory r2 = _route1(_leg1(got, _v3(address(A), WETH, 3000)));
        uint256 outEth = _runErc20(r2, address(A), got, address(0), 1, 0, false);
        assertEq(user.balance - ethBefore, outEth);
        assertEq(address(exec).balance, 0);
        assertEq(IERC20Min(WETH).balanceOf(address(exec)), 0);
        w; // silence
    }

    // ------------------------------------------------------------------ fees (T-5, I-8)

    function test_fee_on_input_on_output_zero_and_max() public {
        _v3Pool(A, B, 3000);
        _give(A, 10_000 ether);
        VectExecutor.Hop memory h = _v3(address(A), address(B), 3000);
        uint256 amt = 1_000 ether;
        // fee on input, 1%: leg amount is the post-fee input
        uint256 fee = (amt * 100) / 10_000;
        uint256 out = _runErc20(_route1(_leg1(amt - fee, h)), address(A), amt, address(B), 1, 100, false);
        assertEq(A.balanceOf(FEE_RECIPIENT), fee);
        assertEq(B.balanceOf(user), out);
        // fee on output, 0.5%
        uint256 before = B.balanceOf(FEE_RECIPIENT);
        uint256 outNet = _runErc20(_route1(_leg1(amt, h)), address(A), amt, address(B), 1, 50, true);
        uint256 feeOut = B.balanceOf(FEE_RECIPIENT) - before;
        assertEq(B.balanceOf(user) - out, outNet);
        assertEq(feeOut, ((feeOut + outNet) * 50) / 10_000);
        // zero fee: no transfer to the recipient
        uint256 aBefore = A.balanceOf(FEE_RECIPIENT);
        _runErc20(_route1(_leg1(amt, h)), address(A), amt, address(B), 1, 0, false);
        assertEq(A.balanceOf(FEE_RECIPIENT), aBefore);
        // MAX + 1 reverts
        Args memory a = _args(_route1(_leg1(amt, h)), address(A), amt, address(B), 1, 101, false);
        a.err = _sel(VectExecutor.FeeTooHigh.selector);
        _go(a);
    }

    function test_tiny_amount_fee_rounds_to_zero() public {
        _v3Pool(A, B, 3000);
        _give(A, 1_000 ether);
        // 99 wei at 1%: fee = 0, whole amount routed
        _runErc20(_route1(_leg1(99, _v3(address(A), address(B), 3000))), address(A), 99, address(B), 1, 100, false);
        assertEq(A.balanceOf(FEE_RECIPIENT), 0);
    }

    // ------------------------------------------------------------------ argument checks

    function test_min_out_zero_expired_value_and_same_token() public {
        _v3Pool(A, B, 3000);
        _give(A, 1_000 ether);
        VectExecutor.Route memory r = _route1(_leg1(10 ether, _v3(address(A), address(B), 3000)));
        Args memory a = _args(r, address(A), 10 ether, address(B), 0, 0, false);
        a.err = _sel(VectExecutor.ZeroMinOut.selector);
        _go(a);
        a = _args(r, address(A), 10 ether, address(B), 1, 0, false);
        a.deadline = block.timestamp - 1;
        a.err = _sel(VectExecutor.Expired.selector);
        _go(a);
        // msg.value with an ERC20 input (T-4)
        a = _args(r, address(A), 10 ether, address(B), 1, 0, false);
        a.value = 1;
        a.err = _sel(VectExecutor.BadValue.selector);
        vm.deal(user, 1 ether);
        _go(a);
        // zero amount
        a = _args(r, address(A), 0, address(B), 1, 0, false);
        a.err = _sel(VectExecutor.ZeroAmount.selector);
        _go(a);
        // tokenIn == tokenOut
        a = _args(r, address(A), 10 ether, address(A), 1, 0, false);
        a.err = _sel(VectExecutor.SameToken.selector);
        _go(a);
        // native input with the wrong msg.value
        VectExecutor.Route memory rn = _route1(_leg1(1 ether, _v3(WETH, address(A), 3000)));
        a = _args(rn, address(0), 1 ether, address(A), 1, 0, false);
        a.value = 1 ether - 1;
        a.err = _sel(VectExecutor.BadValue.selector);
        _go(a);
    }

    function test_min_out_too_high_reverts_and_underdelivering_pool() public {
        MockV3Pool p = _v3Pool(A, B, 3000);
        _give(A, 1_000 ether);
        VectExecutor.Route memory r = _route1(_leg1(10 ether, _v3(address(A), address(B), 3000)));
        Args memory a = _args(r, address(A), 10 ether, address(B), 10 ether, 0, false);
        a.err = _sel(VectExecutor.MinOut.selector);
        _go(a);
        // pool returns less than quoted (UNDER): the honest min-out is not met
        uint256 honest = _runErc20(r, address(A), 10 ether, address(B), 1, 0, false);
        p.setMode(MockV3Pool.Mode.UNDER);
        a = _args(r, address(A), 10 ether, address(B), honest, 0, false);
        a.err = _sel(VectExecutor.MinOut.selector);
        _go(a);
    }

    // ------------------------------------------------------------------ permit (T-7, I-2, I-9)

    function test_permit_field_checks() public {
        _v3Pool(A, B, 3000);
        _give(A, 1_000 ether);
        VectExecutor.Route memory r = _route1(_leg1(10 ether, _v3(address(A), address(B), 3000)));
        // token mismatch (signed for B)
        Args memory a = _args(r, address(A), 10 ether, address(B), 1, 0, false);
        a.permitToken = address(B);
        a.err = _sel(VectExecutor.BadPermit.selector);
        _go(a);
        // permitted amount larger / smaller than amountIn
        a = _args(r, address(A), 10 ether, address(B), 1, 0, false);
        a.permitAmount = 11 ether;
        a.err = _sel(VectExecutor.BadPermit.selector);
        _go(a);
        a.permitAmount = 9 ether;
        _go(a);
        // permit deadline beyond the 30 minute ceiling
        a = _args(r, address(A), 10 ether, address(B), 1, 0, false);
        a.permitDeadline = block.timestamp + 1801;
        a.deadline = block.timestamp + 5000;
        a.err = _sel(VectExecutor.BadPermit.selector);
        _go(a);
        // permit deadline after the transaction deadline
        a = _args(r, address(A), 10 ether, address(B), 1, 0, false);
        a.permitDeadline = block.timestamp + 900;
        a.deadline = block.timestamp + 600;
        a.err = _sel(VectExecutor.BadPermit.selector);
        _go(a);
        // signature for a different spender: Permit2 refuses (InvalidSigner)
        a = _args(r, address(A), 10 ether, address(B), 1, 0, false);
        a.spender = address(0xBAD);
        a.err = _sel(INVALID_SIGNER);
        _go(a);
        // signature of another owner
        a = _args(r, address(A), 10 ether, address(B), 1, 0, false);
        a.signerKey = uint256(keccak256("someone else"));
        a.err = _sel(INVALID_SIGNER);
        _go(a);
    }

    function test_permit_nonce_replay_reverts() public {
        _v3Pool(A, B, 3000);
        _give(A, 1_000 ether);
        VectExecutor.Route memory r = _route1(_leg1(10 ether, _v3(address(A), address(B), 3000)));
        uint256 dl = block.timestamp + 600;
        (ISignatureTransfer.PermitTransferFrom memory permit, bytes memory sig) =
            _signPermit(userKey, address(A), 10 ether, 777, dl, address(exec));
        vm.prank(user);
        exec.execute(r, address(A), 10 ether, address(B), 1, 0, false, permit, sig, dl);
        vm.prank(user);
        vm.expectRevert(INVALID_NONCE);
        exec.execute(r, address(A), 10 ether, address(B), 1, 0, false, permit, sig, dl);
    }

    function test_third_party_cannot_use_the_users_signature() public {
        _v3Pool(A, B, 3000);
        _give(A, 1_000 ether);
        VectExecutor.Route memory r = _route1(_leg1(10 ether, _v3(address(A), address(B), 3000)));
        uint256 dl = block.timestamp + 600;
        (ISignatureTransfer.PermitTransferFrom memory permit, bytes memory sig) =
            _signPermit(userKey, address(A), 10 ether, 5, dl, address(exec));
        // a front-runner calls with the user's signature: the owner is msg.sender, so the signature does not verify
        vm.prank(address(0xF00D));
        vm.expectRevert(INVALID_SIGNER);
        exec.execute(r, address(A), 10 ether, address(B), 1, 0, false, permit, sig, dl);
        assertEq(A.balanceOf(user), 1_000 ether);
    }

    // ------------------------------------------------------------------ route validity (T-3)

    function test_hostile_route_builder_shapes() public {
        _v3Pool(A, B, 3000);
        _v2Pair(B, C);
        _give(A, 100_000 ether);
        VectExecutor.Hop memory ab = _v3(address(A), address(B), 3000);
        VectExecutor.Hop memory bc = _v2(address(B), address(C));
        uint256 amt = 10 ether;
        Args memory a;

        // empty route
        VectExecutor.Route memory empty;
        a = _args(empty, address(A), amt, address(C), 1, 0, false);
        a.err = _sel(VectExecutor.BadRoute.selector);
        _go(a);
        // 4 legs
        VectExecutor.Route memory r4;
        r4.legs = new VectExecutor.Leg[](4);
        for (uint256 i; i < 4; ++i) r4.legs[i] = _leg1(amt / 4, ab);
        a = _args(r4, address(A), amt, address(B), 1, 0, false);
        a.err = _sel(VectExecutor.BadRoute.selector);
        _go(a);
        // leg with no hops
        VectExecutor.Route memory r0 = _route1(VectExecutor.Leg({amountIn: amt, hops: new VectExecutor.Hop[](0)}));
        a = _args(r0, address(A), amt, address(B), 1, 0, false);
        a.err = _sel(VectExecutor.BadRoute.selector);
        _go(a);
        // too many hops in a leg (5): a continuous chain of distinct tokens, so only the hop bound can refuse it
        // (the pools do not exist: without the bound the error would be BadHop)
        {
            MockERC20 D = new MockERC20("D");
            MockERC20 E = new MockERC20("E");
            MockERC20 F = new MockERC20("F");
            VectExecutor.Leg memory l5;
            l5.amountIn = amt;
            l5.hops = new VectExecutor.Hop[](5);
            l5.hops[0] = ab;
            l5.hops[1] = _v3(address(B), address(C), 3000);
            l5.hops[2] = _v3(address(C), address(D), 3000);
            l5.hops[3] = _v3(address(D), address(E), 3000);
            l5.hops[4] = _v3(address(E), address(F), 3000);
            a = _args(_route1(l5), address(A), amt, address(F), 1, 0, false);
            a.err = _sel(VectExecutor.BadRoute.selector);
            _go(a);
        }
        // chain continuity broken: A->B then A->B again
        a = _args(_route1(_leg2(amt, ab, ab)), address(A), amt, address(B), 1, 0, false);
        a.err = _sel(VectExecutor.BadRoute.selector);
        _go(a);
        // a leg that ends at the wrong token
        a = _args(_route1(_leg1(amt, ab)), address(A), amt, address(C), 1, 0, false);
        a.err = _sel(VectExecutor.BadRoute.selector);
        _go(a);
        // a leg that starts at the wrong token
        a = _args(_route1(_leg1(amt, bc)), address(A), amt, address(C), 1, 0, false);
        a.err = _sel(VectExecutor.BadRoute.selector);
        _go(a);
        // zero amount leg
        a = _args(_route1(_leg1(0, ab)), address(A), amt, address(B), 1, 0, false);
        a.err = _sel(VectExecutor.ZeroAmount.selector);
        _go(a);
        // sum off by one (low and high)
        a = _args(_route2(_leg1(amt / 2, ab), _leg1(amt / 2 - 1, ab)), address(A), amt, address(B), 1, 0, false);
        a.err = _sel(VectExecutor.LegSum.selector);
        _go(a);
        a = _args(_route2(_leg1(amt / 2, ab), _leg1(amt / 2 + 1, ab)), address(A), amt, address(B), 1, 0, false);
        a.err = _sel(VectExecutor.LegSum.selector);
        _go(a);
        // cycle inside a leg: A->B->A->B ... (A repeated)
        VectExecutor.Leg memory cyc;
        cyc.amountIn = amt;
        cyc.hops = new VectExecutor.Hop[](3);
        cyc.hops[0] = ab;
        cyc.hops[1] = _v3(address(B), address(A), 3000);
        cyc.hops[2] = ab;
        a = _args(_route1(cyc), address(A), amt, address(B), 1, 0, false);
        a.err = _sel(VectExecutor.BadRoute.selector);
        _go(a);
        // a hop whose pool does not exist (fee tier never created)
        a = _args(_route1(_leg1(amt, _v3(address(A), address(B), 500))), address(A), amt, address(B), 1, 0, false);
        a.err = _sel(VectExecutor.BadHop.selector);
        _go(a);
        // native token on a non-v4 hop
        a = _args(_route1(_leg1(amt, _v3(address(0), address(B), 3000))), address(A), amt, address(B), 1, 0, false);
        a.err = _sel(VectExecutor.BadRoute.selector);
        _go(a);
        // unknown family, unknown CL index, field malleability
        VectExecutor.Hop memory bad = ab;
        bad.family = 9;
        a = _args(_route1(_leg1(amt, bad)), address(A), amt, address(B), 1, 0, false);
        a.err = _sel(VectExecutor.BadHop.selector);
        _go(a);
        bad = _cl(7, address(A), address(B), 60);
        a = _args(_route1(_leg1(amt, bad)), address(A), amt, address(B), 1, 0, false);
        a.err = _sel(VectExecutor.BadHop.selector);
        _go(a);
        bad = ab;
        bad.hooks = address(attacker);
        a = _args(_route1(_leg1(amt, bad)), address(A), amt, address(B), 1, 0, false);
        a.err = _sel(VectExecutor.BadHop.selector);
        _go(a);
        bad = ab;
        bad.tickSpacing = 60;
        a = _args(_route1(_leg1(amt, bad)), address(A), amt, address(B), 1, 0, false);
        a.err = _sel(VectExecutor.BadHop.selector);
        _go(a);
        // a failed validation moved nothing
        assertEq(A.balanceOf(user), 100_000 ether);
    }

    function test_negative_derivation_pool_from_another_factory_or_deployer_is_refused() public {
        // same init code, other factory: its pool must not be accepted
        MockV3Factory evil = new MockV3Factory();
        address fake = evil.createPool(address(A), address(B), 3000, false);
        A.mint(fake, LIQ);
        B.mint(fake, LIQ);
        _give(A, 100 ether);
        // no pool of the real factory exists for (A,B,3000): the derived address has no code
        Args memory a = _args(_route1(_leg1(1 ether, _v3(address(A), address(B), 3000))), address(A), 1 ether, address(B), 1, 0, false);
        a.err = _sel(VectExecutor.BadHop.selector);
        _go(a);
        // and the fake pool cannot reach the callback: no expectation is pending
        vm.prank(fake);
        vm.expectRevert(VectExecutor.BadCallback.selector);
        exec.uniswapV3SwapCallback(1, -1, "");
    }

    // ------------------------------------------------------------------ callbacks (I-5, S-1, T-1, T-11)

    function test_callback_direct_calls_revert() public {
        MockV3Pool p = _v3Pool(A, B, 3000);
        // outside any execute
        vm.expectRevert(VectExecutor.BadCallback.selector);
        exec.uniswapV3SwapCallback(1, -1, "");
        vm.prank(address(p));
        vm.expectRevert(VectExecutor.BadCallback.selector);
        exec.uniswapV3SwapCallback(1, -1, "");
        vm.expectRevert(VectExecutor.BadCallback.selector);
        exec.unlockCallback("");
        vm.prank(address(pm));
        vm.expectRevert(VectExecutor.BadCallback.selector);
        exec.unlockCallback("");
    }

    function test_pool_misbehaviour_modes_exact_errors() public {
        MockV3Pool p = _v3Pool(A, B, 3000);
        _give(A, 1_000 ether);
        VectExecutor.Route memory r = _route1(_leg1(10 ether, _v3(address(A), address(B), 3000)));
        MockV3Pool.Mode[6] memory modes = [
            MockV3Pool.Mode.TWICE,
            MockV3Pool.Mode.OVERASK,
            MockV3Pool.Mode.BOTH_POSITIVE,
            MockV3Pool.Mode.ZERO_OWED,
            MockV3Pool.Mode.NO_CALLBACK,
            MockV3Pool.Mode.PARTIAL
        ];
        bytes4[6] memory errs = [
            VectExecutor.BadCallback.selector, // second callback: nothing pending
            VectExecutor.BadCallback.selector, // asks more than the hop input
            VectExecutor.BadCallback.selector, // the other delta is positive
            VectExecutor.BadCallback.selector, // owes nothing
            VectExecutor.BadCallback.selector, // never called back: the expectation was not consumed
            VectExecutor.PartialFill.selector // consumes half of the input
        ];
        A.mint(address(exec), 50 ether); // dust, so that an over-payment would not fail on a missing balance
        for (uint256 i; i < modes.length; ++i) {
            p.setMode(modes[i]);
            Args memory a = _args(r, address(A), 10 ether, address(B), 1, 0, false);
            a.err = _sel(errs[i]);
            _go(a);
        }
        p.setMode(MockV3Pool.Mode.NORMAL);
        _runErc20(r, address(A), 10 ether, address(B), 1, 0, false);
    }

    /// @dev external wrapper so that `vm.expectRevert()` catches the revert of the whole `_go`
    function callGo(Args memory a) external {
        _go(a);
    }

    function test_callback_after_swap_returned_reverts() public {
        MockV3Pool p = _v3Pool(A, B, 3000);
        _give(A, 1_000 ether);
        // the pool calls the executor's callback again after the swap returned
        p.setMode(MockV3Pool.Mode.ATTACK_AFTER_CB);
        p.setAttack(address(exec), abi.encodeCall(VectExecutor.uniswapV3SwapCallback, (int256(1), int256(-1), "")));
        Args memory a = _args(_route1(_leg1(10 ether, _v3(address(A), address(B), 3000))), address(A), 10 ether, address(B), 1, 0, false);
        a.err = _sel(VectExecutor.BadCallback.selector);
        _go(a);
    }

    /// @dev S-1 / X-01 / T-1: a genuine allowlisted pool P2, not the pool being called, calls the executor's callback
    /// while hop 1 (P1) is in flight. The call comes from a hostile token hook that reaches P2.
    function test_s1_other_genuine_pool_cannot_call_back_during_a_hop() public {
        _v3Pool(A, B, 3000); // P1: the pool of the route
        MockV3Pool p2 = _v3Pool(A, C, 3000); // P2: genuine, allowlisted, derived, but not the pool in flight
        _give(A, 1_000 ether);
        // P2 will call back the executor's callback with a plausible "pay me" request
        p2.setMode(MockV3Pool.Mode.ATTACK_BEFORE_CB);
        p2.setAttack(address(exec), abi.encodeCall(VectExecutor.uniswapV3SwapCallback, (int256(5 ether), int256(-1), "")));
        // token B is hostile: when P1 sends B to the executor, its hook makes P2.swap(...) run
        B.setHook(
            address(p2),
            abi.encodeCall(MockV3Pool.swap, (address(attacker), true, int256(1 ether), uint160(1), bytes("")))
        );
        Args memory a = _args(_route1(_leg1(10 ether, _v3(address(A), address(B), 3000))), address(A), 10 ether, address(B), 1, 0, false);
        a.err = _sel(VectExecutor.BadCallback.selector);
        _go(a);
        assertEq(IERC20Min(address(A)).balanceOf(address(p2)), LIQ, "P2 was not paid");
    }

    function test_hostile_token_hook_calls_callback_directly_and_reenters_execute() public {
        _v3Pool(A, B, 3000);
        _give(A, 1_000 ether);
        VectExecutor.Route memory r = _route1(_leg1(10 ether, _v3(address(A), address(B), 3000)));
        // hook (sender side of every B transfer) calls the callback directly
        B.setHook(address(exec), abi.encodeCall(VectExecutor.uniswapV3SwapCallback, (int256(1), int256(-1), "")));
        Args memory a = _args(r, address(A), 10 ether, address(B), 1, 0, false);
        a.err = _sel(VectExecutor.BadCallback.selector);
        _go(a);
        // hook re-enters execute
        ISignatureTransfer.PermitTransferFrom memory permit;
        B.setHook(address(exec), abi.encodeCall(VectExecutor.execute, (r, address(0), uint256(1), address(B), uint256(1), uint16(0), false, permit, bytes(""), block.timestamp + 1)));
        a = _args(r, address(A), 10 ether, address(B), 1, 0, false);
        a.err = _sel(VectExecutor.Reentrancy.selector);
        _go(a);
    }

    function test_no_residue_after_a_failed_hop_and_clean_state_after_success() public {
        MockV3Pool p = _v3Pool(A, B, 3000);
        _give(A, 1_000 ether);
        VectExecutor.Route memory r = _route1(_leg1(10 ether, _v3(address(A), address(B), 3000)));
        p.setMode(MockV3Pool.Mode.TWICE);
        Args memory a = _args(r, address(A), 10 ether, address(B), 1, 0, false);
        vm.expectRevert();
        this.callGo(a);
        assertEq(A.balanceOf(user), 1_000 ether);
        p.setMode(MockV3Pool.Mode.NORMAL);
        _runErc20(r, address(A), 10 ether, address(B), 1, 0, false);
        // a stale callback after a successful execute is refused (every transient slot is clear)
        vm.prank(address(p));
        vm.expectRevert(VectExecutor.BadCallback.selector);
        exec.uniswapV3SwapCallback(1, -1, "");
    }

    // ------------------------------------------------------------------ donation inertness and forced ETH (T-4, T-6)

    function test_donated_dust_and_forced_eth_are_inert() public {
        _v3Pool(A, B, 3000);
        _v3Pool(B, C, 3000);
        _give(A, 1_000 ether);
        VectExecutor.Route memory r = _route1(_leg2(10 ether, _v3(address(A), address(B), 3000), _v3(address(B), address(C), 3000)));
        uint256 clean = _runErc20(r, address(A), 10 ether, address(C), 1, 0, false);
        // dust of every route token and ETH
        A.mint(address(exec), 7);
        B.mint(address(exec), 11);
        C.mint(address(exec), 13);
        vm.deal(address(exec), 17);
        uint256 withDust = _runErc20(r, address(A), 10 ether, address(C), 1, 0, false);
        // each run moves the pool, so compare against a snapshot of the same state instead
        assertGt(withDust, 0);
        assertGt(clean, 0);
        assertEq(A.balanceOf(address(exec)), 7);
        assertEq(B.balanceOf(address(exec)), 11);
        assertEq(C.balanceOf(address(exec)), 13);
        assertEq(address(exec).balance, 17);
    }

    function test_dust_does_not_change_the_result_same_state() public {
        _v3Pool(A, B, 3000);
        _give(A, 1_000 ether);
        VectExecutor.Route memory r = _route1(_leg1(10 ether, _v3(address(A), address(B), 3000)));
        uint256 snap = vm.snapshotState();
        uint256 clean = _runErc20(r, address(A), 10 ether, address(B), 1, 0, false);
        vm.revertToState(snap);
        A.mint(address(exec), 5);
        B.mint(address(exec), 5);
        vm.deal(address(exec), 5);
        uint256 withDust = _runErc20(r, address(A), 10 ether, address(B), 1, 0, false);
        assertEq(withDust, clean, "dust changed the amount");
    }

    function test_eth_only_from_weth_or_pool_manager() public {
        (bool ok,) = address(exec).call{value: 1}("");
        assertFalse(ok);
        vm.prank(address(pm));
        (ok,) = address(exec).call{value: 0}("");
        assertFalse(ok); // not during a take
        vm.deal(address(pm), 1 ether);
        vm.prank(address(pm));
        (ok,) = address(exec).call{value: 1}("");
        assertFalse(ok);
        vm.deal(WETH, 1 ether);
        vm.prank(WETH);
        (ok,) = address(exec).call{value: 1}("");
        assertFalse(ok); // WETH outside of an unwrap
    }

    // ------------------------------------------------------------------ fee-on-transfer and dishonest tokens (T-8)

    function test_taxed_input_single_v2_leg_is_supported() public {
        MockERC20 tax = new MockERC20("TAX");
        _v2Pair(tax, B);
        tax.setTax(1000); // 10 % burned on every transfer
        _give(tax, 1_000 ether);
        uint256 amt = 100 ether;
        // the declared leg amount cannot know the tax: it is ignored in this shape
        VectExecutor.Route memory r = _route1(_leg1(amt, _v2(address(tax), address(B))));
        uint256 out = _runErc20(r, address(tax), amt, address(B), 1, 0, false);
        assertGt(out, 0);
        assertEq(B.balanceOf(user), out);
        assertEq(tax.balanceOf(address(exec)), 0);
    }

    function test_taxed_input_on_v3_leg_and_on_split_reverts() public {
        MockERC20 tax = new MockERC20("TAX");
        _v3Pool(tax, B, 3000);
        _v2Pair(tax, B);
        tax.setTax(1000);
        _give(tax, 1_000 ether);
        uint256 amt = 100 ether;
        Args memory a = _args(_route1(_leg1(amt, _v3(address(tax), address(B), 3000))), address(tax), amt, address(B), 1, 0, false);
        a.err = _sel(VectExecutor.TaxedInput.selector);
        _go(a);
        a = _args(_route2(_leg1(amt / 2, _v2(address(tax), address(B))), _leg1(amt / 2, _v2(address(tax), address(B)))), address(tax), amt, address(B), 1, 0, false);
        a.err = _sel(VectExecutor.TaxedInput.selector);
        _go(a);
    }

    function test_taxed_output_is_caught_at_the_recipient() public {
        MockERC20 tax = new MockERC20("TAX");
        _v3Pool(A, tax, 3000);
        _give(A, 1_000 ether);
        VectExecutor.Route memory r = _route1(_leg1(10 ether, _v3(address(A), address(tax), 3000)));
        // measure the pool output with a zero tax first
        uint256 snap = vm.snapshotState();
        uint256 nominal = _runErc20(r, address(A), 10 ether, address(tax), 1, 0, false);
        vm.revertToState(snap);
        tax.setTax(1000);
        // the pool pays the executor net of tax (10 %), then the executor pays the user net of tax again
        Args memory a = _args(r, address(A), 10 ether, address(tax), nominal, 0, false);
        a.err = _sel(VectExecutor.MinOut.selector);
        _go(a);
    }

    function test_token_returning_false_and_no_return_tokens() public {
        _v3Pool(A, B, 3000);
        _give(A, 1_000 ether);
        VectExecutor.Route memory r = _route1(_leg1(10 ether, _v3(address(A), address(B), 3000)));
        B.setReturnFalse(true);
        Args memory a = _args(r, address(A), 10 ether, address(B), 1, 0, false);
        vm.expectRevert(); // the pool's own `require(transfer)` fails first
        this.callGo(a);
        B.setReturnFalse(false);

        // USDT-like token (transfer returns nothing) as the v2 output and as the v2 input
        MockNoReturnToken usdt = new MockNoReturnToken();
        MockV2Pair p = MockV2Pair(v2f.createPair(address(A), address(usdt)));
        A.mint(address(p), LIQ);
        usdt.mint(address(p), LIQ);
        p.sync();
        uint256 got = _runErc20(_route1(_leg1(10 ether, _v2(address(A), address(usdt)))), address(A), 10 ether, address(usdt), 1, 0, false);
        assertEq(usdt.balanceOf(user), got);
        vm.prank(user);
        usdt.approve(PERMIT2, type(uint256).max);
        uint256 back = _runErc20(_route1(_leg1(got, _v2(address(usdt), address(A)))), address(usdt), got, address(A), 1, 0, false);
        assertGt(back, 0);
        assertEq(usdt.balanceOf(address(exec)), 0);
    }

    // ------------------------------------------------------------------ v4 (X-03, T-2)

    function test_v4_native_in_and_out_wrap_unwrap() public {
        // pool: native / A. The route holds WETH between hops, so native<->WETH is converted around the hop
        PoolKey memory k = _v4Pool(address(0), address(A), address(0));
        k;
        vm.deal(address(pm), 5_000 ether);
        // WETH -> (v4 native/A): the executor unwraps WETH, settles ETH, takes A
        VectExecutor.Route memory r = _route1(_leg1(10 ether, _v4hop(address(0), address(A), address(0))));
        uint256 got = _runNativeIn(r, 10 ether, address(A), 1, 0, false);
        assertEq(A.balanceOf(user), got);
        assertEq(address(exec).balance, 0);
        assertEq(IERC20Min(WETH).balanceOf(address(exec)), 0);
        // A -> native: the executor takes ETH from the manager, wraps it, then unwraps for the user
        vm.prank(user);
        A.approve(PERMIT2, type(uint256).max);
        VectExecutor.Route memory r2 = _route1(_leg1(got, _v4hop(address(A), address(0), address(0))));
        uint256 ethBefore = user.balance;
        uint256 outEth = _runErc20(r2, address(A), got, address(0), 1, 0, false);
        assertEq(user.balance - ethBefore, outEth);
        assertEq(address(exec).balance, 0);
    }

    function test_v4_hostile_manager_behaviours_exact_errors() public {
        _v4Pool(address(A), address(B), address(0));
        _give(A, 1_000 ether);
        A.mint(address(exec), 50 ether); // dust: an over-payment would not fail on a missing balance
        VectExecutor.Route memory r = _route1(_leg1(10 ether, _v4hop(address(A), address(B), address(0))));
        MockPoolManager.Mode[7] memory modes = [
            MockPoolManager.Mode.INPUT_TOO_BIG,
            MockPoolManager.Mode.NEGATIVE_OUTPUT,
            MockPoolManager.Mode.PARTIAL_INPUT,
            MockPoolManager.Mode.NO_CALLBACK_UNLOCK,
            MockPoolManager.Mode.OTHER_DATA,
            MockPoolManager.Mode.DOUBLE_CALLBACK,
            MockPoolManager.Mode.UNDERPAY_OUTPUT
        ];
        bytes4[7] memory errs = [
            VectExecutor.BadDelta.selector,
            VectExecutor.BadDelta.selector,
            VectExecutor.BadDelta.selector,
            VectExecutor.BadCallback.selector, // unlock returned without calling back
            VectExecutor.BadCallback.selector, // payload differs from what the executor hashed
            VectExecutor.BadCallback.selector, // second callback: nothing pending
            bytes4(0) // a short take is measured, not trusted: the swap succeeds with the measured output
        ];
        for (uint256 i; i < modes.length; ++i) {
            pm.setMode(modes[i]);
            Args memory a = _args(r, address(A), 10 ether, address(B), 1, 0, false);
            if (errs[i] != bytes4(0)) a.err = _sel(errs[i]);
            _go(a);
        }
        pm.setMode(MockPoolManager.Mode.NORMAL);
        _runErc20(r, address(A), 10 ether, address(B), 1, 0, false);
    }

    /// @dev A third contract, called by the manager between `unlock` and the callback, tries to run the callback with
    /// the exact payload. Its call must fail (and is swallowed), and the real callback must then still succeed.
    function test_v4_third_party_cannot_run_the_unlock_callback_in_the_window() public {
        PoolKey memory k = _v4Pool(address(A), address(B), address(0));
        _give(A, 1_000 ether);
        uint256 amt = 10 ether;
        bool z = address(A) < address(B);
        bytes memory payload = abi.encode(k, z, amt);
        Attacker third = new Attacker();
        third.set(address(exec), abi.encodeCall(VectExecutor.unlockCallback, (payload)), true);
        pm.setMode(MockPoolManager.Mode.PRE_UNLOCK_ATTACK);
        pm.setAttack(address(third), hex"01"); // non-empty so that the Attacker fallback forwards the call
        VectExecutor.Route memory r = _route1(_leg1(amt, _v4hop(address(A), address(B), address(0))));
        uint256 out = _runErc20(r, address(A), amt, address(B), 1, 0, false);
        assertGt(out, 0);
        assertEq(third.hits(), 1, "the third party was reached");
    }

    function test_v4_hook_cannot_reenter_or_call_callbacks() public {
        _v4Pool(address(A), address(B), address(0));
        _give(A, 1_000 ether);
        VectExecutor.Route memory r = _route1(_leg1(10 ether, _v4hop(address(A), address(B), address(0))));
        pm.setMode(MockPoolManager.Mode.ATTACK_IN_SWAP);
        // the "hook" calls unlockCallback directly
        pm.setAttack(address(exec), abi.encodeCall(VectExecutor.unlockCallback, (bytes(""))));
        Args memory a = _args(r, address(A), 10 ether, address(B), 1, 0, false);
        a.err = _sel(VectExecutor.BadCallback.selector);
        _go(a);
        // the "hook" calls the v3 callback while the unlock is pending
        pm.setAttack(address(exec), abi.encodeCall(VectExecutor.uniswapV3SwapCallback, (int256(1), int256(-1), "")));
        _go(a);
        // the "hook" re-enters execute
        ISignatureTransfer.PermitTransferFrom memory permit;
        pm.setAttack(address(exec), abi.encodeCall(VectExecutor.execute, (r, address(0), uint256(1), address(B), uint256(1), uint16(0), false, permit, bytes(""), block.timestamp + 1)));
        a.err = _sel(VectExecutor.Reentrancy.selector);
        _go(a);
    }

    function test_v4_hook_allowlist_and_codehash_pin() public {
        PoolKey memory k = _v4Pool(address(A), address(B), address(hookOk));
        k;
        _give(A, 1_000 ether);
        VectExecutor.Route memory ok = _route1(_leg1(10 ether, _v4hop(address(A), address(B), address(hookOk))));
        _runErc20(ok, address(A), 10 ether, address(B), 1, 0, false);
        // an unreviewed hook is refused
        VectExecutor.Route memory bad = _route1(_leg1(10 ether, _v4hop(address(A), address(B), address(attacker))));
        Args memory a = _args(bad, address(A), 10 ether, address(B), 1, 0, false);
        a.err = _sel(VectExecutor.BadHop.selector);
        _go(a);
        // a reviewed hook whose code changed (codehash no longer the pin) is refused
        vm.etch(address(hookOk), hex"6001600055");
        a = _args(ok, address(A), 10 ether, address(B), 1, 0, false);
        a.err = _sel(VectExecutor.BadHop.selector);
        _go(a);
    }

    // ------------------------------------------------------------------ two executes in one transaction (T-10)

    function test_two_executes_in_one_transaction_native_in() public {
        MockV3Pool p = MockV3Pool(v3f.createPool(WETH, address(A), 3000, false));
        vm.deal(address(this), 2_000 ether);
        IWETH(WETH).deposit{value: 1_000 ether}();
        IERC20Min(WETH).transfer(address(p), 1_000 ether);
        A.mint(address(p), LIQ);
        MultiCaller mc = new MultiCaller();
        VectExecutor.Route memory r = _route1(_leg1(1 ether, _v3(WETH, address(A), 3000)));
        vm.deal(address(mc), 10 ether);
        mc.twice(exec, r, address(A));
        assertGt(A.balanceOf(address(mc)), 0);
        assertEq(address(exec).balance, 0);
        // second call reverts internally (min-out), first still commits, then a third succeeds: state is clean
        mc.revertingThenOk(exec, r, address(A));
    }

    // ------------------------------------------------------------------ misc

    function test_fee_recipient_that_blocks_transfers_only_blocks_that_swap() public {
        _v3Pool(A, B, 3000);
        _give(A, 1_000 ether);
        A.setBlocked(FEE_RECIPIENT, true);
        // feeBps = 0: nothing is paid to the recipient, the swap goes through
        _runErc20(_route1(_leg1(99 ether, _v3(address(A), address(B), 3000))), address(A), 99 ether, address(B), 1, 0, false);
        // feeBps > 0: the fee transfer reverts, so this swap (and only this swap) fails closed
        Args memory a = _args(_route1(_leg1(99 ether, _v3(address(A), address(B), 3000))), address(A), 100 ether, address(B), 1, 100, false);
        vm.expectRevert();
        this.callGo(a);
        assertEq(A.balanceOf(address(exec)), 0);
    }

    // ------------------------------------------------------------------ I-11, executor-side token behaviour, cast, config

    function test_i11_token_that_burns_extra_on_send_breaks_the_hop_bound_v3_v2_v4() public {
        _v3Pool(A, B, 3000);
        _v2Pair(A, B);
        _v4Pool(address(A), address(B), address(0));
        _give(A, 1_000 ether);
        A.setExtraBurn(500); // the executor loses 5 % more than it sends
        // pre-donated dust lets the extra debit succeed, so only the per-hop bound can catch it
        A.mint(address(exec), 100 ether);
        VectExecutor.Hop[3] memory hops =
            [_v3(address(A), address(B), 3000), _v2(address(A), address(B)), _v4hop(address(A), address(B), address(0))];
        for (uint256 i; i < 3; ++i) {
            Args memory a = _args(_route1(_leg1(10 ether, hops[i])), address(A), 10 ether, address(B), 1, 0, false);
            a.err = _sel(VectExecutor.SpendBound.selector);
            _go(a);
        }
    }

    function test_executor_side_false_return_on_payout_reverts() public {
        _v3Pool(A, B, 3000);
        _give(A, 1_000 ether);
        B.setFalseFrom(address(exec)); // B.transfer(from the executor) returns false
        Args memory a = _args(_route1(_leg1(10 ether, _v3(address(A), address(B), 3000))), address(A), 10 ether, address(B), 1, 0, false);
        a.err = _sel(VectExecutor.TransferFailed.selector);
        _go(a);
    }

    function test_huge_amount_cast_is_checked() public {
        _v3Pool(A, B, 3000);
        uint256 huge = uint256(type(int256).max) + 1;
        A.mint(user, huge);
        vm.prank(user);
        A.approve(PERMIT2, type(uint256).max);
        Args memory a = _args(_route1(_leg1(huge, _v3(address(A), address(B), 3000))), address(A), huge, address(B), 1, 0, false);
        a.err = _sel(VectExecutor.BadDelta.selector);
        _go(a);
    }

    function test_constructor_rejects_bad_configuration() public {
        VectExecutor.Config memory c = _realConfig();
        c.feeRecipient = address(0);
        vm.expectRevert(VectExecutor.BadConfig.selector);
        new VectExecutor(c);
        c = _realConfig();
        c.feeRecipient = address(0xE0A); // E4-03: an EOA (no code) is refused
        vm.expectRevert(VectExecutor.BadConfig.selector);
        new VectExecutor(c);
        c = _realConfig();
        c.weth = address(0xdead); // no code
        vm.expectRevert(VectExecutor.BadConfig.selector);
        new VectExecutor(c);
        c = _realConfig();
        c.v3InitCodeHash = bytes32(0); // factory set, hash empty
        vm.expectRevert(VectExecutor.BadConfig.selector);
        new VectExecutor(c);
        c = _realConfig();
        c.hookCodehash[0] = bytes32(uint256(1)); // pin that the chain does not show
        vm.expectRevert(VectExecutor.BadConfig.selector);
        new VectExecutor(c);
        c = _realConfig();
        c.clDeployer[2] = address(0xbeef); // no code at the deployer
        vm.expectRevert(VectExecutor.BadConfig.selector);
        new VectExecutor(c);
        c = _realConfig();
        c.v2FeeNumerator = 0;
        vm.expectRevert(VectExecutor.BadConfig.selector);
        new VectExecutor(c);
    }

    // ------------------------------------------------------------------ min-out layers (X-07)

    function test_min_out_recipient_side_catches_a_token_that_taxes_the_executor_payout() public {
        MockERC20 tax = new MockERC20("TAX");
        _v3Pool(A, tax, 3000);
        _give(A, 1_000 ether);
        VectExecutor.Route memory r = _route1(_leg1(10 ether, _v3(address(A), address(tax), 3000)));
        uint256 snap = vm.snapshotState();
        uint256 honest = _runErc20(r, address(A), 10 ether, address(tax), 1, 0, false);
        vm.revertToState(snap);
        // the pool pays the executor in full; only transfers FROM the executor are taxed (10 %)
        tax.setTax(1000);
        tax.setTaxFrom(address(exec));
        // executor-side net == honest passes; the user receives 10 % less: only the recipient-side check sees it
        Args memory a = _args(r, address(A), 10 ether, address(tax), honest, 0, false);
        a.err = _sel(VectExecutor.MinOut.selector);
        _go(a);
        // with the min-out set to what the user can actually get, it passes
        uint256 got = _runErc20(r, address(A), 10 ether, address(tax), (honest * 9) / 10, 0, false);
        assertEq(tax.balanceOf(user), got);
        assertLt(got, honest);
    }

    function test_min_out_native_output_executor_side() public {
        MockV3Pool p = MockV3Pool(v3f.createPool(WETH, address(A), 3000, false));
        vm.deal(address(this), 3_000 ether);
        IWETH(WETH).deposit{value: 1_000 ether}();
        IERC20Min(WETH).transfer(address(p), 1_000 ether);
        A.mint(address(p), LIQ);
        _give(A, 1_000 ether);
        VectExecutor.Route memory r = _route1(_leg1(10 ether, _v3(address(A), WETH, 3000)));
        Args memory a = _args(r, address(A), 10 ether, address(0), 10 ether, 0, false); // asks for 10 ETH for 10 A
        a.err = _sel(VectExecutor.MinOut.selector);
        _go(a);
    }

    // ------------------------------------------------------------------ T-17: the largest legal route

    function test_t17_maximal_route_gas_and_state() public {
        MockERC20 D = new MockERC20("D");
        MockERC20 E = new MockERC20("E");
        _v3Pool(A, B, 3000);
        _v3Pool(B, C, 3000);
        _v3Pool(C, D, 3000);
        _v3Pool(D, E, 3000);
        _give(A, 1_000 ether);
        // 3 legs x 4 hops, A -> B -> C -> D -> E each
        VectExecutor.Hop[4] memory hs = [
            _v3(address(A), address(B), 3000),
            _v3(address(B), address(C), 3000),
            _v3(address(C), address(D), 3000),
            _v3(address(D), address(E), 3000)
        ];
        VectExecutor.Route memory r;
        r.legs = new VectExecutor.Leg[](3);
        uint256 third = uint256(40 ether) / 3;
        for (uint256 l; l < 3; ++l) {
            r.legs[l].amountIn = l == 2 ? 40 ether - 2 * third : third;
            r.legs[l].hops = new VectExecutor.Hop[](4);
            for (uint256 h; h < 4; ++h) r.legs[l].hops[h] = hs[h];
        }
        uint256 out = _runErc20(r, address(A), 40 ether, address(E), 1, 0, false);
        emit log_named_uint("GAS max route (3 legs x 4 hops, 12 hops)", lastExecGas);
        assertGt(out, 0);
        assertLt(lastExecGas, 3_500_000, "the largest legal route must stay far below any block gas limit");
        assertEq(A.balanceOf(address(exec)), 0);
        assertEq(E.balanceOf(address(exec)), 0);
    }

    // ------------------------------------------------------------------ contract wallet as the user, ETH recipient re-entering (T-4)

    function test_contract_wallet_user_native_output_and_reentrancy_through_receive() public {
        MockV3Pool p = MockV3Pool(v3f.createPool(WETH, address(A), 3000, false));
        vm.deal(address(this), 3_000 ether);
        IWETH(WETH).deposit{value: 1_000 ether}();
        IERC20Min(WETH).transfer(address(p), 1_000 ether);
        A.mint(address(p), LIQ);

        ContractUser cu = new ContractUser(exec);
        A.mint(address(cu), 100 ether);
        cu.approvePermit2(address(A));
        uint256 amt = 10 ether;
        VectExecutor.Route memory r = _route1(_leg1(amt, _v3(address(A), WETH, 3000)));
        ISignatureTransfer.PermitTransferFrom memory permit = ISignatureTransfer.PermitTransferFrom({
            permitted: ISignatureTransfer.TokenPermissions({token: address(A), amount: amt}),
            nonce: 1,
            deadline: block.timestamp + 600
        });
        cu.setReenter(true);
        uint256 ethBefore = address(cu).balance;
        uint256 out = cu.run(r, address(A), amt, address(0), 1, permit);
        assertEq(address(cu).balance - ethBefore, out, "the contract wallet got the ETH");
        assertEq(cu.reenterError(), VectExecutor.Reentrancy.selector, "re-entering from receive() must fail with Reentrancy");
        assertEq(address(exec).balance, 0);
        assertEq(IERC20Min(WETH).balanceOf(address(exec)), 0);
        // a recipient that rejects ETH makes only its own swap fail
        cu.setReject(true);
        permit.nonce = 2;
        vm.expectRevert(VectExecutor.EthSendFailed.selector);
        cu.run(r, address(A), amt, address(0), 1, permit);
    }

    // ------------------------------------------------------------------ end checks: ordering and under-delivery

    function test_pool_that_returns_a_positive_output_delta_is_refused() public {
        MockV3Pool p = _v3Pool(A, B, 3000);
        _give(A, 1_000 ether);
        p.setMode(MockV3Pool.Mode.LIE_RETURN_OUT);
        Args memory a = _args(_route1(_leg1(10 ether, _v3(address(A), address(B), 3000))), address(A), 10 ether, address(B), 1, 0, false);
        a.err = _sel(VectExecutor.PartialFill.selector);
        _go(a);
    }

    /// @dev ETH forced into the executor by a hook in the middle of a route is residue created by the execute: refused
    /// before the executor hands control to the recipient (end check A runs before the ETH send).
    function test_end_check_runs_before_the_eth_send_and_sees_forced_eth() public {
        MockV3Pool p = MockV3Pool(v3f.createPool(WETH, address(A), 3000, false));
        vm.deal(address(this), 3_000 ether);
        IWETH(WETH).deposit{value: 1_000 ether}();
        IERC20Min(WETH).transfer(address(p), 1_000 ether);
        A.mint(address(p), LIQ);
        ContractUser cu = new ContractUser(exec);
        A.mint(address(cu), 100 ether);
        cu.approvePermit2(address(A));
        EthForcer forcer = new EthForcer();
        // every transfer of A fires the hook, which credits 1 wei of ETH to the executor
        A.setHook(address(forcer), abi.encodeCall(EthForcer.poke, (address(exec))));
        uint256 amt = 10 ether;
        VectExecutor.Route memory r = _route1(_leg1(amt, _v3(address(A), WETH, 3000)));
        ISignatureTransfer.PermitTransferFrom memory permit = ISignatureTransfer.PermitTransferFrom({
            permitted: ISignatureTransfer.TokenPermissions({token: address(A), amount: amt}),
            nonce: 7,
            deadline: block.timestamp + 600
        });
        // the contract user rejects ETH: if the residue were noticed only after the send, the error would be EthSendFailed
        cu.setReject(true);
        vm.expectRevert(VectExecutor.Residue.selector);
        cu.run(r, address(A), amt, address(0), 1, permit);
    }

    function test_forced_eth_in_a_route_with_erc20_output_is_refused() public {
        _v3Pool(A, B, 3000);
        _give(A, 1_000 ether);
        EthForcer forcer = new EthForcer();
        A.setHook(address(forcer), abi.encodeCall(EthForcer.poke, (address(exec))));
        Args memory a = _args(_route1(_leg1(10 ether, _v3(address(A), address(B), 3000))), address(A), 10 ether, address(B), 1, 0, false);
        a.err = _sel(VectExecutor.Residue.selector);
        _go(a);
    }

    /// @dev A token that debits the sender more than it sends leaves the executor BELOW its entry balance after the
    /// payout: the end check is an equality, not an upper bound.
    function test_end_check_is_an_equality_under_delivery_is_refused() public {
        _v3Pool(A, B, 3000);
        _give(A, 1_000 ether);
        B.mint(address(exec), 100 ether); // dust, so the extra debit on the payout succeeds
        B.setExtraBurn(500);
        Args memory a = _args(_route1(_leg1(10 ether, _v3(address(A), address(B), 3000))), address(A), 10 ether, address(B), 1, 0, false);
        a.err = _sel(VectExecutor.Residue.selector);
        _go(a);
    }

    function test_user_who_is_the_fee_recipient_cannot_use_the_fee_to_meet_min_out() public {
        _v3Pool(A, B, 3000);
        _give(A, 1_000 ether);
        exec = _deployFor(address(pm), user); // the fee recipient of this deployment is the caller itself
        // E4-03: the constructor only accepts a contract recipient, so the user (a smart wallet here) has code at deployment;
        // it is cleared afterwards so the same address can sign the Permit2 transfer as an EOA in this test
        vm.etch(user, "");
        VectExecutor.Route memory r = _route1(_leg1(100 ether, _v3(address(A), address(B), 3000)));
        uint256 snap = vm.snapshotState();
        uint256 gross = _runErc20(r, address(A), 100 ether, address(B), 1, 0, false);
        vm.revertToState(snap);
        // fee on output 1 %: the user receives gross - fee first, then the fee (to the same address). Asking for the
        // gross as min-out must fail although the user's final balance would reach it.
        Args memory a = _args(r, address(A), 100 ether, address(B), gross, 100, true);
        a.err = _sel(VectExecutor.MinOut.selector);
        _go(a);
        // and the honest min-out passes
        uint256 out = _runErc20(r, address(A), 100 ether, address(B), gross - gross / 100, 100, true);
        assertEq(out, gross - gross / 100);
        assertEq(B.balanceOf(user), gross); // net + fee, both to the user
    }

    function test_constant_balance_lies_about_the_executor_are_inert() public {
        _v3Pool(A, B, 3000);
        _give(A, 1_000 ether);
        VectExecutor.Route memory r = _route1(_leg1(10 ether, _v3(address(A), address(B), 3000)));
        uint256 snap = vm.snapshotState();
        uint256 clean = _runErc20(r, address(A), 10 ether, address(B), 1, 0, false);
        vm.revertToState(snap);
        A.setLie(address(exec), 123 ether); // balanceOf(executor) reads 123 / 7 too high, always
        B.setLie(address(exec), 7 ether);
        uint256 dirty = _runErc20(r, address(A), 10 ether, address(B), 1, 0, false);
        assertEq(dirty, clean);
    }

    function test_opcode_scan_no_delegatecall_selfdestruct_create() public view {
        bytes memory code = address(exec).code;
        for (uint256 i; i < code.length;) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += 1 + (op - 0x5f);
                continue;
            }
            // CREATE, CALLCODE, DELEGATECALL, CREATE2, SELFDESTRUCT
            assertTrue(op != 0xf0 && op != 0xf2 && op != 0xf4 && op != 0xf5 && op != 0xff, "forbidden opcode");
            unchecked {
                ++i;
            }
        }
    }

    function test_event_content() public {
        _v3Pool(A, B, 3000);
        _give(A, 1_000 ether);
        VectExecutor.Route memory r = _route1(_leg1(990 ether, _v3(address(A), address(B), 3000)));
        uint256 snap = vm.snapshotState();
        uint256 quoted = _runErc20(r, address(A), 1_000 ether, address(B), 1, 100, false);
        vm.revertToState(snap);
        // 1000 in, 1 % fee = 10 (paid in A), leg 990
        vm.expectEmit(true, false, false, true, address(exec));
        emit VectExecutor.Executed(user, address(A), 1_000 ether, address(B), quoted, 10 ether, 100, false, FEE_RECIPIENT, keccak256(abi.encode(r)));
        _runErc20(r, address(A), 1_000 ether, address(B), 1, 100, false);
        assertEq(A.balanceOf(FEE_RECIPIENT), 10 ether);
    }
}

/// @dev A "user" contract that executes twice in one transaction with native input.
contract MultiCaller {
    receive() external payable {}

    function twice(VectExecutor e, VectExecutor.Route memory r, address tokenOut) external {
        ISignatureTransfer.PermitTransferFrom memory permit;
        e.execute{value: 1 ether}(r, address(0), 1 ether, tokenOut, 1, 0, false, permit, "", block.timestamp + 100);
        e.execute{value: 1 ether}(r, address(0), 1 ether, tokenOut, 1, 0, false, permit, "", block.timestamp + 100);
    }

    function revertingThenOk(VectExecutor e, VectExecutor.Route memory r, address tokenOut) external {
        ISignatureTransfer.PermitTransferFrom memory permit;
        try e.execute{value: 1 ether}(r, address(0), 1 ether, tokenOut, type(uint256).max, 0, false, permit, "", block.timestamp + 100) {
            revert("should have failed");
        } catch {}
        e.execute{value: 1 ether}(r, address(0), 1 ether, tokenOut, 1, 0, false, permit, "", block.timestamp + 100);
    }
}

/// @dev A smart-contract wallet (EIP-1271 always valid, test only) that tries to re-enter from receive().
contract ContractUser {
    VectExecutor internal immutable e;
    bool internal reenter;
    bool internal reject;
    bytes4 public reenterError;

    constructor(VectExecutor e_) {
        e = e_;
    }

    function approvePermit2(address token) external {
        MockERC20(token).approve(0x000000000022D473030F116dDEE9F6B43aC78BA3, type(uint256).max);
    }

    function setReenter(bool v) external {
        reenter = v;
    }

    function setReject(bool v) external {
        reject = v;
    }

    function isValidSignature(bytes32, bytes calldata) external pure returns (bytes4) {
        return 0x1626ba7e;
    }

    function run(
        VectExecutor.Route memory r,
        address tokenIn,
        uint256 amountIn,
        address tokenOut,
        uint256 minOut,
        ISignatureTransfer.PermitTransferFrom memory permit
    ) external returns (uint256) {
        return e.execute(r, tokenIn, amountIn, tokenOut, minOut, 0, false, permit, hex"01", block.timestamp + 600);
    }

    receive() external payable {
        if (reject) revert("no eth");
        if (reenter) {
            VectExecutor.Route memory r;
            ISignatureTransfer.PermitTransferFrom memory permit;
            try e.execute{value: 1}(r, address(0), 1, address(1), 1, 0, false, permit, "", block.timestamp + 1) {}
            catch (bytes memory ret) {
                reenterError = bytes4(ret);
            }
        }
    }
}
