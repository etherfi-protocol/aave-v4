// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from 'forge-std/Test.sol';

import {EtherfiCashTimelockScript} from 'scripts/etherfi/timelock/EtherfiCashTimelock.s.sol';
import {
  AaveV4EtherfiCash as Cash,
  AaveV4EtherfiCashHubs as Hubs,
  AaveV4EtherfiCashSpokes as Spokes,
  AaveV4EtherfiCashTimelock as Timelock,
  AaveV4EtherfiCashRoles as R
} from 'src/etherfi/AaveV4EtherfiCash.sol';
import {EtherFiTimelock} from 'src/etherfi/EtherFiTimelock.sol';
import {TimelockController} from 'src/dependencies/openzeppelin/TimelockController.sol';
import {IAccessManager} from 'src/dependencies/openzeppelin/IAccessManager.sol';
import {Ownable} from 'src/dependencies/openzeppelin/Ownable.sol';
import {ProxyAdmin} from 'src/dependencies/openzeppelin/ProxyAdmin.sol';
import {ITransparentUpgradeableProxy} from 'src/dependencies/openzeppelin/TransparentUpgradeableProxy.sol';
import {IHub} from 'src/hub/interfaces/IHub.sol';
import {ISpoke} from 'src/spoke/interfaces/ISpoke.sol';
import {IHubConfigurator} from 'src/hub/interfaces/IHubConfigurator.sol';
import {ISpokeConfigurator} from 'src/spoke/interfaces/ISpokeConfigurator.sol';

/// @title EtherfiCashTimelockForkTest
/// @notice Dress rehearsal of the whole timelock migration on an OP Mainnet fork. Every step
/// executes the Safe batch JSON that `configure()` actually wrote (parsed back from disk), from the
/// signer it names; `configure()` is re-run after each step so its state machine and read-back
/// verification are exercised end to end. Skips unless forked from OP with the Timelock Safe pinned:
///   forge test --match-path tests/etherfi/EtherfiCashTimelockFork.t.sol --fork-url <op-rpc> -vv
contract EtherfiCashTimelockForkTest is Test {
  EtherfiCashTimelockScript internal script;
  address internal timelock;

  function setUp() public {
    if (!_enabled()) return;
    script = new EtherfiCashTimelockScript();
  }

  function test_fork_fullMigrationRehearsal() public {
    if (!_enabled()) vm.skip(true);

    _step(EtherfiCashTimelockScript.Phase.DEPLOY); // nothing emitted before the deployment

    timelock = script.deploy();
    assertEq(
      keccak256(timelock.code),
      keccak256(type(EtherFiTimelock).runtimeCode),
      'runtime code'
    );

    _step(EtherfiCashTimelockScript.Phase.CANCELLERS); // schedule (Timelock Safe)
    _step(EtherfiCashTimelockScript.Phase.CANCELLERS); // waiting -> +24h
    _step(EtherfiCashTimelockScript.Phase.CANCELLERS); // execute (anyone)

    _step(EtherfiCashTimelockScript.Phase.ACCESS_MANAGER); // Admin Safe batch

    _step(EtherfiCashTimelockScript.Phase.DRY_RUN);
    _step(EtherfiCashTimelockScript.Phase.DRY_RUN);
    _step(EtherfiCashTimelockScript.Phase.DRY_RUN);

    _step(EtherfiCashTimelockScript.Phase.OWNERSHIP); // Admin Safe batch

    _step(EtherfiCashTimelockScript.Phase.TREASURY_ACCEPT);
    _step(EtherfiCashTimelockScript.Phase.TREASURY_ACCEPT);
    _step(EtherfiCashTimelockScript.Phase.TREASURY_ACCEPT);

    _step(EtherfiCashTimelockScript.Phase.REVOCATIONS); // Admin Safe batch

    _step(EtherfiCashTimelockScript.Phase.COMPLETE);

    _assertEndState();
  }

  /// @dev Behavioural checks on top of the script's field-by-field verification.
  function _assertEndState() internal {
    IAccessManager am = IAccessManager(Cash.ACCESS_MANAGER);
    IHubConfigurator hubConfigurator = IHubConfigurator(Cash.HUB_CONFIGURATOR);
    ISpokeConfigurator spokeConfigurator = ISpokeConfigurator(Cash.SPOKE_CONFIGURATOR);
    TimelockController tl = TimelockController(payable(timelock));

    // Admin Safe can no longer administer the AccessManager
    vm.prank(Cash.OWNER_SAFE);
    vm.expectRevert();
    am.grantRole(R.HUB_CONFIGURATOR_DOMAIN_ADMIN_ROLE, Cash.OWNER_SAFE, 0);

    // liquidity fee: Operator Safe lost it, the timelock has it (same value -> no state change)
    uint256 fee = IHub(Hubs.CASH_HUB).getAsset(0).liquidityFee;
    vm.prank(Cash.OPERATOR_SAFE);
    vm.expectRevert();
    hubConfigurator.updateLiquidityFee(Hubs.CASH_HUB, 0, fee);
    _throughTimelock(
      Cash.HUB_CONFIGURATOR,
      abi.encodeCall(IHubConfigurator.updateLiquidityFee, (Hubs.CASH_HUB, 0, fee)),
      'fee'
    );
    assertEq(IHub(Hubs.CASH_HUB).getAsset(0).liquidityFee, fee, 'fee unchanged');

    // restart roles: Admin Safe can un-halt / un-pause / un-freeze, Operator Safe cannot
    vm.prank(Cash.OWNER_SAFE);
    hubConfigurator.updateSpokeHalted(Hubs.CASH_HUB, 0, Spokes.CASH_SPOKE, false);
    vm.prank(Cash.OPERATOR_SAFE);
    vm.expectRevert();
    hubConfigurator.updateSpokeHalted(Hubs.CASH_HUB, 0, Spokes.CASH_SPOKE, false);
    vm.prank(Cash.OWNER_SAFE);
    spokeConfigurator.updatePaused(Spokes.CASH_SPOKE, 0, false);
    vm.prank(Cash.OWNER_SAFE);
    spokeConfigurator.updateFrozen(Spokes.CASH_SPOKE, 0, false);
    vm.prank(Cash.OPERATOR_SAFE);
    vm.expectRevert();
    spokeConfigurator.updatePaused(Spokes.CASH_SPOKE, 0, false);

    // liquidation config: now the Operator Safe's (live values -> no state change)
    ISpoke.LiquidationConfig memory liq = ISpoke(Spokes.CASH_SPOKE).getLiquidationConfig();
    vm.prank(Cash.OPERATOR_SAFE);
    spokeConfigurator.updateLiquidationConfig(Spokes.CASH_SPOKE, liq);

    // borrow enablement: only the timelock
    bool borrowable = ISpoke(Spokes.CASH_SPOKE).getReserveConfig(0).borrowable;
    vm.prank(Cash.OPERATOR_SAFE);
    vm.expectRevert();
    spokeConfigurator.updateBorrowable(Spokes.CASH_SPOKE, 0, borrowable);
    vm.prank(Cash.OWNER_SAFE);
    vm.expectRevert();
    spokeConfigurator.updateBorrowable(Spokes.CASH_SPOKE, 0, borrowable);
    _throughTimelock(
      Cash.SPOKE_CONFIGURATOR,
      abi.encodeCall(ISpokeConfigurator.updateBorrowable, (Spokes.CASH_SPOKE, 0, borrowable)),
      'borrowable'
    );

    // upgrades: the Admin Safe lost the ProxyAdmins, the timelock owns them
    assertEq(Ownable(Hubs.CASH_HUB_PROXY_ADMIN).owner(), timelock);
    assertEq(Ownable(Spokes.CASH_SPOKE_PROXY_ADMIN).owner(), timelock);
    assertEq(Ownable(Spokes.TREASURY_SPOKE_PROXY_ADMIN).owner(), timelock);
    assertEq(Ownable(Spokes.TREASURY_SPOKE).owner(), timelock);
    vm.prank(Cash.OWNER_SAFE);
    vm.expectRevert();
    ProxyAdmin(Hubs.CASH_HUB_PROXY_ADMIN).upgradeAndCall(
      ITransparentUpgradeableProxy(Hubs.CASH_HUB),
      address(this),
      ''
    );

    // queue rules: only the Timelock Safe proposes, never below the min delay, both Safes veto,
    // nothing executes early
    (address[] memory t, uint256[] memory v, bytes[] memory p) = _single(
      Cash.ACCESS_MANAGER,
      abi.encodeCall(
        IAccessManager.labelRole,
        (R.SPOKE_CONFIGURATOR_PAUSE_FREEZE_ROLE, R.SPOKE_CONFIGURATOR_PAUSE_FREEZE_ROLE_LABEL)
      )
    );
    vm.prank(Cash.OWNER_SAFE);
    vm.expectRevert();
    tl.scheduleBatch(t, v, p, bytes32(0), keccak256('veto-1'), Timelock.MIN_DELAY);
    vm.prank(Cash.TIMELOCK_SAFE);
    vm.expectRevert();
    tl.scheduleBatch(t, v, p, bytes32(0), keccak256('veto-1'), Timelock.MIN_DELAY - 1);

    vm.prank(Cash.TIMELOCK_SAFE);
    tl.scheduleBatch(t, v, p, bytes32(0), keccak256('veto-1'), Timelock.MIN_DELAY);
    bytes32 id = tl.hashOperationBatch(t, v, p, bytes32(0), keccak256('veto-1'));
    vm.prank(Cash.OPERATOR_SAFE);
    tl.cancel(id);
    assertFalse(tl.isOperation(id), 'operator veto');

    vm.prank(Cash.TIMELOCK_SAFE);
    tl.scheduleBatch(t, v, p, bytes32(0), keccak256('veto-2'), Timelock.MIN_DELAY);
    id = tl.hashOperationBatch(t, v, p, bytes32(0), keccak256('veto-2'));
    vm.prank(Cash.OWNER_SAFE);
    tl.cancel(id);
    assertFalse(tl.isOperation(id), 'admin veto');

    vm.prank(Cash.TIMELOCK_SAFE);
    tl.scheduleBatch(t, v, p, bytes32(0), keccak256('early'), Timelock.MIN_DELAY);
    vm.expectRevert();
    tl.executeBatch(t, v, p, bytes32(0), keccak256('early'));
  }

  // ─── helpers ───

  function _enabled() internal view returns (bool) {
    return block.chainid == 10 && Cash.TIMELOCK_SAFE != address(0);
  }

  /// @dev Runs configure(), asserts the phase, then either executes the batch it wrote (from the
  /// signer it names, or a random account when execution is open) or, if it wrote nothing because
  /// an operation is maturing, lets 24h pass.
  function _step(EtherfiCashTimelockScript.Phase expected) internal {
    assertEq(uint256(script.configure()), uint256(expected), 'configure() phase');
    (string memory path, address signer) = script.lastEmitted();
    if (bytes(path).length == 0) {
      if (
        expected != EtherfiCashTimelockScript.Phase.DEPLOY &&
        expected != EtherfiCashTimelockScript.Phase.COMPLETE
      ) vm.warp(block.timestamp + Timelock.MIN_DELAY);
      return;
    }
    _executeBatchFile(path, signer == address(0) ? makeAddr('anyone') : signer);
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

  /// @dev Timelock Safe schedules, 24h pass, anyone executes.
  function _throughTimelock(address target, bytes memory data, string memory tag) internal {
    TimelockController tl = TimelockController(payable(timelock));
    (address[] memory t, uint256[] memory v, bytes[] memory p) = _single(target, data);
    bytes32 salt = keccak256(bytes(tag));
    vm.prank(Cash.TIMELOCK_SAFE);
    tl.scheduleBatch(t, v, p, bytes32(0), salt, Timelock.MIN_DELAY);
    vm.warp(block.timestamp + Timelock.MIN_DELAY);
    vm.prank(makeAddr('anyone'));
    tl.executeBatch(t, v, p, bytes32(0), salt);
  }

  function _single(
    address target,
    bytes memory data
  ) internal pure returns (address[] memory t, uint256[] memory v, bytes[] memory p) {
    t = new address[](1);
    v = new uint256[](1);
    p = new bytes[](1);
    t[0] = target;
    p[0] = data;
  }
}
