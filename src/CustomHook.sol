// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseHook} from "./base/BaseHook.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {toBeforeSwapDelta, BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPool} from "lib/aave-v3-origin/src/contracts/interfaces/IPool.sol";
import {IPoolAddressesProvider} from "lib/aave-v3-origin/src/contracts/interfaces/IPoolAddressesProvider.sol";

contract CustomHook is BaseHook {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using BeforeSwapDeltaLibrary for BeforeSwapDelta;

    Currency public USDC =
        Currency.wrap(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48); // USDC
    Currency public USDT =
        Currency.wrap(0xdAC17F958D2ee523a2206206994597C13D831ec7); // USDT
    address public AAVE_POOL_ADDRESSES_PROVIDER =
        0x2f39d218133AFaB8F2B819B1066c7E434Ad94E9e; // Aave v3 Pool Provider

    struct UserInfo {
        uint256 amount;
        uint256 rewardDebt;
    }
    IPool public pool;
    address public feeRecipient;
    mapping(Currency => uint256) public recepientFee;
    mapping(Currency => uint256) public totalDeposited;

    address public constant aUSDT = 0x23878914EFE38d27C4D67Ab83ed1b93A74D4086a;
    address public constant aUSDC = 0x98C23E9d8f34FEFb1B7BD6a91B7FF122F4e16F5c;
    IPoolManager public constant UNISWAP_POOL_MANAGER =
        IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90); // Uniswap v4 Pool Manager
    mapping(Currency => uint256) public tokenShares;

    mapping(Currency => mapping(address => UserInfo)) public userInfos;
    mapping(Currency => uint256) public userRewardPerTokenPaid;
    mapping(Currency => uint256) public totalShares;

    constructor(address _feeRecipient) BaseHook(UNISWAP_POOL_MANAGER) {
        require(_feeRecipient != address(0), "Invalid fee recipient");
        feeRecipient = _feeRecipient;

        // Get Pool address from provider
        IPoolAddressesProvider provider = IPoolAddressesProvider(
            AAVE_POOL_ADDRESSES_PROVIDER
        );
        address poolAddress = provider.getPool();
        pool = IPool(poolAddress);

        IERC20(Currency.unwrap(USDC)).safeIncreaseAllowance(
            address(pool),
            type(uint256).max
        );
        IERC20(Currency.unwrap(USDT)).safeIncreaseAllowance(
            address(pool),
            type(uint256).max
        );
    }

    function claimFee(Currency currency) external {
        uint256 rewards = earned(msg.sender, currency);
        _withdrawFromAave(rewards, msg.sender, currency);
    }

    function claimFeeRecepient(Currency currency) external {
        require(msg.sender == feeRecipient, "Unauthorized");
        _withdrawFromAave(recepientFee[currency], msg.sender, currency);
        recepientFee[currency] = 0;
    }

    function _addRewards(Currency currency, uint256 amount) internal {
        unchecked {
            userRewardPerTokenPaid[currency] +=
                (amount * 1e18) /
                totalShares[currency];
        }
    }

    function _deposit(
        address user,
        uint256 amount,
        Currency currency
    ) internal {
        UserInfo storage userInfo = userInfos[currency][user];
        userInfo.amount += amount;
        userInfo.rewardDebt +=
            (amount * userRewardPerTokenPaid[currency]) /
            1e18;
        totalShares[currency] += amount;
    }

    function earned(
        address user,
        Currency currency
    ) internal returns (uint256) {
        uint256 currentRewardPerToken = userRewardPerTokenPaid[currency];
        UserInfo storage userInfo = userInfos[currency][user];
        uint256 pendingReward = (userInfo.amount * currentRewardPerToken) /
            1e18 -
            userInfo.rewardDebt;

        if (pendingReward > 0) {
            userInfo.rewardDebt =
                (userInfo.amount * currentRewardPerToken) /
                1e18;
        }
        return pendingReward;
    }

    function rewardPerToken(Currency currency) internal view returns (uint256) {
        if (currency == USDC) {
            return
                (IERC20(aUSDC).balanceOf(address(this)) * 1e18) /
                tokenShares[currency];
        } else if (currency == USDT) {
            return
                (IERC20(aUSDT).balanceOf(address(this)) * 1e18) /
                tokenShares[currency];
        }
        return 0;
    }

    function _withdrawFromAave(
        uint256 share,
        address to,
        Currency currency
    ) internal {
        uint256 amount = (share * rewardPerToken(currency)) / 1e18;
        tokenShares[currency] -= share;
        pool.withdraw(Currency.unwrap(currency), amount, to);
    }

    function pendingRewards(
        address user,
        Currency currency
    ) public view returns (uint256) {
        UserInfo storage userInfo = userInfos[currency][user];
        uint256 reward = (userInfo.amount * userRewardPerTokenPaid[currency]) /
            1e18 -
            userInfo.rewardDebt;
        return reward;
    }

    /**
     * @inheritdoc BaseHook
     */

    function _beforeInitialize(
        address sender,
        PoolKey calldata key,
        uint160 sqrtPriceX96
    ) internal override returns (bytes4) {
        if (
            Currency.unwrap(key.currency0) == Currency.unwrap(USDC) &&
            Currency.unwrap(key.currency1) == Currency.unwrap(USDT)
        ) {
            return (BaseHook.beforeInitialize.selector);
        }
        revert("Invalid currency pair");
    }

    /**
     * @inheritdoc BaseHook
     */

    function _beforeSwap(
        address,
        PoolKey calldata,
        IPoolManager.SwapParams calldata swapParams,
        bytes calldata hookData
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        require(msg.sender == address(poolManager), "Unauthorized");

        address user = abi.decode(hookData, (address));

        uint256 swapAmount = uint256(
            swapParams.amountSpecified > 0
                ? swapParams.amountSpecified
                : -swapParams.amountSpecified
        );
        uint256 fee = swapAmount / 1000;
        Currency _currnecy = swapParams.zeroForOne ? USDC : USDT;

        poolManager.take(_currnecy, address(this), fee);

        // Add Collateral to Aave
        tokenShares[_currnecy] += fee;
        pool.supply(Currency.unwrap(_currnecy), fee, address(this), 0);

        totalDeposited[_currnecy] += fee;
        recepientFee[_currnecy] += fee / 2;

        // Update User Info
        UserInfo storage userInfo = userInfos[_currnecy][user];
        userInfo.amount += swapAmount;
        userInfo.rewardDebt +=
            (swapAmount * userRewardPerTokenPaid[_currnecy]) /
            1e18;
        totalShares[_currnecy] += swapAmount;

        // Update Reward Per Token Paid
        Currency currency = swapParams.zeroForOne ? USDC : USDT;
        uint256 _fee = fee - fee / 2;
        unchecked {
            userRewardPerTokenPaid[currency] +=
                (_fee * 1e18) /
                totalShares[currency];
        }

        return (
            BaseHook.beforeSwap.selector,
            toBeforeSwapDelta(int128(int256(fee)), 0),
            0
        );
    }

    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return
            Hooks.Permissions({
                beforeInitialize: true,
                afterInitialize: false,
                beforeAddLiquidity: false,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: true,
                afterSwap: false,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: true,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            });
    }
}
