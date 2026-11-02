// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {ExecBase, IERC20Min} from "./Base.t.sol";
import {VectExecutor} from "../src/VectExecutor.sol";
import {PoolKey} from "../src/Interfaces.sol";

struct ExactInputSingleParams {
    PoolKey poolKey;
    bool zeroForOne;
    uint128 amountIn;
    uint128 amountOutMinimum;
    uint256 maxHopSlippage;
    bytes hookData;
}

interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

interface IAllowanceTransfer {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

/// @dev differential tests against the Universal Router on canonical routes. Same input, same block
/// (snapshot / revert), same output, to the wei. The executor runs with feeBps = 0; the router with min-out 0.
contract DifferentialTest is ExecBase {
    address internal constant PONS = 0x39dBED3a2bd333467115dE45665cC57F813C4571;
    address internal constant MEME = 0x385F4f8ae47651ce5F58F5265395a669f8281e18;

    uint8 internal constant CMD_V3_SWAP_EXACT_IN = 0x00;
    uint8 internal constant CMD_V2_SWAP_EXACT_IN = 0x08;
    uint8 internal constant CMD_V4_SWAP = 0x10;
    uint8 internal constant V4_SWAP_EXACT_IN_SINGLE = 0x06;
    uint8 internal constant V4_SETTLE = 0x0b;
    uint8 internal constant V4_TAKE = 0x0e;
    address internal constant ADDRESS_THIS = address(2); // UR constant: the router itself
    uint256 internal constant CONTRACT_BALANCE = 0x8000000000000000000000000000000000000000000000000000000000000000;

    function setUp() public {
        _fork();
        _setUpUser();
        exec = new VectExecutor(_realConfig());
    }

    // ---------------------------------------------------------------- helpers

    function _ur(bytes memory commands, bytes[] memory inputs) internal {
        IUniversalRouter(UNIVERSAL_ROUTER).execute(commands, inputs, block.timestamp + 600);
    }

    function _v3In(address recipient, uint256 amt, address a, uint24 fee, address b, bool payerIsUser)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(recipient, amt, uint256(0), abi.encodePacked(a, fee, b), payerIsUser, new uint256[](0));
    }

    function _v2In(address recipient, uint256 amt, address a, address b, bool payerIsUser)
        internal
        pure
        returns (bytes memory)
    {
        address[] memory path = new address[](2);
        path[0] = a;
        path[1] = b;
        return abi.encode(recipient, amt, uint256(0), path, payerIsUser, new uint256[](0));
    }

    /// @dev runs `viaExec` (a closure over the executor), reverts, then `viaUr`, and returns both outputs
    function _funded(address token, address who, uint256 amt) internal {
        _fund(token, who, amt);
    }

    // ---------------------------------------------------------------- single hops

    function test_diff_v3_single_hop_exact() public {
        uint256 amt = 0.1 ether;
        uint256 snap = vm.snapshotState();
        _fundUser(WETH, amt);
        uint256 viaExec = _runErc20(_route1(_leg1(amt, _v3(WETH, PONS, 3000))), WETH, amt, PONS, 1, 0, false);
        vm.revertToState(snap);
        _funded(WETH, UNIVERSAL_ROUTER, amt);
        uint256 before = IERC20Min(PONS).balanceOf(address(this));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = _v3In(address(this), amt, WETH, 3000, PONS, false);
        _ur(abi.encodePacked(CMD_V3_SWAP_EXACT_IN), inputs);
        uint256 viaUr = IERC20Min(PONS).balanceOf(address(this)) - before;
        emit log_named_uint("v3 single: executor", viaExec);
        emit log_named_uint("v3 single: universal router", viaUr);
        assertEq(viaExec, viaUr, "v3: executor != universal router");
        assertGt(viaExec, 0);
    }

    function test_diff_v2_single_hop_exact() public {
        uint256 amt = 0.05 ether;
        uint256 snap = vm.snapshotState();
        _fundUser(WETH, amt);
        uint256 viaExec = _runErc20(_route1(_leg1(amt, _v2(WETH, PONS))), WETH, amt, PONS, 1, 0, false);
        vm.revertToState(snap);
        _funded(WETH, UNIVERSAL_ROUTER, amt);
        uint256 before = IERC20Min(PONS).balanceOf(address(this));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = _v2In(address(this), amt, WETH, PONS, false);
        _ur(abi.encodePacked(CMD_V2_SWAP_EXACT_IN), inputs);
        uint256 viaUr = IERC20Min(PONS).balanceOf(address(this)) - before;
        emit log_named_uint("v2 single: executor", viaExec);
        emit log_named_uint("v2 single: universal router", viaUr);
        assertEq(viaExec, viaUr, "v2: executor != universal router");
        assertGt(viaExec, 0);
    }

    function test_diff_v4_single_hop_exact() public {
        uint256 amt = 20e6;
        // USDC -> MEME through the hookless v4 pool (fee 31500, ts 315)
        uint256 snap = vm.snapshotState();
        _fundUser(USDC, amt);
        uint256 viaExec = _runErc20(_route1(_leg1(amt, _v4(USDC, MEME, 31500, 315, address(0)))), USDC, amt, MEME, 1, 0, false);
        vm.revertToState(snap);

        _funded(USDC, UNIVERSAL_ROUTER, amt); // the router pays from its own balance (SETTLE, payerIsUser = false)
        PoolKey memory key;
        (key.currency0, key.currency1) = USDC < MEME ? (USDC, MEME) : (MEME, USDC);
        key.fee = 31500;
        key.tickSpacing = 315;
        bool z = USDC < MEME;
        bytes memory actions = abi.encodePacked(V4_SETTLE, V4_SWAP_EXACT_IN_SINGLE, V4_TAKE);
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(USDC, amt, false);
        params[1] = abi.encode(ExactInputSingleParams(key, z, 0, 0, 0, bytes("")));
        params[2] = abi.encode(MEME, address(this), uint256(0));
        // exact-in amount 0 = OPEN_DELTA: swap the whole settled amount
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);
        uint256 before = IERC20Min(MEME).balanceOf(address(this));
        _ur(abi.encodePacked(CMD_V4_SWAP), inputs);
        uint256 viaUr = IERC20Min(MEME).balanceOf(address(this)) - before;
        emit log_named_uint("v4 single: executor", viaExec);
        emit log_named_uint("v4 single: universal router", viaUr);
        assertEq(viaExec, viaUr, "v4: executor != universal router");
        assertGt(viaExec, 0);
    }

    // ---------------------------------------------------------------- multi-hop and split

    function test_diff_v3_two_hops_exact() public {
        uint256 amt = 0.01 ether;
        // WETH -(v3 3000)-> PONS -(v3 USDC 3000)-> USDC, canonical v3 multi-hop path
        uint256 snap = vm.snapshotState();
        _fundUser(WETH, amt);
        uint256 viaExec = _runErc20(_route1(_leg2(amt, _v3(WETH, PONS, 3000), _v3(PONS, USDC, 3000))), WETH, amt, USDC, 1, 0, false);
        vm.revertToState(snap);
        _funded(WETH, UNIVERSAL_ROUTER, amt);
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(address(this), amt, uint256(0), abi.encodePacked(WETH, uint24(3000), PONS, uint24(3000), USDC), false, new uint256[](0));
        uint256 before = IERC20Min(USDC).balanceOf(address(this));
        _ur(abi.encodePacked(CMD_V3_SWAP_EXACT_IN), inputs);
        uint256 viaUr = IERC20Min(USDC).balanceOf(address(this)) - before;
        assertEq(viaExec, viaUr, "v3 two-hop: executor != universal router");
        assertGt(viaExec, 0);
    }

    function test_diff_mixed_v2_then_v3_exact() public {
        uint256 amt = 0.005 ether;
        // WETH -(v2)-> PONS -(v3 USDC 3000)-> USDC: two router commands, the router holds the intermediate
        uint256 snap = vm.snapshotState();
        _fundUser(WETH, amt);
        uint256 viaExec = _runErc20(_route1(_leg2(amt, _v2(WETH, PONS), _v3(PONS, USDC, 3000))), WETH, amt, USDC, 1, 0, false);
        vm.revertToState(snap);
        _funded(WETH, UNIVERSAL_ROUTER, amt);
        bytes[] memory inputs = new bytes[](2);
        inputs[0] = _v2In(ADDRESS_THIS, amt, WETH, PONS, false);
        inputs[1] = _v3In(address(this), CONTRACT_BALANCE, PONS, 3000, USDC, false);
        uint256 before = IERC20Min(USDC).balanceOf(address(this));
        _ur(abi.encodePacked(CMD_V2_SWAP_EXACT_IN, CMD_V3_SWAP_EXACT_IN), inputs);
        uint256 viaUr = IERC20Min(USDC).balanceOf(address(this)) - before;
        assertEq(viaExec, viaUr, "v2->v3: executor != universal router");
        assertGt(viaExec, 0);
    }

    function test_diff_split_v3_and_v2_exact() public {
        uint256 amt = 0.1 ether;
        uint256 half = amt / 2;
        uint256 snap = vm.snapshotState();
        _fundUser(WETH, amt);
        uint256 viaExec = _runErc20(_route2(_leg1(half, _v3(WETH, PONS, 3000)), _leg1(half, _v2(WETH, PONS))), WETH, amt, PONS, 1, 0, false);
        vm.revertToState(snap);
        _funded(WETH, UNIVERSAL_ROUTER, amt);
        bytes[] memory inputs = new bytes[](2);
        inputs[0] = _v3In(address(this), half, WETH, 3000, PONS, false);
        inputs[1] = _v2In(address(this), half, WETH, PONS, false);
        uint256 before = IERC20Min(PONS).balanceOf(address(this));
        _ur(abi.encodePacked(CMD_V3_SWAP_EXACT_IN, CMD_V2_SWAP_EXACT_IN), inputs);
        uint256 viaUr = IERC20Min(PONS).balanceOf(address(this)) - before;
        assertEq(viaExec, viaUr, "split: executor != universal router");
        assertGt(viaExec, 0);
    }

    function _fundUser(address token, uint256 amount) internal {
        _fund(token, user, amount);
    }
}
