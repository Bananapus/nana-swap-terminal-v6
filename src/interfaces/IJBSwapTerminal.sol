// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";

interface IJBSwapTerminal {
    /// @notice The project ID used for storing default values (pool defaults, accounting contexts).
    /// @return The default project ID (0).
    function DEFAULT_PROJECT_ID() external view returns (uint256);

    /// @notice The maximum TWAP window that can be set for a project's pool.
    /// @return The maximum TWAP window in seconds.
    function MAX_TWAP_WINDOW() external view returns (uint256);

    /// @notice The minimum TWAP window that can be set for a project's pool.
    /// @return The minimum TWAP window in seconds.
    function MIN_TWAP_WINDOW() external view returns (uint256);

    /// @notice The minimum cardinality for a pool to be configured as a default pool.
    /// @return The minimum cardinality.
    function MIN_DEFAULT_POOL_CARDINALITY() external view returns (uint16);

    /// @notice The uncertain slippage tolerance allowed when the swap size relative to liquidity is ambiguous.
    /// @return The uncertain slippage tolerance.
    function UNCERTAIN_SLIPPAGE_TOLERANCE() external view returns (uint256);

    /// @notice The denominator used when calculating TWAP slippage tolerance values.
    /// @return The slippage denominator.
    function SLIPPAGE_DENOMINATOR() external view returns (uint160);

    /// @notice The TWAP window for a given project and pool.
    /// @param projectId The ID of the project.
    /// @param pool The Uniswap v3 pool.
    /// @return The TWAP window in seconds.
    function twapWindowOf(uint256 projectId, IUniswapV3Pool pool) external view returns (uint256);

    /// @notice Add a default pool for a given project and token, setting up the accounting context.
    /// @param projectId The ID of the project to add the default pool for.
    /// @param token The address of the token to add the default pool for.
    /// @param pool The Uniswap v3 pool to set as the default.
    function addDefaultPool(uint256 projectId, address token, IUniswapV3Pool pool) external;

    /// @notice Set or update the TWAP parameters for a given project and pool.
    /// @param projectId The ID of the project to set the TWAP parameters for.
    /// @param pool The Uniswap v3 pool to set the TWAP parameters for.
    /// @param twapWindow The TWAP window in seconds.
    function addTwapParamsFor(uint256 projectId, IUniswapV3Pool pool, uint256 twapWindow) external;
}
