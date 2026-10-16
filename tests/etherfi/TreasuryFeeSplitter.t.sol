// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import 'tests/setup/Base.t.sol';
import {TreasuryFeeSplitter} from 'src/etherfi/TreasuryFeeSplitter.sol';

/// @notice Unit tests for TreasuryFeeSplitter against a locally deployed Hub and TreasurySpoke.
contract TreasuryFeeSplitterTest is Base {
  TreasuryFeeSplitter internal splitter;

  address internal SPLIT_OWNER = makeAddr('SPLIT_OWNER');
  address internal RECIPIENT_A = makeAddr('RECIPIENT_A');
  address internal RECIPIENT_B = makeAddr('RECIPIENT_B');
  address internal ANYONE = makeAddr('ANYONE');

  uint16 internal constant SPLIT_A = 70_00;

  function setUp() public virtual override {
    super.setUp();
    splitter = _deploy(SPLIT_A);
    _handOver();
  }

  // ---------------------------------------------------------------- deployment

  function test_constructor() public view {
    assertEq(address(splitter.TREASURY_SPOKE()), address(treasurySpoke));
    assertEq(address(splitter.HUB()), address(hub1));
    assertEq(splitter.owner(), SPLIT_OWNER);
    assertEq(splitter.RECIPIENT_A(), RECIPIENT_A);
    assertEq(splitter.RECIPIENT_B(), RECIPIENT_B);
    assertEq(splitter.SPLIT_PERCENTAGE_RECIPIENT_A(), SPLIT_A);
  }

  function test_constructor_revertsWith_InvalidPercentSplit() public {
    vm.expectRevert(TreasuryFeeSplitter.InvalidPercentSplit.selector);
    _deploy(0);
    vm.expectRevert(TreasuryFeeSplitter.InvalidPercentSplit.selector);
    _deploy(100_00);
    vm.expectRevert(TreasuryFeeSplitter.InvalidPercentSplit.selector);
    _deploy(type(uint16).max);
  }

  function test_constructor_revertsWith_InvalidAddress() public {
    address t = address(treasurySpoke);
    address h = address(hub1);
    vm.expectRevert(TreasuryFeeSplitter.InvalidAddress.selector);
    new TreasuryFeeSplitter(address(0), h, SPLIT_OWNER, RECIPIENT_A, RECIPIENT_B, SPLIT_A);
    vm.expectRevert(TreasuryFeeSplitter.InvalidAddress.selector);
    new TreasuryFeeSplitter(t, address(0), SPLIT_OWNER, RECIPIENT_A, RECIPIENT_B, SPLIT_A);
    vm.expectRevert(TreasuryFeeSplitter.InvalidAddress.selector);
    new TreasuryFeeSplitter(t, h, SPLIT_OWNER, address(0), RECIPIENT_B, SPLIT_A);
    vm.expectRevert(TreasuryFeeSplitter.InvalidAddress.selector);
    new TreasuryFeeSplitter(t, h, SPLIT_OWNER, RECIPIENT_A, address(0), SPLIT_A);
    vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
    new TreasuryFeeSplitter(t, h, address(0), RECIPIENT_A, RECIPIENT_B, SPLIT_A);
  }

  // ---------------------------------------------------------------- handover

  function test_handover() public view {
    assertEq(Ownable2Step(address(treasurySpoke)).owner(), address(splitter));
    assertEq(Ownable2Step(address(treasurySpoke)).pendingOwner(), address(0));
  }

  function test_handBack() public {
    address newOwner = makeAddr('NEW_OWNER');
    vm.prank(SPLIT_OWNER);
    splitter.executeOnTreasury(abi.encodeCall(Ownable.transferOwnership, (newOwner)));
    vm.prank(newOwner);
    Ownable2Step(address(treasurySpoke)).acceptOwnership();
    assertEq(Ownable2Step(address(treasurySpoke)).owner(), newOwner);
  }

  // ---------------------------------------------------------------- splitRevenue

  function test_splitRevenue_feesOnly_anyoneCanCall() public {
    _accrueFees();
    uint256 fees = treasurySpoke.getSuppliedAssets(address(hub1), address(tokenList.dai));
    assertGt(fees, 0, 'fees');

    vm.prank(ANYONE);
    splitter.splitRevenue(_tokens(address(tokenList.dai)));

    uint256 toA = (fees * SPLIT_A) / 100_00;
    assertEq(tokenList.dai.balanceOf(RECIPIENT_A), toA, 'A');
    assertEq(tokenList.dai.balanceOf(RECIPIENT_B), fees - toA, 'B gets remainder');
    assertEq(tokenList.dai.balanceOf(address(splitter)), 0, 'nothing left');
    assertEq(treasurySpoke.getSuppliedShares(address(hub1), address(tokenList.dai)), 0, 'emptied');
  }

  function test_splitRevenue_multipleTokens() public {
    _supplyAsTreasury(tokenList.dai, 1_000e18);
    _supplyAsTreasury(tokenList.usdx, 500e6);

    splitter.splitRevenue(_tokens(address(tokenList.dai), address(tokenList.usdx)));

    assertEq(tokenList.dai.balanceOf(RECIPIENT_A), 700e18);
    assertEq(tokenList.dai.balanceOf(RECIPIENT_B), 300e18);
    assertEq(tokenList.usdx.balanceOf(RECIPIENT_A), 350e6);
    assertEq(tokenList.usdx.balanceOf(RECIPIENT_B), 150e6);
  }

  function test_splitRevenue_skipsTokensWithNothingSupplied() public {
    _supplyAsTreasury(tokenList.dai, 100e18);

    splitter.splitRevenue(_tokens(address(tokenList.usdx), address(tokenList.dai)));

    assertEq(tokenList.dai.balanceOf(RECIPIENT_A), 70e18);
    assertEq(tokenList.usdx.balanceOf(RECIPIENT_A), 0);
  }

  function test_splitRevenue_emptyArray() public {
    splitter.splitRevenue(new IERC20[](0));
  }

  function test_splitRevenue_cappedAtHubLiquidity() public {
    _accrueFees();
    uint256 fees = treasurySpoke.getSuppliedAssets(address(hub1), address(tokenList.dai));
    uint256 liquidity = fees / 4;
    // drain Hub liquidity down to a quarter of the fees by borrowing the rest
    uint256 toDraw = hub1.getAssetLiquidity(daiAssetId) - liquidity;
    vm.prank(address(spoke1));
    hub1.draw(daiAssetId, toDraw, address(spoke1));
    assertEq(hub1.getAssetLiquidity(daiAssetId), liquidity, 'liquidity');

    splitter.splitRevenue(_tokens(address(tokenList.dai)));

    assertEq(
      tokenList.dai.balanceOf(RECIPIENT_A) + tokenList.dai.balanceOf(RECIPIENT_B),
      liquidity,
      'split what the Hub could pay'
    );
    assertApproxEqAbs(
      treasurySpoke.getSuppliedAssets(address(hub1), address(tokenList.dai)),
      fees - liquidity,
      1,
      'rest stays supplied'
    );
  }

  function test_splitRevenue_fuzz_conservesAmount(uint256 amount, uint16 splitA) public {
    amount = bound(amount, 1, MAX_SUPPLY_AMOUNT);
    splitA = uint16(bound(splitA, 1, 99_99));
    splitter = _deploy(splitA);
    _handOver();
    _supplyAsTreasury(tokenList.dai, amount);

    splitter.splitRevenue(_tokens(address(tokenList.dai)));

    assertEq(tokenList.dai.balanceOf(RECIPIENT_A), (amount * splitA) / 100_00);
    assertEq(tokenList.dai.balanceOf(RECIPIENT_A) + tokenList.dai.balanceOf(RECIPIENT_B), amount);
    assertEq(tokenList.dai.balanceOf(address(splitter)), 0);
  }

  function test_splitRevenue_ignoresStrayBalance() public {
    _supplyAsTreasury(tokenList.dai, 1_000e18);
    deal(address(tokenList.dai), address(splitter), 5e18);

    splitter.splitRevenue(_tokens(address(tokenList.dai)));

    assertEq(tokenList.dai.balanceOf(RECIPIENT_A), 700e18);
    assertEq(tokenList.dai.balanceOf(RECIPIENT_B), 300e18);
    assertEq(tokenList.dai.balanceOf(address(splitter)), 5e18, 'stray balance untouched');
  }

  function test_splitRevenue_revertsOnUnlistedToken() public {
    IERC20[] memory tokens = _tokens(address(new MockERC20()));
    vm.expectRevert();
    splitter.splitRevenue(tokens);
  }

  // ---------------------------------------------------------------- splitNativeRevenue

  function test_splitNativeRevenue() public {
    vm.deal(ANYONE, 1 ether);
    vm.prank(ANYONE);
    (bool ok, ) = address(splitter).call{value: 1 ether}('');
    assertTrue(ok, 'receive');

    vm.prank(ANYONE);
    splitter.splitNativeRevenue();

    assertEq(RECIPIENT_A.balance, 0.7 ether);
    assertEq(RECIPIENT_B.balance, 0.3 ether);
    assertEq(address(splitter).balance, 0);
  }

  function test_splitNativeRevenue_zeroBalance() public {
    splitter.splitNativeRevenue();
    assertEq(RECIPIENT_A.balance, 0);
  }

  function test_splitNativeRevenue_rejectingRecipientDoesNotBlock() public {
    // recipient A is a contract without receive(): its send fails, B is still paid
    address rejecting = address(new MockERC20());
    splitter = new TreasuryFeeSplitter(
      address(treasurySpoke),
      address(hub1),
      SPLIT_OWNER,
      rejecting,
      RECIPIENT_B,
      SPLIT_A
    );
    vm.deal(address(splitter), 1 ether);

    splitter.splitNativeRevenue();

    assertEq(RECIPIENT_B.balance, 0.3 ether);
    assertEq(address(splitter).balance, 0.7 ether, 'A share stays');
  }

  // ---------------------------------------------------------------- owner passthroughs

  function test_executeOnTreasury_revertsWith_OwnableUnauthorizedAccount() public {
    vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, ANYONE));
    vm.prank(ANYONE);
    splitter.executeOnTreasury(abi.encodeCall(Ownable.transferOwnership, (ANYONE)));
  }

  function test_executeOnTreasury_bubblesRevert() public {
    vm.expectRevert(
      abi.encodeWithSelector(
        IERC20Errors.ERC20InsufficientBalance.selector,
        address(treasurySpoke),
        0,
        1
      )
    );
    vm.prank(SPLIT_OWNER);
    splitter.executeOnTreasury(
      abi.encodeCall(ITreasurySpoke.transfer, (address(tokenList.dai), RECIPIENT_A, 1))
    );
  }

  function test_executeOnTreasury_withdrawThenRescue() public {
    _supplyAsTreasury(tokenList.dai, 100e18);
    address sink = makeAddr('SINK');

    vm.startPrank(SPLIT_OWNER);
    splitter.executeOnTreasury(
      abi.encodeCall(ITreasurySpoke.withdraw, (address(hub1), address(tokenList.dai), 100e18))
    );
    assertEq(tokenList.dai.balanceOf(address(splitter)), 100e18, 'held after plain withdraw');
    splitter.rescueToken(address(tokenList.dai), sink, 100e18);
    vm.stopPrank();

    assertEq(tokenList.dai.balanceOf(sink), 100e18);
  }

  function test_rescueToken_revertsWith_OwnableUnauthorizedAccount() public {
    vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, ANYONE));
    vm.prank(ANYONE);
    splitter.rescueToken(address(tokenList.dai), ANYONE, 1);
  }

  // ---------------------------------------------------------------- helpers

  function _deploy(uint16 splitA) internal returns (TreasuryFeeSplitter) {
    return
      new TreasuryFeeSplitter(
        address(treasurySpoke),
        address(hub1),
        SPLIT_OWNER,
        RECIPIENT_A,
        RECIPIENT_B,
        splitA
      );
  }

  /// @dev Mirrors the prod handover: the current owner proposes, the splitter owner accepts
  ///      through executeOnTreasury.
  function _handOver() internal {
    vm.prank(Ownable2Step(address(treasurySpoke)).owner());
    Ownable2Step(address(treasurySpoke)).transferOwnership(address(splitter));
    vm.prank(SPLIT_OWNER);
    splitter.executeOnTreasury(abi.encodeCall(Ownable2Step.acceptOwnership, ()));
  }

  /// @dev Real liquidity fees: open debt, accrue a year, mint fee shares to the treasury.
  function _accrueFees() internal {
    _openDebtPosition(spoke1, _getReserveIdByAssetId(spoke1, hub1, daiAssetId), 100e18, true);
    skip(365 days);
    HubActions.mintFeeShares({hub: hub1, assetId: daiAssetId, caller: ADMIN});
  }

  /// @dev Treasury-held balance without waiting on accrual: supply skimmed on the treasury.
  function _supplyAsTreasury(IERC20 token, uint256 amount) internal {
    deal(address(token), address(hub1), token.balanceOf(address(hub1)) + amount);
    vm.prank(SPLIT_OWNER);
    splitter.executeOnTreasury(
      abi.encodeCall(ITreasurySpoke.supplySkimmed, (address(hub1), address(token), amount))
    );
  }

  function _tokens(address a) internal pure returns (IERC20[] memory t) {
    t = new IERC20[](1);
    t[0] = IERC20(a);
  }

  function _tokens(address a, address b) internal pure returns (IERC20[] memory t) {
    t = new IERC20[](2);
    t[0] = IERC20(a);
    t[1] = IERC20(b);
  }
}
