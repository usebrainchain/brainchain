// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

struct MarketParams {
    address loanToken;
    address collateralToken;
    address oracle;
    address irm;
    uint256 lltv;
}

interface IMorpho {
    function idToMarketParams(bytes32 id) external view returns (MarketParams memory);
    function market(bytes32 id)
        external
        view
        returns (
            uint128 totalSupplyAssets,
            uint128 totalSupplyShares,
            uint128 totalBorrowAssets,
            uint128 totalBorrowShares,
            uint128 lastUpdate,
            uint128 fee
        );
    function position(bytes32 id, address user)
        external
        view
        returns (uint256 supplyShares, uint128 borrowShares, uint128 collateral);
    function supply(MarketParams calldata params, uint256 assets, uint256 shares, address onBehalf, bytes calldata data)
        external
        returns (uint256 assetsSupplied, uint256 sharesSupplied);
    function withdraw(MarketParams calldata params, uint256 assets, uint256 shares, address onBehalf, address receiver)
        external
        returns (uint256 assetsWithdrawn, uint256 sharesWithdrawn);
    function accrueInterest(MarketParams calldata params) external;
}

interface IUniswapV3PoolLike {
    function token0() external view returns (address);
    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96, bytes calldata data)
        external
        returns (int256 amount0, int256 amount1);
}

interface IWETH9 {
    function deposit() external payable;
}

/// @notice The chain's float: idle USDG lent on Morpho under a cap, every move a public record.
///
/// The owner (the Safe) allows markets, sets the cap, funds, pauses and can take everything back.
/// The operator moves USDG between this contract and the allowed markets, and may release USDG to
/// the desk for payouts. USDG only ever goes to Morpho, to the desk, or to the owner.
contract Float is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint160 private constant MIN_SQRT_RATIO = 4295128739;
    uint160 private constant MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342;
    uint256 private constant VIRTUAL_SHARES = 1e6;
    uint256 private constant VIRTUAL_ASSETS = 1;

    IERC20 public immutable USDG;
    IMorpho public immutable MORPHO;
    IERC20 public immutable WETH;
    IUniswapV3PoolLike public immutable WETH_POOL;

    address public operator;
    address public desk;
    uint256 public cap;
    bool public paused;
    bytes32[] public markets;
    mapping(bytes32 id => bool) public allowed;

    address private _expectedPool;

    event MarketAllowed(bytes32 indexed id, bool allowed);
    event Supplied(bytes32 indexed id, uint256 usdg, uint256 shares);
    event Withdrawn(bytes32 indexed id, uint256 usdg, uint256 shares);
    event Funded(address indexed from, uint256 usdg);
    event Released(address indexed to, uint256 usdg);
    event Swept(address indexed to, uint256 usdg);
    event CapSet(uint256 cap);
    event OperatorSet(address operator);
    event DeskSet(address desk);
    event PausedSet(bool paused);

    error NotOperator();
    error Paused();
    error ZeroAmount();
    error NotAllowed(bytes32 id);
    error NotUsdgMarket(bytes32 id);
    error OverCap(uint256 wouldBe, uint256 cap);
    error OffPrice(uint256 out, uint256 minOut);
    error WrongPool(address caller);
    error NoDesk();

    modifier onlyOperator() {
        if (msg.sender != operator && msg.sender != owner()) revert NotOperator();
        _;
    }

    constructor(
        IERC20 usdg,
        IMorpho morpho,
        IERC20 weth,
        IUniswapV3PoolLike wethPool,
        address owner_,
        address operator_,
        address desk_,
        uint256 cap_
    ) Ownable(owner_) {
        USDG = usdg;
        MORPHO = morpho;
        WETH = weth;
        WETH_POOL = wethPool;
        operator = operator_;
        desk = desk_;
        cap = cap_;
    }

    // Owner

    function allow(bytes32 id, bool ok) external onlyOwner {
        if (ok) {
            MarketParams memory params = MORPHO.idToMarketParams(id);
            if (params.loanToken != address(USDG)) revert NotUsdgMarket(id);
            if (!allowed[id]) markets.push(id);
        }
        allowed[id] = ok;
        emit MarketAllowed(id, ok);
    }

    function setCap(uint256 cap_) external onlyOwner {
        cap = cap_;
        emit CapSet(cap_);
    }

    function setOperator(address operator_) external onlyOwner {
        operator = operator_;
        emit OperatorSet(operator_);
    }

    function setDesk(address desk_) external onlyOwner {
        desk = desk_;
        emit DeskSet(desk_);
    }

    function setPaused(bool paused_) external onlyOwner {
        paused = paused_;
        emit PausedSet(paused_);
    }

    /// @notice ETH in, USDG kept here until the operator lends it.
    function fundWithEth(uint256 minOut) external payable onlyOwner nonReentrant {
        if (msg.value == 0) revert ZeroAmount();
        IWETH9(address(WETH)).deposit{value: msg.value}();
        uint256 out = _swap(WETH_POOL, address(WETH), msg.value);
        if (out < minOut) revert OffPrice(out, minOut);
        emit Funded(msg.sender, out);
    }

    function sweep(address to, uint256 usdg) external onlyOwner nonReentrant {
        USDG.safeTransfer(to, usdg);
        emit Swept(to, usdg);
    }

    // Anyone

    function fund(uint256 usdg) external nonReentrant {
        if (usdg == 0) revert ZeroAmount();
        USDG.safeTransferFrom(msg.sender, address(this), usdg);
        emit Funded(msg.sender, usdg);
    }

    // Operator

    function supply(bytes32 id, uint256 usdg) external onlyOperator nonReentrant returns (uint256 shares) {
        if (paused) revert Paused();
        if (usdg == 0) revert ZeroAmount();
        if (!allowed[id]) revert NotAllowed(id);
        uint256 wouldBe = supplied() + usdg;
        if (wouldBe > cap) revert OverCap(wouldBe, cap);
        MarketParams memory params = MORPHO.idToMarketParams(id);
        USDG.forceApprove(address(MORPHO), usdg);
        (, shares) = MORPHO.supply(params, usdg, 0, address(this), "");
        emit Supplied(id, usdg, shares);
    }

    function withdraw(bytes32 id, uint256 usdg) external onlyOperator nonReentrant returns (uint256 shares) {
        if (usdg == 0) revert ZeroAmount();
        MarketParams memory params = MORPHO.idToMarketParams(id);
        (, shares) = MORPHO.withdraw(params, usdg, 0, address(this), address(this));
        emit Withdrawn(id, usdg, shares);
    }

    /// @notice Everything lent in a market comes back here.
    function withdrawAll(bytes32 id) external onlyOperator nonReentrant returns (uint256 usdg) {
        MarketParams memory params = MORPHO.idToMarketParams(id);
        (uint256 sharesHeld,,) = MORPHO.position(id, address(this));
        if (sharesHeld == 0) return 0;
        (usdg,) = MORPHO.withdraw(params, 0, sharesHeld, address(this), address(this));
        emit Withdrawn(id, usdg, sharesHeld);
    }

    /// @notice Idle USDG to the desk, for payouts.
    function release(uint256 usdg) external onlyOperator nonReentrant {
        if (desk == address(0)) revert NoDesk();
        if (usdg == 0) revert ZeroAmount();
        USDG.safeTransfer(desk, usdg);
        emit Released(desk, usdg);
    }

    // Views

    function idle() public view returns (uint256) {
        return USDG.balanceOf(address(this));
    }

    /// @notice USDG lent across the allowed markets, at the last accrual.
    function supplied() public view returns (uint256 sum) {
        for (uint256 i = 0; i < markets.length; i++) sum += suppliedIn(markets[i]);
    }

    function suppliedIn(bytes32 id) public view returns (uint256) {
        (uint256 shares,,) = MORPHO.position(id, address(this));
        if (shares == 0) return 0;
        (uint128 totalSupplyAssets, uint128 totalSupplyShares,,,,) = MORPHO.market(id);
        return shares * (totalSupplyAssets + VIRTUAL_ASSETS) / (totalSupplyShares + VIRTUAL_SHARES);
    }

    function total() external view returns (uint256) {
        return idle() + supplied();
    }

    function marketCount() external view returns (uint256) {
        return markets.length;
    }

    // Uniswap v3

    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external {
        if (msg.sender != _expectedPool) revert WrongPool(msg.sender);
        address tokenIn = abi.decode(data, (address));
        uint256 owed = uint256(amount0Delta > 0 ? amount0Delta : amount1Delta);
        IERC20(tokenIn).safeTransfer(msg.sender, owed);
    }

    function _swap(IUniswapV3PoolLike pool, address tokenIn, uint256 amountIn) private returns (uint256 amountOut) {
        bool zeroForOne = pool.token0() == tokenIn;
        _expectedPool = address(pool);
        (int256 amount0, int256 amount1) = pool.swap(
            address(this), zeroForOne, int256(amountIn), zeroForOne ? MIN_SQRT_RATIO + 1 : MAX_SQRT_RATIO - 1, abi.encode(tokenIn)
        );
        _expectedPool = address(0);
        amountOut = uint256(-(zeroForOne ? amount1 : amount0));
    }
}
