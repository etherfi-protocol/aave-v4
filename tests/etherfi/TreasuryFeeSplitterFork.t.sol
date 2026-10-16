// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from 'forge-std/Test.sol';

import {
  AaveV4EtherfiCash as Cash,
  AaveV4EtherfiCashHubs as Hubs,
  AaveV4EtherfiCashSpokes as Spokes,
  AaveV4EtherfiCashAssets as Assets
} from 'src/etherfi/AaveV4EtherfiCash.sol';
import {TreasuryFeeSplitter} from 'src/etherfi/TreasuryFeeSplitter.sol';
import {Ownable} from 'src/dependencies/openzeppelin/Ownable.sol';
import {Ownable2Step} from 'src/dependencies/openzeppelin/Ownable2Step.sol';
import {IERC20} from 'src/dependencies/openzeppelin/IERC20.sol';
import {IHub} from 'src/hub/interfaces/IHub.sol';
import {ITreasurySpoke} from 'src/spoke/interfaces/ITreasurySpoke.sol';

/// @title TreasuryFeeSplitterForkTest
/// @notice Rehearses the splitter against the live OP Mainnet TreasurySpoke: the timelock hands
/// over ownership, the Owner Safe mints fees, anyone splits them, the timelock can hand it back.
/// The timelock is pranked directly; the schedule/execute mechanics are covered by
/// EtherfiCashTimelockFork.t.sol. Skips unless forked from OP:
///   forge test --match-path tests/etherfi/TreasuryFeeSplitterFork.t.sol --fork-url <op-rpc> -vv
contract TreasuryFeeSplitterForkTest is Test {
  IHub internal constant HUB = IHub(Hubs.CASH_HUB);
  ITreasurySpoke internal constant TREASURY = ITreasurySpoke(Spokes.TREASURY_SPOKE);

  address internal RECIPIENT_A = makeAddr('RECIPIENT_A');
  address internal RECIPIENT_B = makeAddr('RECIPIENT_B');

  TreasuryFeeSplitter internal splitter;

  function setUp() public {
    if (!_enabled()) return;

    splitter = new TreasuryFeeSplitter(
      Spokes.TREASURY_SPOKE,
      Hubs.CASH_HUB,
      Cash.TIMELOCK,
      RECIPIENT_A,
      RECIPIENT_B,
      50_00
    );

    // one timelock operation: propose, then accept through the splitter
    vm.startPrank(Cash.TIMELOCK);
    Ownable(Spokes.TREASURY_SPOKE).transferOwnership(address(splitter));
    splitter.executeOnTreasury(abi.encodeCall(Ownable2Step.acceptOwnership, ()));
    vm.stopPrank();
  }

  function test_fork_handover() public {
    if (!_enabled()) vm.skip(true);
    assertEq(Ownable(Spokes.TREASURY_SPOKE).owner(), address(splitter), 'treasury owner');
    // upgrades stay with the timelock
    assertEq(
      Ownable(Spokes.TREASURY_SPOKE_PROXY_ADMIN).owner(),
      Cash.TIMELOCK,
      'proxy admin owner'
    );
  }

  /// @dev Interest fee path (USDC, WETH) and liquidation fee path (ETHFI, collateral-asset fee
  ///      shares) in one permissionless call, plus an asset with no fees (weETH) that is skipped.
  function test_fork_mintAndSplitRevenue() public {
    if (!_enabled()) vm.skip(true);
    address[4] memory underlyings = [
      Assets.USDC_UNDERLYING,
      Assets.WETH_UNDERLYING,
      Assets.ETHFI_UNDERLYING,
      Assets.WEETH_UNDERLYING
    ];

    // Owner Safe holds HUB_FEE_MINTER_ROLE (102) with no execution delay
    vm.startPrank(Cash.OWNER_SAFE);
    HUB.mintFeeShares(HUB.getAssetId(Assets.USDC_UNDERLYING));
    HUB.mintFeeShares(HUB.getAssetId(Assets.WETH_UNDERLYING));
    vm.stopPrank();

    IERC20[] memory tokens = new IERC20[](4);
    uint256[4] memory supplied;
    uint256[4] memory aBefore;
    uint256[4] memory bBefore;
    for (uint256 i; i < 4; ++i) {
      tokens[i] = IERC20(underlyings[i]);
      supplied[i] = TREASURY.getSuppliedAssets(Hubs.CASH_HUB, underlyings[i]);
      aBefore[i] = tokens[i].balanceOf(RECIPIENT_A);
      bBefore[i] = tokens[i].balanceOf(RECIPIENT_B);
    }
    assertGt(supplied[0], 0, 'USDC fees');
    assertGt(supplied[1], 0, 'WETH fees');
    assertGt(supplied[2], 0, 'ETHFI liquidation fees');
    assertEq(supplied[3], 0, 'weETH has no fees');

    vm.prank(makeAddr('ANYONE'));
    splitter.splitRevenue(tokens);

    for (uint256 i; i < 4; ++i) {
      uint256 toA = tokens[i].balanceOf(RECIPIENT_A) - aBefore[i];
      uint256 toB = tokens[i].balanceOf(RECIPIENT_B) - bBefore[i];
      assertEq(toA + toB, supplied[i], 'whole position split');
      assertEq(toA, supplied[i] / 2, 'A');
      assertEq(tokens[i].balanceOf(address(splitter)), 0, 'nothing left in splitter');
      assertEq(TREASURY.getSuppliedShares(Hubs.CASH_HUB, underlyings[i]), 0, 'treasury emptied');
    }
  }

  function test_fork_handBack() public {
    if (!_enabled()) vm.skip(true);
    vm.prank(Cash.TIMELOCK);
    splitter.executeOnTreasury(abi.encodeCall(Ownable.transferOwnership, (Cash.TIMELOCK)));
    vm.prank(Cash.TIMELOCK);
    Ownable2Step(Spokes.TREASURY_SPOKE).acceptOwnership();
    assertEq(Ownable(Spokes.TREASURY_SPOKE).owner(), Cash.TIMELOCK);
  }

  function _enabled() internal view returns (bool) {
    return block.chainid == 10;
  }
}
