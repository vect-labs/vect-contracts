// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test, Vm} from "forge-std/Test.sol";
import {VectExecutor} from "../src/VectExecutor.sol";
import {ISignatureTransfer, IWETH} from "../src/Interfaces.sol";

interface IERC20Min {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
    function decimals() external view returns (uint8);
}

interface IPermit2Domain {
    function DOMAIN_SEPARATOR() external view returns (bytes32);
}

/// @dev Everything runs on a fork of Robinhood Chain (4663) pinned at one block, through an archive RPC (set ROBINHOOD_RPC).
/// Mocks are deployed on top of the fork; no key is used except throwaway test keys derived from
/// labels, which exist only inside the test EVM.
abstract contract ExecBase is Test {
    uint256 internal constant PIN = 103_505_000;

    address internal constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address internal constant USDC = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address internal constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address internal constant UNIVERSAL_ROUTER = 0x204FAca1764B154221e35c0d20aBb3c525710498;
    address internal constant V3_FACTORY = 0x1f7d7550B1b028f7571E69A784071F0205FD2EfA;
    bytes32 internal constant V3_HASH = 0xe34f199b19b2b4f47f68442619d555527d244f78a3297ea89325f843f87b8b54;
    address internal constant V2_FACTORY = 0x8bcEaA40B9AcdfAedF85AdF4FF01F5Ad6517937f;
    bytes32 internal constant V2_HASH = 0x96e8ac4277198ff8b6f785478aa9a39f403cb768dd02cbee326c3e7da348845f;
    // CL table (order = router profile order): 0 Ramses-type (deployer), 1..4 Slipstream-type clone factories
    address internal constant CL0_DEP = 0x4b37359BF291AbE8453692DB58d515a8b013Dca9; // RamsesV3PoolDeployer (factory 0xe0c4ceb9)
    bytes32 internal constant CL0_HASH = 0x892f127ed4b26ca352056c8fb54585a3268f76f97fdd84d5836ef4bda8d8c685;
    address internal constant CL1_DEP = 0xc63d7338c178e805c544B8f897066bD3BBcBE136;
    bytes32 internal constant CL1_HASH = 0x3e77b70b9c4ce644601ed4aab19834375c6a9a2bca7adeb89a7bdd5fd8eb0a7d;
    address internal constant CL2_DEP = 0x1ac9dB4a2608ba45D6127B1737949b51Bb54B7F3;
    bytes32 internal constant CL2_HASH = 0x2a16e4a055eca1bf027a534adf1626e905f61a8fd28055bbcc8787c573c76e33;
    address internal constant CL3_DEP = 0x5481864ddd46a2D798Df0925C23B7846e776E5E3;
    bytes32 internal constant CL3_HASH = 0x6755479e7fc5517a003ad6c3467aac908acd527799d1b22d22fe61ff7f470fc0;
    address internal constant CL4_DEP = 0xaa5865dC3A60b25D305226d66fd573021f0D8fFB;
    bytes32 internal constant CL4_HASH = 0x8fc9aa80232b763bd70701e158188b66915cbbbcf908ccd947500767ef4dc7c1;
    // K-7 reviewed hooks (router profile `hookReviewedAllowlist`)
    address internal constant HOOK_E5E7 = 0xE5e702641Ea86F4ae6cC3cDaeD2B886f976Be044;
    address internal constant HOOK_4E34 = 0x4e3468951D49f2EEa976eD0D6e75fFCb44a9a544;
    address internal constant HOOK_48B8 = 0x48B8F6AD3A1b4aA477314c9a23035b8F84dDe8cc;
    address internal constant HOOK_75A5 = 0x75A54357D9C78a2Db19004a5FDc76c50F9242AEC;

    address internal constant FEE_RECIPIENT = address(0xFEE5AFE);

    uint256 internal userKey;
    address internal user;
    VectExecutor internal exec;
    uint256 internal lastExecGas; // gas used by the last `execute` call, read right after it returns

    bytes32 internal constant TOKEN_PERMISSIONS_TYPEHASH = keccak256("TokenPermissions(address token,uint256 amount)");
    bytes32 internal constant PERMIT_TYPEHASH = keccak256(
        "PermitTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline)TokenPermissions(address token,uint256 amount)"
    );

    function _fork() internal {
        // DEV_PIN (E4 QA) re-pins the fork suites to another block, e.g. the deployment block at E7 (D-6)
        vm.createSelectFork(vm.rpcUrl("robinhood"), vm.envOr("DEV_PIN", PIN));
        _etchFeeRecipient();
    }

    /// E4-03: the fee recipient must be a contract (the Vect Labs Safe); a code stub stands in for it in tests
    function _etchFeeRecipient() internal {
        vm.etch(FEE_RECIPIENT, hex"fe");
    }

    // E4 QA: LOCAL_WORLD=1 etches the real runtime code of Permit2 and WETH into a local EVM (no
    // fork), so mock-only campaigns need no historical RPC state. Unset = the developer's fork at PIN.
    function _forkOrLocal() internal {
        if (vm.envOr("LOCAL_WORLD", uint256(0)) == 1) {
            vm.chainId(4663);
            vm.warp(0x6ae76153);
            vm.roll(0x191a03f);
            address[2] memory a = [PERMIT2, WETH];
            for (uint256 i; i < a.length; ++i) {
                bytes memory code = vm.rpc("robinhood", "eth_getCode", string.concat('["', vm.toString(a[i]), '","latest"]'));
                vm.etch(a[i], code);
            }
            // the WETH proxy (EIP-1967): etch its implementation and set the implementation slot
            address impl = 0xC6B81b429797E0f555440b70cD99e032D7AE947e;
            vm.etch(impl, vm.rpc("robinhood", "eth_getCode", string.concat('["', vm.toString(impl), '","latest"]')));
            vm.store(WETH, 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc, bytes32(uint256(uint160(impl))));
            vm.store(WETH, bytes32(0), bytes32(uint256(1)));
            _etchFeeRecipient();
            return;
        }
        _fork();
    }

    function _setUpUser() internal {
        userKey = uint256(keccak256("exec01-test-user"));
        user = vm.addr(userKey);
        vm.deal(user, 100 ether);
        vm.label(user, "user");
    }

    function _realConfig() internal view returns (VectExecutor.Config memory c) {
        c.weth = WETH;
        c.permit2 = PERMIT2;
        c.poolManager = POOL_MANAGER;
        c.feeRecipient = FEE_RECIPIENT;
        c.v3Factory = V3_FACTORY;
        c.v3InitCodeHash = V3_HASH;
        c.v2Factory = V2_FACTORY;
        c.v2InitCodeHash = V2_HASH;
        c.v2FeeNumerator = 997;
        c.clDeployer = [CL0_DEP, CL1_DEP, CL2_DEP, CL3_DEP, CL4_DEP];
        c.clInitCodeHash = [CL0_HASH, CL1_HASH, CL2_HASH, CL3_HASH, CL4_HASH];
        c.hook = [HOOK_E5E7, HOOK_4E34, HOOK_48B8, HOOK_75A5, address(0), address(0), address(0), address(0)];
        c.hookCodehash = [
            HOOK_E5E7.codehash,
            HOOK_4E34.codehash,
            HOOK_48B8.codehash,
            HOOK_75A5.codehash,
            bytes32(0),
            bytes32(0),
            bytes32(0),
            bytes32(0)
        ];
    }

    // ---------------------------------------------------------------- route builders

    function _hop(uint8 family, address a, address b) internal pure returns (VectExecutor.Hop memory h) {
        h.family = family;
        h.tokenIn = a;
        h.tokenOut = b;
    }

    function _v2(address a, address b) internal pure returns (VectExecutor.Hop memory) {
        return _hop(0, a, b);
    }

    function _v3(address a, address b, uint24 fee) internal pure returns (VectExecutor.Hop memory h) {
        h = _hop(1, a, b);
        h.fee = fee;
    }

    function _cl(uint8 idx, address a, address b, int24 ts) internal pure returns (VectExecutor.Hop memory h) {
        h = _hop(2, a, b);
        h.index = idx;
        h.tickSpacing = ts;
    }

    function _v4(address a, address b, uint24 fee, int24 ts, address hooks)
        internal
        pure
        returns (VectExecutor.Hop memory h)
    {
        h = _hop(3, a, b);
        h.fee = fee;
        h.tickSpacing = ts;
        h.hooks = hooks;
    }

    function _leg1(uint256 amt, VectExecutor.Hop memory a) internal pure returns (VectExecutor.Leg memory l) {
        l.amountIn = amt;
        l.hops = new VectExecutor.Hop[](1);
        l.hops[0] = a;
    }

    function _leg2(uint256 amt, VectExecutor.Hop memory a, VectExecutor.Hop memory b)
        internal
        pure
        returns (VectExecutor.Leg memory l)
    {
        l.amountIn = amt;
        l.hops = new VectExecutor.Hop[](2);
        l.hops[0] = a;
        l.hops[1] = b;
    }

    function _route1(VectExecutor.Leg memory a) internal pure returns (VectExecutor.Route memory r) {
        r.legs = new VectExecutor.Leg[](1);
        r.legs[0] = a;
    }

    function _route2(VectExecutor.Leg memory a, VectExecutor.Leg memory b)
        internal
        pure
        returns (VectExecutor.Route memory r)
    {
        r.legs = new VectExecutor.Leg[](2);
        r.legs[0] = a;
        r.legs[1] = b;
    }

    // ---------------------------------------------------------------- permit

    function _signPermit(uint256 pk, address token, uint256 amount, uint256 nonce, uint256 deadline, address spender)
        internal
        view
        returns (ISignatureTransfer.PermitTransferFrom memory permit, bytes memory sig)
    {
        permit = ISignatureTransfer.PermitTransferFrom({
            permitted: ISignatureTransfer.TokenPermissions({token: token, amount: amount}),
            nonce: nonce,
            deadline: deadline
        });
        bytes32 tokenPermissions = keccak256(abi.encode(TOKEN_PERMISSIONS_TYPEHASH, token, amount));
        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, tokenPermissions, spender, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", IPermit2Domain(PERMIT2).DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        sig = abi.encodePacked(r, s, v);
    }

    struct Args {
        VectExecutor.Route route;
        address tokenIn;
        uint256 amountIn;
        address tokenOut;
        uint256 minOut;
        uint16 feeBps;
        bool feeOnOutput;
        // permit knobs (0 = honest default)
        address permitToken;
        uint256 permitAmount;
        uint256 permitDeadline; // absolute; 0 = now + 600
        uint256 deadline; // absolute; 0 = now + 600
        address spender; // 0 = exec
        uint256 signerKey; // 0 = userKey
        uint256 nonce; // 0 = derived
        uint256 value; // native input only
        bytes err; // expected revert data, empty = expect success
    }

    function _args(
        VectExecutor.Route memory route,
        address tokenIn,
        uint256 amountIn,
        address tokenOut,
        uint256 minOut,
        uint16 feeBps,
        bool feeOnOutput
    ) internal pure returns (Args memory a) {
        a.route = route;
        a.tokenIn = tokenIn;
        a.amountIn = amountIn;
        a.tokenOut = tokenOut;
        a.minOut = minOut;
        a.feeBps = feeBps;
        a.feeOnOutput = feeOnOutput;
    }

    /// @dev Calls `execute` as `user`. For an ERC20 input it signs a fresh permit with the knobs of `a`.
    function _go(Args memory a) internal returns (uint256 out) {
        uint256 dl = a.deadline == 0 ? block.timestamp + 600 : a.deadline;
        ISignatureTransfer.PermitTransferFrom memory permit;
        bytes memory sig;
        if (a.tokenIn != address(0)) {
            uint256 pdl = a.permitDeadline == 0 ? block.timestamp + 600 : a.permitDeadline;
            uint256 nonce = a.nonce == 0 ? uint256(keccak256(abi.encode(a.route, a.minOut, a.amountIn, block.timestamp, gasleft()))) : a.nonce;
            (permit, sig) = _signPermit(
                a.signerKey == 0 ? userKey : a.signerKey,
                a.permitToken == address(0) ? a.tokenIn : a.permitToken,
                a.permitAmount == 0 ? a.amountIn : a.permitAmount,
                nonce,
                pdl,
                a.spender == address(0) ? address(exec) : a.spender
            );
        }
        if (a.err.length > 0) vm.expectRevert(a.err);
        vm.prank(user);
        out = exec.execute{value: a.value}(
            a.route, a.tokenIn, a.amountIn, a.tokenOut, a.minOut, a.feeBps, a.feeOnOutput, permit, sig, dl
        );
        if (a.err.length == 0) lastExecGas = vm.lastCallGas().gasTotalUsed;
    }

    function _runErc20(
        VectExecutor.Route memory route,
        address tokenIn,
        uint256 amountIn,
        address tokenOut,
        uint256 minOut,
        uint16 feeBps,
        bool feeOnOutput
    ) internal returns (uint256 out) {
        return _go(_args(route, tokenIn, amountIn, tokenOut, minOut, feeBps, feeOnOutput));
    }

    function _runNativeIn(
        VectExecutor.Route memory route,
        uint256 amountIn,
        address tokenOut,
        uint256 minOut,
        uint16 feeBps,
        bool feeOnOutput
    ) internal returns (uint256 out) {
        Args memory a = _args(route, address(0), amountIn, tokenOut, minOut, feeBps, feeOnOutput);
        a.value = amountIn;
        return _go(a);
    }

    function _fund(address token, address to, uint256 amount) internal {
        if (token == WETH) {
            vm.deal(address(this), address(this).balance + amount);
            IWETH(WETH).deposit{value: amount}();
            IERC20Min(WETH).transfer(to, amount);
        } else {
            deal(token, to, amount);
        }
        vm.prank(to);
        IERC20Min(token).approve(PERMIT2, type(uint256).max);
    }

    function _bal(address token, address who) internal view returns (uint256) {
        return token == address(0) ? who.balance : IERC20Min(token).balanceOf(who);
    }
}
