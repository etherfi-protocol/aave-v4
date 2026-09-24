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
  AaveV4EtherfiCashCollateral as Collateral,
  AaveV4EtherfiCashRates as Rates,
  AaveV4EtherfiCashTimelock as Timelock
} from 'src/etherfi/AaveV4EtherfiCash.sol';
import {TimelockController} from 'src/dependencies/openzeppelin/TimelockController.sol';
import {IERC20Metadata} from 'src/dependencies/openzeppelin/IERC20Metadata.sol';
import {IHub} from 'src/hub/interfaces/IHub.sol';
import {ISpoke} from 'src/spoke/interfaces/ISpoke.sol';
import {IAaveOracle} from 'src/spoke/interfaces/IAaveOracle.sol';
import {IPriceFeed} from 'src/spoke/interfaces/IPriceFeed.sol';
import {IAssetInterestRateStrategy} from 'src/hub/interfaces/IAssetInterestRateStrategy.sol';

/// @title EtherfiCashCollateralListings
/// @notice Three timelock operations on the ether.fi Cash Aave V4 instance (OP Mainnet), through the
/// EtherFiTimelock (the only holder of the configurator domain-admin roles 200 / 400 since the
/// migration), scheduled together in ONE Timelock Safe batch and executed one by one, each from its
/// own Timelock Safe file:
///   usdt   USDT0 listed BORROWABLE (draw cap 0) + the live USDT reserve OPENED for borrowing
///          (updateLiquidityFee + updateBorrowable) - one atomic operation, salt OP_SALT_USDT0_LISTING
///   paxgy  PAXGy listed collateral-only                                   salt OP_SALT_PAXGY_LISTING
///   zchf   ZCHF listed collateral-only                                    salt OP_SALT_ZCHF_LISTING
/// The USDT curve and its draw cap (explicitly 0) are the risk curator's calls (role 201): ONE
/// Operator Safe batch, written alongside; the usdt operation executes only once it has landed.
/// Inputs: `AaveV4EtherfiCash.sol` (Assets.<ASSET>_*, Caps.<ASSET>_*_CAP, Collateral.*, Rates.*).
///
///   Listing (per new asset), the iwSPYx / iPAXG shape:
///     1. HubConfigurator.addAsset       curve + liquidity fee (flat 0% / 0% when collateral-only), TreasurySpoke
///     2. HubConfigurator.addSpoke       Cash Spoke: addCap Caps.<ASSET>_ADD_CAP (0 = listed closed), drawCap 0
///     3. SpokeConfigurator.addReserve   Assets.<ASSET>_ORACLE, Collateral.<ASSET>_* CF / bonus, borrowable flag
///   Asset ids are baked into the calldata: the unlisted assets take the live counter onwards in the
///   order above (USDT0, PAXGy, ZCHF); an operation already on the queue keeps the id it was scheduled
///   with. Operations therefore EXECUTE IN THAT ORDER, each once the one before it is done (an
///   out-of-order execute reverts as a whole; the script emits one execute per run, in order). If
///   anything else is listed in between, the ids drift and a queued operation can only revert: a
///   canceller Safe cancels it and this script schedules a fresh one - it refuses to write anything
///   while such a stale operation is queued.
///
///   Scheduling does NOT wait for the feeds: an operation is scheduled even when its oracle has no
///   code yet ([feed] note). Executing needs the feed to PRICE (AaveOracle.setReserveSource reads
///   latestAnswer()): a Ready operation whose feed is dead is held ([hold]) until it does. An asset
///   whose underlying has no code yet (a predicted OFT) is held before scheduling ([token]).
///
///   configure() read-only; verifies underlyings + feeds and that each signer may send its calls under
///               the LIVE AccessManager (NoSigner otherwise), then writes to output/etherfi/listings/:
///               listings-schedule.json  ONE Timelock Safe MultiSend scheduling every unscheduled operation
///               <op>-execute.json       one Timelock Safe file per operation, pre-written ([prep]) from the
///                                       first run; the next one to send is the run's [next]
///               openings-curator.json   the Operator Safe batch (USDT curve + draw cap 0), [also] / [next]
///               Re-run after each Safe execution and after the delay until it returns COMPLETE, which
///               reads every parameter back. BLOCKED = nothing can move (feed / token / curator).
///   plan()      configure(), then applies each batch in this VM (24h delay included) to COMPLETE.
///
///   forge script scripts/etherfi/listings/EtherfiCashCollateralListings.s.sol --sig 'configure()' \
///     --rpc-url optimism
///   forge script scripts/etherfi/listings/EtherfiCashCollateralListings.s.sol --sig 'plan()' \
///     --rpc-url optimism
contract EtherfiCashCollateralListingsScript is EtherfiCashGovernanceBase {
  enum Phase {
    BLOCKED,
    LISTING,
    COMPLETE
  }

  struct Listing {
    string symbol;
    string opName;
    address underlying;
    uint8 decimals;
    address oracle;
    string feedDescription;
    uint40 addCap;
    uint40 drawCap;
    uint16 collateralFactor;
    uint32 maxLiquidationBonus;
    bool borrowable;
    uint256 liquidityFee;
    IAssetInterestRateStrategy.InterestRateData ir;
    bytes32 salt;
  }

  /// @dev A live reserve to open for borrowing, folded into the operation of `withListing`.
  struct Opening {
    string symbol;
    address underlying;
    uint40 drawCap;
    uint256 liquidityFee;
    IAssetInterestRateStrategy.InterestRateData ir;
    uint256 withListing; // index into _listings()
  }

  /// @dev One timelock operation of this run.
  struct Op {
    string name;
    bytes32 salt;
    GnosisTxBuilder.Tx[] txs; // empty = done
    bool executable; // its feed prices / its curator calls are live
    string holdReason;
  }

  /// @dev The run (memory struct: keeps the drivers' stacks small).
  struct Run {
    Op[] ops;
    GnosisTxBuilder.Tx[] curator;
    uint256 curatorCalls;
    bool waiting;
    bool blocked;
  }

  error Blocked();
  error StaleOperationQueued(string op, bytes32 id, uint256 scheduledAssetId, uint256 liveAssetId);
  error DuplicateAssetId(uint256 assetId);

  string internal constant NAME = 'listings';
  string internal constant CURATOR_NAME = 'openings-curator';
  uint256 internal constant NONE = type(uint256).max;

  function configure() external returns (Phase) {
    return _configure();
  }

  function plan() external returns (Phase live) {
    return Phase(_plan(_step, uint256(Phase.COMPLETE), Timelock.MIN_DELAY));
  }

  function listings() external pure returns (Listing[] memory) {
    return _listings();
  }

  function openings() external pure returns (Opening[] memory) {
    return _openings();
  }

  /// @dev plan() cannot wait a feed / token / curator out: BLOCKED would loop until PlanDidNotConverge.
  function _step() internal returns (uint256) {
    Phase phase = _configure();
    require(phase != Phase.BLOCKED, Blocked());
    return uint256(phase);
  }

  /// @dev The listings = the operations, in scheduling AND execution order.
  function _listings() internal pure returns (Listing[] memory l) {
    l = new Listing[](3);
    l[0] = Listing({
      symbol: 'USDT0',
      opName: 'usdt',
      underlying: Assets.USDT0_UNDERLYING,
      decimals: Assets.USDT0_DECIMALS,
      oracle: Assets.USDT0_ORACLE,
      feedDescription: 'Capped USDT / USD',
      addCap: Caps.USDT0_ADD_CAP,
      drawCap: Caps.USDT0_DRAW_CAP,
      collateralFactor: Collateral.USDT0_COLLATERAL_FACTOR,
      maxLiquidationBonus: Collateral.USDT0_MAX_LIQUIDATION_BONUS,
      borrowable: true,
      liquidityFee: Rates.USDT0_LIQUIDITY_FEE,
      ir: IAssetInterestRateStrategy.InterestRateData({
        optimalUsageRatio: Rates.USDT0_OPTIMAL_USAGE_RATIO,
        baseDrawnRate: Rates.USDT0_BASE_DRAWN_RATE,
        rateGrowthBeforeOptimal: Rates.USDT0_RATE_GROWTH_BEFORE_OPTIMAL,
        rateGrowthAfterOptimal: Rates.USDT0_RATE_GROWTH_AFTER_OPTIMAL
      }),
      salt: Timelock.OP_SALT_USDT0_LISTING
    });
    l[2] = Listing({
      symbol: 'ZCHF',
      opName: 'zchf',
      underlying: Assets.ZCHF_UNDERLYING,
      decimals: Assets.ZCHF_DECIMALS,
      oracle: Assets.ZCHF_ORACLE,
      feedDescription: 'ZCHF / USD',
      addCap: Caps.ZCHF_ADD_CAP,
      drawCap: 0,
      collateralFactor: Collateral.ZCHF_COLLATERAL_FACTOR,
      maxLiquidationBonus: Collateral.ZCHF_MAX_LIQUIDATION_BONUS,
      borrowable: false,
      liquidityFee: Collateral.COLLATERAL_ONLY_LIQUIDITY_FEE,
      ir: _flatCurve(),
      salt: Timelock.OP_SALT_ZCHF_LISTING
    });
    l[1] = Listing({
      symbol: 'PAXGy',
      opName: 'paxgy',
      underlying: Assets.PAXGY_UNDERLYING,
      decimals: Assets.PAXGY_DECIMALS,
      oracle: Assets.PAXGY_ORACLE,
      feedDescription: 'PAXGy / USD',
      addCap: Caps.PAXGY_ADD_CAP,
      drawCap: 0,
      collateralFactor: Collateral.PAXGY_COLLATERAL_FACTOR,
      maxLiquidationBonus: Collateral.PAXGY_MAX_LIQUIDATION_BONUS,
      borrowable: false,
      liquidityFee: Collateral.COLLATERAL_ONLY_LIQUIDITY_FEE,
      ir: _flatCurve(),
      salt: Timelock.OP_SALT_PAXGY_LISTING
    });
  }

  /// @dev The live reserves to open for borrowing, each folded into a listing's operation.
  function _openings() internal pure returns (Opening[] memory o) {
    o = new Opening[](1);
    o[0] = Opening({
      symbol: 'USDT',
      underlying: Assets.USDT_UNDERLYING,
      drawCap: Caps.USDT_DRAW_CAP,
      liquidityFee: Rates.USDT_LIQUIDITY_FEE,
      ir: IAssetInterestRateStrategy.InterestRateData({
        optimalUsageRatio: Rates.USDT_OPTIMAL_USAGE_RATIO,
        baseDrawnRate: Rates.USDT_BASE_DRAWN_RATE,
        rateGrowthBeforeOptimal: Rates.USDT_RATE_GROWTH_BEFORE_OPTIMAL,
        rateGrowthAfterOptimal: Rates.USDT_RATE_GROWTH_AFTER_OPTIMAL
      }),
      withListing: 0
    });
  }

  function _configure() internal returns (Phase) {
    _requireOpMainnet();
    Listing[] memory ls = _listings();
    Run memory r;
    r.ops = new Op[](ls.length);
    r.curator = new GnosisTxBuilder.Tx[](2 * _openings().length);

    bool[] memory listNow = _survey(ls, r);
    uint256[] memory ids = _assignAssetIds(ls, listNow);
    for (uint256 i; i < ls.length; i++) {
      r.ops[i] = _buildOp(r, ls, i, listNow[i], ids[i]);
    }
    return _emit(r);
  }

  /// @dev Which listings still have to be listed: skipped ([todo]) / held ([token]) / live ([done],
  /// verified) ones do not.
  function _survey(Listing[] memory ls, Run memory r) internal returns (bool[] memory listNow) {
    IHub hub = IHub(Hubs.CASH_HUB);
    listNow = new bool[](ls.length);
    for (uint256 i; i < ls.length; i++) {
      Listing memory l = ls[i];
      if (l.underlying == address(0)) {
        console2.log(
          string.concat(
            '[todo] ',
            l.symbol,
            ': underlying not pinned in AaveV4EtherfiCashAssets - skipped'
          )
        );
        continue;
      }
      if (l.underlying.code.length == 0) {
        console2.log(
          string.concat(
            '[token] ',
            l.symbol,
            ': no code at its underlying yet (OFT not deployed) - held'
          )
        );
        r.blocked = true;
        continue;
      }
      _check(
        string.concat(l.symbol, '.decimals'),
        IERC20Metadata(l.underlying).decimals(),
        l.decimals
      );
      _assertNoMismatches(string.concat(l.symbol, ' underlying'));
      if (hub.isUnderlyingListed(l.underlying)) {
        _verifyListing(l);
        console2.log(string.concat('[done] ', l.symbol, ': listed, every parameter verified'));
        continue;
      }
      listNow[i] = true;
    }
  }

  /// @dev An operation already on the queue pins its asset id; the rest take the free ids from
  /// the live counter in table order. A queued operation for an id the counter has passed can
  /// only revert (cancel it first); two queued operations on one id cannot both succeed.
  function _assignAssetIds(
    Listing[] memory ls,
    bool[] memory listNow
  ) internal view returns (uint256[] memory ids) {
    TimelockController tl = TimelockController(payable(Cash.TIMELOCK));
    uint256 live = IHub(Hubs.CASH_HUB).getAssetCount();
    uint256 n = ls.length;
    ids = new uint256[](n);
    bool[] memory taken = new bool[](n);
    bool[] memory pinned = new bool[](n);
    for (uint256 i; i < n; i++) {
      ids[i] = NONE;
      if (!listNow[i]) continue;
      for (uint256 id; id < live; id++) {
        bytes32 stale = _operationId(Cash.TIMELOCK, ls[i].salt, _opTxs(ls, i, id));
        require(!tl.isOperationPending(stale), StaleOperationQueued(ls[i].opName, stale, id, live));
      }
      for (uint256 k; k < n; k++) {
        bytes32 id = _operationId(Cash.TIMELOCK, ls[i].salt, _opTxs(ls, i, live + k));
        if (!tl.isOperationPending(id)) continue;
        require(!taken[k], DuplicateAssetId(live + k));
        ids[i] = live + k;
        taken[k] = true;
        pinned[i] = true;
        break;
      }
    }
    uint256 free;
    for (uint256 i; i < n; i++) {
      if (!listNow[i] || pinned[i]) continue;
      while (taken[free]) free++;
      ids[i] = live + free;
      taken[free] = true;
    }
  }

  /// @dev The transactions of operation `i` for the asset id `assetId`: the listing (when not listed
  /// yet) plus the openings folded into it (when not opened yet).
  function _opTxs(
    Listing[] memory ls,
    uint256 i,
    uint256 assetId
  ) internal view returns (GnosisTxBuilder.Tx[] memory txs) {
    GnosisTxBuilder.Tx[] memory listing = assetId == NONE
      ? new GnosisTxBuilder.Tx[](0)
      : _listing(ls[i], assetId);
    GnosisTxBuilder.Tx[] memory opening = _openingTxs(i);
    txs = new GnosisTxBuilder.Tx[](listing.length + opening.length);
    for (uint256 k; k < listing.length; k++) txs[k] = listing[k];
    for (uint256 k; k < opening.length; k++) txs[listing.length + k] = opening[k];
  }

  /// @dev The timelock part of the openings folded into operation `i` that are not live yet:
  /// updateLiquidityFee (200) + updateBorrowable (400).
  function _openingTxs(uint256 i) internal view returns (GnosisTxBuilder.Tx[] memory txs) {
    Opening[] memory os = _openings();
    GnosisTxBuilder.Tx[] memory all = new GnosisTxBuilder.Tx[](2 * os.length);
    uint256 n;
    for (uint256 k; k < os.length; k++) {
      if (os[k].withListing != i) continue;
      (uint256 assetId, uint256 reserveId) = _ids(os[k].underlying);
      if (ISpoke(Spokes.CASH_SPOKE).getReserveConfig(reserveId).borrowable) continue;
      all[n++] = _updateLiquidityFee(Hubs.CASH_HUB, assetId, os[k].liquidityFee);
      all[n++] = _updateBorrowable(Spokes.CASH_SPOKE, reserveId, true);
    }
    txs = _take(all, n);
  }

  /// @dev Operation `i`: its transactions, whether it may execute now, and the curator calls it waits on.
  function _buildOp(
    Run memory r,
    Listing[] memory ls,
    uint256 i,
    bool listNow,
    uint256 assetId
  ) internal returns (Op memory op) {
    Listing memory l = ls[i];
    op.name = l.opName;
    op.salt = l.salt;
    op.txs = _opTxs(ls, i, listNow ? assetId : NONE);
    op.executable = true;
    if (op.txs.length == 0) return op; // done: listed (or skipped / held) and nothing to open
    _requireCanCall(Cash.TIMELOCK, op.txs);

    if (listNow) {
      console2.log(
        string.concat(
          '       ',
          l.symbol,
          ' assetId ',
          vm.toString(assetId),
          ' / reserveId ',
          vm.toString(
            ISpoke(Spokes.CASH_SPOKE).getReserveCount() +
              (assetId - IHub(Hubs.CASH_HUB).getAssetCount())
          )
        )
      );
      if (l.oracle.code.length == 0) {
        console2.log(
          string.concat(
            '[feed] ',
            l.symbol,
            ': no code at its oracle yet - scheduled anyway; executing needs it to price'
          )
        );
      } else {
        _verifyFeed(l);
      }
      if (!_feedPricing(l.oracle)) {
        op.executable = false;
        op.holdReason = string.concat(l.symbol, ' feed is not pricing (executing would revert)');
      }
    }

    // openings folded in: the curator's curve + draw cap must be live before the flag flips
    Opening[] memory os = _openings();
    for (uint256 k; k < os.length; k++) {
      if (os[k].withListing != i) continue;
      (uint256 oAssetId, uint256 reserveId) = _ids(os[k].underlying);
      if (ISpoke(Spokes.CASH_SPOKE).getReserveConfig(reserveId).borrowable) {
        _verifyOpening(os[k], oAssetId, reserveId);
        console2.log(
          string.concat('[done] ', os[k].symbol, ': borrowable, every parameter verified')
        );
        continue;
      }
      bool curveLive = keccak256(
        abi.encode(
          IAssetInterestRateStrategy(Hubs.CASH_HUB_IR_STRATEGY).getInterestRateData(oAssetId)
        )
      ) == keccak256(abi.encode(os[k].ir));
      bool capPinned = IHub(Hubs.CASH_HUB).getSpokeConfig(oAssetId, Spokes.CASH_SPOKE).drawCap ==
        os[k].drawCap;
      if (!curveLive)
        r.curator[r.curatorCalls++] = _updateInterestRateData(Hubs.CASH_HUB, oAssetId, os[k].ir);
      if (!capPinned)
        r.curator[r.curatorCalls++] = _updateSpokeDrawCap(
          Hubs.CASH_HUB,
          oAssetId,
          Spokes.CASH_SPOKE,
          os[k].drawCap
        );
      if (!curveLive || !capPinned) {
        op.executable = false;
        op.holdReason = string.concat(
          'the risk curator (Operator Safe) has not set the ',
          os[k].symbol,
          ' curve / draw cap yet'
        );
      }
    }
  }

  /// @dev Sorts every pending operation by state, then writes: ONE execute ([next], the first Ready
  /// one in order whose predecessors are done), the schedule MultiSend of every Unset one, the
  /// curator batch, and every pending operation's execute file ([prep]).
  function _emit(Run memory r) internal returns (Phase) {
    TimelockController tl = TimelockController(payable(Cash.TIMELOCK));
    uint256 n = r.ops.length;
    bytes32[] memory ss = new bytes32[](n);
    GnosisTxBuilder.Tx[][] memory so = new GnosisTxBuilder.Tx[][](n);
    uint256 s;
    uint256 next = NONE;
    bool prevDone = true;
    for (uint256 i; i < n; i++) {
      Op memory op = r.ops[i];
      if (op.txs.length == 0) continue;
      TimelockController.OperationState state = tl.getOperationState(
        _operationId(Cash.TIMELOCK, op.salt, op.txs)
      );
      if (state == TimelockController.OperationState.Unset) {
        ss[s] = op.salt;
        so[s++] = op.txs;
      } else if (state == TimelockController.OperationState.Waiting) {
        console2.log(
          string.concat('[wait] ', op.name, ': scheduled, executable at unix time'),
          tl.getTimestamp(_operationId(Cash.TIMELOCK, op.salt, op.txs))
        );
        r.waiting = true;
      } else if (!op.executable) {
        console2.log(string.concat('[hold] ', op.name, ': Ready, but ', op.holdReason));
        r.blocked = true;
      } else if (!prevDone) {
        console2.log(
          string.concat('[queue] ', op.name, ': Ready, executes after the operation before it')
        );
      } else if (next == NONE) {
        next = i;
      } else {
        console2.log(string.concat('[queue] ', op.name, ': Ready, executes on the next run'));
      }
      if (next != i) _previewExecute(Cash.TIMELOCK, Cash.TIMELOCK_SAFE, op.name, op.salt, op.txs);
      prevDone = false;
    }
    GnosisTxBuilder.Tx[] memory curator = _take(r.curator, r.curatorCalls);
    if (curator.length > 0) _requireCanCall(Cash.OPERATOR_SAFE, curator);

    if (next != NONE) {
      _emitExecute(
        Cash.TIMELOCK,
        Cash.TIMELOCK_SAFE,
        r.ops[next].name,
        r.ops[next].salt,
        r.ops[next].txs
      );
      (bytes32[] memory salts, GnosisTxBuilder.Tx[][] memory ops) = _trim(ss, so, s);
      _also(salts, ops, curator);
      return Phase.LISTING;
    }
    if (s > 0) {
      (bytes32[] memory salts, GnosisTxBuilder.Tx[][] memory ops) = _trim(ss, so, s);
      _emitSchedules(Cash.TIMELOCK, Cash.TIMELOCK_SAFE, NAME, salts, Timelock.MIN_DELAY, ops);
      _also(new bytes32[](0), new GnosisTxBuilder.Tx[][](0), curator);
      return Phase.LISTING;
    }
    _clearAlso();
    if (curator.length > 0) {
      _emitBatch(Cash.OPERATOR_SAFE, CURATOR_NAME, curator);
      return Phase.LISTING;
    }
    _clearNext();
    if (r.waiting) return Phase.LISTING;
    if (r.blocked) {
      console2.log(
        '[next] nothing can move: see the [feed] / [token] / [hold] lines above, re-run'
      );
      return Phase.BLOCKED;
    }
    console2.log('=== COMPLETE: every listing / opening live with every parameter verified ===');
    return Phase.COMPLETE;
  }

  /// @dev The [also] step next to `[next]`: the schedule MultiSend when there is one, else the curator
  /// batch; whichever does not fit is emitted on the next run ([later]).
  function _also(
    bytes32[] memory ss,
    GnosisTxBuilder.Tx[][] memory so,
    GnosisTxBuilder.Tx[] memory curator
  ) internal {
    if (so.length > 0) {
      _emitSchedulesAlongside(Cash.TIMELOCK, Cash.TIMELOCK_SAFE, NAME, ss, Timelock.MIN_DELAY, so);
      if (curator.length > 0)
        console2.log('[later] risk curator batch (Operator Safe): emitted on the next run');
      return;
    }
    if (curator.length > 0) {
      _emitBatchAlongside(Cash.OPERATOR_SAFE, CURATOR_NAME, curator);
      return;
    }
    _clearAlso();
  }

  /// @dev The one listing of `l`: addAsset -> addSpoke -> addReserve for the asset id `assetId`.
  function _listing(
    Listing memory l,
    uint256 assetId
  ) internal pure returns (GnosisTxBuilder.Tx[] memory txs) {
    txs = new GnosisTxBuilder.Tx[](3);
    txs[0] = _addAsset(
      Hubs.CASH_HUB,
      l.underlying,
      Spokes.TREASURY_SPOKE,
      l.liquidityFee,
      Hubs.CASH_HUB_IR_STRATEGY,
      l.ir
    );
    txs[1] = _addSpoke(
      Hubs.CASH_HUB,
      Spokes.CASH_SPOKE,
      assetId,
      IHub.SpokeConfig({
        addCap: l.addCap,
        drawCap: l.drawCap,
        riskPremiumThreshold: 0,
        active: true,
        halted: false
      })
    );
    txs[2] = _addReserve(
      Spokes.CASH_SPOKE,
      Hubs.CASH_HUB,
      assetId,
      l.oracle,
      ISpoke.ReserveConfig({
        collateralRisk: Collateral.COLLATERAL_RISK,
        paused: false,
        frozen: false,
        borrowable: l.borrowable,
        receiveSharesEnabled: true
      }),
      ISpoke.DynamicReserveConfig({
        collateralFactor: l.collateralFactor,
        maxLiquidationBonus: l.maxLiquidationBonus,
        liquidationFee: Collateral.LIQUIDATION_FEE
      })
    );
  }

  function _flatCurve() internal pure returns (IAssetInterestRateStrategy.InterestRateData memory) {
    return
      IAssetInterestRateStrategy.InterestRateData({
        optimalUsageRatio: Collateral.COLLATERAL_ONLY_OPTIMAL_USAGE_RATIO,
        baseDrawnRate: 0,
        rateGrowthBeforeOptimal: 0,
        rateGrowthAfterOptimal: 0
      });
  }

  function _ids(address underlying) internal view returns (uint256 assetId, uint256 reserveId) {
    assetId = IHub(Hubs.CASH_HUB).getAssetId(underlying);
    reserveId = ISpoke(Spokes.CASH_SPOKE).getReserveId(Hubs.CASH_HUB, assetId);
  }

  /// @dev Immutable feed shape (what AaveOracle.setReserveSource checks, plus the description).
  function _verifyFeed(Listing memory l) internal {
    IPriceFeed feed = IPriceFeed(l.oracle);
    _check(string.concat(l.symbol, ' feed.decimals'), feed.decimals(), 8);
    _checkBool(
      string.concat(l.symbol, ' feed.description == "', l.feedDescription, '"'),
      keccak256(bytes(feed.description())) == keccak256(bytes(l.feedDescription)),
      true
    );
    _assertNoMismatches(string.concat(l.symbol, ' feed'));
  }

  function _feedPricing(address feed) internal view returns (bool) {
    if (feed.code.length == 0) return false; // a high-level call to no code reverts before try/catch
    try IPriceFeed(feed).latestAnswer() returns (int256 answer) {
      return answer > 0;
    } catch {
      return false;
    }
  }

  /// @dev Every parameter of the live listing of `l` equals the constants, except the caps: the add cap
  /// (and, for a borrowable reserve, the draw cap) is the risk curator's after the listing and is only
  /// reported. Listings may go out with caps of 0 (listed closed) and be raised later.
  function _verifyListing(Listing memory l) internal {
    IHub hub = IHub(Hubs.CASH_HUB);
    ISpoke spoke = ISpoke(Spokes.CASH_SPOKE);
    (uint256 assetId, uint256 reserveId) = _ids(l.underlying);
    string memory s = string.concat(l.symbol, ' ');

    (address underlying, uint8 decimals) = hub.getAssetUnderlyingAndDecimals(assetId);
    _checkAddr(string.concat(s, 'hub asset.underlying'), underlying, l.underlying);
    _check(string.concat(s, 'hub asset.decimals'), decimals, l.decimals);
    _verifyDebtSide(s, assetId, l.liquidityFee, l.ir);
    IHub.SpokeConfig memory spokeConfig = hub.getSpokeConfig(assetId, Spokes.CASH_SPOKE);
    console2.log(
      string.concat('[info] ', s, 'hub spoke.addCap (curator-managed):'),
      spokeConfig.addCap
    );
    if (l.borrowable) {
      console2.log(
        string.concat('[info] ', s, 'hub spoke.drawCap (curator-managed):'),
        spokeConfig.drawCap
      );
    } else {
      _check(string.concat(s, 'hub spoke.drawCap'), spokeConfig.drawCap, 0);
    }
    _check(string.concat(s, 'hub spoke.riskPremiumThreshold'), spokeConfig.riskPremiumThreshold, 0);
    _checkBool(string.concat(s, 'hub spoke.active'), spokeConfig.active, true);
    _checkBool(string.concat(s, 'hub spoke.halted'), spokeConfig.halted, false);

    ISpoke.Reserve memory reserve = spoke.getReserve(reserveId);
    _checkAddr(string.concat(s, 'reserve.underlying'), reserve.underlying, l.underlying);
    _checkAddr(string.concat(s, 'reserve.hub'), address(reserve.hub), Hubs.CASH_HUB);
    _check(string.concat(s, 'reserve.assetId'), reserve.assetId, assetId);
    _check(string.concat(s, 'reserve.decimals'), reserve.decimals, l.decimals);
    ISpoke.ReserveConfig memory config = spoke.getReserveConfig(reserveId);
    _check(
      string.concat(s, 'reserve.collateralRisk'),
      config.collateralRisk,
      Collateral.COLLATERAL_RISK
    );
    _checkBool(string.concat(s, 'reserve.paused'), config.paused, false);
    _checkBool(string.concat(s, 'reserve.frozen'), config.frozen, false);
    _checkBool(string.concat(s, 'reserve.borrowable'), config.borrowable, l.borrowable);
    _checkBool(string.concat(s, 'reserve.receiveSharesEnabled'), config.receiveSharesEnabled, true);
    ISpoke.DynamicReserveConfig memory dynamicConfig = spoke.getDynamicReserveConfig(
      reserveId,
      reserve.dynamicConfigKey
    );
    _check(
      string.concat(s, 'reserve.collateralFactor'),
      dynamicConfig.collateralFactor,
      l.collateralFactor
    );
    _check(
      string.concat(s, 'reserve.maxLiquidationBonus'),
      dynamicConfig.maxLiquidationBonus,
      l.maxLiquidationBonus
    );
    _check(
      string.concat(s, 'reserve.liquidationFee'),
      dynamicConfig.liquidationFee,
      Collateral.LIQUIDATION_FEE
    );

    _checkAddr(
      string.concat(s, 'oracle reserve source'),
      IAaveOracle(spoke.ORACLE()).getReserveSource(reserveId),
      l.oracle
    );
    _checkBool(string.concat(s, 'feed pricing'), _feedPricing(l.oracle), true);
    _assertNoMismatches(string.concat(l.symbol, ' listing'));
  }

  /// @dev Every parameter of the live opening of `o` equals the constants (draw cap: curator's).
  function _verifyOpening(Opening memory o, uint256 assetId, uint256 reserveId) internal {
    string memory s = string.concat(o.symbol, ' ');
    _verifyDebtSide(s, assetId, o.liquidityFee, o.ir);
    _checkBool(
      string.concat(s, 'reserve.borrowable'),
      ISpoke(Spokes.CASH_SPOKE).getReserveConfig(reserveId).borrowable,
      true
    );
    console2.log(
      string.concat('[info] ', s, 'hub spoke.drawCap (curator-managed):'),
      IHub(Hubs.CASH_HUB).getSpokeConfig(assetId, Spokes.CASH_SPOKE).drawCap
    );
    _assertNoMismatches(string.concat(o.symbol, ' opening'));
  }

  function _verifyDebtSide(
    string memory s,
    uint256 assetId,
    uint256 liquidityFee,
    IAssetInterestRateStrategy.InterestRateData memory ir
  ) internal {
    IHub.AssetConfig memory assetConfig = IHub(Hubs.CASH_HUB).getAssetConfig(assetId);
    _checkAddr(
      string.concat(s, 'hub asset.feeReceiver'),
      assetConfig.feeReceiver,
      Spokes.TREASURY_SPOKE
    );
    _check(string.concat(s, 'hub asset.liquidityFee'), assetConfig.liquidityFee, liquidityFee);
    _checkAddr(
      string.concat(s, 'hub asset.irStrategy'),
      assetConfig.irStrategy,
      Hubs.CASH_HUB_IR_STRATEGY
    );
    _checkBool(
      string.concat(s, 'hub asset IR curve'),
      keccak256(
        abi.encode(
          IAssetInterestRateStrategy(Hubs.CASH_HUB_IR_STRATEGY).getInterestRateData(assetId)
        )
      ) == keccak256(abi.encode(ir)),
      true
    );
  }

  function _trim(
    bytes32[] memory salts,
    GnosisTxBuilder.Tx[][] memory ops,
    uint256 n
  ) internal pure returns (bytes32[] memory s, GnosisTxBuilder.Tx[][] memory o) {
    s = new bytes32[](n);
    o = new GnosisTxBuilder.Tx[][](n);
    for (uint256 i; i < n; i++) {
      s[i] = salts[i];
      o[i] = ops[i];
    }
  }

  function _outputDir() internal pure override returns (string memory) {
    return 'output/etherfi/listings/';
  }
}
