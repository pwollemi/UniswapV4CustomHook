// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {CustomHook} from "../src/CustomHook.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {HookMiner} from "../src/HookMiner.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {CurrencyLibrary, Currency} from "v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Actions} from "v4-periphery/src/libraries/Actions.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUniversalRouter} from "universal-router/contracts/interfaces/IUniversalRouter.sol";
import {Commands} from "universal-router/contracts/libraries/Commands.sol";
import {IV4Router} from "v4-periphery/src/interfaces/IV4Router.sol";
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";
import {IPermit2} from "v4-periphery/lib/permit2/src/interfaces/IPermit2.sol";
import {IPool} from "lib/aave-v3-origin/src/contracts/interfaces/IPool.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

contract CustomHookTest is Test, IERC721Receiver {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using SafeERC20 for IERC20;

    CustomHook customHook;
    PoolKey poolKey;
    uint160 initSqrtPriceX96;
    IPoolManager public poolManager =
        IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    IPositionManager public positionManager =
        IPositionManager(0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e);
    IPermit2 public permit2 =
        IPermit2(0x000000000022D473030F116dDEE9F6B43aC78BA3);
    IUniversalRouter constant router =
        IUniversalRouter(0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af);
    IERC20 public aUSDC = IERC20(0x98C23E9d8f34FEFb1B7BD6a91B7FF122F4e16F5c);
    IERC20 public aUSDT = IERC20(0x23878914EFE38d27C4D67Ab83ed1b93A74D4086a);
    IERC20 constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    IERC20 constant USDT = IERC20(0xdAC17F958D2ee523a2206206994597C13D831ec7);
    address constant user1 = address(1);
    address constant user2 = address(2);

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("mainnet"));
        // Initialize test accounts with tokens
        deal(address(USDC), user1, 2_000_000e6);
        deal(address(USDT), user1, 2_000_000e6);
        deal(address(USDC), user2, 2_000_000e6);
        deal(address(USDT), user2, 2_000_000e6);

        // Set up permit2 approvals for test users
        vm.startPrank(user1);
        USDC.safeIncreaseAllowance(address(permit2), type(uint256).max);
        USDT.safeIncreaseAllowance(address(permit2), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(user2);
        USDC.safeIncreaseAllowance(address(permit2), type(uint256).max);
        USDT.safeIncreaseAllowance(address(permit2), type(uint256).max);
        vm.stopPrank();

        // Deploy custom hook contract with required flags
        (, bytes32 salt) = HookMiner.find(
            address(this),
            uint160(
                Hooks.BEFORE_SWAP_FLAG |
                    Hooks.BEFORE_INITIALIZE_FLAG |
                    Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
            ),
            type(CustomHook).creationCode,
            abi.encode(address(this))
        );

        customHook = new CustomHook{salt: salt}(address(this));

        // Configure pool parameters
        poolKey = PoolKey({
            currency0: Currency.wrap(address(USDC)),
            currency1: Currency.wrap(address(USDT)),
            fee: 10000,
            tickSpacing: 300,
            hooks: IHooks(address(customHook))
        });

        // Initialize pool with sqrt price at tick 0
        initSqrtPriceX96 = uint160(TickMath.getSqrtPriceAtTick(0));
        poolManager.initialize(poolKey, initSqrtPriceX96);

        // Set up test contract with initial liquidity
        deal(address(USDC), address(this), 2_000_000e6);
        deal(address(USDT), address(this), 2_000_000e6);
        USDC.safeIncreaseAllowance(address(permit2), type(uint256).max);
        USDT.safeIncreaseAllowance(address(permit2), type(uint256).max);

        permit2.approve(
            address(USDC),
            address(positionManager),
            type(uint160).max,
            uint48(block.timestamp + 60)
        );
        permit2.approve(
            address(USDT),
            address(positionManager),
            type(uint160).max,
            uint48(block.timestamp + 60)
        );

        // Add initial liquidity to the pool
        bytes memory actions = abi.encodePacked(
            uint8(Actions.MINT_POSITION),
            uint8(Actions.SETTLE_PAIR)
        );
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(
            poolKey,
            -300,
            300,
            2_000_000e6,
            type(uint256).max,
            type(uint256).max,
            address(this),
            ""
        );
        params[1] = abi.encode(
            Currency.wrap(address(USDC)),
            Currency.wrap(address(USDT))
        );
        positionManager.modifyLiquidities(
            abi.encode(actions, params),
            block.timestamp + 60
        );
    }

    function testSwapFeeToAave() public {
        permit2.approve(
            address(USDC),
            address(router),
            type(uint160).max,
            uint48(block.timestamp + 60)
        );

        // Define swap parameters
        uint128 swapAmount = 2000e6; // 1000 USDC
        uint256 expectedFee = swapAmount / 1000; // 0.1% fee

        // Record initial aToken balance
        uint256 aReserveBefore = USDC.balanceOf(address(aUSDC));

        // Execute swap
        swapExactInputSingle(poolKey, swapAmount, 0, address(this));

        // Verify fee collection and distribution
        assertEq(
            USDC.balanceOf(address(aUSDC)) - aReserveBefore,
            expectedFee,
            "Incorrect fee amount sent to Aave"
        );
    }

    function testclaimFeeRecepient() public {
        // Setup: User1 performs a swap
        vm.startPrank(user1);
        permit2.approve(
            address(USDC),
            address(router),
            type(uint160).max,
            uint48(block.timestamp + 60)
        );

        uint128 swapAmount = 2000e6;
        uint256 expectedFee = swapAmount / 1000; // 0.1% fee

        swapExactInputSingle(poolKey, swapAmount, 0, user1);
        vm.stopPrank();

        // Verify fee distribution
        uint256 expectedRecipientFee = expectedFee / 2;
        assertEq(
            customHook.recepientFee(Currency.wrap(address(USDC))),
            expectedRecipientFee,
            "Incorrect recipient fee for USDC"
        );
        assertEq(
            customHook.recepientFee(Currency.wrap(address(USDT))),
            0,
            "USDT recipient fee should be 0"
        );
        assertEq(
            customHook.pendingRewards(user1, Currency.wrap(address(USDC))),
            expectedRecipientFee,
            "Incorrect pending rewards for user1"
        );

        // Test recipient fee claim
        vm.startPrank(address(this));
        uint256 recipientBalanceBefore = USDC.balanceOf(address(this));
        customHook.claimFeeRecepient(Currency.wrap(address(USDC)));

        assertEq(
            customHook.recepientFee(Currency.wrap(address(USDC))),
            0,
            "Recipient fee should be 0 after claim"
        );
        assertEq(
            USDC.balanceOf(address(this)) - recipientBalanceBefore,
            expectedRecipientFee,
            "Incorrect recipient fee transfer amount"
        );
        vm.stopPrank();

        // Test user fee claim
        vm.startPrank(user1);
        uint256 userBalanceBefore = USDC.balanceOf(user1);
        customHook.claimFee(Currency.wrap(address(USDC)));

        assertEq(
            customHook.pendingRewards(user1, Currency.wrap(address(USDC))),
            0,
            "Pending rewards should be 0 after claim"
        );
        assertEq(
            USDC.balanceOf(user1) - userBalanceBefore,
            expectedRecipientFee,
            "Incorrect user fee transfer amount"
        );
        vm.stopPrank();
    }

    function testClaimFee() public {
        // Initial swap amount and calculated rewards
        uint128 swapAmount = 2_000e6;
        uint256 rewards = swapAmount / 1000 / 2; // 0.1% rewards rate - 1/2 dev fee

        // First user performs swap
        vm.startPrank(user1);
        permit2.approve(
            address(USDC),
            address(router),
            type(uint160).max,
            uint48(block.timestamp + 60)
        );
        swapExactInputSingle(poolKey, swapAmount, 0, user1);
        vm.stopPrank();

        // Verify user1's initial rewards
        assertEq(
            customHook.pendingRewards(user1, Currency.wrap(address(USDC))),
            rewards,
            "User1 initial rewards incorrect"
        );

        // Second user performs swap
        vm.startPrank(user2);
        permit2.approve(
            address(USDC),
            address(router),
            type(uint160).max,
            uint48(block.timestamp + 60)
        );
        swapExactInputSingle(poolKey, swapAmount, 0, user2);
        vm.stopPrank();

        // Verify reward distribution after second swap
        assertEq(
            customHook.pendingRewards(user1, Currency.wrap(address(USDC))),
            rewards + rewards / 2,
            "User1 rewards after second swap incorrect"
        );
        assertEq(
            customHook.pendingRewards(user2, Currency.wrap(address(USDC))),
            rewards / 2,
            "User2 rewards after second swap incorrect"
        );

        // User1 claims rewards
        vm.prank(user1);
        customHook.claimFee(Currency.wrap(address(USDC)));

        // User2 performs another swap
        vm.startPrank(user2);
        permit2.approve(
            address(USDC),
            address(router),
            type(uint160).max,
            uint48(block.timestamp + 60)
        );
        swapExactInputSingle(poolKey, swapAmount, 0, user2);
        vm.stopPrank();

        // Verify final reward distribution
        assertEq(
            customHook.pendingRewards(user1, Currency.wrap(address(USDC))),
            333333,
            "User1 final rewards incorrect"
        );
        assertEq(
            customHook.pendingRewards(user2, Currency.wrap(address(USDC))),
            1166666,
            "User2 final rewards incorrect"
        );
    }

    /// @notice Helper function to perform a single token swap
    /// @param key Pool key for the swap
    /// @param amountIn Amount of tokens to swap
    /// @param minAmountOut Minimum amount of tokens to receive
    /// @param user Address of the user performing the swap
    /// @return amountOut Amount of tokens received from the swap
    function swapExactInputSingle(
        PoolKey memory key,
        uint128 amountIn,
        uint128 minAmountOut,
        address user
    ) public returns (uint256 amountOut) {
        bytes memory commands = abi.encodePacked(uint8(Commands.V4_SWAP));
        bytes[] memory inputs = new bytes[](1);

        bytes memory actions = abi.encodePacked(
            uint8(Actions.SWAP_EXACT_IN_SINGLE),
            uint8(Actions.SETTLE_ALL),
            uint8(Actions.TAKE_ALL)
        );

        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: key,
                zeroForOne: true,
                amountIn: amountIn,
                amountOutMinimum: minAmountOut,
                hookData: abi.encode(user)
            })
        );
        params[1] = abi.encode(key.currency0, amountIn);
        params[2] = abi.encode(key.currency1, minAmountOut);

        inputs[0] = abi.encode(actions, params);

        router.execute(commands, inputs, block.timestamp + 60);

        amountOut = IERC20(Currency.unwrap(key.currency1)).balanceOf(
            address(this)
        );
        require(amountOut >= minAmountOut, "Insufficient output amount");
        return amountOut;
    }

    function onERC721Received(
        address,
        address,
        uint256,
        bytes calldata
    ) external returns (bytes4) {
        return this.onERC721Received.selector;
    }
}
