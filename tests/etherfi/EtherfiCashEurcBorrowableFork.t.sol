// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from 'forge-std/Test.sol';

import {EtherfiCashEurcBorrowableScript} from 'scripts/etherfi/borrowable/EtherfiCashEurcBorrowable.s.sol';
import {EtherfiCashTimelockScript} from 'scripts/etherfi/timelock/EtherfiCashTimelock.s.sol';
import {EtherfiCashGovernanceBase} from 'scripts/etherfi/utils/EtherfiCashGovernanceBase.sol';
import {
  AaveV4EtherfiCash as Cash,
  AaveV4EtherfiCashHubs as Hubs,
  AaveV4EtherfiCashSpokes as Spokes,
  AaveV4EtherfiCashAssets as Assets,
  AaveV4EtherfiCashCaps as Caps,
  AaveV4EtherfiCashRates as Rates
} from 'src/etherfi/AaveV4EtherfiCash.sol';
import {IEtherFiDataProvider} from 'src/etherfi/interfaces/IEtherFiDataProvider.sol';
import {IHub} from 'src/hub/interfaces/IHub.sol';
import {IHubConfigurator} from 'src/hub/interfaces/IHubConfigurator.sol';
import {ISpoke} from 'src/spoke/interfaces/ISpoke.sol';
import {IAssetInterestRateStrategy} from 'src/hub/interfaces/IAssetInterestRateStrategy.sol';
import {IERC20} from 'src/dependencies/openzeppelin/IERC20.sol';

/// @title EtherfiCashEurcBorrowableForkTest
/// @notice Dress rehearsal of the EURC borrowable batch on an OP Mainnet fork: the batch JSON that
/// `configure()` wrote is executed from the Owner Safe, `configure()` re-verifies to COMPLETE, the
/// risk curator (Operator Safe) raises the draw cap from 0, and a Cash Safe actually borrows EURC
/// against WETH (impossible before). Skips unless forked from OP:
///   forge test --match-path tests/etherfi/EtherfiCashEurcBorrowableFork.t.sol --fork-url <op-rpc> -vv
contract EtherfiCashEurcBorrowableForkTest is Test {
  IHub internal constant HUB = IHub(Hubs.CASH_HUB);
  ISpoke internal constant SPOKE = ISpoke(Spokes.CASH_SPOKE);
  uint256 internal constant BORROW = 1_000e6; // 1,000 EURC
  uint40 internal constant CURATOR_DRAW_CAP = 2_500_000; // whatever the curator decides later
  /// @dev EtherFiSpokeInstance.ETHERFI_DATA_PROVIDER (prod proxy, OP Mainnet)
  address internal constant ETHERFI_DATA_PROVIDER = 0xDC515Cb479a64552c5A11a57109C314E40A1A778;

  EtherfiCashEurcBorrowableScript internal script;
  address internal user = makeAddr('cash-safe');
  uint256 internal eurcId;
  uint256 internal wethId;

  function setUp() public {
    if (block.chainid != 10) return;
    script = new EtherfiCashEurcBorrowableScript();
    eurcId = SPOKE.getReserveId(Hubs.CASH_HUB, HUB.getAssetId(Assets.EURC_UNDERLYING));
    wethId = SPOKE.getReserveId(Hubs.CASH_HUB, HUB.getAssetId(Assets.WETH_UNDERLYING));
    // a Cash Safe (per EtherFiDataProvider) with 10 WETH of collateral
    vm.mockCall(
      ETHERFI_DATA_PROVIDER,
      abi.encodeCall(IEtherFiDataProvider.isEtherFiSafe, (user)),
      abi.encode(true)
    );
    deal(Assets.WETH_UNDERLYING, user, 10 ether);
    vm.startPrank(user);
    IERC20(Assets.WETH_UNDERLYING).approve(Spokes.CASH_SPOKE, type(uint256).max);
    SPOKE.supply(wethId, 10 ether, user);
    SPOKE.setUsingAsCollateral(wethId, true, user);
    vm.stopPrank();
  }

  function test_fork_eurcBorrowable() public {
    if (block.chainid != 10) vm.skip(true);

    vm.prank(user);
    vm.expectRevert(ISpoke.ReserveNotBorrowable.selector);
    SPOKE.borrow(eurcId, BORROW, user);

    assertEq(uint256(script.configure()), uint256(EtherfiCashEurcBorrowableScript.Phase.SAFE));
    (string memory path, address signer) = script.lastEmitted();
    assertEq(signer, Cash.OWNER_SAFE, 'signer');
    _expectBatchFileReverts(path, makeAddr('anyone'));
    _expectBatchFileReverts(path, Cash.TIMELOCK_SAFE);
    _executeBatchFile(path, Cash.OWNER_SAFE);

    assertEq(uint256(script.configure()), uint256(EtherfiCashEurcBorrowableScript.Phase.COMPLETE));
    _assertEndState();

    // borrowable, but the draw cap was set to 0: nothing goes through until the curator raises it
    uint256 assetId = HUB.getAssetId(Assets.EURC_UNDERLYING);
    vm.prank(user);
    vm.expectRevert(abi.encodeWithSelector(IHub.DrawCapExceeded.selector, 0));
    SPOKE.borrow(eurcId, BORROW, user);
    vm.prank(Cash.OPERATOR_SAFE);
    IHubConfigurator(Cash.HUB_CONFIGURATOR).updateSpokeDrawCap(
      Hubs.CASH_HUB,
      assetId,
      Spokes.CASH_SPOKE,
      CURATOR_DRAW_CAP
    );

    uint256 before = IERC20(Assets.EURC_UNDERLYING).balanceOf(user);
    vm.prank(user);
    SPOKE.borrow(eurcId, BORROW, user);
    assertEq(IERC20(Assets.EURC_UNDERLYING).balanceOf(user) - before, BORROW, 'EURC received');
    assertEq(SPOKE.getUserTotalDebt(eurcId, user), BORROW, 'debt opened');
    vm.warp(block.timestamp + 365 days);
    assertGt(SPOKE.getUserTotalDebt(eurcId, user), BORROW, 'debt accrues (curve is not 0%)');
  }

  /// @dev plan() = the same rehearsal driven by the script itself.
  function test_fork_plan() public {
    if (block.chainid != 10) vm.skip(true);
    assertEq(uint256(script.plan()), uint256(EtherfiCashEurcBorrowableScript.Phase.SAFE));
    assertEq(uint256(script.configure()), uint256(EtherfiCashEurcBorrowableScript.Phase.COMPLETE));
    _assertEndState();
  }

  /// @dev Once the timelock migration has moved updateLiquidityFee / updateBorrowable behind the
  /// queue, the Owner Safe can no longer send the batch and the script says so instead of writing
  /// a batch that would revert.
  function test_fork_afterTimelockMigration_revertsNoSigner() public {
    if (block.chainid != 10) vm.skip(true);
    EtherfiCashTimelockScript migration = new EtherfiCashTimelockScript();
    assertEq(
      uint256(migration.plan()) < uint256(EtherfiCashTimelockScript.Phase.COMPLETE),
      true,
      'migration not complete on chain yet'
    );
    vm.expectPartialRevert(EtherfiCashGovernanceBase.NoSigner.selector);
    script.configure();
  }

  function _assertEndState() internal view {
    uint256 assetId = HUB.getAssetId(Assets.EURC_UNDERLYING);
    IAssetInterestRateStrategy.InterestRateData memory ir = IAssetInterestRateStrategy(
      Hubs.CASH_HUB_IR_STRATEGY
    ).getInterestRateData(assetId);
    assertEq(ir.optimalUsageRatio, Rates.EURC_OPTIMAL_USAGE_RATIO, 'kink');
    assertEq(ir.baseDrawnRate, Rates.EURC_BASE_DRAWN_RATE, 'base');
    assertEq(ir.rateGrowthBeforeOptimal, Rates.EURC_RATE_GROWTH_BEFORE_OPTIMAL, 'slope1');
    assertEq(ir.rateGrowthAfterOptimal, Rates.EURC_RATE_GROWTH_AFTER_OPTIMAL, 'slope2');
    assertEq(HUB.getAssetConfig(assetId).liquidityFee, Rates.EURC_LIQUIDITY_FEE, 'fee');
    IHub.SpokeConfig memory spokeConfig = HUB.getSpokeConfig(assetId, Spokes.CASH_SPOKE);
    assertEq(spokeConfig.drawCap, Caps.EURC_DRAW_CAP, 'drawCap explicitly 0');
    assertEq(spokeConfig.addCap, Caps.EURC_ADD_CAP, 'addCap untouched');
    ISpoke.ReserveConfig memory config = SPOKE.getReserveConfig(eurcId);
    assertTrue(config.borrowable, 'borrowable');
    assertFalse(config.paused, 'paused');
    assertFalse(config.frozen, 'frozen');
  }

  /// @dev Every transaction of a written batch reverts when sent by `sender`.
  function _expectBatchFileReverts(string memory path, address sender) internal {
    string memory json = vm.readFile(path);
    for (uint256 i; ; i++) {
      string memory key = string.concat('.transactions[', vm.toString(i), ']');
      if (!vm.keyExistsJson(json, key)) break;
      address to = vm.parseJsonAddress(json, string.concat(key, '.to'));
      bytes memory data = vm.parseJsonBytes(json, string.concat(key, '.data'));
      vm.prank(sender);
      (bool ok, ) = to.call(data);
      assertFalse(
        ok,
        string.concat('tx ', vm.toString(i), ' of ', path, ' must revert for sender')
      );
    }
  }

  /// @dev Replays a written Safe Transaction Builder JSON: every transaction, from `sender`.
  function _executeBatchFile(string memory path, address sender) internal {
    string memory json = vm.readFile(path);
    for (uint256 i; ; i++) {
      string memory key = string.concat('.transactions[', vm.toString(i), ']');
      if (!vm.keyExistsJson(json, key)) break;
      address to = vm.parseJsonAddress(json, string.concat(key, '.to'));
      bytes memory data = vm.parseJsonBytes(json, string.concat(key, '.data'));
      vm.prank(sender);
      (bool ok, bytes memory ret) = to.call(data);
      if (!ok) {
        assembly {
          revert(add(ret, 32), mload(ret))
        }
      }
    }
  }
}
