// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {PriceOracle} from "./PriceOracle.sol";

interface IERC20Metadata {
    function decimals() external view returns (uint8);
}

contract LendingPool is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant ANNUAL_RATE_BPS = 500;
    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant SECONDS_PER_YEAR = 365 days;
    uint256 public constant USD_DECIMALS = 1e8;
    uint256 public constant LTV_DENOMINATOR = 10_000;
    uint256 public constant LIQUIDATION_THRESHOLD_BPS = 8_000;
    uint256 public constant LIQUIDATION_BONUS_BPS = 1_000;
    uint256 public constant HEALTH_FACTOR_SCALE = 1e18;
    uint256 public constant MAX_LIQUIDATION_CLOSE_FACTOR_BPS = 5_000;

    struct Reserve {
        bool active;
        uint256 totalSupplied;
        uint256 totalBorrowed;
    }

    mapping(address => Reserve) public reserves;
    address[] public supportedAssets;

    mapping(address => mapping(address => uint256)) public principal;
    mapping(address => mapping(address => uint256)) public accruedInterest;
    mapping(address => mapping(address => uint256)) public lastAccrualTimestamp;
    mapping(address => mapping(address => uint256)) public suppliedBalance;
    mapping(address => mapping(address => uint256)) public collateralBalance;
    mapping(address => uint256) public totalCollateral;
    mapping(address => uint256) public ltvBps;

    PriceOracle public priceOracle;

    event AssetListed(address indexed asset);
    event Supplied(address indexed user, address indexed asset, uint256 amount);
    event Withdrawn(address indexed user, address indexed asset, uint256 amount);
    event Borrowed(address indexed user, address indexed asset, uint256 amount);
    event Repaid(address indexed user, address indexed asset, uint256 amount);
    event CollateralDeposited(address indexed user, address indexed asset, uint256 amount);
    event CollateralWithdrawn(address indexed user, address indexed asset, uint256 amount);
    event PriceUpdated(address indexed asset, uint256 price);
    event LTVUpdated(address indexed asset, uint256 ltv);
    event Liquidated(address indexed liquidator, address indexed borrower, address indexed debtAsset, address collateralAsset, uint256 debtRepaid, uint256 collateralSeized);

    constructor() Ownable(msg.sender) {
        priceOracle = new PriceOracle();
    }

    function _computeInterest(uint256 p, uint256 elapsed) internal pure returns (uint256) {
        return (p * ANNUAL_RATE_BPS * elapsed) / (BPS_DENOMINATOR * SECONDS_PER_YEAR);
    }

    function _currentDebt(address asset, address user) internal view returns (uint256) {
        uint256 p = principal[asset][user];
        uint256 accrued = accruedInterest[asset][user];
        if (p == 0 && accrued == 0) return 0;
        uint256 unmaterialised;
        if (p > 0) {
            uint256 lastTs = lastAccrualTimestamp[asset][user];
            if (lastTs > 0 && block.timestamp > lastTs) {
                unmaterialised = _computeInterest(p, block.timestamp - lastTs);
            }
        }
        return p + accrued + unmaterialised;
    }

    function _accrueInterest(address asset, address user) internal {
        uint256 p = principal[asset][user];
        if (p == 0) {
            lastAccrualTimestamp[asset][user] = block.timestamp;
            return;
        }
        uint256 lastTs = lastAccrualTimestamp[asset][user];
        if (lastTs == 0 || block.timestamp <= lastTs) {
            lastAccrualTimestamp[asset][user] = block.timestamp;
            return;
        }
        uint256 interest = _computeInterest(p, block.timestamp - lastTs);
        if (interest > 0) {
            accruedInterest[asset][user] += interest;
            reserves[asset].totalBorrowed += interest;
        }
        lastAccrualTimestamp[asset][user] = block.timestamp;
    }

    function addAsset(address asset) external onlyOwner {
        require(asset != address(0), "Invalid asset");
        require(!reserves[asset].active, "Asset already listed");
        reserves[asset].active = true;
        supportedAssets.push(asset);
        emit AssetListed(asset);
    }

    function setAssetPrice(address asset, uint256 price) external onlyOwner {
        require(reserves[asset].active, "Unsupported asset");
        priceOracle.setPrice(asset, price);
        emit PriceUpdated(asset, price);
    }

    function setLTV(address asset, uint256 ltv) external onlyOwner {
        require(reserves[asset].active, "Unsupported asset");
        require(ltv > 0 && ltv <= LTV_DENOMINATOR, "Invalid LTV");
        ltvBps[asset] = ltv;
        emit LTVUpdated(asset, ltv);
    }

    function supply(address asset, uint256 amount) external nonReentrant {
        require(reserves[asset].active, "Unsupported asset");
        require(amount > 0, "Amount must be greater than zero");
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        suppliedBalance[asset][msg.sender] += amount;
        reserves[asset].totalSupplied += amount;
        emit Supplied(msg.sender, asset, amount);
    }

    function withdraw(address asset, uint256 amount) external nonReentrant {
        require(reserves[asset].active, "Unsupported asset");
        require(amount > 0, "Amount must be greater than zero");
        require(suppliedBalance[asset][msg.sender] >= amount, "Insufficient supplied balance");
        require(_lenderLiquidity(asset) >= amount, "Insufficient pool liquidity");
        suppliedBalance[asset][msg.sender] -= amount;
        reserves[asset].totalSupplied -= amount;
        IERC20(asset).safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, asset, amount);
    }

    function depositCollateral(address asset, uint256 amount) external nonReentrant {
        require(reserves[asset].active, "Unsupported asset");
        require(ltvBps[asset] > 0, "LTV not configured");
        require(amount > 0, "Amount must be greater than zero");
        priceOracle.getPrice(asset);
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        collateralBalance[asset][msg.sender] += amount;
        totalCollateral[asset] += amount;
        emit CollateralDeposited(msg.sender, asset, amount);
    }

    function withdrawCollateral(address asset, uint256 amount) external nonReentrant {
        require(reserves[asset].active, "Unsupported asset");
        require(amount > 0, "Amount must be greater than zero");
        uint256 userCollateral = collateralBalance[asset][msg.sender];
        require(userCollateral >= amount, "Insufficient collateral");
        collateralBalance[asset][msg.sender] = userCollateral - amount;
        totalCollateral[asset] -= amount;
        require(_userDebtValueUSD(msg.sender) <= _userBorrowCapacityUSD(msg.sender), "Withdrawal exceeds borrowing limit");
        require(IERC20(asset).balanceOf(address(this)) >= amount, "Insufficient token liquidity");
        IERC20(asset).safeTransfer(msg.sender, amount);
        emit CollateralWithdrawn(msg.sender, asset, amount);
    }

    function _valueInUSD(address asset, uint256 amount) internal view returns (uint256) {
        uint256 price = priceOracle.getPrice(asset);
        uint8 tokenDecimals = IERC20Metadata(asset).decimals();
        return (amount * price) / (10 ** tokenDecimals);
    }

    function _userBorrowCapacityUSD(address user) internal view returns (uint256 capacity) {
        for (uint256 i; i < supportedAssets.length; i++) {
            address asset = supportedAssets[i];
            uint256 amount = collateralBalance[asset][user];
            if (amount == 0) continue;
            capacity += (_valueInUSD(asset, amount) * ltvBps[asset]) / LTV_DENOMINATOR;
        }
    }

    function _userDebtValueUSD(address user) internal view returns (uint256 debtValue) {
        for (uint256 i; i < supportedAssets.length; i++) {
            address asset = supportedAssets[i];
            uint256 debt = _currentDebt(asset, user);
            if (debt == 0) continue;
            debtValue += _valueInUSD(asset, debt);
        }
    }

    function _userCollateralValueUSD(address user) internal view returns (uint256 collateralValue) {
        for (uint256 i; i < supportedAssets.length; i++) {
            address asset = supportedAssets[i];
            uint256 amount = collateralBalance[asset][user];
            if (amount == 0) continue;
            collateralValue += _valueInUSD(asset, amount);
        }
    }

    function _weightedLiquidationCollateralUSD(address user) internal view returns (uint256 value) {
        for (uint256 i; i < supportedAssets.length; i++) {
            address asset = supportedAssets[i];
            uint256 amount = collateralBalance[asset][user];
            if (amount == 0) continue;
            value += (_valueInUSD(asset, amount) * LIQUIDATION_THRESHOLD_BPS) / LTV_DENOMINATOR;
        }
    }

    function getBorrowCapacityUSD(address user) external view returns (uint256) {
        return _userBorrowCapacityUSD(user);
    }

    function getUserDebtUSD(address user) external view returns (uint256) {
        return _userDebtValueUSD(user);
    }

    function getAvailableBorrowUSD(address user) external view returns (uint256) {
        uint256 capacity = _userBorrowCapacityUSD(user);
        uint256 debt = _userDebtValueUSD(user);
        if (debt >= capacity) return 0;
        return capacity - debt;
    }

    function getHealthFactor(address user) public view returns (uint256) {
        uint256 debt = _userDebtValueUSD(user);
        if (debt == 0) return type(uint256).max;
        return (_weightedLiquidationCollateralUSD(user) * HEALTH_FACTOR_SCALE) / debt;
    }

    function borrow(address asset, uint256 amount) external nonReentrant {
        require(reserves[asset].active, "Unsupported asset");
        require(amount > 0, "Amount must be greater than zero");
        require(_lenderLiquidity(asset) >= amount, "Insufficient pool liquidity");
        priceOracle.getPrice(asset);
        uint256 existingDebtUSD = _userDebtValueUSD(msg.sender);
        uint256 newBorrowUSD = _valueInUSD(asset, amount);
        uint256 capacityUSD = _userBorrowCapacityUSD(msg.sender);
        require(existingDebtUSD + newBorrowUSD <= capacityUSD, "Exceeds borrowing capacity");
        _accrueInterest(asset, msg.sender);
        principal[asset][msg.sender] += amount;
        reserves[asset].totalBorrowed += amount;
        IERC20(asset).safeTransfer(msg.sender, amount);
        emit Borrowed(msg.sender, asset, amount);
    }

    function repay(address asset, uint256 amount) external nonReentrant {
        require(reserves[asset].active, "Unsupported asset");
        require(amount > 0, "Amount must be greater than zero");
        _accrueInterest(asset, msg.sender);
        uint256 p = principal[asset][msg.sender];
        uint256 accrued = accruedInterest[asset][msg.sender];
        uint256 totalDebt = p + accrued;
        require(totalDebt > 0, "No outstanding debt");
        uint256 repayAmount = amount > totalDebt ? totalDebt : amount;
        uint256 remaining = repayAmount;
        if (remaining >= accrued) {
            remaining -= accrued;
            accruedInterest[asset][msg.sender] = 0;
            principal[asset][msg.sender] -= remaining;
        } else {
            accruedInterest[asset][msg.sender] -= remaining;
        }
        reserves[asset].totalBorrowed -= repayAmount;
        if (principal[asset][msg.sender] == 0 && accruedInterest[asset][msg.sender] == 0) {
            lastAccrualTimestamp[asset][msg.sender] = 0;
        }
        IERC20(asset).safeTransferFrom(msg.sender, address(this), repayAmount);
        emit Repaid(msg.sender, asset, repayAmount);
    }

    // Repay a borrower's debt and seize collateral if their health factor is below 1.
    function liquidate(address borrower, address debtAsset, address collateralAsset, uint256 debtToRepay)
        external nonReentrant returns (uint256 actualDebtRepaid, uint256 collateralSeized)
    {
        require(borrower != msg.sender, "Cannot self-liquidate");
        require(reserves[debtAsset].active && reserves[collateralAsset].active, "Unsupported asset");
        require(debtToRepay > 0, "Amount must be greater than zero");
        require(getHealthFactor(borrower) < HEALTH_FACTOR_SCALE, "Borrower is healthy");
        require(principal[debtAsset][borrower] + accruedInterest[debtAsset][borrower] > 0, "No debt in selected asset");
        require(collateralBalance[collateralAsset][borrower] > 0, "No collateral in selected asset");

        _accrueInterest(debtAsset, borrower);
        uint256 borrowerDebt = principal[debtAsset][borrower] + accruedInterest[debtAsset][borrower];
        uint256 closeLimit = (borrowerDebt * MAX_LIQUIDATION_CLOSE_FACTOR_BPS) / LTV_DENOMINATOR;
        if (closeLimit == 0) closeLimit = borrowerDebt;
        actualDebtRepaid = debtToRepay > closeLimit ? closeLimit : debtToRepay;
        if (actualDebtRepaid > borrowerDebt) actualDebtRepaid = borrowerDebt;

        uint256 debtValueUSD = _valueInUSD(debtAsset, actualDebtRepaid);
        uint256 seizeValueUSD = (debtValueUSD * (LTV_DENOMINATOR + LIQUIDATION_BONUS_BPS)) / LTV_DENOMINATOR;
        collateralSeized = (seizeValueUSD * (10 ** IERC20Metadata(collateralAsset).decimals())) / priceOracle.getPrice(collateralAsset);

        uint256 availableCollateral = collateralBalance[collateralAsset][borrower];
        if (collateralSeized > availableCollateral) {
            collateralSeized = availableCollateral;
            seizeValueUSD = _valueInUSD(collateralAsset, collateralSeized);
            actualDebtRepaid = (seizeValueUSD * LTV_DENOMINATOR) / (LTV_DENOMINATOR + LIQUIDATION_BONUS_BPS);
            actualDebtRepaid = (actualDebtRepaid * (10 ** IERC20Metadata(debtAsset).decimals())) / priceOracle.getPrice(debtAsset);
            if (actualDebtRepaid > borrowerDebt) actualDebtRepaid = borrowerDebt;
        }
        require(actualDebtRepaid > 0 && collateralSeized > 0, "Liquidation too small");

        // Reduce borrower debt, interest first, then principal.
        uint256 remaining = actualDebtRepaid;
        uint256 accrued = accruedInterest[debtAsset][borrower];
        if (remaining >= accrued) {
            remaining -= accrued;
            accruedInterest[debtAsset][borrower] = 0;
            principal[debtAsset][borrower] -= remaining;
        } else {
            accruedInterest[debtAsset][borrower] -= remaining;
        }
        reserves[debtAsset].totalBorrowed -= actualDebtRepaid;

        collateralBalance[collateralAsset][borrower] -= collateralSeized;
        totalCollateral[collateralAsset] -= collateralSeized;

        IERC20(debtAsset).safeTransferFrom(msg.sender, address(this), actualDebtRepaid);
        IERC20(collateralAsset).safeTransfer(msg.sender, collateralSeized);

        if (principal[debtAsset][borrower] == 0 && accruedInterest[debtAsset][borrower] == 0) {
            lastAccrualTimestamp[debtAsset][borrower] = 0;
        }

        emit Liquidated(msg.sender, borrower, debtAsset, collateralAsset, actualDebtRepaid, collateralSeized);
    }

    function _lenderLiquidity(address asset) internal view returns (uint256) {
        uint256 balance = IERC20(asset).balanceOf(address(this));
        if (balance <= totalCollateral[asset]) return 0;
        return balance - totalCollateral[asset];
    }

    function getUserSupply(address user, address asset) external view returns (uint256) {
        return suppliedBalance[asset][user];
    }

    function getTotalSupplied(address asset) external view returns (uint256) {
        return reserves[asset].totalSupplied;
    }

    function getUserBorrow(address user, address asset) external view returns (uint256) {
        return _currentDebt(asset, user);
    }

    function getTotalBorrowed(address asset) external view returns (uint256) {
        return reserves[asset].totalBorrowed;
    }

    function getAvailableLiquidity(address asset) external view returns (uint256) {
        return _lenderLiquidity(asset);
    }

    function getUserCollateral(address user, address asset) external view returns (uint256) {
        return collateralBalance[asset][user];
    }

    function getTotalCollateral(address asset) external view returns (uint256) {
        return totalCollateral[asset];
    }
}
