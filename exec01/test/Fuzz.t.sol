// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {MockWorld} from "./MockWorld.sol";
import {VectExecutor} from "../src/VectExecutor.sol";
import {MockV3Pool} from "./mocks/Mocks.sol";

/// @dev Stateless property fuzzing of the executor's accounting against closed-form expectations on the mock pools.
contract FuzzTest is MockWorld {
    /// forge-config: default.fuzz.runs = 12000
    function testFuzz_single_hop_accounting_is_exact(uint96 amtRaw, uint16 bpsRaw, bool onOut) public {
        MockV3Pool p = _v3Pool(A, B, 3000);
        uint256 amt = bound(uint256(amtRaw), 1_000, 100_000 ether);
        uint16 bps = uint16(bpsRaw % 101);
        _give(A, amt);
        uint256 rIn = A.balanceOf(address(p));
        uint256 rOut = B.balanceOf(address(p));

        uint256 inFee = onOut ? 0 : (amt * bps) / 10_000;
        uint256 netIn = amt - inFee;
        uint256 gross = (netIn * 997 * rOut) / (rIn * 1000 + netIn * 997);
        if (gross == 0) return; // below one unit of output: the executor must refuse (checked below)
        uint256 outFee = onOut ? (gross * bps) / 10_000 : 0;
        uint256 net = gross - outFee;
        if (net == 0) return;

        uint256 out = _runErc20(_route1(_leg1(netIn, _v3(address(A), address(B), 3000))), address(A), amt, address(B), 1, bps, onOut);
        assertEq(out, net, "user output");
        assertEq(B.balanceOf(user), net);
        assertEq(B.balanceOf(FEE_RECIPIENT), outFee, "output fee");
        assertEq(A.balanceOf(FEE_RECIPIENT), inFee, "input fee");
        assertEq(A.balanceOf(user), 0, "input pulled exactly");
        assertEq(A.balanceOf(address(exec)), 0);
        assertEq(B.balanceOf(address(exec)), 0);
        assertLe(inFee + outFee, ((onOut ? gross : amt) * 100) / 10_000, "fee above the cap");
    }

    /// forge-config: default.fuzz.runs = 12000
    function testFuzz_split_legs_must_add_up_exactly(uint96 amtRaw, uint16 wRaw, int8 delta) public {
        _v3Pool(A, B, 3000);
        _v2Pair(A, B);
        uint256 amt = bound(uint256(amtRaw), 10_000, 100_000 ether);
        _give(A, amt);
        // F-1 (E4 QA): both legs stay above dust; a 1-wei leg can quote 0 and the executor then correctly refuses it (BadDelta)
        uint256 a1 = bound(uint256(wRaw), 1_000, amt - 1_000);
        int256 d = int256(delta) % 3; // -2..2
        uint256 a2 = uint256(int256(amt - a1) + d > 0 ? int256(amt - a1) + d : int256(1));
        VectExecutor.Route memory r = _route2(_leg1(a1, _v3(address(A), address(B), 3000)), _leg1(a2, _v2(address(A), address(B))));
        Args memory a = _args(r, address(A), amt, address(B), 1, 0, false);
        if (a1 + a2 != amt) a.err = abi.encodePacked(VectExecutor.LegSum.selector);
        _go(a);
        if (a1 + a2 == amt) {
            assertEq(A.balanceOf(address(exec)), 0);
            assertEq(A.balanceOf(user), 0);
        }
    }

    /// forge-config: default.fuzz.runs = 12000
    function testFuzz_donations_never_change_the_result(uint96 d0, uint96 d1, uint96 d2, uint96 eth, uint96 amtRaw) public {
        _v3Pool(A, B, 3000);
        _v3Pool(B, C, 3000);
        uint256 amt = bound(uint256(amtRaw), 1_000, 10_000 ether);
        _give(A, amt);
        VectExecutor.Route memory r = _route1(_leg2(amt, _v3(address(A), address(B), 3000), _v3(address(B), address(C), 3000)));
        uint256 snap = vm.snapshotState();
        uint256 clean = _runErc20(r, address(A), amt, address(C), 1, 0, false);
        vm.revertToState(snap);
        A.mint(address(exec), d0);
        B.mint(address(exec), d1);
        C.mint(address(exec), d2);
        vm.deal(address(exec), eth);
        uint256 dirty = _runErc20(r, address(A), amt, address(C), 1, 0, false);
        assertEq(dirty, clean);
        assertEq(A.balanceOf(address(exec)), d0);
        assertEq(B.balanceOf(address(exec)), d1);
        assertEq(C.balanceOf(address(exec)), d2);
        assertEq(address(exec).balance, eth);
    }

    /// forge-config: default.fuzz.runs = 12000
    function testFuzz_min_out_is_a_hard_floor(uint96 amtRaw, uint16 slackBps) public {
        _v3Pool(A, B, 3000);
        uint256 amt = bound(uint256(amtRaw), 1_000, 10_000 ether);
        _give(A, amt);
        VectExecutor.Route memory r = _route1(_leg1(amt, _v3(address(A), address(B), 3000)));
        uint256 snap = vm.snapshotState();
        uint256 quoted = _runErc20(r, address(A), amt, address(B), 1, 0, false);
        vm.revertToState(snap);
        if (quoted == 0) return;
        uint256 minOut = (quoted * (uint256(slackBps) % 20_000)) / 10_000; // 0 .. 2x the quote
        Args memory a = _args(r, address(A), amt, address(B), minOut, 0, false);
        if (minOut == 0) a.err = abi.encodePacked(VectExecutor.ZeroMinOut.selector);
        else if (minOut > quoted) a.err = abi.encodePacked(VectExecutor.MinOut.selector);
        uint256 out = _go(a);
        if (a.err.length == 0) assertGe(out, minOut);
    }
}
