// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

// TEST ONLY. Unrestricted mint and tax configuration; never deploy on a public chain.
// MC857 variants: honest net Transfer or deliberately gross Transfer with taxed
// balances. Gross logs are an explicit synthetic fixture, not honest ERC20 accounting.
contract R6Token {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    uint256 public taxBps;
    bool public grossLogs;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(string memory label, bool grossLogVariant) {
        name = label; symbol = label; grossLogs = grossLogVariant;
    }
    function setTax(uint256 bps) external { require(bps <= 1000); taxBps = bps; }
    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount; totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }
    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount); return true;
    }
    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount); return true;
    }
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        _transfer(from, to, amount); return true;
    }
    function _transfer(address from, address to, uint256 amount) internal {
        uint256 tax = amount * taxBps / 10000;
        balanceOf[from] -= amount; balanceOf[to] += amount - tax;
        totalSupply -= tax;
        emit Transfer(from, to, grossLogs ? amount : amount - tax);
        if (tax > 0) emit Transfer(from, address(0), tax);
    }
}

interface R6Factory { function createPool(address, address, uint24) external returns (address); }
interface R6Pool {
    function initialize(uint160) external;
    function mint(address, int24, int24, uint128, bytes calldata) external returns (uint256, uint256);
}
interface R6ERC20 { function transfer(address, uint256) external returns (bool); }

// Seeds a REAL canonical v3 factory pool. No replacement AMM/quoter/router code.
// Fund this helper before calling seed. The caller supplies a tick-spacing-aligned
// full range, sqrt price and liquidity; all inputs are captured in the run manifest.
contract R6Seeder {
    address private activePool;
    address private token0;
    address private token1;
    function seed(address factory, address a, address b, uint24 fee, uint160 sqrtPrice,
        int24 lower, int24 upper, uint128 liquidity) external returns (address pool) {
        require(activePool == address(0) && a != b && liquidity > 0);
        (token0, token1) = a < b ? (a,b) : (b,a);
        pool = R6Factory(factory).createPool(token0, token1, fee);
        activePool = pool;
        R6Pool(pool).initialize(sqrtPrice);
        R6Pool(pool).mint(address(this), lower, upper, liquidity, "");
        activePool = address(0);
    }
    function uniswapV3MintCallback(uint256 amount0, uint256 amount1, bytes calldata) external {
        require(msg.sender == activePool && activePool != address(0));
        if (amount0 > 0) require(R6ERC20(token0).transfer(msg.sender, amount0));
        if (amount1 > 0) require(R6ERC20(token1).transfer(msg.sender, amount1));
    }
}
