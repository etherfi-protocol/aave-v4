// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {console2} from 'forge-std/console2.sol';

import {EtherfiCashGovernanceBase} from 'scripts/etherfi/utils/EtherfiCashGovernanceBase.sol';
import {GnosisTxBuilder} from 'scripts/etherfi/utils/GnosisTxBuilder.sol';
import {
  AaveV4EtherfiCash as Cash,
  AaveV4EtherfiCashHubs as Hubs,
  AaveV4EtherfiCashSpokes as Spokes,
  AaveV4EtherfiCashAssets as Assets,
  AaveV4EtherfiCashCaps as Caps,
  AaveV4EtherfiCashRates as Rates
} from 'src/etherfi/AaveV4EtherfiCash.sol';
import {IHub} from 'src/hub/interfaces/IHub.sol';
import {ISpoke} from 'src/spoke/interfaces/ISpoke.sol';
import {IAssetInterestRateStrategy} from 'src/hub/interfaces/IAssetInterestRateStrategy.sol';

/// @title EtherfiCashEurcBorrowable
/// @notice Makes EURC borrowable on the ether.fi Cash Aave V4 instance (OP Mainnet), in one Owner
/// Safe batch. Inputs: `AaveV4EtherfiCash.sol` (Rates.EURC_*, Caps.EURC_DRAW_CAP = 0).
///
///   Four calls, in this order (price the debt, fee it, cap it, then open it):
///     1. HubConfigurator.updateInterestRateData   flat 0% launch curve -> Rates.EURC_* curve
///     2. HubConfigurator.updateLiquidityFee       0% -> Rates.EURC_LIQUIDITY_FEE
///     3. HubConfigurator.updateSpokeDrawCap       -> Caps.EURC_DRAW_CAP = 0, explicitly: the reserve
///                                                 opens CLOSED, every borrow reverts DrawCapExceeded
///     4. SpokeConfigurator.updateBorrowable       false -> true
///   The draw cap is signed as part of opening (whenever any of the other calls is pending) and
///   is not a completion criterion: the risk curator (HUB_RISK_CURATOR_ROLE, Operator Safe)
///   raises it later with updateSpokeDrawCap, outside this script.
///   Already in place (verified, not touched): asset active + not halted for the Cash Spoke,
///   reserve not paused / frozen, price feed, Hub IR strategy, collateral parameters.
///
///   configure() read-only; verifies the preconditions and that the Owner Safe may send every
///               call under the LIVE AccessManager (reverts NoSigner once the timelock migration's
///               phase 2 has moved updateLiquidityFee / updateBorrowable behind the queue), then
///               writes the batch to output/etherfi/borrowable/. Re-run after execution: COMPLETE
///               reads every parameter back.
///   plan()      configure(), then applies the batch in this VM and re-verifies to COMPLETE.
///
///   forge script scripts/etherfi/borrowable/EtherfiCashEurcBorrowable.s.sol --sig 'configure()' \
///     --rpc-url optimism
///   forge script scripts/etherfi/borrowable/EtherfiCashEurcBorrowable.s.sol --sig 'plan()' \
///     --rpc-url optimism
contract EtherfiCashEurcBorrowableScript is EtherfiCashGovernanceBase {
  enum Phase {
    SAFE,
    COMPLETE
  }

  function configure() external returns (Phase) {
    return _configure();
  }

  function plan() external returns (Phase live) {
    return Phase(_plan(_step, uint256(Phase.COMPLETE), 0));
  }

  function _step() internal returns (uint256) {
    return uint256(_configure());
  }

  function _configure() internal returns (Phase) {
    _requireOpMainnet();
    IHub hub = IHub(Hubs.CASH_HUB);
    ISpoke spoke = ISpoke(Spokes.CASH_SPOKE);
    uint256 assetId = hub.getAssetId(Assets.EURC_UNDERLYING);
    uint256 reserveId = spoke.getReserveId(Hubs.CASH_HUB, assetId);
    _verifyPreconditions(hub, spoke, assetId, reserveId);

    IAssetInterestRateStrategy.InterestRateData memory irData = IAssetInterestRateStrategy
      .InterestRateData({
        optimalUsageRatio: Rates.EURC_OPTIMAL_USAGE_RATIO,
        baseDrawnRate: Rates.EURC_BASE_DRAWN_RATE,
        rateGrowthBeforeOptimal: Rates.EURC_RATE_GROWTH_BEFORE_OPTIMAL,
        rateGrowthAfterOptimal: Rates.EURC_RATE_GROWTH_AFTER_OPTIMAL
      });
    IAssetInterestRateStrategy.InterestRateData memory liveIr = IAssetInterestRateStrategy(
      Hubs.CASH_HUB_IR_STRATEGY
    ).getInterestRateData(assetId);

    GnosisTxBuilder.Tx[] memory calls = new GnosisTxBuilder.Tx[](4);
    uint256 n;
    if (keccak256(abi.encode(liveIr)) != keccak256(abi.encode(irData))) {
      calls[n++] = _updateInterestRateData(Hubs.CASH_HUB, assetId, irData);
    } else {
      _done('interest rate curve');
    }
    if (hub.getAssetConfig(assetId).liquidityFee != Rates.EURC_LIQUIDITY_FEE) {
      calls[n++] = _updateLiquidityFee(Hubs.CASH_HUB, assetId, Rates.EURC_LIQUIDITY_FEE);
    } else {
      _done('liquidity fee');
    }
    bool borrowable = spoke.getReserveConfig(reserveId).borrowable;
    if (borrowable) _done('borrowable flag');
    if (n != 0 || !borrowable) {
      // pinned closed as part of opening; not re-emitted once the curator manages the cap
      calls[n++] = _updateSpokeDrawCap(
        Hubs.CASH_HUB,
        assetId,
        Spokes.CASH_SPOKE,
        Caps.EURC_DRAW_CAP
      );
    }
    if (!borrowable) calls[n++] = _updateBorrowable(Spokes.CASH_SPOKE, reserveId, true);

    if (n == 0) {
      _clearNext();
      console2.log('=== COMPLETE: EURC is borrowable with every parameter verified ===');
      return Phase.COMPLETE;
    }
    calls = _take(calls, n);
    _requireCanCall(Cash.OWNER_SAFE, calls);
    _emitBatch(Cash.OWNER_SAFE, 'eurc-borrowable-owner-safe', calls);
    return Phase.SAFE;
  }

  /// @dev Everything a borrow needs besides the four calls above must already hold.
  function _verifyPreconditions(
    IHub hub,
    ISpoke spoke,
    uint256 assetId,
    uint256 reserveId
  ) internal {
    ISpoke.Reserve memory reserve = spoke.getReserve(reserveId);
    _checkAddr('reserve.underlying', reserve.underlying, Assets.EURC_UNDERLYING);
    _checkAddr('reserve.hub', address(reserve.hub), Hubs.CASH_HUB);
    _check('reserve.decimals', reserve.decimals, Assets.EURC_DECIMALS);
    ISpoke.ReserveConfig memory config = spoke.getReserveConfig(reserveId);
    _checkBool('reserve.paused', config.paused, false);
    _checkBool('reserve.frozen', config.frozen, false);
    IHub.SpokeConfig memory spokeConfig = hub.getSpokeConfig(assetId, Spokes.CASH_SPOKE);
    _checkBool('hub spoke.active', spokeConfig.active, true);
    _checkBool('hub spoke.halted', spokeConfig.halted, false);
    _check('hub spoke.addCap', spokeConfig.addCap, Caps.EURC_ADD_CAP);
    console2.log('[info] hub spoke.drawCap (curator-managed after opening):', spokeConfig.drawCap);
    IHub.AssetConfig memory assetConfig = hub.getAssetConfig(assetId);
    _checkAddr('hub asset.irStrategy', assetConfig.irStrategy, Hubs.CASH_HUB_IR_STRATEGY);
    _checkAddr('hub asset.feeReceiver', assetConfig.feeReceiver, Spokes.TREASURY_SPOKE);
    _assertNoMismatches('EURC preconditions');
  }

  function _outputDir() internal pure override returns (string memory) {
    return 'output/etherfi/borrowable/';
  }

  function _done(string memory what) internal pure {
    console2.log('[done]', what);
  }
}
