// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {console2} from 'forge-std/console2.sol';

import {EtherfiCashGovernanceBase} from 'scripts/etherfi/utils/EtherfiCashGovernanceBase.sol';
import {GnosisTxBuilder} from 'scripts/etherfi/utils/GnosisTxBuilder.sol';
import {
  AaveV4EtherfiCash as Cash,
  AaveV4EtherfiCashHubs as Hubs,
  AaveV4EtherfiCashSpokes as Spokes,
  AaveV4EtherfiCashTimelock as Timelock,
  AaveV4EtherfiCashRoles as R
} from 'src/etherfi/AaveV4EtherfiCash.sol';
import {EtherFiTimelock} from 'src/etherfi/EtherFiTimelock.sol';
import {EtherfiCashLaunchPayload} from 'src/etherfi/EtherfiCashLaunchPayload.sol';
import {TimelockController} from 'src/dependencies/openzeppelin/TimelockController.sol';
import {IAccessManager} from 'src/dependencies/openzeppelin/IAccessManager.sol';
import {Ownable2StepUpgradeable} from 'src/dependencies/openzeppelin-upgradeable/Ownable2StepUpgradeable.sol';
import {Create2Utils} from 'src/deployments/utils/libraries/Create2Utils.sol';
import {Roles} from 'src/deployments/utils/libraries/Roles.sol';
import {IHubConfigurator} from 'src/hub/interfaces/IHubConfigurator.sol';
import {ISpokeConfigurator} from 'src/spoke/interfaces/ISpokeConfigurator.sol';
import {IAaveV4ConfigEngine} from 'src/config-engine/interfaces/IAaveV4ConfigEngine.sol';

/// @title EtherfiCashTimelock
/// @notice ether.fi Cash Aave V4 timelock migration (OP Mainnet). Inputs: `AaveV4EtherfiCash.sol`.
///
///   deploy()    phase 1a — deterministic EtherFiTimelock deployment (any funded key).
///   configure() phases 1b-5 — read-only; verifies every completed phase and writes the next
///               Safe batch to output/etherfi/timelock/ ([next]). For timelock operations it also
///               pre-writes the execute batch as soon as the schedule batch exists ([prep]), so it
///               can be reviewed and queued in the Safe before the delay elapses. A batch that does
///               not depend on [next] and may be sent at the same time by its own signer is written
///               as [also] (phase 3's schedule goes out with phase 2, so the 24h delay overlaps the
///               Admin Safe's signing). Re-run after each Safe execution or timelock maturity until
///               it returns COMPLETE.
///
///   forge script scripts/etherfi/timelock/EtherfiCashTimelock.s.sol --sig 'deploy()' \
///     --rpc-url optimism --account <keystore> --sender <address> --slow --broadcast --verify
///   forge script scripts/etherfi/timelock/EtherfiCashTimelock.s.sol --sig 'configure()' \
///     --rpc-url optimism
contract EtherfiCashTimelockScript is EtherfiCashGovernanceBase {
  enum Phase {
    DEPLOY,
    EXECUTOR,
    CANCELLERS,
    ACCESS_MANAGER,
    DRY_RUN,
    OWNERSHIP,
    TREASURY_ACCEPT,
    REVOCATIONS,
    COMPLETE
  }

  error StagedConstant(string name);
  error PinnedAddressMismatch(string name, address pinned, address actual);
  error DeployedAddressMismatch(address deployed, address predicted);
  error BytecodeMismatch(address timelock);

  function run() external {
    vm.startBroadcast(vm.envUint('PRIVATE_KEY'));
    address(0xbaCa0cD6B69Eef3257e2D122b22ddEE8AeE5e283).call(
      hex'e38335e500000000000000000000000000000000000000000000000000000000000000a0000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000001600000000000000000000000000000000000000000000000000000000000000000eb819b245cbf5981f8591b6a1832b56d855f1a0fb9208df8bb2daf88cea84b650000000000000000000000000000000000000000000000000000000000000002000000000000000000000000baca0cd6b69eef3257e2d122b22ddee8aee5e283000000000000000000000000baca0cd6b69eef3257e2d122b22ddee8aee5e2830000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000000c000000000000000000000000000000000000000000000000000000000000000442f2ff15dd8aa0f3194971a2a116679f7c2090f6939c8d4e01a2a8d7e41d55e5351469e63000000000000000000000000d442635bc9bf83e21bba8b65e224f5db6a011166000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000044d547741fd8aa0f3194971a2a116679f7c2090f6939c8d4e01a2a8d7e41d55e5351469e63000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000'
    );
    vm.stopBroadcast();
  }

  function deploy() external returns (address timelock) {
    _requireOpMainnet();
    timelock = _timelockAddress();
    address broadcaster;
    if (timelock.code.length == 0) {
      vm.startBroadcast();
      (, broadcaster, ) = vm.readCallers();
      address deployed = Create2Utils.create2Deploy(Timelock.SALT, _timelockInitCode());
      vm.stopBroadcast();
      require(deployed == timelock, DeployedAddressMismatch(deployed, timelock));
      console2.log('EtherFiTimelock deployed at:', timelock);
    } else {
      console2.log('EtherFiTimelock already deployed at:', timelock, '- verifying only');
    }
    _verifyTimelock(timelock, broadcaster, _executorSeated(timelock), _cancellersGranted(timelock));
    if (Cash.TIMELOCK == address(0)) {
      console2.log('ACTION: pin AaveV4EtherfiCash.TIMELOCK =', timelock);
    }
  }

  function configure() external returns (Phase) {
    _requireOpMainnet();
    delete alsoEmitted;
    address timelock = _timelockAddress();
    if (timelock.code.length == 0) return _pending(Phase.DEPLOY, 'no timelock code: run deploy()');
    bool executorSeated = _executorSeated(timelock);
    bool cancellersGranted = _cancellersGranted(timelock);
    _verifyTimelock(timelock, address(0), executorSeated, cancellersGranted);
    _done('phase 1a: timelock deployed + verified');

    // phase 1b — the Timelock Safe schedules two operations in one MultiSend; after 24h they are
    // executed one at a time, in this order:
    //   1b-i  executor op: seats the Timelock Safe as the only EXECUTOR and revokes the open
    //         address(0) seat. Executed under open execution — the last time anyone may execute.
    //   1b-ii cancellers op: CANCELLER_ROLE to the Admin + Operator Safes. Only the Timelock
    //         Safe can execute it now, which proves the executor seat live before anything else
    //         goes through the queue.
    GnosisTxBuilder.Tx[] memory executorOp = new GnosisTxBuilder.Tx[](2);
    executorOp[0] = _timelockGrantRole(timelock, Timelock.EXECUTOR_ROLE, Cash.TIMELOCK_SAFE);
    executorOp[1] = _timelockRevokeRole(timelock, Timelock.EXECUTOR_ROLE, Timelock.EXECUTOR);
    GnosisTxBuilder.Tx[] memory cancellersOp = new GnosisTxBuilder.Tx[](2);
    cancellersOp[0] = _timelockGrantRole(timelock, Timelock.CANCELLER_ROLE, Cash.OWNER_SAFE);
    cancellersOp[1] = _timelockGrantRole(timelock, Timelock.CANCELLER_ROLE, Cash.OPERATOR_SAFE);
    if (!executorSeated || !cancellersGranted) {
      bool executorScheduled = _isOperation(timelock, Timelock.OP_SALT_EXECUTOR, executorOp);
      bool cancellersScheduled = _isOperation(timelock, Timelock.OP_SALT_CANCELLERS, cancellersOp);
      if (!executorScheduled || !cancellersScheduled) {
        return
          _scheduleBoth(timelock, executorScheduled, executorOp, cancellersScheduled, cancellersOp);
      }
    }
    if (!executorSeated) {
      return
        _drive(Phase.EXECUTOR, timelock, 'phase1b-executor', Timelock.OP_SALT_EXECUTOR, executorOp);
    }
    _done('phase 1b-i: Timelock Safe is the only EXECUTOR (open seat revoked)');
    if (!cancellersGranted) {
      return
        _drive(
          Phase.CANCELLERS,
          timelock,
          'phase1b-cancellers',
          Timelock.OP_SALT_CANCELLERS,
          cancellersOp
        );
    }
    _done(
      'phase 1b-ii: Admin Safe + Operator Safe hold CANCELLER_ROLE (Timelock-Safe-only execute)'
    );

    // phase 2 — Admin Safe, one batch
    bool phase2Done = _hasRole(R.ADMIN_ROLE, timelock);
    bool adminRevoked = !_hasRole(R.ADMIN_ROLE, Cash.OWNER_SAFE);
    _verifyAccessManager(timelock, phase2Done, adminRevoked);
    GnosisTxBuilder.Tx[] memory txs = new GnosisTxBuilder.Tx[](16);
    txs[0] = _labelRole(
      R.HUB_CONFIGURATOR_SPOKE_UNHALT_ROLE,
      R.HUB_CONFIGURATOR_SPOKE_UNHALT_ROLE_LABEL
    );
    txs[1] = _labelRole(
      R.SPOKE_CONFIGURATOR_UNPAUSE_UNFREEZE_ROLE,
      R.SPOKE_CONFIGURATOR_UNPAUSE_UNFREEZE_ROLE_LABEL
    );
    txs[2] = _setTargetFunctionRole(
      Cash.HUB_CONFIGURATOR,
      _sel(IHubConfigurator.updateLiquidityFee.selector),
      R.HUB_CONFIGURATOR_DOMAIN_ADMIN_ROLE
    );
    txs[3] = _setTargetFunctionRole(
      Cash.HUB_CONFIGURATOR,
      _sel(IHubConfigurator.updateSpokeHalted.selector),
      R.HUB_CONFIGURATOR_SPOKE_UNHALT_ROLE
    );
    txs[4] = _setTargetFunctionRole(
      Cash.SPOKE_CONFIGURATOR,
      _sel(ISpokeConfigurator.updateBorrowable.selector),
      R.SPOKE_CONFIGURATOR_DOMAIN_ADMIN_ROLE
    );
    txs[5] = _setTargetFunctionRole(
      Cash.SPOKE_CONFIGURATOR,
      _sel(ISpokeConfigurator.updatePaused.selector, ISpokeConfigurator.updateFrozen.selector),
      R.SPOKE_CONFIGURATOR_UNPAUSE_UNFREEZE_ROLE
    );
    txs[6] = _setTargetFunctionRole(
      Cash.SPOKE_CONFIGURATOR,
      _sel(ISpokeConfigurator.updateLiquidationConfig.selector),
      R.SPOKE_RISK_CURATOR_ROLE
    );
    txs[7] = _grantRole(R.HUB_CONFIGURATOR_SPOKE_UNHALT_ROLE, Cash.OWNER_SAFE);
    txs[8] = _grantRole(R.SPOKE_CONFIGURATOR_UNPAUSE_UNFREEZE_ROLE, Cash.OWNER_SAFE);
    txs[9] = _grantRole(R.ADMIN_ROLE, timelock);
    txs[10] = _grantRole(R.HUB_CONFIGURATOR_DOMAIN_ADMIN_ROLE, timelock);
    txs[11] = _grantRole(R.SPOKE_CONFIGURATOR_DOMAIN_ADMIN_ROLE, timelock);
    txs[12] = _grantRole(R.HUB_DEFICIT_ELIMINATOR_ROLE, timelock);
    txs[13] = _grantRole(R.SPOKE_USER_POSITION_UPDATER_ROLE, timelock);
    txs[14] = _setRoleGuardian(R.HUB_CONFIGURATOR_DOMAIN_ADMIN_ROLE, R.HUB_GUARDIAN_ROLE);
    txs[15] = _setRoleGuardian(R.SPOKE_CONFIGURATOR_DOMAIN_ADMIN_ROLE, R.SPOKE_GUARDIAN_ROLE);

    // phase 3 — no-op through the queue (proves timelock -> AccessManager root). Re-sets a phase-2
    // value: AccessManager refuses to relabel a role (AccessManagerRoleAlreadyLabeled)
    GnosisTxBuilder.Tx[] memory dryRun = new GnosisTxBuilder.Tx[](1);
    dryRun[0] = _setRoleGuardian(R.HUB_CONFIGURATOR_DOMAIN_ADMIN_ROLE, R.HUB_GUARDIAN_ROLE);

    if (!phase2Done) {
      _emitBatch(Cash.OWNER_SAFE, 'phase2-admin-safe-access-manager', txs);
      // The phase 3 schedule only needs the Timelock Safe's PROPOSER seat, so it goes out with
      // phase 2 and the 24h delay runs while the Admin Safe signs. Its execute stays [prep]: it
      // needs phase 2 applied (timelock = AccessManager admin) and is gated below.
      if (!_isOperation(timelock, Timelock.OP_SALT_DRY_RUN, dryRun)) {
        _emitScheduleAlongside(
          timelock,
          Cash.TIMELOCK_SAFE,
          Cash.TIMELOCK_SAFE,
          'phase3-dry-run',
          Timelock.OP_SALT_DRY_RUN,
          Timelock.MIN_DELAY,
          dryRun
        );
      }
      return Phase.ACCESS_MANAGER;
    }
    _done('phase 2: AccessManager batch applied');

    if (!_isOperationDone(timelock, Timelock.OP_SALT_DRY_RUN, dryRun)) {
      return _drive(Phase.DRY_RUN, timelock, 'phase3-dry-run', Timelock.OP_SALT_DRY_RUN, dryRun);
    }
    _done('phase 3: dry run executed through the timelock');

    // phase 4 — Admin Safe, one batch; TreasurySpoke is two-step so the timelock accepts via the queue
    bool proxyAdminsMoved = _owner(Hubs.CASH_HUB_PROXY_ADMIN) == timelock;
    bool treasuryAccepted = _owner(Spokes.TREASURY_SPOKE) == timelock;
    _verifyOwnership(timelock, proxyAdminsMoved, treasuryAccepted);
    txs = new GnosisTxBuilder.Tx[](4);
    txs[0] = _transferOwnership(Hubs.CASH_HUB_PROXY_ADMIN, timelock);
    txs[1] = _transferOwnership(Spokes.CASH_SPOKE_PROXY_ADMIN, timelock);
    txs[2] = _transferOwnership(Spokes.TREASURY_SPOKE_PROXY_ADMIN, timelock);
    txs[3] = _transferOwnership(Spokes.TREASURY_SPOKE, timelock);
    if (!proxyAdminsMoved) return _emit(Phase.OWNERSHIP, 'phase4-admin-safe-ownership', txs);
    _done('phase 4a: ProxyAdmins owned by the timelock');

    txs = new GnosisTxBuilder.Tx[](1);
    txs[0] = _acceptOwnership(Spokes.TREASURY_SPOKE);
    if (!treasuryAccepted) {
      return
        _drive(
          Phase.TREASURY_ACCEPT,
          timelock,
          'phase4b-treasury-accept',
          Timelock.OP_SALT_TREASURY_ACCEPT,
          txs
        );
    }
    _done('phase 4b: TreasurySpoke owned by the timelock');

    // phase 5 — Admin Safe, one batch; root admin last. POINT OF NO RETURN
    txs = new GnosisTxBuilder.Tx[](5);
    txs[0] = _revokeRole(R.HUB_CONFIGURATOR_DOMAIN_ADMIN_ROLE, Cash.OWNER_SAFE);
    txs[1] = _revokeRole(R.SPOKE_CONFIGURATOR_DOMAIN_ADMIN_ROLE, Cash.OWNER_SAFE);
    txs[2] = _revokeRole(R.HUB_DEFICIT_ELIMINATOR_ROLE, Cash.OWNER_SAFE);
    txs[3] = _revokeRole(R.SPOKE_USER_POSITION_UPDATER_ROLE, Cash.OWNER_SAFE);
    txs[4] = _revokeRole(R.ADMIN_ROLE, Cash.OWNER_SAFE);
    if (!adminRevoked) return _emit(Phase.REVOCATIONS, 'phase5-admin-safe-revocations', txs);
    _done('phase 5: Admin Safe holds no timelocked role');

    delete lastEmitted;
    console2.log('=== COMPLETE: every phase executed and verified ===');
    return Phase.COMPLETE;
  }

  // ═══════════════════════════════════════════════════════════════════════════════════════════
  // Timelock deployment
  // ═══════════════════════════════════════════════════════════════════════════════════════════

  function _timelockInitCode() internal pure returns (bytes memory) {
    address[] memory proposers = new address[](1);
    proposers[0] = Cash.TIMELOCK_SAFE;
    address[] memory executors = new address[](1);
    executors[0] = Timelock.EXECUTOR;
    return
      abi.encodePacked(
        type(EtherFiTimelock).creationCode,
        abi.encode(Timelock.MIN_DELAY, proposers, executors, Timelock.ADMIN)
      );
  }

  /// @notice Predicted CREATE2 address (Safe Singleton Factory); asserted against the pin once set.
  function timelockAddress() external pure returns (address) {
    return _timelockAddress();
  }

  function _timelockAddress() internal pure returns (address predicted) {
    require(Cash.TIMELOCK_SAFE != address(0), StagedConstant('TIMELOCK_SAFE'));
    predicted = Create2Utils.computeCreate2Address(Timelock.SALT, _timelockInitCode());
    require(
      Cash.TIMELOCK == address(0) || Cash.TIMELOCK == predicted,
      PinnedAddressMismatch('TIMELOCK', Cash.TIMELOCK, predicted)
    );
  }

  /// @dev Exact runtime code + every role seat; `broadcaster` (if given) must hold nothing.
  /// @param executorSeated after phase 1b-i: Timelock Safe sole EXECUTOR, open seat revoked
  /// @param cancellersGranted after phase 1b-ii: Admin + Operator Safes CANCELLER
  function _verifyTimelock(
    address timelock,
    address broadcaster,
    bool executorSeated,
    bool cancellersGranted
  ) internal {
    require(
      keccak256(timelock.code) == keccak256(type(EtherFiTimelock).runtimeCode),
      BytecodeMismatch(timelock)
    );
    TimelockController tl = TimelockController(payable(timelock));
    bytes32 proposer = tl.PROPOSER_ROLE();
    bytes32 executor = tl.EXECUTOR_ROLE();
    bytes32 canceller = tl.CANCELLER_ROLE();
    bytes32 admin = tl.DEFAULT_ADMIN_ROLE();

    _check('CANCELLER_ROLE constant', uint256(canceller), uint256(Timelock.CANCELLER_ROLE));
    _check('EXECUTOR_ROLE constant', uint256(executor), uint256(Timelock.EXECUTOR_ROLE));
    _check('timelock.minDelay', tl.getMinDelay(), Timelock.MIN_DELAY);
    _checkBool('timelock is its own ADMIN', tl.hasRole(admin, timelock), true);
    // Timelock Safe: proposer + canceller from the constructor, executor from phase 1b-i
    _checkBool('Timelock Safe is PROPOSER', tl.hasRole(proposer, Cash.TIMELOCK_SAFE), true);
    _checkBool('Timelock Safe is CANCELLER', tl.hasRole(canceller, Cash.TIMELOCK_SAFE), true);
    _checkBool(
      'Timelock Safe is EXECUTOR',
      tl.hasRole(executor, Cash.TIMELOCK_SAFE),
      executorSeated
    );
    _checkBool('Timelock Safe is not ADMIN', tl.hasRole(admin, Cash.TIMELOCK_SAFE), false);
    // open execution (address(0)) only until phase 1b-i revokes it
    _checkBool(
      'open EXECUTOR (address(0))',
      tl.hasRole(executor, Timelock.EXECUTOR),
      !executorSeated
    );
    // Admin Safe + Operator Safe: cancellers from phase 1b-ii, nothing else ever
    _checkBool(
      'Admin Safe is CANCELLER',
      tl.hasRole(canceller, Cash.OWNER_SAFE),
      cancellersGranted
    );
    _checkBool('Admin Safe is not PROPOSER', tl.hasRole(proposer, Cash.OWNER_SAFE), false);
    _checkBool('Admin Safe is not EXECUTOR', tl.hasRole(executor, Cash.OWNER_SAFE), false);
    _checkBool('Admin Safe is not ADMIN', tl.hasRole(admin, Cash.OWNER_SAFE), false);
    _checkBool(
      'Operator Safe is CANCELLER',
      tl.hasRole(canceller, Cash.OPERATOR_SAFE),
      cancellersGranted
    );
    _checkBool('Operator Safe is not PROPOSER', tl.hasRole(proposer, Cash.OPERATOR_SAFE), false);
    _checkBool('Operator Safe is not EXECUTOR', tl.hasRole(executor, Cash.OPERATOR_SAFE), false);
    _checkBool('Operator Safe is not ADMIN', tl.hasRole(admin, Cash.OPERATOR_SAFE), false);
    if (broadcaster != address(0)) {
      _checkBool('deployer is not PROPOSER', tl.hasRole(proposer, broadcaster), false);
      _checkBool('deployer is not CANCELLER', tl.hasRole(canceller, broadcaster), false);
      _checkBool('deployer is not EXECUTOR', tl.hasRole(executor, broadcaster), false);
      _checkBool('deployer is not ADMIN', tl.hasRole(admin, broadcaster), false);
    }
    _assertNoMismatches('timelock configuration');
  }

  /// @dev Phase 1b-i applied: the Timelock Safe executes, the open seat is gone.
  function _executorSeated(address timelock) internal view returns (bool) {
    TimelockController tl = TimelockController(payable(timelock));
    return
      tl.hasRole(Timelock.EXECUTOR_ROLE, Cash.TIMELOCK_SAFE) &&
      !tl.hasRole(Timelock.EXECUTOR_ROLE, Timelock.EXECUTOR);
  }

  /// @dev Phase 1b-ii applied: both Safes can cancel.
  function _cancellersGranted(address timelock) internal view returns (bool) {
    TimelockController tl = TimelockController(payable(timelock));
    return
      tl.hasRole(Timelock.CANCELLER_ROLE, Cash.OWNER_SAFE) &&
      tl.hasRole(Timelock.CANCELLER_ROLE, Cash.OPERATOR_SAFE);
  }

  // ═══════════════════════════════════════════════════════════════════════════════════════════
  // Expected-state verification (step 18 and the per-phase gates)
  // ═══════════════════════════════════════════════════════════════════════════════════════════

  /// @dev Memberships, the 46-selector map and role guardians.
  /// @param migrated false = launch state expected (phase 2 not applied), true = after phase 2
  /// @param adminRevoked true = after phase 5 (Admin Safe out of 0/200/400/103/302)
  function _verifyAccessManager(address timelock, bool migrated, bool adminRevoked) internal {
    EtherfiCashLaunchPayload payload = new EtherfiCashLaunchPayload();
    _verifyConstants(payload);
    _verifyRoleMemberships(timelock, migrated, adminRevoked);
    _verifySelectorMap(payload.accessManagerTargetFunctionRoleUpdates(), migrated);
    IAccessManager am = IAccessManager(Cash.ACCESS_MANAGER);
    _check(
      'roleGuardian(200)',
      am.getRoleGuardian(R.HUB_CONFIGURATOR_DOMAIN_ADMIN_ROLE),
      migrated ? R.HUB_GUARDIAN_ROLE : R.ADMIN_ROLE
    );
    _check(
      'roleGuardian(400)',
      am.getRoleGuardian(R.SPOKE_CONFIGURATOR_DOMAIN_ADMIN_ROLE),
      migrated ? R.SPOKE_GUARDIAN_ROLE : R.ADMIN_ROLE
    );
    _assertNoMismatches(
      migrated ? 'AccessManager state after phase 2' : 'AccessManager pre-state (live != launch)'
    );
  }

  /// @dev ProxyAdmins re-derived from the EIP-1967 slots, then owners per phase-4 progress.
  function _verifyOwnership(
    address timelock,
    bool proxyAdminsMoved,
    bool treasuryAccepted
  ) internal {
    _checkAddr('CASH_HUB admin slot', _erc1967Admin(Hubs.CASH_HUB), Hubs.CASH_HUB_PROXY_ADMIN);
    _checkAddr(
      'CASH_SPOKE admin slot',
      _erc1967Admin(Spokes.CASH_SPOKE),
      Spokes.CASH_SPOKE_PROXY_ADMIN
    );
    _checkAddr(
      'TREASURY_SPOKE admin slot',
      _erc1967Admin(Spokes.TREASURY_SPOKE),
      Spokes.TREASURY_SPOKE_PROXY_ADMIN
    );

    address expectedOwner = proxyAdminsMoved ? timelock : Cash.OWNER_SAFE;
    _checkAddr('CASH_HUB_PROXY_ADMIN.owner', _owner(Hubs.CASH_HUB_PROXY_ADMIN), expectedOwner);
    _checkAddr(
      'CASH_SPOKE_PROXY_ADMIN.owner',
      _owner(Spokes.CASH_SPOKE_PROXY_ADMIN),
      expectedOwner
    );
    _checkAddr(
      'TREASURY_SPOKE_PROXY_ADMIN.owner',
      _owner(Spokes.TREASURY_SPOKE_PROXY_ADMIN),
      expectedOwner
    );

    Ownable2StepUpgradeable treasury = Ownable2StepUpgradeable(Spokes.TREASURY_SPOKE);
    _checkAddr(
      'TREASURY_SPOKE.owner',
      treasury.owner(),
      treasuryAccepted ? timelock : Cash.OWNER_SAFE
    );
    _checkAddr(
      'TREASURY_SPOKE.pendingOwner',
      treasury.pendingOwner(),
      proxyAdminsMoved && !treasuryAccepted ? timelock : address(0)
    );
    _assertNoMismatches('ownership (ProxyAdmins + TreasurySpoke)');
  }

  /// @dev The plain-value constants in AaveV4EtherfiCash.sol must equal what the code derives.
  function _verifyConstants(EtherfiCashLaunchPayload payload) internal {
    _check('ADMIN_ROLE', R.ADMIN_ROLE, Roles.ACCESS_MANAGER_ADMIN_ROLE);
    _check('HUB_FEE_MINTER_ROLE', R.HUB_FEE_MINTER_ROLE, Roles.HUB_FEE_MINTER_ROLE);
    _check(
      'HUB_DEFICIT_ELIMINATOR_ROLE',
      R.HUB_DEFICIT_ELIMINATOR_ROLE,
      Roles.HUB_DEFICIT_ELIMINATOR_ROLE
    );
    _check(
      'HUB_CONFIGURATOR_DOMAIN_ADMIN_ROLE',
      R.HUB_CONFIGURATOR_DOMAIN_ADMIN_ROLE,
      Roles.HUB_CONFIGURATOR_DOMAIN_ADMIN_ROLE
    );
    _check(
      'SPOKE_USER_POSITION_UPDATER_ROLE',
      R.SPOKE_USER_POSITION_UPDATER_ROLE,
      Roles.SPOKE_USER_POSITION_UPDATER_ROLE
    );
    _check(
      'SPOKE_CONFIGURATOR_DOMAIN_ADMIN_ROLE',
      R.SPOKE_CONFIGURATOR_DOMAIN_ADMIN_ROLE,
      Roles.SPOKE_CONFIGURATOR_DOMAIN_ADMIN_ROLE
    );
    _check('HUB_RISK_CURATOR_ROLE', R.HUB_RISK_CURATOR_ROLE, payload.HUB_RISK_CURATOR_ROLE());
    _check('HUB_GUARDIAN_ROLE', R.HUB_GUARDIAN_ROLE, payload.HUB_GUARDIAN_ROLE());
    _check('SPOKE_RISK_CURATOR_ROLE', R.SPOKE_RISK_CURATOR_ROLE, payload.SPOKE_RISK_CURATOR_ROLE());
    _check('SPOKE_GUARDIAN_ROLE', R.SPOKE_GUARDIAN_ROLE, payload.SPOKE_GUARDIAN_ROLE());

    _check(
      'CONFIGURATOR_SELECTOR_COUNT',
      R.CONFIGURATOR_SELECTOR_COUNT,
      Roles.getHubConfiguratorDomainAdminRoleSelectors().length +
        Roles.getSpokeConfiguratorDomainAdminRoleSelectors().length
    );
  }

  /// @dev OZ AccessManager has no member enumeration: every account expected anywhere is checked
  /// against every role of interest (12 roles × 5 accounts), presence AND absence.
  function _verifyRoleMemberships(address timelock, bool migrated, bool adminRevoked) internal {
    uint64[12] memory roles = [
      R.ADMIN_ROLE,
      R.HUB_FEE_MINTER_ROLE,
      R.HUB_DEFICIT_ELIMINATOR_ROLE,
      R.HUB_CONFIGURATOR_DOMAIN_ADMIN_ROLE,
      R.HUB_RISK_CURATOR_ROLE,
      R.HUB_GUARDIAN_ROLE,
      R.HUB_CONFIGURATOR_SPOKE_UNHALT_ROLE,
      R.SPOKE_USER_POSITION_UPDATER_ROLE,
      R.SPOKE_CONFIGURATOR_DOMAIN_ADMIN_ROLE,
      R.SPOKE_RISK_CURATOR_ROLE,
      R.SPOKE_GUARDIAN_ROLE,
      R.SPOKE_CONFIGURATOR_UNPAUSE_UNFREEZE_ROLE
    ];
    for (uint256 i; i < roles.length; i++) {
      uint64 role = roles[i];
      bool timelocked = role == R.ADMIN_ROLE ||
        role == R.HUB_CONFIGURATOR_DOMAIN_ADMIN_ROLE ||
        role == R.SPOKE_CONFIGURATOR_DOMAIN_ADMIN_ROLE ||
        role == R.HUB_DEFICIT_ELIMINATOR_ROLE ||
        role == R.SPOKE_USER_POSITION_UPDATER_ROLE;
      bool restart = role == R.HUB_CONFIGURATOR_SPOKE_UNHALT_ROLE ||
        role == R.SPOKE_CONFIGURATOR_UNPAUSE_UNFREEZE_ROLE;
      bool curator = role == R.HUB_RISK_CURATOR_ROLE || role == R.SPOKE_RISK_CURATOR_ROLE;
      bool guardian = role == R.HUB_GUARDIAN_ROLE || role == R.SPOKE_GUARDIAN_ROLE;

      // TIMELOCK: 0/200/400/103/302 once migrated, nothing before
      _expectMember(role, timelock, 'TIMELOCK', migrated && timelocked);
      // Admin Safe: everything until phase 5, then minus the timelocked roles; 203/403 from phase 2
      _expectMember(
        role,
        Cash.OWNER_SAFE,
        'ADMIN_SAFE',
        restart ? migrated : (timelocked ? !adminRevoked : true)
      );
      // Operator Safe: 201/202/401/402 only
      _expectMember(role, Cash.OPERATOR_SAFE, 'OPERATOR_SAFE', curator || guardian);
      // guardian EOA: 202/402 only
      _expectMember(role, Cash.GUARDIAN_HYPERNATIVE, 'GUARDIAN_EOA', guardian);
      // Timelock Safe: never a direct member of anything
      _expectMember(role, Cash.TIMELOCK_SAFE, 'TIMELOCK_SAFE', false);
    }
  }

  function _expectMember(uint64 role, address account, string memory who, bool expected) internal {
    _checkBool(
      string.concat('hasRole(', vm.toString(role), ', ', who, ')'),
      _hasRole(role, account),
      expected
    );
  }

  /// @dev All 46 configurator selectors: expected = launch payload assignment, overlaid with the
  /// phase-2 moves when `migrated`; anything else falls back to the domain admin role.
  function _verifySelectorMap(
    IAaveV4ConfigEngine.TargetFunctionRoleUpdate[] memory launch,
    bool migrated
  ) internal {
    bytes4[] memory hub = Roles.getHubConfiguratorDomainAdminRoleSelectors();
    for (uint256 i; i < hub.length; i++) {
      _checkSelectorRole(Cash.HUB_CONFIGURATOR, hub[i], launch, migrated);
    }
    bytes4[] memory spoke = Roles.getSpokeConfiguratorDomainAdminRoleSelectors();
    for (uint256 i; i < spoke.length; i++) {
      _checkSelectorRole(Cash.SPOKE_CONFIGURATOR, spoke[i], launch, migrated);
    }
  }

  function _checkSelectorRole(
    address target,
    bytes4 selector,
    IAaveV4ConfigEngine.TargetFunctionRoleUpdate[] memory launch,
    bool migrated
  ) internal {
    _check(
      string.concat('role of ', _name(target), '.', _hex(selector)),
      IAccessManager(Cash.ACCESS_MANAGER).getTargetFunctionRole(target, selector),
      _expectedSelectorRole(target, selector, launch, migrated)
    );
  }

  function _expectedSelectorRole(
    address target,
    bytes4 selector,
    IAaveV4ConfigEngine.TargetFunctionRoleUpdate[] memory launch,
    bool migrated
  ) internal pure returns (uint64) {
    if (migrated && target == Cash.HUB_CONFIGURATOR) {
      if (selector == IHubConfigurator.updateLiquidityFee.selector) {
        return R.HUB_CONFIGURATOR_DOMAIN_ADMIN_ROLE;
      }
      if (selector == IHubConfigurator.updateSpokeHalted.selector) {
        return R.HUB_CONFIGURATOR_SPOKE_UNHALT_ROLE;
      }
    }
    if (migrated && target == Cash.SPOKE_CONFIGURATOR) {
      if (selector == ISpokeConfigurator.updateBorrowable.selector) {
        return R.SPOKE_CONFIGURATOR_DOMAIN_ADMIN_ROLE;
      }
      if (
        selector == ISpokeConfigurator.updatePaused.selector ||
        selector == ISpokeConfigurator.updateFrozen.selector
      ) {
        return R.SPOKE_CONFIGURATOR_UNPAUSE_UNFREEZE_ROLE;
      }
      if (selector == ISpokeConfigurator.updateLiquidationConfig.selector) {
        return R.SPOKE_RISK_CURATOR_ROLE;
      }
    }
    for (uint256 i; i < launch.length; i++) {
      if (launch[i].target != target) continue;
      for (uint256 j; j < launch[i].selectors.length; j++) {
        if (launch[i].selectors[j] == selector) return launch[i].roleId;
      }
    }
    return
      target == Cash.HUB_CONFIGURATOR
        ? R.HUB_CONFIGURATOR_DOMAIN_ADMIN_ROLE
        : R.SPOKE_CONFIGURATOR_DOMAIN_ADMIN_ROLE;
  }

  // ═══════════════════════════════════════════════════════════════════════════════════════════
  // Phase flow
  // ═══════════════════════════════════════════════════════════════════════════════════════════

  function _emit(
    Phase phase,
    string memory name,
    GnosisTxBuilder.Tx[] memory txs
  ) internal returns (Phase) {
    _emitBatch(Cash.OWNER_SAFE, name, txs);
    return phase;
  }

  /// @dev Phase 1b schedule: one Timelock Safe MultiSend with a `scheduleBatch` per operation
  /// not yet on the queue (both, normally).
  function _scheduleBoth(
    address timelock,
    bool executorScheduled,
    GnosisTxBuilder.Tx[] memory executorOp,
    bool cancellersScheduled,
    GnosisTxBuilder.Tx[] memory cancellersOp
  ) internal returns (Phase) {
    uint256 n = (executorScheduled ? 0 : 1) + (cancellersScheduled ? 0 : 1);
    bytes32[] memory salts = new bytes32[](n);
    GnosisTxBuilder.Tx[][] memory ops = new GnosisTxBuilder.Tx[][](n);
    uint256 i;
    if (!executorScheduled) {
      salts[i] = Timelock.OP_SALT_EXECUTOR;
      ops[i++] = executorOp;
    }
    if (!cancellersScheduled) {
      salts[i] = Timelock.OP_SALT_CANCELLERS;
      ops[i] = cancellersOp;
    }
    _emitSchedules(
      timelock,
      Cash.TIMELOCK_SAFE,
      'phase1b-timelock-roles',
      salts,
      Timelock.MIN_DELAY,
      ops
    );
    // execute batches ahead of time, in execution order
    _previewExecute(
      timelock,
      Cash.TIMELOCK_SAFE,
      'phase1b-executor',
      Timelock.OP_SALT_EXECUTOR,
      executorOp
    );
    _previewExecute(
      timelock,
      Cash.TIMELOCK_SAFE,
      'phase1b-cancellers',
      Timelock.OP_SALT_CANCELLERS,
      cancellersOp
    );
    return Phase.EXECUTOR;
  }

  function _drive(
    Phase phase,
    address timelock,
    string memory name,
    bytes32 salt,
    GnosisTxBuilder.Tx[] memory txs
  ) internal returns (Phase) {
    _driveOperation(
      timelock,
      Cash.TIMELOCK_SAFE,
      Cash.TIMELOCK_SAFE,
      name,
      salt,
      Timelock.MIN_DELAY,
      txs
    );
    return phase;
  }

  function _pending(Phase phase, string memory reason) internal returns (Phase) {
    delete lastEmitted;
    console2.log('[next]', reason);
    return phase;
  }

  function _done(string memory what) internal pure {
    console2.log('[done]', what);
  }
}
