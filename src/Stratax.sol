// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IPool} from "./interfaces/external/IPool.sol";
import {IAggregationRouter} from "./interfaces/external/IAggregationRouter.sol";
import {IProtocolDataProvider} from "./interfaces/external/IProtocolDataProvider.sol";
import {IStrataxOracle} from "./interfaces/internal/IStrataxOracle.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

contract Stratax is Initializable {
    /*//////////////////////////////////////////////////////////////
                            TYPE DECLARATIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Enum for flash loan operation types
    enum OperationType {
        /// @notice Opening a new leveraged position
        OPEN,
        /// @notice Unwinding an existing leveraged position
        UNWIND
    }


    /// @notice Parameters for opening a leveraged position via flash loan
    struct FlashLoanParams {
        /// @notice Address of the token used as collateral
        address collateralToken;
        /// @notice Amount of additional collateral provided by user
        uint256 collateralAmount;
        /// @notice Address of the token to borrow from Aave
        address borrowToken;
        /// @notice Amount to borrow from Aave
        uint256 borrowAmount;
        /// @notice Encoded calldata for 1inch swap
        bytes oneInchSwapData;
        /// @notice Minimum acceptable amount from swap (slippage protection)
        uint256 minReturnAmount;
    }

    /// @notice Parameters for unwinding a leveraged position via flash loan
    struct UnwindParams {
        /// @notice Address of the collateral token held in Aave
        address collateralToken;
        /// @notice Amount of collateral to withdraw from Aave
        uint256 collateralToWithdraw;
        /// @notice Address of the debt token borrowed from Aave
        address debtToken;
        /// @notice Amount of debt to repay
        uint256 debtAmount;
        /// @notice Encoded calldata for 1inch swap
        bytes oneInchSwapData;
        /// @notice Minimum acceptable amount from swap (slippage protection)
        uint256 minReturnAmount;
    }

    /// @notice Parameters for calculating leveraged position details
    struct TradeDetails {
        /// @notice Address of the collateral token
        address collateralToken;
        /// @notice Address of the borrow token
        address borrowToken;
        /// @notice Desired leverage multiplier with 4 decimals (e.g., 30000 = 3x)
        uint256 desiredLeverage;
        /// @notice Amount of collateral the user will provide
        uint256 collateralAmount;
        /// @notice Price of collateral token in USD with 8 decimals
        uint256 collateralTokenPrice;
        /// @notice Price of borrow token in USD with 8 decimals
        uint256 borrowTokenPrice;
        /// @notice Number of decimals in the collateral token
        uint256 collateralTokenDec;
        /// @notice Number of decimals in the borrow token
        uint256 borrowTokenDec;
    }

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Constant for basis points calculations (100% = 10000)
    uint256 public constant FLASHLOAN_FEE_PREC = 10000;


    /// @notice Precision used for price feeds (8 decimals)
    uint256 public constant PRICE_FEED_PREC = 1e8;

    /// @notice Precision for loan-to-value ratios (4 decimals, e.g., 8000 = 80%)
    uint256 public constant LTV_PRECISION = 1e4;

    /// @notice Precision for leverage calculations (4 decimals, e.g., 30000 = 3x)
    uint256 public constant LEVERAGE_PRECISION = 1e4;


    /// @notice Safety margin for borrow calculations (9500 = 95% of max LTV)
    /// @dev This ensures positions have a healthy buffer and don't immediately risk liquidation
    uint256 public constant BORROW_SAFETY_MARGIN = 9500; // 95% of max

    /// @notice Aave lending pool interface for flash loans and lending operations
    IPool public aavePool;


    /// @notice Aave protocol data provider for querying reserve configurations
    IProtocolDataProvider public aaveDataProvider;

    /// @notice 1inch aggregation router interface for token swaps
    IAggregationRouter public oneInchRouter;

    /// @notice USDC token address
    address public USDC;

    /// @notice Address of the Stratax price oracle contract
    address public strataxOracle;

    /// @notice Contract owner address
    address public owner;

    /// @notice Flash loan fee in basis points (e.g., 9 = 0.09%)
    uint256 public flashLoanFeeBps;

    /// @notice Storage gap for future upgrades (reserve space for 50 new state variables)
    /// @dev This prevents storage collisions when adding new state variables in upgrades
    uint256[50] private __gap;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when a new leveraged position is created
    /// @param user Address of the user who created the position
    /// @param collateralToken Address of the collateral token
    /// @param borrowedToken Address of the borrowed token
    /// @param totalCollateralSupplied Total amount of collateral supplied to Aave
    /// @param borrowedAmount Amount borrowed from Aave
    /// @param healthFactor Final health factor of the position
    event LeveragePositionCreated(
        address indexed user,
        address collateralToken,
        address borrowedToken,
        uint256 totalCollateralSupplied,
        uint256 borrowedAmount,
        uint256 healthFactor
    );

    /// @notice Emitted when a leveraged position is unwound
    /// @param user Address of the user whose position was unwound
    /// @param collateralToken Address of the collateral token
    /// @param debtToken Address of the debt token
    /// @param debtRepaid Amount of debt repaid
    /// @param collateralReturned Amount of collateral withdrawn from Aave
    event PositionUnwound(
        address indexed user, address collateralToken, address debtToken, uint256 debtRepaid, uint256 collateralReturned
    );

    /*//////////////////////////////////////////////////////////////
                              MODIFIERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Restricts function access to contract owner only
    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        // TODO: Contract ownership will be handled in ERC721 style so open positions will be transferrable
        _;
    }

    /*//////////////////////////////////////////////////////////////
                            INITIALIZER
    //////////////////////////////////////////////////////////////*/

    /// @notice Initializes the Stratax contract with required protocol addresses
    /// @dev Can only be called once due to initializer modifier
    /// @param _aavePool Address of the Aave lending pool
    /// @param _aaveDataProvider Address of the Aave protocol data provider
    /// @param _oneInchRouter Address of the 1inch aggregation router
    /// @param _usdc Address of the USDC token
    /// @param _strataxOracle Address of the Stratax price oracle
    function initialize(
        address _aavePool,
        address _aaveDataProvider,
        address _oneInchRouter,
        address _usdc,
        address _strataxOracle
    ) external initializer {
        aavePool = IPool(_aavePool);
        aaveDataProvider = IProtocolDataProvider(_aaveDataProvider);
        oneInchRouter = IAggregationRouter(_oneInchRouter);
        USDC = _usdc;
        strataxOracle = _strataxOracle;
        owner = msg.sender;
        flashLoanFeeBps = 9; // Default 0.09% Aave flash loan fee
    }

    /*//////////////////////////////////////////////////////////////
                        EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Callback function called by Aave after receiving flash loan
     * @param _asset The flash loaned asset address
     * @param _amount The flash loan amount
     * @param _premium The flash loan fee
     * @param _initiator The initiator of the flash loan
     * @param _params Encoded parameters for the operation
     * @return bool Returns true if operation succeeds
     */
    function executeOperation(
        address _asset,
        uint256 _amount,
        uint256 _premium,
        address _initiator,
        bytes calldata _params
    ) external returns (bool) {
        require(msg.sender == address(aavePool), "Caller must be Aave Pool");
        require(_initiator == address(this), "Initiator must be this contract");

        // Decode operation type
        OperationType opType = abi.decode(_params, (OperationType));

        if (opType == OperationType.OPEN) {
            return _executeOpenOperation(_asset, _amount, _premium, _params);
        } else {
            return _executeUnwindOperation(_asset, _amount, _premium, _params);
        }
    }

    /**
     * @notice Unwinds a leveraged position by:
     * 1. Taking a flash loan of the debt token
     * 2. Repaying the Aave debt
     * 3. Withdrawing all collateral from Aave
     * 4. Swapping collateral back to debt token
     * 5. Repaying the flash loan
     * @param _collateralToken The collateral token held in Aave
     * @param _collateralToWithdraw The amount of collateral to withdraw from Aave
     * @param _debtToken The debt token borrowed from Aave
     * @param _debtAmount The amount of debt to repay
     * @param _oneInchSwapData The calldata from 1inch API to swap collateral back to debt token
     * @param _minReturnAmount Minimum amount of debt token expected from swap (slippage protection)
     */
    function unwindPosition(
        address _collateralToken,
        uint256 _collateralToWithdraw,
        address _debtToken,
        uint256 _debtAmount,
        bytes calldata _oneInchSwapData,
        uint256 _minReturnAmount
    ) external onlyOwner {
        UnwindParams memory params = UnwindParams({
            collateralToken: _collateralToken,
            collateralToWithdraw: _collateralToWithdraw,
            debtToken: _debtToken,
            debtAmount: _debtAmount,
            oneInchSwapData: _oneInchSwapData,
            minReturnAmount: _minReturnAmount
        });

        bytes memory encodedParams = abi.encode(OperationType.UNWIND, msg.sender, params);

        // Initiate flash loan of the debt token to repay Aave
        aavePool.flashLoanSimple(address(this), _debtToken, _debtAmount, encodedParams, 0);
    }

    /**
     * @notice Sets the Stratax Oracle address
     * @param _strataxOracle The new oracle address
     */
    function setStrataxOracle(address _strataxOracle) external onlyOwner {
        require(_strataxOracle != address(0), "Invalid oracle address");
        strataxOracle = _strataxOracle;
    }

    /**
     * @notice Sets the flash loan fee in basis points
     * @param _flashLoanFeeBps The flash loan fee in basis points (e.g., 9 = 0.09%)
     */
    function setFlashLoanFee(uint256 _flashLoanFeeBps) external onlyOwner {
        require(_flashLoanFeeBps < FLASHLOAN_FEE_PREC, "Fee must be < 100%");
        flashLoanFeeBps = _flashLoanFeeBps;
    }

    /**
     * @notice Emergency function to recover tokens sent to contract
     * @param _token The token address to recover
     * @param _amount The amount to recover
     */
    function recoverTokens(address _token, uint256 _amount) external onlyOwner {
        IERC20(_token).transfer(owner, _amount);
    }

    /**
     * @notice Updates the owner address
     * @param _newOwner The new owner address
     */
    function transferOwnership(address _newOwner) external onlyOwner {
        require(_newOwner != address(0), "Invalid address");
        owner = _newOwner;
    }

    /*//////////////////////////////////////////////////////////////
                        PUBLIC FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Creates a leveraged position by:
     * 1. Taking a flash loan
     * 2. Supplying flash loan + user's extra amount as collateral
     * 3. Borrowing against the collateral
     * 4. Swapping borrowed tokens via 1inch
     * 5. Repaying flash loan with swap proceeds
     * @param _flashLoanToken The token to flash loan (will be used as collateral)
     * @param _flashLoanAmount The amount to flash loan
     * @param _collateralAmount Additional amount from user to supply as collateral
     * @param _borrowToken The token to borrow from Aave against collateral
     * @param _borrowAmount The amount to borrow from Aave
     * @param _oneInchSwapData The calldata from 1inch API to swap borrowed token back to flash loan token
     * @param _minReturnAmount Minimum amount expected from swap (slippage protection)
     */
    function createLeveragedPosition(
        address _flashLoanToken,
        uint256 _flashLoanAmount,
        uint256 _collateralAmount,
        address _borrowToken,
        uint256 _borrowAmount, 
        bytes calldata _oneInchSwapData,
        uint256 _minReturnAmount
    ) public onlyOwner {
        require(_collateralAmount > 0, "Collateral Cannot be Zero");
        // Transfer the user's collateral to the contract
        IERC20(_flashLoanToken).transferFrom(msg.sender, address(this), _collateralAmount);

        FlashLoanParams memory params = FlashLoanParams({
            collateralToken: _flashLoanToken,
            collateralAmount: _collateralAmount,
            borrowToken: _borrowToken,
            borrowAmount: _borrowAmount,
            oneInchSwapData: _oneInchSwapData,
            minReturnAmount: _minReturnAmount
        });

        bytes memory encodedParams = abi.encode(OperationType.OPEN, msg.sender, params);

        // Initiate flash loan
        aavePool.flashLoanSimple(address(this), _flashLoanToken, _flashLoanAmount, encodedParams, 0);
    }

    /**
     * @notice Calculates the maximum theoretical leverage for a given LTV
     * @param _ltv The loan-to-value ratio with 4 decimals (e.g., 8000 = 80%)
     * @return maxLeverage The maximum leverage with 4 decimals (e.g., 50000 = 5x)
     */
    function getMaxLeverage(uint256 _ltv) public pure returns (uint256 maxLeverage) {
        require(_ltv > 0 && _ltv < LTV_PRECISION, "Invalid LTV");

        // Maximum leverage = 1 / (1 - LTV)
        // With 4 decimal precision: maxLeverage = 10000 / (10000 - ltv)
        maxLeverage = (LEVERAGE_PRECISION * LEVERAGE_PRECISION) / (LTV_PRECISION - _ltv);
    }

    /**
     * @notice Calculates the maximum theoretical leverage for a specific asset on Aave
     * @param _asset The address of the collateral asset
     * @return maxLeverage The maximum leverage with 4 decimals (e.g., 50000 = 5x)
     */
    function getMaxLeverage(address _asset) public view returns (uint256 maxLeverage) {
        (, uint256 ltv,,,,,,,,) = aaveDataProvider.getReserveConfigurationData(_asset);
        require(ltv > 0, "Asset not usable as collateral");

        return getMaxLeverage(ltv);
    }

    /**
     * @notice Calculates the flash loan and borrow amounts needed to achieve desired leverage
     * @param details TradeDetails struct containing:
     *        - collateralToken: Address of the collateral token
     *        - desiredLeverage: The desired leverage multiplier with 4 decimals (e.g., 30000 = 3x)
     *        - collateralAmount: The amount of collateral the user will provide (in collateral token units)
     *        - collateralTokenPrice: Price of collateral token in USD with 8 decimals
     *        - borrowTokenPrice: Price of borrow token in USD with 8 decimals
     *        - collateralTokenDec: Decimals of the collateral token
     *        - borrowTokenDec: Decimals of the borrow token
     * @return flashLoanAmount The amount to flash loan (in collateral token units)
     * @return borrowAmount The amount to borrow from Aave (in borrow token units)
     */
    function calculateOpenParams(TradeDetails memory details)
        public
        view
        returns (uint256 flashLoanAmount, uint256 borrowAmount)
    {
        // Get LTV from Aave for the collateral token
        (, uint256 ltv,,,,,,,,) = aaveDataProvider.getReserveConfigurationData(details.collateralToken);
        require(ltv > 0, "Asset not usable as collateral");

        require(details.desiredLeverage >= LEVERAGE_PRECISION, "Leverage must be >= 1x");
        require(details.collateralAmount > 0, "Collateral must be > 0");

        // If collateral token price is zero, fetch it from the oracle
        if (details.collateralTokenPrice == 0) {
            require(strataxOracle != address(0), "Oracle not set");
            details.collateralTokenPrice = IStrataxOracle(strataxOracle).getPrice(details.collateralToken);
        }
        require(details.collateralTokenPrice > 0, "Collateral token price must be > 0");

        // If borrow token price is zero, fetch it from the oracle
        if (details.borrowTokenPrice == 0) {
            require(strataxOracle != address(0), "Oracle not set");
            details.borrowTokenPrice = IStrataxOracle(strataxOracle).getPrice(details.borrowToken);
        }
        require(details.borrowTokenPrice > 0, "Borrow token price must be > 0");

        // Calculate maximum theoretical leverage and validate desired leverage
        uint256 maxLeverage = getMaxLeverage(ltv);
        require(details.desiredLeverage <= maxLeverage, "Desired leverage exceeds maximum");

        // Flash loan amount = collateral × (leverage - 1)
        // flashLoanAmount = C × (L - 1) / LEVERAGE_PRECISION
        flashLoanAmount =
            (details.collateralAmount * (details.desiredLeverage - LEVERAGE_PRECISION)) / LEVERAGE_PRECISION;

        // Total collateral to supply = user collateral + flash loan
        uint256 totalCollateral = details.collateralAmount + flashLoanAmount;

        // Calculate total collateral value in USD (with proper decimal handling)
        // totalCollateralValueUSD = (totalCollateral * collateralPrice) / (10^collateralDec)
        // Result is in USD with 8 decimals
        uint256 totalCollateralValueUSD =
            (totalCollateral * details.collateralTokenPrice) / (10 ** details.collateralTokenDec);

        // Calculate borrow value in USD (with 8 decimals)
        // Apply safety margin to ensure healthy position: borrowValueUSD = (totalCollateralValueUSD * ltv * BORROW_SAFETY_MARGIN) / (LTV_PRECISION * 10000)
        uint256 borrowValueUSD = (totalCollateralValueUSD * ltv * BORROW_SAFETY_MARGIN) / (LTV_PRECISION * 10000);

        // Convert borrow value to borrow token amount
        // borrowAmount = (borrowValueUSD * 10^borrowTokenDec) / borrowTokenPrice
        borrowAmount = (borrowValueUSD * (10 ** details.borrowTokenDec)) / details.borrowTokenPrice;

        // Ensure borrow amount when swapped back covers flash loan + fee
        uint256 flashLoanFee = (flashLoanAmount * flashLoanFeeBps) / FLASHLOAN_FEE_PREC;
        uint256 minRequiredAfterSwap = flashLoanAmount + flashLoanFee;

        // Calculate the value of borrowed tokens in collateral token terms
        // borrowValueInCollateral = (borrowAmount * borrowPrice * 10^collateralDec) / (collateralPrice * 10^borrowDec)
        uint256 borrowValueInCollateral = (borrowAmount * details.borrowTokenPrice * (10 ** details.collateralTokenDec))
            / (details.collateralTokenPrice * (10 ** details.borrowTokenDec));

        require(borrowValueInCollateral >= minRequiredAfterSwap, "Insufficient borrow to repay flash loan");

        return (flashLoanAmount, borrowAmount);
    }

    /**
     * @notice Calculates the amount of collateral to withdraw and debt to repay for unwinding a position
     * @param _collateralToken The address of the collateral token
     * @param _borrowToken The address of the borrowed token
     * @return collateralToWithdraw The amount of collateral to withdraw from Aave
     * @return debtAmount The total debt amount to repay
     */
    function calculateUnwindParams(address _collateralToken, address _borrowToken)
        public
        view
        returns (uint256 collateralToWithdraw, uint256 debtAmount)
    {
        // Get the address of the debt token
        (,, address debtToken) = aaveDataProvider.getReserveTokensAddresses(_borrowToken);
        debtAmount = IERC20(debtToken).balanceOf(address(this));
        uint256 debtTokenPrice = IStrataxOracle(strataxOracle).getPrice(_borrowToken);
        uint256 collateralTokenPrice = IStrataxOracle(strataxOracle).getPrice(_collateralToken);

        collateralToWithdraw = (debtTokenPrice * debtAmount * 10 ** IERC20(_collateralToken).decimals())
            / (collateralTokenPrice * 10 ** IERC20(_borrowToken).decimals());

        // Account for 5% slippage in swap
        collateralToWithdraw = (collateralToWithdraw * 1050) / 1000;

        return (collateralToWithdraw, debtAmount);
    }

    /*//////////////////////////////////////////////////////////////
                        INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Internal function to handle opening a leveraged position
     * @dev Executes the flash loan callback logic for opening positions
     * @param _asset The flash loaned asset address
     * @param _amount The flash loan amount
     * @param _premium The flash loan fee
     * @param _params Encoded parameters containing operation type and FlashLoanParams
     * @return bool Returns true if operation succeeds
     */
    function _executeOpenOperation(address _asset, uint256 _amount, uint256 _premium, bytes calldata _params)
        internal
        returns (bool)
    {
        (, address user, FlashLoanParams memory flashParams) =
            abi.decode(_params, (OperationType, address, FlashLoanParams));

        // Step 1: Supply flash loan amount + user's extra amount to Aave as collateral
        uint256 totalCollateral = _amount + flashParams.collateralAmount;
        IERC20(_asset).approve(address(aavePool), totalCollateral);
        aavePool.supply(_asset, totalCollateral, address(this), 0);

        // Store initial balance to verify all borrowed tokens are used in swap
        uint256 prevBorrowTokenBalance = IERC20(flashParams.borrowToken).balanceOf(address(this));
        // Step 2: Borrow against the supplied collateral
        aavePool.borrow(
            flashParams.borrowToken,
            flashParams.borrowAmount,
            2, // Variable interest rate mode
            0,
            address(this)
        );

        // Step 3: Swap borrowed tokens via 1inch to get back the collateral token
        IERC20(flashParams.borrowToken).approve(address(oneInchRouter), flashParams.borrowAmount);

        // Execute swap via 1inch
        uint256 returnAmount =
            _call1InchSwap(flashParams.oneInchSwapData, flashParams.borrowToken, flashParams.minReturnAmount);

        // Ensure all borrowed tokens were used in the swap
        uint256 afterSwapBorrowTokenbalance = IERC20(flashParams.borrowToken).balanceOf(address(this));
        require(afterSwapBorrowTokenbalance == prevBorrowTokenBalance, "Borrow token left in contract");

        // Step 4: Repay flash loan
        uint256 totalDebt = _amount + _premium;
        require(returnAmount >= totalDebt, "Insufficient funds to repay flash loan");

        // Step 5: Check health factor of user's position
        (,,,,, uint256 healthFactor) = aavePool.getUserAccountData(address(this));
        require(healthFactor > 1e18, "Position health factor too low");

        // Supply any leftover tokens back to Aave to improve position health
        if (returnAmount - totalDebt > 0) {
            IERC20(_asset).approve(address(aavePool), returnAmount - totalDebt);
            aavePool.supply(_asset, returnAmount - totalDebt, address(this), 0);
        }

        IERC20(_asset).approve(address(aavePool), totalDebt);

        emit LeveragePositionCreated(
            user, _asset, flashParams.borrowToken, totalCollateral, flashParams.borrowAmount, healthFactor
        );

        return true;
    }

    /**
     * @notice Internal function to handle unwinding a leveraged position
     * @dev Executes the flash loan callback logic for unwinding positions
     * @param _asset The flash loaned asset address
     * @param _amount The flash loan amount
     * @param _premium The flash loan fee
     * @param _params Encoded parameters containing operation type and UnwindParams
     * @return bool Returns true if operation succeeds
     */
    function _executeUnwindOperation(address _asset, uint256 _amount, uint256 _premium, bytes calldata _params)
        internal
        returns (bool)
    {
        (, address user, UnwindParams memory unwindParams) = abi.decode(_params, (OperationType, address, UnwindParams));

        // Step 1: Repay the Aave debt using flash loaned tokens
        IERC20(_asset).approve(address(aavePool), _amount);
        aavePool.repay(_asset, _amount, 2, address(this));

        // Step 2: Calculate and withdraw only the collateral that backed the repaid debt
        uint256 withdrawnAmount;
        {
            // Get LTV from Aave for the collateral token
            (,, uint256 liqThreshold,,,,,,,) =
                aaveDataProvider.getReserveConfigurationData(unwindParams.collateralToken);

            // Get prices and decimals
            uint256 debtTokenPrice = IStrataxOracle(strataxOracle).getPrice(_asset);
            uint256 collateralTokenPrice = IStrataxOracle(strataxOracle).getPrice(unwindParams.collateralToken);
            require(debtTokenPrice > 0 && collateralTokenPrice > 0, "Invalid prices");

            // Calculate collateral to withdraw: (debtAmount * debtPrice * collateralDec * LTV_PRECISION) / (collateralPrice * debtDec * ltv)
            uint256 collateralToWithdraw = (
                _amount * debtTokenPrice * (10 ** IERC20(unwindParams.collateralToken).decimals()) * LTV_PRECISION
            ) / (collateralTokenPrice * (10 ** IERC20(_asset).decimals()) * liqThreshold);

            withdrawnAmount = aavePool.withdraw(unwindParams.collateralToken, collateralToWithdraw, address(this));
        }

        // Step 3: Swap collateral to debt token to repay flash loan
        IERC20(unwindParams.collateralToken).approve(address(oneInchRouter), withdrawnAmount);
        uint256 returnAmount = _call1InchSwap(unwindParams.oneInchSwapData, _asset, unwindParams.minReturnAmount);

        // Step 4: Repay flash loan
        uint256 totalDebt = _amount + _premium;
        require(returnAmount >= totalDebt, "Insufficient funds to repay flash loan");

        // Supply any leftover tokens back to Aave
        // Note: There might be other positions open, so unwinding one position will increase the health factor
        if (returnAmount - totalDebt > 0) {
            IERC20(_asset).approve(address(aavePool), returnAmount - totalDebt);
            aavePool.supply(_asset, returnAmount - totalDebt, address(this), 0);
        }

        IERC20(_asset).approve(address(aavePool), totalDebt);

        emit PositionUnwound(user, unwindParams.collateralToken, _asset, _amount, withdrawnAmount);

        return true;
    }

    /**
     * @notice Internal function to execute a token swap via 1inch
     * @dev Performs low-level call to 1inch router and validates return amount
     * @param _swapParams Encoded calldata for the 1inch swap
     * @param _asset Address of the asset being swapped to
     * @param _minReturnAmount Minimum acceptable return amount (slippage protection)
     * @return returnAmount Actual amount received from the swap
     */
    function _call1InchSwap(bytes memory _swapParams, address _asset, uint256 _minReturnAmount)
        internal
        returns (uint256 returnAmount)
    {
        // Execute the 1inch swap using low-level call with the calldata from the API
        (bool success, bytes memory result) = address(oneInchRouter).call(_swapParams);
        require(success, "1inch swap failed");

        // Decode the return amount from the swap
        if (result.length > 0) {
            (returnAmount,) = abi.decode(result, (uint256, uint256));
        } else {
            // If no return data, check balance
            returnAmount = IERC20(_asset).balanceOf(address(this));
        }
        // Sanity check
        require(returnAmount >= _minReturnAmount, "Insufficient return amount from swap");
        return returnAmount;
    }
}
