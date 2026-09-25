// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from 'forge-std/Test.sol';

import {EtherfiCashCollateralListingsScript} from 'scripts/etherfi/listings/EtherfiCashCollateralListings.s.sol';
import {EtherfiCashTimelockScript} from 'scripts/etherfi/timelock/EtherfiCashTimelock.s.sol';
import {
  AaveV4EtherfiCash as Cash,
  AaveV4EtherfiCashHubs as Hubs,
  AaveV4EtherfiCashSpokes as Spokes,
  AaveV4EtherfiCashAssets as Assets,
  AaveV4EtherfiCashCollateral as Collateral,
  AaveV4EtherfiCashTimelock as Timelock
} from 'src/etherfi/AaveV4EtherfiCash.sol';
import {IHubConfigurator} from 'src/hub/interfaces/IHubConfigurator.sol';
import {IEtherFiDataProvider} from 'src/etherfi/interfaces/IEtherFiDataProvider.sol';
import {IHub} from 'src/hub/interfaces/IHub.sol';
import {ISpoke} from 'src/spoke/interfaces/ISpoke.sol';
import {IAaveOracle} from 'src/spoke/interfaces/IAaveOracle.sol';
import {IPriceFeed} from 'src/spoke/interfaces/IPriceFeed.sol';
import {IERC20} from 'src/dependencies/openzeppelin/IERC20.sol';
import {IERC20Metadata} from 'src/dependencies/openzeppelin/IERC20Metadata.sol';
import {IAssetInterestRateStrategy} from 'src/hub/interfaces/IAssetInterestRateStrategy.sol';

/// @dev Stand-in for a feed the fork has no code for yet (the cash-v3 feeds before their deploy):
/// the IPriceFeed surface, 8 decimals, $1.00. No constructor state, so its runtime code can be
/// etched at the pinned address; description / price are then mocked per asset.
contract MockUsdFeed is IPriceFeed {
  function decimals() external pure returns (uint8) {
    return 8;
  }

  function description() external pure returns (string memory) {
    return 'MOCK / USD';
  }

  function latestAnswer() external pure returns (int256) {
    return 1e8;
  }
}

/// @dev Stand-in for an ether.fi shadow OFT the fork has no code for yet: a bare 18-decimal ERC20
/// whose balances `deal` can set. No constructor state, so it can be etched.
contract MockOft {
  mapping(address => uint256) public balanceOf;
  mapping(address => mapping(address => uint256)) public allowance;
  uint256 public totalSupply;

  function decimals() external pure returns (uint8) {
    return 18;
  }

  function symbol() external pure returns (string memory) {
    return 'iMOCK';
  }

  function approve(address spender, uint256 amount) external returns (bool) {
    allowance[msg.sender][spender] = amount;
    return true;
  }

  function transfer(address to, uint256 amount) external returns (bool) {
    balanceOf[msg.sender] -= amount;
    balanceOf[to] += amount;
    return true;
  }

  function transferFrom(address from, address to, uint256 amount) external returns (bool) {
    if (allowance[from][msg.sender] != type(uint256).max) allowance[from][msg.sender] -= amount;
    balanceOf[from] -= amount;
    balanceOf[to] += amount;
    return true;
  }
}

/// @title EtherfiCashCollateralListingsForkTest
/// @notice Dress rehearsal of the USDT0 (+ USDT opening), PAXGy and ZCHF operations on an OP Mainnet
/// fork, after the timelock migration (run in-VM to COMPLETE when the chain is not there yet): every
/// batch `configure()` writes is sent by its signer (Timelock Safe schedule MultiSend, Operator Safe
/// curator batch, then one Timelock Safe execute file per operation, in order), 24h pass in between,
/// `configure()` re-verifies to COMPLETE, and a Cash Safe borrows USDC against each new asset and
/// borrows the opened ones once the risk curator raises their caps. Feeds / tokens without code on
/// the fork are stood in by mocks. Skips unless forked from OP:
///   forge test --match-path tests/etherfi/EtherfiCashCollateralListingsFork.t.sol --fork-url <op-rpc> -vv
contract EtherfiCashCollateralListingsForkTest is Test {
  IHub internal constant HUB = IHub(Hubs.CASH_HUB);
  ISpoke internal constant SPOKE = ISpoke(Spokes.CASH_SPOKE);
  /// @dev EtherFiSpokeInstance.ETHERFI_DATA_PROVIDER (prod proxy, OP Mainnet)
  address internal constant ETHERFI_DATA_PROVIDER = 0xDC515Cb479a64552c5A11a57109C314E40A1A778;
  uint40 internal constant CURATOR_DRAW_CAP = 1_000_000; // whatever the curator decides later
  uint256 internal constant SUPPLY_USD = 50_000; // per asset, in the borrow rehearsal
  uint256 internal constant MAX_STEPS = 12;

  EtherfiCashCollateralListingsScript internal script;
  EtherfiCashCollateralListingsScript.Listing[] internal active;
  address internal user = makeAddr('cash-safe');

  function setUp() public {
    if (block.chainid != 10) return;
    script = new EtherfiCashCollateralListingsScript();
    EtherfiCashCollateralListingsScript.Listing[] memory all = script.listings();
    for (uint256 i; i < all.length; i++) {
      if (all[i].underlying != address(0)) active.push(all[i]);
    }
  }

  /// @dev Until the migration has moved the domain-admin roles, the timelock cannot send the
  /// operations and the script says so instead of writing a batch that would revert.
  function test_fork_beforeMigration_revertsNoSigner() public {
    if (block.chainid != 10) vm.skip(true);
    EtherfiCashTimelockScript migration = new EtherfiCashTimelockScript();
    if (uint256(migration.configure()) >= uint256(EtherfiCashTimelockScript.Phase.OWNERSHIP))
      vm.skip(true); // roles already moved on chain
    _etchMissing();
    vm.expectPartialRevert(EtherfiCashGovernanceBaseErrors.NoSigner.selector);
    script.configure();
  }

  /// @dev Feeds without code do not hold scheduling back: every operation is scheduled and every
  /// execute file is written on the first run.
  function test_fork_feedMissing_schedulesAnyway() public {
    if (block.chainid != 10) vm.skip(true);
    uint256 missing;
    for (uint256 i; i < active.length; i++) {
      if (active[i].oracle.code.length == 0) missing++;
    }
    if (missing == 0) vm.skip(true);
    _migrate();
    _etchMissingTokens();
    assertEq(
      uint256(script.configure()),
      uint256(EtherfiCashCollateralListingsScript.Phase.LISTING)
    );
    (string memory path, address signer) = script.lastEmitted();
    assertEq(signer, Cash.TIMELOCK_SAFE, 'schedule signer');
    assertEq(_txCount(path), active.length, 'one scheduleBatch per operation, feeds or not');
    _assertExecuteFiles();
  }

  function test_fork_listings() public {
    if (block.chainid != 10) vm.skip(true);
    _migrate();
    _etchMissing();

    // step 1: one schedule MultiSend (Timelock Safe) + the curator batch (Operator Safe) alongside
    assertEq(
      uint256(script.configure()),
      uint256(EtherfiCashCollateralListingsScript.Phase.LISTING)
    );
    (string memory path, address signer) = script.lastEmitted();
    assertEq(signer, Cash.TIMELOCK_SAFE, 'schedule signer');
    assertEq(_txCount(path), active.length, 'one scheduleBatch per operation');
    (string memory also, address alsoSigner) = script.alsoEmitted();
    assertEq(alsoSigner, Cash.OPERATOR_SAFE, 'curator signer');
    _assertExecuteFiles();
    _send(signer, path);
    _send(alsoSigner, also);

    // waiting: nothing to send until the delay passes
    assertEq(
      uint256(script.configure()),
      uint256(EtherfiCashCollateralListingsScript.Phase.LISTING)
    );
    (path, ) = script.lastEmitted();
    assertEq(bytes(path).length, 0, 'maturing: nothing written');
    vm.warp(block.timestamp + Timelock.MIN_DELAY);

    // one execute per run, in operation order: usdt, paxgy, zchf
    for (uint256 i; i < active.length; i++) {
      assertEq(
        uint256(script.configure()),
        uint256(EtherfiCashCollateralListingsScript.Phase.LISTING)
      );
      (path, signer) = script.lastEmitted();
      assertEq(signer, Cash.TIMELOCK_SAFE, 'execute signer');
      assertEq(
        path,
        string.concat('output/etherfi/listings/', active[i].opName, '-execute.json'),
        'execute file order'
      );
      assertEq(_txCount(path), 1, 'one executeBatch per file');
      _send(signer, path);
    }

    assertEq(
      uint256(script.configure()),
      uint256(EtherfiCashCollateralListingsScript.Phase.COMPLETE)
    );
    _assertEndState();
    _borrowAgainstEach();
    _borrowOpened();
  }

  /// @dev plan() = the same rehearsal driven by the script itself.
  function test_fork_plan() public {
    if (block.chainid != 10) vm.skip(true);
    _migrate();
    _etchMissing();
    assertEq(uint256(script.plan()), uint256(EtherfiCashCollateralListingsScript.Phase.LISTING));
    assertEq(
      uint256(script.configure()),
      uint256(EtherfiCashCollateralListingsScript.Phase.COMPLETE)
    );
    _assertEndState();
    _borrowAgainstEach();
    _borrowOpened();
  }

  // ─── helpers ───

  /// @dev Brings the fork to the post-migration state the operations assume (timelock sole holder
  /// of 200 / 400), replaying the migration's own plan when the chain is not there yet.
  function _migrate() internal {
    EtherfiCashTimelockScript migration = new EtherfiCashTimelockScript();
    if (migration.timelockAddress().code.length == 0) migration.deploy();
    if (uint256(migration.configure()) != uint256(EtherfiCashTimelockScript.Phase.COMPLETE)) {
      migration.plan();
    }
    assertEq(
      uint256(migration.configure()),
      uint256(EtherfiCashTimelockScript.Phase.COMPLETE),
      'migration complete'
    );
  }

  function _etchMissing() internal {
    _etchMissingTokens();
    _etchMissingFeeds();
  }

  /// @dev Every active asset whose underlying has no code yet (a predicted OFT) gets the mock token.
  function _etchMissingTokens() internal {
    for (uint256 i; i < active.length; i++) {
      if (active[i].underlying.code.length == 0)
        vm.etch(active[i].underlying, address(new MockOft()).code);
    }
  }

  /// @dev Every active asset whose oracle has no code yet gets the mock, described and priced as
  /// the script expects (ZCHF ~ CHF/USD, PAXGy ~ XAU/USD; anything else $1.00).
  function _etchMissingFeeds() internal {
    for (uint256 i; i < active.length; i++) {
      address oracle = active[i].oracle;
      if (oracle.code.length != 0) continue;
      vm.etch(oracle, address(new MockUsdFeed()).code);
      vm.mockCall(
        oracle,
        abi.encodeCall(IPriceFeed.description, ()),
        abi.encode(active[i].feedDescription)
      );
      if (oracle == Assets.ZCHF_ORACLE) {
        vm.mockCall(
          oracle,
          abi.encodeCall(IPriceFeed.latestAnswer, ()),
          abi.encode(int256(1.2134e8))
        );
      }
      if (oracle == Assets.PAXGY_ORACLE) {
        vm.mockCall(
          oracle,
          abi.encodeCall(IPriceFeed.latestAnswer, ()),
          abi.encode(int256(4292e8))
        );
      }
    }
  }

  function _assertExecuteFiles() internal view {
    for (uint256 i; i < active.length; i++) {
      assertTrue(
        vm.exists(string.concat('output/etherfi/listings/', active[i].opName, '-execute.json')),
        string.concat(active[i].opName, '-execute.json pre-written')
      );
    }
  }

  function _assertEndState() internal view {
    for (uint256 i; i < active.length; i++) {
      EtherfiCashCollateralListingsScript.Listing memory l = active[i];
      uint256 assetId = HUB.getAssetId(l.underlying);
      uint256 reserveId = SPOKE.getReserveId(Hubs.CASH_HUB, assetId);
      ISpoke.Reserve memory reserve = SPOKE.getReserve(reserveId);
      assertEq(reserve.underlying, l.underlying, string.concat(l.symbol, ' underlying'));
      assertEq(reserve.decimals, l.decimals, string.concat(l.symbol, ' decimals'));
      ISpoke.ReserveConfig memory config = SPOKE.getReserveConfig(reserveId);
      assertEq(config.borrowable, l.borrowable, string.concat(l.symbol, ' borrowable flag'));
      assertTrue(config.receiveSharesEnabled, string.concat(l.symbol, ' receive shares'));
      ISpoke.DynamicReserveConfig memory dynamicConfig = SPOKE.getDynamicReserveConfig(
        reserveId,
        reserve.dynamicConfigKey
      );
      assertEq(dynamicConfig.collateralFactor, l.collateralFactor, string.concat(l.symbol, ' CF'));
      assertEq(
        dynamicConfig.maxLiquidationBonus,
        l.maxLiquidationBonus,
        string.concat(l.symbol, ' bonus')
      );
      assertEq(
        dynamicConfig.liquidationFee,
        Collateral.LIQUIDATION_FEE,
        string.concat(l.symbol, ' liq fee')
      );
      IHub.SpokeConfig memory spokeConfig = HUB.getSpokeConfig(assetId, Spokes.CASH_SPOKE);
      assertEq(spokeConfig.addCap, l.addCap, string.concat(l.symbol, ' addCap as listed'));
      assertEq(spokeConfig.drawCap, l.drawCap, string.concat(l.symbol, ' drawCap as listed'));
      assertEq(
        IAaveOracle(SPOKE.ORACLE()).getReserveSource(reserveId),
        l.oracle,
        string.concat(l.symbol, ' price source')
      );
      assertEq(
        HUB.getAssetConfig(assetId).liquidityFee,
        l.liquidityFee,
        string.concat(l.symbol, ' liquidity fee')
      );
    }
    // openings: borrowable, curve + fee applied, draw cap pinned to 0
    EtherfiCashCollateralListingsScript.Opening[] memory opened = script.openings();
    for (uint256 i; i < opened.length; i++) {
      uint256 assetId = HUB.getAssetId(opened[i].underlying);
      uint256 reserveId = SPOKE.getReserveId(Hubs.CASH_HUB, assetId);
      assertTrue(
        SPOKE.getReserveConfig(reserveId).borrowable,
        string.concat(opened[i].symbol, ' opened')
      );
      assertEq(
        HUB.getAssetConfig(assetId).liquidityFee,
        opened[i].liquidityFee,
        string.concat(opened[i].symbol, ' fee')
      );
      assertEq(
        keccak256(
          abi.encode(
            IAssetInterestRateStrategy(Hubs.CASH_HUB_IR_STRATEGY).getInterestRateData(assetId)
          )
        ),
        keccak256(abi.encode(opened[i].ir)),
        string.concat(opened[i].symbol, ' curve')
      );
      assertEq(
        HUB.getSpokeConfig(assetId, Spokes.CASH_SPOKE).drawCap,
        opened[i].drawCap,
        string.concat(opened[i].symbol, ' drawCap explicitly 0')
      );
    }
  }

  /// @dev A Cash Safe (per EtherFiDataProvider) supplies ~$50k of each new asset (raising a 0 add cap
  /// as the risk curator first: listings may go out closed) and borrows USDC worth 40% of it; a
  /// collateral-only asset cannot be borrowed, a borrowable one is closed until its draw cap is raised.
  function _borrowAgainstEach() internal {
    uint256 usdcId = SPOKE.getReserveId(Hubs.CASH_HUB, HUB.getAssetId(Assets.USDC_UNDERLYING));
    vm.mockCall(
      ETHERFI_DATA_PROVIDER,
      abi.encodeCall(IEtherFiDataProvider.isEtherFiSafe, (user)),
      abi.encode(true)
    );
    for (uint256 i; i < active.length; i++) {
      EtherfiCashCollateralListingsScript.Listing memory l = active[i];
      uint256 assetId = HUB.getAssetId(l.underlying);
      uint256 reserveId = SPOKE.getReserveId(Hubs.CASH_HUB, assetId);
      uint256 price = uint256(IPriceFeed(l.oracle).latestAnswer()); // 8 decimals
      uint256 supply = (SUPPLY_USD * 1e8 * 10 ** l.decimals) / price; // ~$50k of the asset
      uint256 borrow = SUPPLY_USD * 0.4e6; // USDC, 6 decimals
      _ensureAddCap(assetId, supply / 10 ** l.decimals + 1);

      deal(l.underlying, user, supply);
      vm.startPrank(user);
      IERC20(l.underlying).approve(Spokes.CASH_SPOKE, type(uint256).max);
      SPOKE.supply(reserveId, supply, user);
      SPOKE.setUsingAsCollateral(reserveId, true, user);

      if (l.borrowable) {
        vm.expectRevert(abi.encodeWithSelector(IHub.DrawCapExceeded.selector, 0)); // opened closed
      } else {
        vm.expectRevert(ISpoke.ReserveNotBorrowable.selector);
      }
      SPOKE.borrow(reserveId, 10 ** l.decimals, user);

      uint256 before = IERC20(Assets.USDC_UNDERLYING).balanceOf(user);
      uint256 debtBefore = SPOKE.getUserTotalDebt(usdcId, user);
      SPOKE.borrow(usdcId, borrow, user);
      vm.stopPrank();
      assertEq(
        IERC20(Assets.USDC_UNDERLYING).balanceOf(user) - before,
        borrow,
        string.concat(l.symbol, ': USDC received')
      );
      // debt shares round up: the debt may read 1 wei above the borrowed amount
      assertApproxEqAbs(
        SPOKE.getUserTotalDebt(usdcId, user) - debtBefore,
        borrow,
        1,
        string.concat(l.symbol, ': debt opened')
      );
    }
  }

  /// @dev Each opened reserve (and each borrowable listing) is closed until the risk curator raises
  /// the draw cap; then the Cash Safe (collateral from `_borrowAgainstEach`) borrows it and interest accrues.
  function _borrowOpened() internal {
    EtherfiCashCollateralListingsScript.Opening[] memory opened = script.openings();
    for (uint256 i; i < opened.length; i++) {
      _openAndBorrow(
        opened[i].symbol,
        opened[i].underlying,
        1_000 * 10 ** IERC20Metadata(opened[i].underlying).decimals()
      );
    }
    for (uint256 i; i < active.length; i++) {
      if (active[i].borrowable)
        _openAndBorrow(active[i].symbol, active[i].underlying, 1_000 * 10 ** active[i].decimals);
    }
  }

  function _openAndBorrow(string memory symbol, address underlying, uint256 amount) internal {
    uint256 assetId = HUB.getAssetId(underlying);
    uint256 reserveId = SPOKE.getReserveId(Hubs.CASH_HUB, assetId);
    if (HUB.getSpokeConfig(assetId, Spokes.CASH_SPOKE).drawCap == 0) {
      vm.prank(user);
      vm.expectRevert(abi.encodeWithSelector(IHub.DrawCapExceeded.selector, 0));
      SPOKE.borrow(reserveId, amount, user);
      vm.prank(Cash.OPERATOR_SAFE);
      IHubConfigurator(Cash.HUB_CONFIGURATOR).updateSpokeDrawCap(
        Hubs.CASH_HUB,
        assetId,
        Spokes.CASH_SPOKE,
        CURATOR_DRAW_CAP
      );
    }
    uint256 before = IERC20(underlying).balanceOf(user);
    uint256 debtBefore = SPOKE.getUserTotalDebt(reserveId, user);
    vm.prank(user);
    SPOKE.borrow(reserveId, amount, user);
    assertEq(
      IERC20(underlying).balanceOf(user) - before,
      amount,
      string.concat(symbol, ': received')
    );
    uint256 debt = SPOKE.getUserTotalDebt(reserveId, user);
    assertApproxEqAbs(debt - debtBefore, amount, 1, string.concat(symbol, ': debt opened'));
    vm.warp(block.timestamp + 30 days);
    assertGt(
      SPOKE.getUserTotalDebt(reserveId, user),
      debt,
      string.concat(symbol, ': debt accrues (curve is not 0%)')
    );
    vm.warp(block.timestamp - 30 days);
  }

  /// @dev Listings may go out with an add cap of 0 (closed): the risk curator raises it before anyone supplies.
  function _ensureAddCap(uint256 assetId, uint256 wholeTokens) internal {
    if (HUB.getSpokeConfig(assetId, Spokes.CASH_SPOKE).addCap >= wholeTokens) return;
    vm.prank(Cash.OPERATOR_SAFE);
    IHubConfigurator(Cash.HUB_CONFIGURATOR).updateSpokeAddCap(
      Hubs.CASH_HUB,
      assetId,
      Spokes.CASH_SPOKE,
      wholeTokens
    );
  }

  /// @dev Sends a written batch as its signer, after proving it reverts from everyone else.
  function _send(address signer, string memory path) internal {
    _expectBatchFileReverts(path, makeAddr('anyone'));
    if (signer == Cash.TIMELOCK_SAFE) {
      _expectBatchFileReverts(path, Cash.OWNER_SAFE);
      _expectBatchFileReverts(path, Cash.OPERATOR_SAFE);
    } else {
      _expectBatchFileReverts(path, Cash.TIMELOCK_SAFE);
    }
    _executeBatchFile(path, signer);
  }

  function _txCount(string memory path) internal view returns (uint256 n) {
    string memory json = vm.readFile(path);
    while (vm.keyExistsJson(json, string.concat('.transactions[', vm.toString(n), ']'))) n++;
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

/// @dev Error surface of the base, for expectPartialRevert.
interface EtherfiCashGovernanceBaseErrors {
  error NoSigner(string note);
}
