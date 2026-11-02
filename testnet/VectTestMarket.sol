// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// Test assets only. This market is not a production router or a VECT token launch.
contract VectTestToken is ERC20 {
    address private immutable market;
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) { market=msg.sender; }
    function mint(address to,uint256 amount) external { require(msg.sender==market,"Only market"); _mint(to,amount); }
}
contract VectTestMarket is ReentrancyGuard {
    using SafeERC20 for IERC20;
    uint256 public constant CHAIN_ID=46630;
    uint256 public constant FEE_BPS=30;
    address public usd;
    address public alpha;
    address public beta;
    mapping(address=>bool) public claimed;
    struct Reserves { uint256 usdAmount; uint256 assetAmount; }
    mapping(address=>Reserves) public reserves;
    event Swap(address indexed account,address indexed tokenIn,address indexed tokenOut,uint256 amountIn,uint256 amountOut);
    constructor() {
        require(block.chainid==CHAIN_ID,"Testnet only");
        usd=address(new VectTestToken("Vect Test Dollar","tUSD"));
        alpha=address(new VectTestToken("Vect Test Alpha","tALPHA"));
        beta=address(new VectTestToken("Vect Test Beta","tBETA"));
        VectTestToken(usd).mint(address(this),200000 ether);
        VectTestToken(alpha).mint(address(this),50000 ether);
        VectTestToken(beta).mint(address(this),100000 ether);
        reserves[alpha]=Reserves(100000 ether,50000 ether);
        reserves[beta]=Reserves(100000 ether,100000 ether);
    }
    function faucet() external {
        require(block.chainid==CHAIN_ID,"Testnet only");
        require(!claimed[msg.sender],"Already claimed");
        claimed[msg.sender]=true;
        VectTestToken(usd).mint(msg.sender,1000 ether);
    }
    function quote(address tokenIn,address tokenOut,uint256 amountIn) public view returns(uint256 amountOut) {
        require(amountIn>0,"Zero amount");
        bool buy=tokenIn==usd;
        address asset=buy?tokenOut:tokenIn;
        require((asset==alpha || asset==beta) && (buy || tokenOut==usd),"Unsupported pair");
        Reserves memory r=reserves[asset];
        uint256 reserveIn=buy?r.usdAmount:r.assetAmount;
        uint256 reserveOut=buy?r.assetAmount:r.usdAmount;
        uint256 withFee=amountIn*(10000-FEE_BPS);
        amountOut=withFee*reserveOut/(reserveIn*10000+withFee);
        require(amountOut>0 && amountOut<reserveOut,"Invalid output");
    }
    function swap(address tokenIn,address tokenOut,uint256 amountIn,uint256 minimumOut,uint256 deadline) external nonReentrant returns(uint256 amountOut) {
        require(block.chainid==CHAIN_ID,"Testnet only");
        require(block.timestamp<=deadline,"Expired");
        require(minimumOut>0,"Missing minimum");
        amountOut=quote(tokenIn,tokenOut,amountIn);
        require(amountOut>=minimumOut,"Slippage");
        bool buy=tokenIn==usd;
        Reserves storage r=reserves[buy?tokenOut:tokenIn];
        if(buy){r.usdAmount+=amountIn;r.assetAmount-=amountOut;}
        else {r.assetAmount+=amountIn;r.usdAmount-=amountOut;}
        IERC20(tokenIn).safeTransferFrom(msg.sender,address(this),amountIn);
        IERC20(tokenOut).safeTransfer(msg.sender,amountOut);
        emit Swap(msg.sender,tokenIn,tokenOut,amountIn,amountOut);
    }
}
