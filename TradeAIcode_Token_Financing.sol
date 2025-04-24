// SPDX-License-Identifier: MIT
pragma solidity ^0.8.11;

// OpenZeppelin Imports (using specific commit for reproducibility)
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.9.3/contracts/utils/Context.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.9.3/contracts/token/ERC20/IERC20.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.9.3/contracts/utils/Address.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.9.3/contracts/utils/math/SafeMath.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.9.3/contracts/access/Ownable.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.9.3/contracts/token/ERC20/utils/SafeERC20.sol";

// Uniswap V2 Interfaces (Imported directly from GitHub)
import "https://github.com/Uniswap/v2-core/blob/master/contracts/interfaces/IUniswapV2Factory.sol";
import "https://github.com/Uniswap/v2-core/blob/master/contracts/interfaces/IUniswapV2Pair.sol";
import "https://github.com/Uniswap/v2-periphery/blob/master/contracts/interfaces/IUniswapV2Router02.sol";

/**
 * @title JARVI_Token_Financing
 * @dev Implementation of an ERC20 token with reflection, auto-liquidity, fees,
 * and basic security improvements. Autofinancing model.
 * Handles swapAndLiquify slippage failures by emitting an event and allowing the original tx to proceed.
 * Requires owner intervention via withdrawStuckETH() to recover ETH from such failures.
 * Includes function to recover mistakenly sent ERC20 tokens.
 * @notice This contract still holds significant centralization risks due to owner privileges.
 * Consider using a Timelock + Multisig for critical changes and asset recovery.
 */
contract JARVI_Token_Financing is Context, IERC20, Ownable {
    using SafeMath for uint256;
    using Address for address;
    using SafeERC20 for IERC20;

    // --- Custom Errors ---
    error ZeroAddress();
    error AmountMustBeGreaterThanZero();
    error TransferAmountExceedsLimit();
    error ExceedsMaximumWallet();
    error InsufficientAllowance();
    error AccountAlreadyExcluded();
    error AccountNotExcluded();
    error CannotExcludeAdminOrContract();
    error ExcludedAddressesCannotCall(); // Not currently used, but kept for potential future use
    error AmountMustBeLessThanSupply();
    error AmountMustBeLessThanReflections();
    error TotalFeesExceedLimit();
    error SlippageToleranceExceedsLimit();
    error SwapAmountTooLow();
    error SwapOutputBelowMinimum(); // Defined, but not used to revert in swapAndLiquify with Option A
    error ETHWithdrawalFailed();
    error FailedToSendETH(); // Potentially useful if using sendValue directly
    error CannotRecoverNativeToken();
    error InsufficientRecoveryBalance();
    error InvalidRouter(); // Added for router checks
    error PairCreationFailed(); // Added for pair check

    // --- State Variables ---
    mapping(address => uint256) private _rOwned; // Reflected balances
    mapping(address => uint256) private _tOwned; // Actual token balances for reward-excluded addresses
    mapping(address => mapping(address => uint256)) private _allowances;
    mapping(address => bool) private _isExcludedFromFee; // Excluded from paying fees
    mapping(address => bool) private _isExcluded; // Excluded from receiving reflection rewards
    address[] private _excluded; // Array of addresses excluded from rewards

    uint256 private constant MAX = ~uint256(0);
    uint256 private _tTotal; // Total supply in actual token amount
    uint256 private _rTotal; // Total supply in reflected amount (decreases with reflections)
    uint256 private _tFeeTotal; // Total fees collected (for reflection calculation?) - Review if needed

    string private _name;
    string private _symbol;
    uint8 private _decimals;

    // Fees in Basis Points (BPS), e.g., 100 BPS = 1%
    uint256 private _reflectionFeeBps;
    uint256 private _liquidityFeeBps;
    uint256 private _devFeeBps;
    // Variables to potentially restore fees if temporarily set to 0 - used in _tokenTransfer
    uint256 private _previousReflectionFeeBps;
    uint256 private _previousLiquidityFeeBps;
    uint256 private _previousDevFeeBps;

    // Constants for limits
    uint256 public constant MAX_TOTAL_FEES_BPS = 2500; // Max 25% total fees allowed
    uint256 public constant MAX_SLIPPAGE_TOLERANCE_BPS = 1000; // Max 10% slippage allowed

    // Wallets for fee distribution
    address public devWalletAddress; // Receives 1/3 dev fee + remainder
    address public liqWalletAddress; // Receives liquidity fee tokens (used by contract for swapAndLiquify)
    address public mkWalletAddress;  // Receives 1/3 dev fee
    address public chaWalletAddress; // Receives 1/3 dev fee

    // Anti-whale and swap threshold variables
    uint256 public maxTxAmount;     // Max tokens per transaction
    uint256 public maxWalletToken;  // Max tokens per wallet
    uint256 public numTokensSellToAddToLiquidity; // Amount of tokens contract processes in swapAndLiquify
    uint256 public minTokensBeforeSwap; // Threshold balance for contract to trigger swapAndLiquify

    // Uniswap Integration
    IUniswapV2Router02 public uniswapV2Router;
    address public uniswapV2Pair; // Address of the TKN/WETH pair

    // Swap and Liquify control
    bool public swapAndLiquifyEnabled = true;
    uint256 private _slippageToleranceBps = 200; // Default 2% slippage tolerance
    bool internal inSwapAndLiquify; // Mutex lock for swapAndLiquify

    // --- Events ---
    event FeesUpdated(uint256 reflectionFeeBps, uint256 liquidityFeeBps, uint256 devFeeBps);
    event FeeWalletUpdated(uint8 indexed walletType, address newAddress); // Cambiado a uint8
    event LimitsUpdated(uint256 newMaxTx, uint256 newMaxWallet);
    event ExcludedFromFee(address indexed account, bool isExcluded);
    event ExcludedFromReward(address indexed account, bool isExcluded);
    event SwapAndLiquifyEnabledUpdated(bool enabled);
    event MinTokensBeforeSwapUpdated(uint256 minTokens);
    event SlippageToleranceUpdated(uint256 newSlippageBps);
    event SwapAndLiquify(uint256 tokensSwapped, uint256 ethReceived, uint256 tokensIntoLiquidity); // Success
    event RouterAddressUpdated(address indexed newRouter, address indexed newPair);
    event AutoLiquifySlippageFailure(uint256 tokensSold, uint256 ethReceived, uint256 minEthRequired); // Slippage Failure
    event EthWithdrawn(address indexed recipient, uint256 amount); // ETH Withdrawal
    event TokensRecovered(address indexed tokenRecovered, address indexed recipient, uint256 amount); // ERC20 Recovery

    // --- Modifier ---
    modifier lockTheSwap {
        if (inSwapAndLiquify) revert("Swap lock engaged"); // Prevent re-entrancy explicitly
        inSwapAndLiquify = true;
        _;
        inSwapAndLiquify = false;
    }

    // --- Constructor ---
    constructor (
        string memory tokenName,
        string memory tokenSymbol,
        uint8 tokenDecimals,
        uint256 initialSupply, // Supply WITHOUT decimals
        uint256 reflectionFeePercent, // Percentage, e.g., 5 for 5%
        uint256 liquidityFeePercent,
        uint256 devFeePercent,
        address routerAddress,
        address initialDevWallet,
        address initialLiqWallet,
        address initialMkWallet,
        address initialChaWallet,
        address tokenOwner
    ) {
        // Basic address checks
        if (routerAddress == address(0) || initialDevWallet == address(0) ||
            initialLiqWallet == address(0) || initialMkWallet == address(0) ||
            initialChaWallet == address(0) || tokenOwner == address(0)) revert ZeroAddress();

        // Set token metadata
        _name = tokenName;
        _symbol = tokenSymbol;
        _decimals = tokenDecimals;

        // Calculate total supply and reflection supply
        uint256 supply = initialSupply * (10 ** uint256(tokenDecimals));
        if (supply == 0) revert AmountMustBeGreaterThanZero(); // Supply must be > 0
        _tTotal = supply;
        _rTotal = (MAX - (MAX % _tTotal)); // Calculate initial reflected supply

        // Check and set fees (converted to basis points)
        uint256 totalFeesPercent = reflectionFeePercent + liquidityFeePercent + devFeePercent; // Using SafeMath not strictly needed for adds here
        if (totalFeesPercent > (MAX_TOTAL_FEES_BPS / 100)) revert TotalFeesExceedLimit();
        _reflectionFeeBps = reflectionFeePercent * 100; // Convert to BPS
        _liquidityFeeBps = liquidityFeePercent * 100;
        _devFeeBps = devFeePercent * 100;
        _previousReflectionFeeBps = _reflectionFeeBps; // Initialize previous fees
        _previousLiquidityFeeBps = _liquidityFeeBps;
        _previousDevFeeBps = _devFeeBps;

        // Set fee wallets
        devWalletAddress = initialDevWallet;
        liqWalletAddress = initialLiqWallet;
        mkWalletAddress = initialMkWallet;
        chaWalletAddress = initialChaWallet;

        // Set initial limits and swap threshold relative to supply
        maxTxAmount = supply * 2 / 100; // Example: 2%
        maxWalletToken = supply * 4 / 100; // Example: 4%
        minTokensBeforeSwap = supply * 1 / 1000; // Example: 0.1%
        // Ensure basic sanity for limits if supply is very small
        if (maxTxAmount == 0 && supply > 0) maxTxAmount = supply; // Allow full transfer if % is too small
        if (maxWalletToken == 0 && supply > 0) maxWalletToken = supply;
        if (minTokensBeforeSwap == 0 && supply > 0) minTokensBeforeSwap = 1; // Minimum 1 token threshold if possible
        numTokensSellToAddToLiquidity = minTokensBeforeSwap;

        // Assign total supply to the designated token owner
        _rOwned[tokenOwner] = _rTotal;

        // Setup Uniswap Router and create Pair
        IUniswapV2Router02 _uniswapV2Router = IUniswapV2Router02(routerAddress);
        uniswapV2Router = _uniswapV2Router;
        address factoryAddress;
        address wethAddress;
        try _uniswapV2Router.factory() returns (address _factory) { factoryAddress = _factory; } catch { revert InvalidRouter(); }
        try _uniswapV2Router.WETH() returns (address _weth) { wethAddress = _weth; } catch { revert InvalidRouter(); }
        if (factoryAddress == address(0) || wethAddress == address(0)) revert InvalidRouter();

        uniswapV2Pair = IUniswapV2Factory(factoryAddress)
            .createPair(address(this), wethAddress);
        if (uniswapV2Pair == address(0)) revert PairCreationFailed();

        // Exclude critical addresses from fees and rewards
        // Use internal functions directly to bypass checks/events during setup
        _isExcludedFromFee[tokenOwner] = true;
        _isExcludedFromFee[address(this)] = true;
        _isExcludedFromFee[devWalletAddress] = true;
        _isExcludedFromFee[liqWalletAddress] = true;
        _isExcludedFromFee[mkWalletAddress] = true;
        _isExcludedFromFee[chaWalletAddress] = true;
        // No need to explicitly emit ExcludedFromFee events here

        _excludeFromRewardInternal(tokenOwner);
        _excludeFromRewardInternal(address(this));
        _excludeFromRewardInternal(devWalletAddress);
        _excludeFromRewardInternal(liqWalletAddress);
        _excludeFromRewardInternal(mkWalletAddress);
        _excludeFromRewardInternal(chaWalletAddress);
        _excludeFromRewardInternal(uniswapV2Pair);

        // Set contract ownership via Ownable library
        // Ownable's constructor sets msg.sender as owner initially
        if (msg.sender != tokenOwner) {
            transferOwnership(tokenOwner); // Transfer ownership if deployer is not the intended owner
        } else {
            // If deployer IS the intended owner, manually emit event as Ownable constructor is silent
            emit OwnershipTransferred(address(0), tokenOwner);
        }

        // Emit the ERC20 Transfer event for token creation
        emit Transfer(address(0), tokenOwner, _tTotal);
    }

    // --- External View Functions ---
    function name() public view returns (string memory) { return _name; }
    function symbol() public view returns (string memory) { return _symbol; }
    function decimals() public view returns (uint8) { return _decimals; }
    function totalSupply() public view override returns (uint256) { return _tTotal; }
    function allowance(address owner, address spender) public view override returns (uint256) { return _allowances[owner][spender]; }
    function isExcludedFromFee(address account) public view returns(bool) { return _isExcludedFromFee[account]; }
    function isExcludedFromReward(address account) public view returns (bool) { return _isExcluded[account]; }
    function totalFees() public view returns (uint256 reflectionFeeBps, uint256 liquidityFeeBps, uint256 devFeeBps) {
        return (_reflectionFeeBps, _liquidityFeeBps, _devFeeBps);
    }
     function getCurrentSlippageToleranceBps() external view returns (uint256) {
        return _slippageToleranceBps;
     }
    function balanceOf(address account) public view override returns (uint256) {
        if (_isExcluded[account]) return _tOwned[account];
        return tokenFromReflection(_rOwned[account]);
    }
    function tokenFromReflection(uint256 rAmount) public view returns(uint256) {
        if (rAmount > _rTotal) revert AmountMustBeLessThanReflections();
        uint256 currentRate = _getRate();
        if (currentRate == 0) return 0;
        return rAmount / currentRate; // SafeMath div not needed for view function potentially
    }
     function reflectionFromToken(uint256 tAmount, bool deductTransferFee) public view returns(uint256) {
        if (tAmount > _tTotal) revert AmountMustBeLessThanSupply();
        (uint256 rAmount, uint256 rTransferAmount,,,,,) = _getValues(tAmount);
        return deductTransferFee ? rTransferAmount : rAmount;
     }

    // --- External Transaction Functions ---
    function transfer(address recipient, uint256 amount) public override returns (bool) {
        _transfer(_msgSender(), recipient, amount);
        return true;
    }
    function approve(address spender, uint256 amount) public override returns (bool) {
        _approve(_msgSender(), spender, amount);
        return true;
    }
    function transferFrom(address sender, address recipient, uint256 amount) public override returns (bool) {
        uint256 currentAllowance = _allowances[sender][_msgSender()];
        if (currentAllowance < amount) revert InsufficientAllowance();
        _approve(sender, _msgSender(), currentAllowance.sub(amount)); // Decrease allowance first
        _transfer(sender, recipient, amount); // Then transfer
        return true;
    }
    function increaseAllowance(address spender, uint256 addedValue) public virtual returns (bool) {
        _approve(_msgSender(), spender, _allowances[_msgSender()][spender].add(addedValue));
        return true;
    }
    function decreaseAllowance(address spender, uint256 subtractedValue) public virtual returns (bool) {
        uint256 currentAllowance = _allowances[_msgSender()][spender];
        if (subtractedValue > currentAllowance) revert InsufficientAllowance(); // Check subtraction won't underflow
        _approve(_msgSender(), spender, currentAllowance.sub(subtractedValue));
        return true;
    }

    // --- Owner Functions ---
   /**
    * @dev Sets the fee percentages. Fees are in basis points (100 = 1%).
    * Total fees cannot exceed MAX_TOTAL_FEES_BPS.
    */
    function setFees(uint256 reflectionFeeBps, uint256 liquidityFeeBps, uint256 devFeeBps) external onlyOwner {
        uint256 totalFee = reflectionFeeBps + liquidityFeeBps + devFeeBps; // SafeMath not strictly needed if MAX_TOTAL_FEES_BPS is reasonable
        if (totalFee > MAX_TOTAL_FEES_BPS) revert TotalFeesExceedLimit();

        _reflectionFeeBps = reflectionFeeBps;
        _liquidityFeeBps = liquidityFeeBps;
        _devFeeBps = devFeeBps;

        // Update previous fees as well
        _previousReflectionFeeBps = _reflectionFeeBps;
        _previousLiquidityFeeBps = _liquidityFeeBps;
        _previousDevFeeBps = _devFeeBps;

        emit FeesUpdated(reflectionFeeBps, liquidityFeeBps, devFeeBps);
    }

    function setDevWalletAddress(address newAddress) external onlyOwner {
        if (newAddress == address(0)) revert ZeroAddress();
        devWalletAddress = newAddress;
        emit FeeWalletUpdated(0, newAddress); // Use 0 for dev type? Or use string?
    }
    function setLiqWalletAddress(address newAddress) external onlyOwner {
        if (newAddress == address(0)) revert ZeroAddress();
        liqWalletAddress = newAddress;
        emit FeeWalletUpdated(1, newAddress); // Use 1 for liq type?
    }
     function setMkWalletAddress(address newAddress) external onlyOwner {
        if (newAddress == address(0)) revert ZeroAddress();
        mkWalletAddress = newAddress;
        emit FeeWalletUpdated(2, newAddress); // Use 2 for mk type?
    }
     function setChaWalletAddress(address newAddress) external onlyOwner {
        if (newAddress == address(0)) revert ZeroAddress();
        chaWalletAddress = newAddress;
        emit FeeWalletUpdated(3, newAddress); // Use 3 for cha type?
        // Consider using string or enum in Event for clarity if needed
    }

    function setMaxTxAmount(uint256 newMaxTx) external onlyOwner {
        // Add reasonable upper bound check if desired (e.g., 50% of total supply)
        if (newMaxTx > _tTotal / 2) revert("Max TX cannot exceed 50% of total supply");
        if (newMaxTx == 0 && _tTotal > 0) revert AmountMustBeGreaterThanZero();
        maxTxAmount = newMaxTx;
        emit LimitsUpdated(maxTxAmount, maxWalletToken);
    }

     function setMaxWalletAmount(uint256 newMaxWallet) external onlyOwner {
        if (newMaxWallet > _tTotal / 2) revert("Max Wallet cannot exceed 50% of total supply");
        if (newMaxWallet == 0 && _tTotal > 0) revert AmountMustBeGreaterThanZero();
        if (newMaxWallet < maxTxAmount && maxTxAmount > 0) revert ("Max Wallet must be >= Max TX");
        maxWalletToken = newMaxWallet;
        emit LimitsUpdated(maxTxAmount, maxWalletToken);
    }

    function setSwapAndLiquifyEnabled(bool _enabled) external onlyOwner {
        swapAndLiquifyEnabled = _enabled;
        emit SwapAndLiquifyEnabledUpdated(_enabled);
    }

    function setMinTokensBeforeSwap(uint256 amount) external onlyOwner {
        if (amount == 0 && _tTotal > 0) revert AmountMustBeGreaterThanZero();
        // Ensure threshold makes sense relative to limits
        if (amount > maxTxAmount && maxTxAmount > 0) revert ("Min swap threshold cannot exceed Max TX");
        minTokensBeforeSwap = amount;
        numTokensSellToAddToLiquidity = amount; // Keep synced
        emit MinTokensBeforeSwapUpdated(amount);
    }

     function setSlippageToleranceBps(uint256 slippageBps) external onlyOwner {
        if (slippageBps > MAX_SLIPPAGE_TOLERANCE_BPS) revert SlippageToleranceExceedsLimit();
        _slippageToleranceBps = slippageBps;
        emit SlippageToleranceUpdated(slippageBps);
    }

    function excludeFromFee(address account, bool exclude) external onlyOwner {
        _excludeFromFee(account, exclude);
    }

     function excludeFromReward(address account) public onlyOwner() {
        if (account == address(this) || account == uniswapV2Pair ||
            account == devWalletAddress || account == liqWalletAddress ||
            account == mkWalletAddress || account == chaWalletAddress ||
            account == owner()) {
             revert CannotExcludeAdminOrContract();
        }
         if (_isExcluded[account]) revert AccountAlreadyExcluded();

        _excludeFromRewardInternal(account);
        emit ExcludedFromReward(account, true);
    }

    function includeInReward(address account) external onlyOwner() {
        if (!_isExcluded[account]) revert AccountNotExcluded();
        bool found = false;
        uint256 excludedCount = _excluded.length;
        for (uint256 i = 0; i < excludedCount; i++) {
            if (_excluded[i] == account) {
                _excluded[i] = _excluded[excludedCount - 1]; // Replace with last element
                _tOwned[account] = 0;
                _isExcluded[account] = false;
                _excluded.pop(); // Remove last element
                found = true;
                break;
            }
        }
        if (!found) revert AccountNotExcluded(); // Should be unreachable if logic is correct

         emit ExcludedFromReward(account, false);
    }


    function setRouterAddress(address newRouter) external onlyOwner {
        if (newRouter == address(0)) revert ZeroAddress();
        IUniswapV2Router02 _newUniswapV2Router = IUniswapV2Router02(newRouter);
        address _newFactory;
        address _weth;
        // Validate new router
        try _newUniswapV2Router.factory() returns (address factoryAddr) { _newFactory = factoryAddr; } catch { revert InvalidRouter(); }
        try _newUniswapV2Router.WETH() returns (address wethAddr) { _weth = wethAddr; } catch { revert InvalidRouter(); }
        if (_newFactory == address(0) || _weth == address(0)) revert InvalidRouter();

        // Create new pair
        address _newPair = IUniswapV2Factory(_newFactory).createPair(address(this), _weth);
        if (_newPair == address(0)) revert PairCreationFailed();

        // Update state
        uniswapV2Router = _newUniswapV2Router;
        uniswapV2Pair = _newPair;

        // Exclude the new pair from fees & rewards
         _excludeFromFee(_newPair, true);
         _excludeFromRewardInternal(_newPair);

        emit RouterAddressUpdated(newRouter, _newPair);
    }


    // --- Function to recover ETH sent to the contract ---
    /**
     * @dev Allows the owner to withdraw any ETH balance held by this contract.
     * Useful for recovering ETH from failed swapAndLiquify attempts (Option A)
     * or ETH sent accidentally to the contract address.
     * @notice Ensure the owner address is secure (Multisig + Timelock recommended).
     */
    function withdrawStuckETH() external onlyOwner {
        uint256 balance = address(this).balance;
        if (balance == 0) revert AmountMustBeGreaterThanZero();

        // Transfer the ETH balance to the owner using .call
        (bool success, ) = payable(owner()).call{value: balance}("");
        if (!success) revert ETHWithdrawalFailed();

        emit EthWithdrawn(owner(), balance);
    }


    // --- Function to recover OTHER ERC20 tokens sent to the contract address ---
    /**
     * @dev Allows the owner to recover *OTHER* ERC20 tokens mistakenly sent to this contract.
     * @notice This function is powerful and introduces risks if the owner key is compromised
     * or if the owner acts maliciously. Use with extreme caution.
     * HIGHLY RECOMMENDED: The owner address should be a Multisig + Timelock.
     * CANNOT be used to recover the native token of this contract (JARVI_Token_Financing).
     * @param _tokenAddress The contract address of the ERC20 token to recover.
     * @param _to The address where the recovered tokens should be sent.
     * @param _amount The amount of tokens to recover.
     */
    function recoverERC20Token(address _tokenAddress, address _to, uint256 _amount) external onlyOwner {
        // Input Validations
        if (_tokenAddress == address(0) || _to == address(0)) revert ZeroAddress();
        if (_amount == 0) revert AmountMustBeGreaterThanZero();
        if (_tokenAddress == address(this)) revert CannotRecoverNativeToken();

        // Check Balance
        IERC20 recoveryToken = IERC20(_tokenAddress);
        uint256 balance = recoveryToken.balanceOf(address(this));
        if (balance < _amount) revert InsufficientRecoveryBalance();

        // Perform Recovery Transfer using SafeERC20
        recoveryToken.safeTransfer(_to, _amount);

        // Emit Event
        emit TokensRecovered(_tokenAddress, _to, _amount);
    }


    // --- Internal Functions ---

    function _approve(address owner, address spender, uint256 amount) private {
        if (owner == address(0) || spender == address(0)) revert ZeroAddress();
        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }

    function _excludeFromFee(address account, bool exclude) internal {
        if (account == address(0)) revert ZeroAddress();
        _isExcludedFromFee[account] = exclude;
        emit ExcludedFromFee(account, exclude);
    }

    // Internal version without checks/event for constructor usage
    function _excludeFromRewardInternal(address account) internal {
         if (_isExcluded[account]) return;
         if (_rOwned[account] > 0) {
            _tOwned[account] = tokenFromReflection(_rOwned[account]);
        } else {
             _tOwned[account] = 0;
        }
        _isExcluded[account] = true;
        _excluded.push(account);
    }

    /**
     * @dev Central transfer function called by public transfer and transferFrom.
     * Handles swapAndLiquify trigger and delegates actual balance updates/fees to _tokenTransfer.
     */
    function _transfer(
        address from,
        address to,
        uint256 amount
    ) private {
        if (from == address(0) || to == address(0)) revert ZeroAddress();
        if (amount == 0) revert AmountMustBeGreaterThanZero();

        // --- Swap and Liquify Trigger Logic ---
        bool shouldSwap = false;
        // Only consider swapping if not already swapping, feature enabled, and not a buy from LP
        if (!inSwapAndLiquify && swapAndLiquifyEnabled && from != uniswapV2Pair) {
             uint256 contractTokenBalance = balanceOf(address(this));
             if (contractTokenBalance >= minTokensBeforeSwap) {
                  shouldSwap = true;
             }
        }

        // --- Perform Swap and Liquify if conditions met ---
        if (shouldSwap) {
             uint256 contractTokenBalance = balanceOf(address(this)); // Re-fetch balance in case of donations etc?
             uint256 amountToSwap = numTokensSellToAddToLiquidity > contractTokenBalance ? contractTokenBalance : numTokensSellToAddToLiquidity;
             if(amountToSwap >= 2) { // Need at least 2 tokens to split
                  // Call swapAndLiquify. Option A implemented: returns on slippage failure, doesn't revert _transfer.
                  swapAndLiquify(amountToSwap);
             }
        }

        // --- Fee Calculation & Actual Token Transfer ---
        // Determine if fees should apply to this specific transfer
        bool takeFee = !_isExcludedFromFee[from] && !_isExcludedFromFee[to];
        // Delegate the core logic including limit checks, fee processing, reflections, balance updates
        _tokenTransfer(from, to, amount, takeFee);
    }


    /**
     * @dev Internal function that handles the core transfer logic AFTER potential swapAndLiquify call.
     * Includes limit checks, fee calculations, reflections, and balance updates.
     * Separated from _transfer to manage complexity and swap trigger timing.
     */
    function _tokenTransfer(address sender, address recipient, uint256 amount, bool takeFee) private {
        // --- Limit Checks ---
        // Use a separate mapping for limit exclusions if needed, otherwise tie to fee exclusion?
        // Assuming fee-excluded are also limit-excluded for simplicity. Owner always bypasses.
        bool limitsApply = !_isExcludedFromFee[sender] && !_isExcludedFromFee[recipient] && sender != owner() && recipient != owner();

        if (limitsApply) {
            if (amount > maxTxAmount) revert TransferAmountExceedsLimit();

            uint256 recipientBalance = balanceOf(recipient);
            uint256 amountReceived = amount;
            if(takeFee) {
                (amountReceived,,,,,,) = _getValues(amount); // Get actual transfer amount after fees
            }
            if (recipientBalance.add(amountReceived) > maxWalletToken) revert ExceedsMaximumWallet();
        }

        // --- Apply/Remove Fees Temporarily for Calculation Scope ---
        uint256 previousRefFee = _reflectionFeeBps;
        uint256 previousLiqFee = _liquidityFeeBps;
        uint256 previousDevFee = _devFeeBps;

        if (!takeFee) {
           _reflectionFeeBps = 0;
           _liquidityFeeBps = 0;
           _devFeeBps = 0;
        }

        // --- Calculate Values and Update Balances ---
        (uint256 rAmount, uint256 rTransferAmount, uint256 rFee, uint256 tTransferAmount, uint256 tFee, uint256 tLiquidity, uint256 tDev) = _getValues(amount);

        // Update sender balance
        if (_isExcluded[sender]) {
            // Ensure sender has enough tOwned if excluded
            if (_tOwned[sender] < amount) revert("ERC20: transfer amount exceeds balance");
            _tOwned[sender] = _tOwned[sender].sub(amount);
        }
         // Ensure sender has enough rOwned (covers both excluded and non-excluded cases)
        if (_rOwned[sender] < rAmount) revert("ERC20: transfer amount exceeds balance");
        _rOwned[sender] = _rOwned[sender].sub(rAmount);

        // Update recipient balance
        if (_isExcluded[recipient]) {
            _tOwned[recipient] = _tOwned[recipient].add(tTransferAmount);
        }
        _rOwned[recipient] = _rOwned[recipient].add(rTransferAmount);

        // Process fees
        _takeLiquidity(tLiquidity);
        _takeDev(tDev);
        _reflectFee(rFee, tFee);

        // Emit standard ERC20 Transfer event
        emit Transfer(sender, recipient, tTransferAmount);

        // --- Restore fees ---
        if (!takeFee) {
            _reflectionFeeBps = previousRefFee;
            _liquidityFeeBps = previousLiqFee;
            _devFeeBps = previousDevFee;
        }
    }

    // --- Swap and Liquify ---
   /**
    * @dev Executes the swap and liquidity addition. Emits failure event if swap output is below minimum.
    * @notice Option A implemented: Does NOT revert parent transaction on slippage failure AFTER successful swap, requires withdrawStuckETH.
    * Internal failures within swapTokensForEth or addLiquidity WILL cause revert.
    */
   function swapAndLiquify(uint256 tokenAmount) private lockTheSwap {
       if (tokenAmount < 2) revert SwapAmountTooLow(); // Revert if not enough to split

       uint256 half = tokenAmount / 2; // Use standard division
       uint256 otherHalf = tokenAmount - half; // Subtracting is safe after division

       uint256 initialETHBalance = address(this).balance;
       uint256 minEthOutput = 0;

       // --- Call swapTokensForEth directly ---
       // If swapTokensForEth reverts internally (e.g., getAmountsOut failed, router swap fails),
       // the entire transaction will revert from this point.
       minEthOutput = swapTokensForEth(half);
       // Execution only continues if swapTokensForEth completed without reverting.

       // --- Check ETH received vs Minimum (Slippage Check Post-Swap) ---
       uint256 ethReceived = address(this).balance - initialETHBalance; // Safe sub since balance >= initial
       if (ethReceived < minEthOutput) {
           // Option A Behavior: Emit failure event for slippage and return early.
           // The original user transaction (_transfer) will continue.
           emit AutoLiquifySlippageFailure(half, ethReceived, minEthOutput);
           // ETH from the swap remains in the contract, requires withdrawStuckETH()
           return; // Exit without adding liquidity
       }

       // --- Call addLiquidity directly ---
       // Ensure we have tokens and sufficient ETH received to proceed
       if (otherHalf > 0 && ethReceived > 0) {
            // If addLiquidity reverts internally (e.g., router call fails),
            // the entire transaction will revert from this point.
           addLiquidity(otherHalf, ethReceived);
           // Only emit success if addLiquidity also succeeded without reverting.
           emit SwapAndLiquify(half, ethReceived, otherHalf);
       } else {
           // This case should be rare now: swap succeeded above minEthOutput,
           // but otherHalf became 0 (impossible if tokenAmount>=2) or ethReceived is 0 (contradicts check above).
           // If somehow reached, indicates only swap occurred.
            emit SwapAndLiquify(half, ethReceived, 0);
       }
   }


    /**
     * @dev Swaps tokens for ETH, respecting slippage tolerance. REVERTS on internal error.
     * @return minAmountOutETH Minimum ETH expected based on current reserves and slippage.
     */
    function swapTokensForEth(uint256 tokenAmount) private returns (uint256 minAmountOutETH) {
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = uniswapV2Router.WETH();

        // Get expected amounts
        uint[] memory amountsOut = uniswapV2Router.getAmountsOut(tokenAmount, path);
        // No need for try/catch here, if getAmountsOut fails, we *want* it to revert.

        if (amountsOut.length < 2 || amountsOut[1] == 0) revert("Invalid or zero amounts out");
        uint256 expectedOutput = amountsOut[1];

        // Calculate minimum acceptable ETH based on tolerance
        minAmountOutETH = expectedOutput * (10000 - _slippageToleranceBps) / 10000; // SafeMath not needed for constant BPS
        if (minAmountOutETH == 0 && expectedOutput > 0) {
             minAmountOutETH = 1; // Ensure minimum is at least 1 wei if expecting ETH
        }

        // Approve and Swap
        _approve(address(this), address(uniswapV2Router), tokenAmount);
        uniswapV2Router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            tokenAmount,
            minAmountOutETH, // Router will check this slippage internally too
            path,
            address(this),
            block.timestamp
        );
        // Return calculated minimum for checking in swapAndLiquify
        return minAmountOutETH;
    }

    /**
     * @dev Adds liquidity to the Uniswap pair. REVERTS on internal error.
     */
    function addLiquidity(uint256 tokenAmount, uint256 ethAmount) private {
        // Calculate minimums for adding liquidity based on tolerance
        uint256 tokenAmountMin = tokenAmount * (10000 - _slippageToleranceBps) / 10000;
        uint256 ethAmountMin = ethAmount * (10000 - _slippageToleranceBps) / 10000;
        if (tokenAmountMin == 0 && tokenAmount > 0) tokenAmountMin = 1;
        if (ethAmountMin == 0 && ethAmount > 0) ethAmountMin = 1;

        // Approve and Add Liquidity
        _approve(address(this), address(uniswapV2Router), tokenAmount);
        uniswapV2Router.addLiquidityETH{value: ethAmount}(
            address(this),
            tokenAmount,
            tokenAmountMin,
            ethAmountMin,
            owner(), // Send LP tokens to owner (Consider Multisig/Treasury)
            block.timestamp
        );
    }

    // --- Reflection and Fee Calculation ---
    /** @dev Calculates all fee values and transfer amounts for a given input amount */
    function _getValues(uint256 tAmount) private view returns (uint256 rAmount, uint256 rTransferAmount, uint256 rFee, uint256 tTransferAmount, uint256 tFee, uint256 tLiquidity, uint256 tDev) {
        (tTransferAmount, tFee, tLiquidity, tDev) = _getTValues(tAmount);
        uint256 currentRate = _getRate();
        if (currentRate == 0) return (0, 0, 0, tTransferAmount, tFee, tLiquidity, tDev);
        (rAmount, rTransferAmount, rFee) = _getRValues(tAmount, tFee, tLiquidity, tDev, currentRate);
    }

    /** @dev Calculates fee amounts in terms of standard token amount (t). */
    function _getTValues(uint256 tAmount) private view returns (uint256 tTransferAmount, uint256 tFee, uint256 tLiquidity, uint256 tDev) {
        tFee = calculateFee(tAmount, _reflectionFeeBps);
        tLiquidity = calculateFee(tAmount, _liquidityFeeBps);
        tDev = calculateFee(tAmount, _devFeeBps);
        uint256 _totalFees = tFee.add(tLiquidity).add(tDev); // Renombrada a _totalFees
        tTransferAmount = tAmount > _totalFees ? tAmount.sub(_totalFees) : 0;
    }

    /** @dev Calculates fee amounts and total amount in terms of reflected supply amount (r). */
    function _getRValues(uint256 tAmount, uint256 tFee, uint256 tLiquidity, uint256 tDev, uint256 currentRate) private pure returns (uint256 rAmount, uint256 rTransferAmount, uint256 rFee) {
        rAmount = tAmount * currentRate; // SafeMath mul needed if rate or tAmount can be large
        rFee = tFee * currentRate;
        uint256 rLiquidity = tLiquidity * currentRate;
        uint256 rDev = tDev * currentRate;
        uint256 totalRFees = rFee + rLiquidity + rDev;
        rTransferAmount = rAmount > totalRFees ? rAmount - totalRFees : 0;
        // rFee is the reflection fee component in reflected value
    }

    /** @dev Calculates the current reflection rate (_rSupply / _tSupply). */
    function _getRate() private view returns(uint256) {
        (uint256 rSupply, uint256 tSupply) = _getCurrentSupply();
        if (tSupply == 0) return 0;
        return rSupply / tSupply; // SafeMath div not needed if we accept truncation
    }

   /**
    * @dev Calculates the current supply eligible for rewards (total supply minus excluded accounts' supply).
    * @notice Iterates over _excluded array. Can become gas-intensive if the array grows very large.
    */
    function _getCurrentSupply() private view returns(uint256 rSupply, uint256 tSupply) {
        rSupply = _rTotal;
        tSupply = _tTotal;
        uint256 excludedCount = _excluded.length;
        for (uint256 i = 0; i < excludedCount; i++) {
             address excludedAddr = _excluded[i];
             // Check for potential inconsistencies before subtraction
            if (_rOwned[excludedAddr] > rSupply || _tOwned[excludedAddr] > tSupply) {
                return (_rTotal, _tTotal); // Return full totals if inconsistency detected
            }
            rSupply -= _rOwned[excludedAddr]; // Use unchecked or SafeMath sub? SafeMath is safer.
            tSupply -= _tOwned[excludedAddr]; // Using SafeMath via '-' operator overload since 0.8.0
        }
        // Prevent division by zero or nonsensical rates if calculations result in zero supply
        if (rSupply == 0 || tSupply == 0) return (_rTotal, _tTotal);
        return (rSupply, tSupply);
    }

    /** @dev Allocates liquidity fee tokens to the designated liquidity wallet address. */
    function _takeLiquidity(uint256 tLiquidity) private {
        if (tLiquidity == 0 || liqWalletAddress == address(0)) return;
        uint256 currentRate = _getRate();
        if (currentRate == 0) return;
        uint256 rLiquidity = tLiquidity * currentRate; // SafeMath mul needed?

        _rOwned[liqWalletAddress] = _rOwned[liqWalletAddress].add(rLiquidity);
        if (_isExcluded[liqWalletAddress]) {
            _tOwned[liqWalletAddress] = _tOwned[liqWalletAddress].add(tLiquidity);
        }
        // Note: No Transfer event is emitted for fee distributions.
    }

   /**
    * @notice Distributes dev fee 3 ways. Integer division rounding handled by giving remainder to devWalletAddress.
    */
    function _takeDev(uint256 tDev) private {
        if (tDev == 0) return;
         uint256 currentRate = _getRate();
         if (currentRate == 0) return;
         uint256 rDev = tDev * currentRate; // SafeMath mul needed?

         uint256 devShare = rDev / 3;
         uint256 tDevShare = tDev / 3;
         uint256 remainder = rDev % 3;
         uint256 tRemainder = tDev % 3;

         // Distribute shares, add remainder to the first wallet
         if (devWalletAddress != address(0)) {
             _rOwned[devWalletAddress] = _rOwned[devWalletAddress].add(devShare).add(remainder);
             if (_isExcluded[devWalletAddress]) _tOwned[devWalletAddress] = _tOwned[devWalletAddress].add(tDevShare).add(tRemainder);
         }
         if (mkWalletAddress != address(0)) {
             _rOwned[mkWalletAddress] = _rOwned[mkWalletAddress].add(devShare);
             if (_isExcluded[mkWalletAddress]) _tOwned[mkWalletAddress] = _tOwned[mkWalletAddress].add(tDevShare);
         }
         if (chaWalletAddress != address(0)) {
             _rOwned[chaWalletAddress] = _rOwned[chaWalletAddress].add(devShare);
             if (_isExcluded[chaWalletAddress]) _tOwned[chaWalletAddress] = _tOwned[chaWalletAddress].add(tDevShare);
         }
    }

    /** @dev Updates reflection supply and total fee tracking for reflection fee component. */
    function _reflectFee(uint256 rFee, uint256 tFee) private {
        _rTotal = _rTotal.sub(rFee); // Decrease total reflected supply
        _tFeeTotal = _tFeeTotal.add(tFee); // Track total standard fees (optional use)
    }

    /** @dev Calculates fee amount based on basis points. */
    function calculateFee(uint256 _amount, uint256 _feeBps) private pure returns (uint256) {
        // 10000 BPS = 100%
        return _amount.mul(_feeBps).div(10000);
    }

    // --- Transfer Variations (Removed as logic is consolidated in _tokenTransfer) ---
    // function _transferStandard(address sender, address recipient, uint256 tAmount) private {}
    // function _transferToExcluded(address sender, address recipient, uint256 tAmount) private {}
    // function _transferFromExcluded(address sender, address recipient, uint256 tAmount) private {}
    // function _transferBothExcluded(address sender, address recipient, uint256 tAmount) private {}

    // --- Receive Ether ---
    // Allows contract to receive ETH from Uniswap Router swaps or direct sends.
    receive() external payable {}

}

// REMINDER: Ensure you have the IUniswapV2Factory.sol, IUniswapV2Pair.sol, IUniswapV2Router02.sol
// interface files in a local './interfaces/' folder relative to this contract,
// or update the import paths accordingly.