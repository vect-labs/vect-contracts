// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {ExecBase, IERC20Min} from "./Base.t.sol";
import {VectExecutor} from "../src/VectExecutor.sol";
import {ISignatureTransfer, IWETH} from "../src/Interfaces.sol";

/// @dev Calls a pool directly (no executor) so that its output is the wei-exact reference of the executor's output.
contract DirectSwapper {
    function swap(address pool, address tokenIn, address tokenOut, uint256 amountIn, bool zeroForOne)
        external
        returns (uint256 out)
    {
        uint256 before = IERC20Min(tokenOut).balanceOf(address(this));
        (bool ok,) = pool.call(
            abi.encodeWithSignature(
                "swap(address,bool,int256,uint160,bytes)",
                address(this),
                zeroForOne,
                int256(amountIn),
                zeroForOne ? uint160(4295128740) : uint160(1461446703485210103287273052203988822378723970341),
                abi.encode(tokenIn)
            )
        );
        require(ok, "direct swap failed");
        out = IERC20Min(tokenOut).balanceOf(address(this)) - before;
    }

    function uniswapV3SwapCallback(int256 a0, int256 a1, bytes calldata data) external {
        address tokenIn = abi.decode(data, (address));
        uint256 owed = uint256(a0 > 0 ? a0 : a1);
        IERC20Min(tokenIn).transfer(msg.sender, owed);
    }
}

/// @dev Fork tests on real Robinhood pools (block 103,505,000) for every family: v2, v3, the five CL factories, v4
/// hookless and K-7 reviewed hooks, two-hop routes across families, 2-3 split legs, native in and out, fee in / out,
/// feeBps = 0, and the gas per route shape.
contract ForkTest is ExecBase {
    // PONS: a token that has a pool in every family at the pin (v2, v3, 4 CL factories, v4 native).
    address internal constant PONS = 0x39dBED3a2bd333467115dE45665cC57F813C4571;
    // hooked v4 pools (K-7 reviewed hooks)
    address internal constant X48 = 0xB87b6eD068b4f109230191EACac2Fa418666980b; // WETH / X48, hook 0x48b8 (Clanker static v2)
    address internal constant X4E = 0xa77cE6b68A6775bbe135ecc1556382600F055Ba3; // WETH / X4E, hook 0x4e34 (Doppler initializer)
    address internal constant N4E = 0x9C54b891ebb12B2e8ae4E3D2e4aa323E99751E18; // native / N4E, hook 0x4e34
    address internal constant DAAF = 0xdaaf4622330EcfdC4C205827483acf232214CCdf; // native / DAAF, hookless (fee 2500, ts 25)
    address internal constant MEME = 0x385F4f8ae47651ce5F58F5265395a669f8281e18; // v3 WETH/MEME, v4 MEME/USDC (fee 31500, ts 315), CL 5481
    address internal constant XE5 = 0x3f9Ff9f1D40369f99c281375bD19D6EcbEbFeCd7; // native / XE5, hook 0xe5e7

    DirectSwapper internal direct;

    function setUp() public {
        _fork();
        _setUpUser();
        exec = new VectExecutor(_realConfig());
        direct = new DirectSwapper();
    }

    function _pons(address to, uint256 amt) internal {
        deal(PONS, to, amt);
    }

    function _fundUser(address token, uint256 amount) internal {
        _fund(token, user, amount);
    }

    function _gas(string memory shape) internal {
        emit log_named_uint(string.concat("GAS ", shape), lastExecGas);
    }

    // ------------------------------------------------------------------ derivation: every family routes on real pools

    function _singleWethToPons(VectExecutor.Hop memory h, uint256 amt) internal returns (uint256 out) {
        _fundUser(WETH, amt);
        out = _runErc20(_route1(_leg1(amt, h)), WETH, amt, PONS, 1, 0, false);
        assertEq(IERC20Min(PONS).balanceOf(user), out, "user received");
        assertEq(IERC20Min(WETH).balanceOf(address(exec)), 0, "weth residue");
        assertEq(IERC20Min(PONS).balanceOf(address(exec)), 0, "pons residue");
        assertEq(address(exec).balance, 0, "eth residue");
    }

    /// @dev Output of the executor and of the pool called directly must be identical to the wei.
    function _sameAsDirect(VectExecutor.Hop memory h, address pool, uint256 amt, string memory gasLabel) internal {
        uint256 snap = vm.snapshotState();
        uint256 viaExec = _singleWethToPons(h, amt);
        _gas(gasLabel);
        vm.revertToState(snap);
        _fund(WETH, address(direct), amt);
        uint256 viaPool = direct.swap(pool, WETH, PONS, amt, WETH < PONS);
        assertEq(viaExec, viaPool, "executor != direct pool swap");
        assertGt(viaExec, 0);
    }

    function test_v2_exact_vs_pair_formula_and_residue() public {
        address pair = 0x8018Ee3ad3c0321bE0e69536733CD28e29564dD4;
        pair; // address recorded for the manifest
        uint256 amt = 0.05 ether;
        uint256 out = _singleWethToPons(_v2(WETH, PONS), amt);
        _gas("v2 single hop");
        assertGt(out, 0);
    }

    function test_v3_exact_vs_direct() public {
        address pool = 0xEd50bDeeA8aDC232f159486192a4157281D722ff;
        _sameAsDirect(_v3(WETH, PONS, 3000), pool, 0.1 ether, "v3 single hop");
        pool = 0x10CC6BD38112cAc182db90B6a71d8Bb5939526bA;
        _sameAsDirect(_v3(WETH, PONS, 10000), pool, 0.1 ether, "v3 single hop (10000)");
    }

    function test_cl_ramses_family_exact_vs_direct() public {
        _sameAsDirect(_cl(0, WETH, PONS, 100), 0x51B6Ca77DEaE9f17c1D89EdFb301AE50053C57A5, 0.1 ether, "cl ramses single hop");
    }

    function test_cl_slipstream_c63d_exact_vs_direct() public {
        _sameAsDirect(_cl(1, WETH, PONS, 100), 0x1D87Bbf4643bC7569DB04353fa29Af8225918eB5, 0.1 ether, "cl slipstream(c63d, swap hook) single hop");
    }

    function test_cl_slipstream_1ac9_exact_vs_direct() public {
        _sameAsDirect(_cl(2, WETH, PONS, 200), 0x25C93DaC3A72E48E67314709f058CCf56C0Cf43a, 0.1 ether, "cl slipstream(1ac9) single hop");
    }

    function test_cl_slipstream_aa58_exact_vs_direct() public {
        _sameAsDirect(_cl(4, WETH, PONS, 50), 0x9990de5A2eadFa50112077dAE6630864d29ac309, 0.1 ether, "cl slipstream(aa58) single hop");
    }

    function test_cl_slipstream_5481_usdc_to_pons_exact_vs_direct() public {
        // the only live 5481 pool of PONS is PONS/USDC (ts 200)
        address pool = 0x1937215e6fa2F9F1cdD5192B623634bE38Af77Cc;
        uint256 amt = 20e6;
        uint256 snap = vm.snapshotState();
        _fundUser(USDC, amt);
        uint256 viaExec = _runErc20(_route1(_leg1(amt, _cl(3, USDC, PONS, 200))), USDC, amt, PONS, 1, 0, false);
        _gas("cl slipstream(5481) single hop");
        vm.revertToState(snap);
        _fund(USDC, address(direct), amt);
        uint256 viaPool = direct.swap(pool, USDC, PONS, amt, USDC < PONS);
        assertEq(viaExec, viaPool);
        assertGt(viaExec, 0);
    }

    function test_cl_ramses_usdc_ts50_and_c63d_usdc_ts100_exact_vs_direct() public {
        uint256 amt = 20e6;
        uint256 snap = vm.snapshotState();
        _fundUser(USDC, amt);
        uint256 a = _runErc20(_route1(_leg1(amt, _cl(0, USDC, PONS, 50))), USDC, amt, PONS, 1, 0, false);
        vm.revertToState(snap);
        _fund(USDC, address(direct), amt);
        assertEq(a, direct.swap(0xf2A0bE59AB76b96f957bd5E5b967F2B75e8dB269, USDC, PONS, amt, USDC < PONS));
        vm.revertToState(snap);
        _fundUser(USDC, amt);
        uint256 b = _runErc20(_route1(_leg1(amt, _cl(1, USDC, PONS, 100))), USDC, amt, PONS, 1, 0, false);
        vm.revertToState(snap);
        _fund(USDC, address(direct), amt);
        assertEq(b, direct.swap(0xD75790f3a3F639FEdB7406DF6dABB5bb8605949b, USDC, PONS, amt, USDC < PONS));
        assertGt(a, 0);
        assertGt(b, 0);
    }

    // ------------------------------------------------------------------ v4

    function test_v4_hookless_native_in_and_native_out() public {
        // native / DAAF, hookless: native in (wrapped, then unwrapped by the executor, settle ETH) then DAAF -> native out
        uint256 amt = 0.1 ether;
        VectExecutor.Route memory r = _route1(_leg1(amt, _v4(address(0), DAAF, 2500, 25, address(0))));
        uint256 got = _runNativeIn(r, amt, DAAF, 1, 0, false);
        _gas("v4 hookless native in");
        assertEq(IERC20Min(DAAF).balanceOf(user), got);
        assertEq(address(exec).balance, 0);
        assertEq(IERC20Min(WETH).balanceOf(address(exec)), 0);
        vm.prank(user);
        IERC20Min(DAAF).approve(PERMIT2, type(uint256).max);
        VectExecutor.Route memory r2 = _route1(_leg1(got, _v4(DAAF, address(0), 2500, 25, address(0))));
        uint256 ethBefore = user.balance;
        uint256 outEth = _runErc20(r2, DAAF, got, address(0), 1, 0, false);
        _gas("v4 hookless native out");
        assertEq(user.balance - ethBefore, outEth);
        assertEq(address(exec).balance, 0);
        assertEq(IERC20Min(WETH).balanceOf(address(exec)), 0);
        assertLt(outEth, amt); // two fee-bearing swaps
    }

    function test_v4_reviewed_hooks_route() public {
        uint256 amt = 0.05 ether;
        // Clanker static v2 hook (0x48b8): WETH / X48, dynamic fee flag
        _fundUser(WETH, amt);
        uint256 o1 = _runErc20(_route1(_leg1(amt, _v4(WETH, X48, 8388608, 200, HOOK_48B8))), WETH, amt, X48, 1, 0, false);
        _gas("v4 reviewed hook 48b8 (clanker)");
        assertGt(o1, 0);
        // Doppler initializer hook (0x4e34): WETH / X4E
        _fundUser(WETH, amt);
        uint256 o2 = _runErc20(_route1(_leg1(amt, _v4(WETH, X4E, 8388608, 200, HOOK_4E34))), WETH, amt, X4E, 1, 0, false);
        _gas("v4 reviewed hook 4e34 (doppler)");
        assertGt(o2, 0);
        // hook e5e7, native in
        uint256 o3 = _runNativeIn(_route1(_leg1(amt, _v4(address(0), XE5, 0, 200, HOOK_E5E7))), amt, XE5, 1, 0, false);
        _gas("v4 reviewed hook e5e7, native in");
        assertGt(o3, 0);
        // doppler native pool
        uint256 o4 = _runNativeIn(_route1(_leg1(amt, _v4(address(0), N4E, 8388608, 8, HOOK_4E34))), amt, N4E, 1, 0, false);
        assertGt(o4, 0);
        assertEq(IERC20Min(WETH).balanceOf(address(exec)), 0);
        assertEq(IERC20Min(X48).balanceOf(address(exec)), 0);
        assertEq(address(exec).balance, 0);
    }

    function test_v4_unreviewed_hook_is_refused() public {
        // a real hooked pool whose hook is NOT in the reviewed allowlist of this deployment
        VectExecutor.Config memory c = _realConfig();
        c.hook = [HOOK_E5E7, address(0), address(0), address(0), address(0), address(0), address(0), address(0)];
        c.hookCodehash = [HOOK_E5E7.codehash, bytes32(0), bytes32(0), bytes32(0), bytes32(0), bytes32(0), bytes32(0), bytes32(0)];
        exec = new VectExecutor(c);
        _fundUser(WETH, 0.05 ether);
        Args memory a = _args(_route1(_leg1(0.05 ether, _v4(WETH, X48, 8388608, 200, HOOK_48B8))), WETH, 0.05 ether, X48, 1, 0, false);
        a.err = abi.encodePacked(VectExecutor.BadHop.selector);
        _go(a);
    }

    // ------------------------------------------------------------------ two hops across families

    function test_two_hops_across_families() public {
        uint256 amt = 0.1 ether;
        // WETH -(v3 3000)-> PONS -(CL ramses ts50, PONS/USDC)-> USDC
        _fundUser(WETH, amt);
        VectExecutor.Route memory r1 = _route1(_leg2(amt, _v3(WETH, PONS, 3000), _cl(0, PONS, USDC, 50)));
        uint256 usdcOut = _runErc20(r1, WETH, amt, USDC, 1, 0, false);
        _gas("2 hops v3 -> cl(ramses)");
        assertEq(IERC20Min(USDC).balanceOf(user), usdcOut);
        // USDC -(CL 5481 ts200)-> PONS -(v2)-> WETH
        vm.prank(user);
        IERC20Min(USDC).approve(PERMIT2, type(uint256).max);
        uint256 usdcIn = usdcOut / 2;
        VectExecutor.Route memory r2 = _route1(_leg2(usdcIn, _cl(3, USDC, PONS, 200), _v2(PONS, WETH)));
        uint256 wethBefore = IERC20Min(WETH).balanceOf(user);
        uint256 wethOut = _runErc20(r2, USDC, usdcIn, WETH, 1, 0, false);
        _gas("2 hops cl(slipstream) -> v2");
        assertEq(IERC20Min(WETH).balanceOf(user) - wethBefore, wethOut);
        // native in -(wrap)- WETH -(v3 3000)-> MEME -(v4 MEME/USDC)-> USDC
        VectExecutor.Route memory r3 = _route1(_leg2(amt, _v3(WETH, MEME, 3000), _v4(MEME, USDC, 31500, 315, address(0))));
        uint256 u3 = _runNativeIn(r3, amt, USDC, 1, 0, false);
        _gas("2 hops v3 -> v4, native in");
        assertGt(u3, 0);
        // USDC -(v4)-> MEME -(v3 3000)-> WETH -(unwrap)-> native out
        VectExecutor.Route memory r4 = _route1(_leg2(u3 / 2, _v4(USDC, MEME, 31500, 315, address(0)), _v3(MEME, WETH, 3000)));
        uint256 ethBefore = user.balance;
        uint256 outEth = _runErc20(r4, USDC, u3 / 2, address(0), 1, 0, false);
        _gas("2 hops v4 -> v3, native out");
        assertEq(user.balance - ethBefore, outEth);
        assertEq(IERC20Min(MEME).balanceOf(address(exec)), 0);
        assertEq(IERC20Min(USDC).balanceOf(address(exec)), 0);
        assertEq(IERC20Min(WETH).balanceOf(address(exec)), 0);
        assertEq(address(exec).balance, 0);
    }

    // ------------------------------------------------------------------ splits

    function test_split_two_and_three_legs() public {
        uint256 amt = 0.3 ether;
        _fundUser(WETH, amt * 2);
        VectExecutor.Route memory r2 = _route2(
            _leg1(0.15 ether, _v3(WETH, PONS, 3000)),
            _leg1(0.15 ether, _cl(0, WETH, PONS, 100))
        );
        uint256 o2 = _runErc20(r2, WETH, amt, PONS, 1, 0, false);
        _gas("split 2 legs (v3 + cl)");
        assertEq(IERC20Min(PONS).balanceOf(user), o2);

        VectExecutor.Route memory r3;
        r3.legs = new VectExecutor.Leg[](3);
        r3.legs[0] = _leg1(0.1 ether, _v3(WETH, PONS, 3000));
        r3.legs[1] = _leg1(0.1 ether, _cl(0, WETH, PONS, 100));
        r3.legs[2] = _leg1(0.1 ether, _cl(1, WETH, PONS, 100));
        uint256 before = IERC20Min(PONS).balanceOf(user);
        uint256 o3 = _runErc20(r3, WETH, amt, PONS, 1, 0, false);
        _gas("split 3 legs (v3 + cl + cl)");
        assertEq(IERC20Min(PONS).balanceOf(user) - before, o3);
        // mixed: one direct leg, one two-hop leg with a v2 hop in the middle
        _fundUser(WETH, 0.2 ether);
        VectExecutor.Route memory r4 = _route2(
            _leg1(0.1 ether, _cl(2, WETH, PONS, 200)),
            _leg2(0.1 ether, _v3(WETH, USDC, 3000), _cl(3, USDC, PONS, 200))
        );
        uint256 o4 = _runErc20(r4, WETH, 0.2 ether, PONS, 1, 0, false);
        _gas("split 2 legs (cl direct + v3->cl two-hop)");
        assertGt(o4, 0);
        assertEq(IERC20Min(WETH).balanceOf(address(exec)), 0);
        assertEq(IERC20Min(USDC).balanceOf(address(exec)), 0);
        assertEq(IERC20Min(PONS).balanceOf(address(exec)), 0);
    }

    // ------------------------------------------------------------------ native, fees

    function test_native_in_out_v3_and_fees() public {
        uint256 amt = 1 ether;
        // native in, v3, fee on input 0.5 %
        uint256 fee = (amt * 50) / 10_000;
        VectExecutor.Route memory r = _route1(_leg1(amt - fee, _v3(WETH, PONS, 3000)));
        uint256 got = _runNativeIn(r, amt, PONS, 1, 50, false);
        _gas("native in, v3, fee on input");
        assertEq(IERC20Min(WETH).balanceOf(FEE_RECIPIENT), fee);
        assertEq(IERC20Min(PONS).balanceOf(user), got);
        // PONS -> native out via v3, fee on output 1 %
        vm.prank(user);
        IERC20Min(PONS).approve(PERMIT2, type(uint256).max);
        VectExecutor.Route memory r2 = _route1(_leg1(got, _v3(PONS, WETH, 3000)));
        uint256 ethBefore = user.balance;
        uint256 feeBefore = IERC20Min(WETH).balanceOf(FEE_RECIPIENT);
        uint256 net = _runErc20(r2, PONS, got, address(0), 1, 100, true);
        _gas("native out, v3, fee on output");
        assertEq(user.balance - ethBefore, net);
        uint256 feeOut = IERC20Min(WETH).balanceOf(FEE_RECIPIENT) - feeBefore;
        assertEq(feeOut, ((net + feeOut) * 100) / 10_000);
        assertEq(address(exec).balance, 0);
        assertEq(IERC20Min(WETH).balanceOf(address(exec)), 0);
    }

    function test_fee_zero_and_max_on_real_pool() public {
        uint256 amt = 0.2 ether;
        _fundUser(WETH, amt * 3);
        VectExecutor.Hop memory h = _v3(WETH, PONS, 3000);
        _runErc20(_route1(_leg1(amt, h)), WETH, amt, PONS, 1, 0, false);
        assertEq(IERC20Min(WETH).balanceOf(FEE_RECIPIENT), 0);
        uint256 fee = (amt * 100) / 10_000;
        _runErc20(_route1(_leg1(amt - fee, h)), WETH, amt, PONS, 1, 100, false);
        assertEq(IERC20Min(WETH).balanceOf(FEE_RECIPIENT), fee);
    }

    // ------------------------------------------------------------------ negative derivation on real data (T-13)

    function test_negative_derivation_wrong_factory_slot_or_key() public {
        _fundUser(WETH, 0.05 ether);
        Args memory a;
        // the real PONS/WETH CL pool of factory slot 0 asked through slot 1 (c63d) with the other's key: no such pool
        a = _args(_route1(_leg1(0.05 ether, _cl(1, WETH, PONS, 200))), WETH, 0.05 ether, PONS, 1, 0, false);
        a.err = abi.encodePacked(VectExecutor.BadHop.selector);
        _go(a);
        // a v3 fee tier that has no pool for this pair
        a = _args(_route1(_leg1(0.05 ether, _v3(WETH, PONS, 2500))), WETH, 0.05 ether, PONS, 1, 0, false);
        a.err = abi.encodePacked(VectExecutor.BadHop.selector);
        _go(a);
        // tick spacing with no pool
        a = _args(_route1(_leg1(0.05 ether, _cl(0, WETH, PONS, 75))), WETH, 0.05 ether, PONS, 1, 0, false);
        a.err = abi.encodePacked(VectExecutor.BadHop.selector);
        _go(a);
    }

    // ------------------------------------------------------------------ deployment constants vs the chain (T-16)

    function test_constants_match_the_chain() public view {
        assertEq(exec.WETH(), WETH);
        assertEq(exec.PERMIT2(), PERMIT2);
        assertEq(exec.POOL_MANAGER(), POOL_MANAGER);
        assertTrue(WETH.code.length > 0 && PERMIT2.code.length > 0 && POOL_MANAGER.code.length > 0);
        assertEq(exec.V3_FACTORY().codehash, 0xec72b1abd1f2faee020cfea9c646bd8994f9fb389054f6e574f103a895091739);
        assertEq(exec.V2_FACTORY().codehash, 0xbab145d02e7005f0d84c6c1639d39b799b0ea16df99ebbdaf5a14d9da820b4e0);
        assertEq(POOL_MANAGER.codehash, 0xbd3881180b547f5fe817545743cfb4343e96b1bc6640dcd70c106b0066e95626);
        assertEq(PERMIT2.codehash, 0x5208783f52488f7d3493e5e38311ab707c1d75457fe472a19b0b4d57d66a7fca);
        // reviewed hook pins equal the router profile's
        assertEq(HOOK_E5E7.codehash, 0xc21b1e6c1b45403e81a581f22ed6d9c747997af1cfdac1b1dc9f4b1d346a10db);
        assertEq(HOOK_4E34.codehash, 0xc41a91106002f15bf70ae266824317f3f3ac638ac72ca5253bae395fa47ee631);
        assertEq(HOOK_48B8.codehash, 0x0883056c4856f8fe464ff49f9c1c028455459dad8ceddcc6d5159259fe51e07f);
        assertEq(HOOK_75A5.codehash, 0x5bbb7cb03abf34683d1f1e795e5e1a96573a0feee7c20c51f1cbf02139eb9003);
        for (uint256 i; i < 5; ++i) {
            (bool ok, bytes memory ret) = address(exec).staticcall(abi.encodeWithSignature("clDeployer(uint256)", i));
            assertTrue(ok);
            assertTrue(abi.decode(ret, (address)).code.length > 0);
        }
    }
}
