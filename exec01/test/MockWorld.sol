// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {ExecBase, IERC20Min} from "./Base.t.sol";
import {VectExecutor} from "../src/VectExecutor.sol";
import {PoolKey} from "../src/Interfaces.sol";
import {MockERC20, MockV3Factory, MockV3Pool, MockV2Factory, MockV2Pair, MockPoolManager, Attacker} from "./mocks/Mocks.sol";

/// @dev Shared mock world of the adversarial and fuzz suites: mock v3 / CL / v2 factories and a mock PoolManager over
/// the pinned fork (real Permit2 and WETH), three mock tokens, and the builders for pools.
abstract contract MockWorld is ExecBase {
    MockV3Factory internal v3f;
    MockV3Factory internal clf;
    MockV2Factory internal v2f;
    MockPoolManager internal pm;
    MockERC20 internal A;
    MockERC20 internal B;
    MockERC20 internal C;
    Attacker internal hookOk; // an allowlisted v4 "hook" (code-pinned)
    Attacker internal attacker;
    bytes32 internal mockPoolHash;
    bytes32 internal mockPairHash;

    uint256 internal constant LIQ = 1_000_000 ether;
    bytes4 internal constant INVALID_SIGNER = 0x815e1d64; // Permit2 InvalidSigner()
    bytes4 internal constant INVALID_NONCE = 0x756688fe; // Permit2 InvalidNonce()

    function setUp() public {
        _fork();
        _setUpUser();
        v3f = new MockV3Factory();
        clf = new MockV3Factory();
        v2f = new MockV2Factory();
        pm = new MockPoolManager();
        hookOk = new Attacker();
        attacker = new Attacker();
        mockPoolHash = keccak256(type(MockV3Pool).creationCode);
        mockPairHash = keccak256(type(MockV2Pair).creationCode);
        A = new MockERC20("A");
        B = new MockERC20("B");
        C = new MockERC20("C");
        exec = _deploy(address(pm));
        vm.deal(address(pm), 1_000_000 ether);
    }

    function _deploy(address poolManager) internal returns (VectExecutor) {
        return _deployFor(poolManager, FEE_RECIPIENT);
    }

    function _deployFor(address poolManager, address feeRecipient) internal returns (VectExecutor) {
        VectExecutor.Config memory c = _realConfig();
        if (feeRecipient.code.length == 0) vm.etch(feeRecipient, hex"fe"); // E4-03 stand-in for the Safe
        c.feeRecipient = feeRecipient;
        c.poolManager = poolManager;
        c.v3Factory = address(v3f);
        c.v3InitCodeHash = mockPoolHash;
        c.v2Factory = address(v2f);
        c.v2InitCodeHash = mockPairHash;
        c.clDeployer = [address(clf), address(0), address(0), address(0), address(0)];
        c.clInitCodeHash = [mockPoolHash, bytes32(0), bytes32(0), bytes32(0), bytes32(0)];
        c.hook = [address(hookOk), address(0), address(0), address(0), address(0), address(0), address(0), address(0)];
        c.hookCodehash =
            [address(hookOk).codehash, bytes32(0), bytes32(0), bytes32(0), bytes32(0), bytes32(0), bytes32(0), bytes32(0)];
        return new VectExecutor(c);
    }

    // ------------------------------------------------------------------ world builders

    function _v3Pool(MockERC20 x, MockERC20 y, uint24 fee) internal returns (MockV3Pool p) {
        p = MockV3Pool(v3f.createPool(address(x), address(y), fee, false));
        x.mint(address(p), LIQ);
        y.mint(address(p), LIQ);
    }

    function _clPool(MockERC20 x, MockERC20 y, int24 ts) internal returns (MockV3Pool p) {
        p = MockV3Pool(clf.createPool(address(x), address(y), uint24(ts), true));
        x.mint(address(p), LIQ);
        y.mint(address(p), LIQ);
    }

    function _v2Pair(MockERC20 x, MockERC20 y) internal returns (MockV2Pair p) {
        p = MockV2Pair(v2f.createPair(address(x), address(y)));
        x.mint(address(p), LIQ);
        y.mint(address(p), LIQ);
        p.sync();
    }

    function _v4Key(address x, address y, address hooks) internal pure returns (PoolKey memory k) {
        (k.currency0, k.currency1) = x < y ? (x, y) : (y, x);
        k.fee = 3000;
        k.tickSpacing = 60;
        k.hooks = hooks;
    }

    function _v4Pool(address x, address y, address hooks) internal returns (PoolKey memory k) {
        k = _v4Key(x, y, hooks);
        if (k.currency0 != address(0)) MockERC20(k.currency0).mint(address(pm), LIQ);
        if (k.currency1 != address(0)) MockERC20(k.currency1).mint(address(pm), LIQ);
        pm.seed(k, LIQ, LIQ);
    }

    function _give(MockERC20 t, uint256 amt) internal {
        t.mint(user, amt);
        vm.prank(user);
        t.approve(PERMIT2, type(uint256).max);
    }

    function _v4hop(address a, address b, address hooks) internal pure returns (VectExecutor.Hop memory h) {
        h = _hop(3, a, b);
        h.fee = 3000;
        h.tickSpacing = 60;
        h.hooks = hooks;
    }

    function _sel(bytes4 s) internal pure returns (bytes memory) {
        return abi.encodePacked(s);
    }

    function _expectResidueFree(address[] memory toks) internal view {
        for (uint256 i; i < toks.length; ++i) {
            assertEq(_bal(toks[i], address(exec)), 0, "residue");
        }
        assertEq(address(exec).balance, 0, "eth residue");
    }
}
