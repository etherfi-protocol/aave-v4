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
    assertTrue(splitter.isHubAllowed(address(hub1)));
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
    address[] memory h = _hubList(address(hub1));
    address[] memory zeroHub = _hubList(address(0));
    vm.expectRevert(TreasuryFeeSplitter.InvalidAddress.selector);
    new TreasuryFeeSplitter(address(0), h, SPLIT_OWNER, RECIPIENT_A, RECIPIENT_B, SPLIT_A);
    vm.expectRevert(TreasuryFeeSplitter.InvalidAddress.selector);
    new TreasuryFeeSplitter(t, zeroHub, SPLIT_OWNER, RECIPIENT_A, RECIPIENT_B, SPLIT_A);
    vm.expectRevert(TreasuryFeeSplitter.InvalidAddress.selector);
    new TreasuryFeeSplitter(t, h, SPLIT_OWNER, address(0), RECIPIENT_B, SPLIT_A);
    vm.expectRevert(TreasuryFeeSplitter.InvalidAddress.selector);
    new TreasuryFeeSplitter(t, h, SPLIT_OWNER, RECIPIENT_A, address(0), SPLIT_A);
    vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
    new TreasuryFeeSplitter(t, h, address(0), RECIPIENT_A, RECIPIENT_B, SPLIT_A);
  }

  function test_constructor_revertsWith_SameRecipients() public {
    address[] memory h = _hubList(address(hub1));
    vm.expectRevert(TreasuryFeeSplitter.SameRecipients.selector);
    new TreasuryFeeSplitter(
      address(treasurySpoke),
      h,
      SPLIT_OWNER,
      RECIPIENT_A,
      RECIPIENT_A,
      SPLIT_A
    );
  }

  function test_constructor_noHubs() public {
    TreasuryFeeSplitter s = new TreasuryFeeSplitter(
      address(treasurySpoke),
      new address[](0),
      SPLIT_OWNER,
      RECIPIENT_A,
      RECIPIENT_B,
      SPLIT_A
    );
    assertFalse(s.isHubAllowed(address(hub1)));
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

  // ---------------------------------------------------------------- hub allowlist

  function test_splitRevenue_revertsWith_HubNotAllowed() public {
    (IHub hub2, ) = _hub2Fixture();
    IERC20[] memory tokens = _tokens(address(tokenList.dai));
    vm.expectRevert(
      abi.encodeWithSelector(TreasuryFeeSplitter.HubNotAllowed.selector, address(hub2))
    );
    splitter.splitRevenue(address(hub2), tokens);
  }

  function test_setHubAllowed_secondHub() public {
    // hub2 lists the same TreasurySpoke as fee receiver
    (IHub hub2, ) = _hub2Fixture();
    vm.prank(SPLIT_OWNER);
    splitter.setHubAllowed(address(hub2), true);
    _supplyAsTreasury(hub1, tokenList.dai, 100e18);
    _supplyAsTreasury(hub2, tokenList.dai, 10e18);

    splitter.splitRevenue(address(hub2), _tokens(address(tokenList.dai)));

    assertEq(tokenList.dai.balanceOf(RECIPIENT_A), 7e18, 'hub2 split A');
    assertEq(tokenList.dai.balanceOf(RECIPIENT_B), 3e18, 'hub2 split B');
    assertEq(
      treasurySpoke.getSuppliedAssets(address(hub1), address(tokenList.dai)),
      100e18,
      'hub1 untouched'
    );
  }

  function test_setHubAllowed_disallow() public {
    _supplyAsTreasury(hub1, tokenList.dai, 100e18);
    vm.prank(SPLIT_OWNER);
    splitter.setHubAllowed(address(hub1), false);

    IERC20[] memory tokens = _tokens(address(tokenList.dai));
    vm.expectRevert(
      abi.encodeWithSelector(TreasuryFeeSplitter.HubNotAllowed.selector, address(hub1))
    );
    splitter.splitRevenue(address(hub1), tokens);
  }

  function test_setHubAllowed_revertsWith_OwnableUnauthorizedAccount() public {
    vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, ANYONE));
    vm.prank(ANYONE);
    splitter.setHubAllowed(ANYONE, true);
  }

  function test_setHubAllowed_revertsWith_InvalidAddress() public {
    vm.expectRevert(TreasuryFeeSplitter.InvalidAddress.selector);
    vm.prank(SPLIT_OWNER);
    splitter.setHubAllowed(address(0), true);
  }

  // ---------------------------------------------------------------- splitRevenue

  function test_splitRevenue_feesOnly_anyoneCanCall() public {
    _accrueFees();
    uint256 fees = treasurySpoke.getSuppliedAssets(address(hub1), address(tokenList.dai));
    assertGt(fees, 0, 'fees');

    vm.prank(ANYONE);
    splitter.splitRevenue(address(hub1), _tokens(address(tokenList.dai)));

    uint256 toA = (fees * SPLIT_A) / 100_00;
    assertEq(tokenList.dai.balanceOf(RECIPIENT_A), toA, 'A');
    assertEq(tokenList.dai.balanceOf(RECIPIENT_B), fees - toA, 'B gets remainder');
    assertEq(tokenList.dai.balanceOf(address(splitter)), 0, 'nothing left');
    assertEq(treasurySpoke.getSuppliedShares(address(hub1), address(tokenList.dai)), 0, 'emptied');
  }

  function test_splitRevenue_multipleTokens() public {
    _supplyAsTreasury(hub1, tokenList.dai, 1_000e18);
    _supplyAsTreasury(hub1, tokenList.usdx, 500e6);

    splitter.splitRevenue(address(hub1), _tokens(address(tokenList.dai), address(tokenList.usdx)));

    assertEq(tokenList.dai.balanceOf(RECIPIENT_A), 700e18);
    assertEq(tokenList.dai.balanceOf(RECIPIENT_B), 300e18);
    assertEq(tokenList.usdx.balanceOf(RECIPIENT_A), 350e6);
    assertEq(tokenList.usdx.balanceOf(RECIPIENT_B), 150e6);
  }

  function test_splitRevenue_skipsTokensWithNothingSupplied() public {
    _supplyAsTreasury(hub1, tokenList.dai, 100e18);

    splitter.splitRevenue(address(hub1), _tokens(address(tokenList.usdx), address(tokenList.dai)));

    assertEq(tokenList.dai.balanceOf(RECIPIENT_A), 70e18);
    assertEq(tokenList.usdx.balanceOf(RECIPIENT_A), 0);
  }

  function test_splitRevenue_emptyArray() public {
    splitter.splitRevenue(address(hub1), new IERC20[](0));
  }

  /// @dev 1 wei at 70/30: A's share floors to zero, so only B is paid and nothing reverts.
  function test_splitRevenue_zeroShareSkipped() public {
    _supplyAsTreasury(hub1, tokenList.dai, 1);

    vm.expectEmit(address(splitter));
    emit TreasuryFeeSplitter.RevenueSplit(address(hub1), address(tokenList.dai), 0, 1);
    splitter.splitRevenue(address(hub1), _tokens(address(tokenList.dai)));

    assertEq(tokenList.dai.balanceOf(RECIPIENT_A), 0);
    assertEq(tokenList.dai.balanceOf(RECIPIENT_B), 1);
  }

  /// @dev A withdrawal that delivers no tokens (both shares zero) reverts, so the TreasurySpoke
  ///      keeps its Hub shares.
  function test_splitRevenue_revertsWith_NothingWithdrawn() public {
    _supplyAsTreasury(hub1, tokenList.dai, 100e18);
    uint256 sharesBefore = treasurySpoke.getSuppliedShares(address(hub1), address(tokenList.dai));
    // withdraw succeeds but pays nothing
    vm.mockCall(
      address(treasurySpoke),
      abi.encodeWithSelector(ITreasurySpoke.withdraw.selector),
      abi.encode(uint256(0), uint256(0))
    );

    IERC20[] memory tokens = _tokens(address(tokenList.dai));
    vm.expectRevert(
      abi.encodeWithSelector(TreasuryFeeSplitter.NothingWithdrawn.selector, address(tokenList.dai))
    );
    splitter.splitRevenue(address(hub1), tokens);

    vm.clearMockedCalls();
    assertEq(
      treasurySpoke.getSuppliedShares(address(hub1), address(tokenList.dai)),
      sharesBefore,
      'shares kept'
    );
    assertEq(tokenList.dai.balanceOf(RECIPIENT_A) + tokenList.dai.balanceOf(RECIPIENT_B), 0);
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

    splitter.splitRevenue(address(hub1), _tokens(address(tokenList.dai)));

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
    _redeployAndHandOver(splitA);
    _supplyAsTreasury(hub1, tokenList.dai, amount);

    splitter.splitRevenue(address(hub1), _tokens(address(tokenList.dai)));

    _assertSplit(
      tokenList.dai.balanceOf(RECIPIENT_A),
      tokenList.dai.balanceOf(RECIPIENT_B),
      amount,
      splitA
    );
    assertEq(tokenList.dai.balanceOf(address(splitter)), 0);
  }

  /// @dev Small amounts, where A's or B's share rounds to zero and is skipped.
  function test_splitRevenue_fuzz_smallAmounts(uint256 amount, uint16 splitA) public {
    amount = bound(amount, 1, 100_00);
    splitA = uint16(bound(splitA, 1, 99_99));
    _redeployAndHandOver(splitA);
    _supplyAsTreasury(hub1, tokenList.dai, amount);

    splitter.splitRevenue(address(hub1), _tokens(address(tokenList.dai)));

    _assertSplit(
      tokenList.dai.balanceOf(RECIPIENT_A),
      tokenList.dai.balanceOf(RECIPIENT_B),
      amount,
      splitA
    );
    assertEq(tokenList.dai.balanceOf(address(splitter)), 0);
  }

  function test_splitRevenue_ignoresStrayBalance() public {
    _supplyAsTreasury(hub1, tokenList.dai, 1_000e18);
    deal(address(tokenList.dai), address(splitter), 5e18);

    splitter.splitRevenue(address(hub1), _tokens(address(tokenList.dai)));

    assertEq(tokenList.dai.balanceOf(RECIPIENT_A), 700e18);
    assertEq(tokenList.dai.balanceOf(RECIPIENT_B), 300e18);
    assertEq(tokenList.dai.balanceOf(address(splitter)), 5e18, 'stray balance untouched');
  }

  function test_splitRevenue_revertsOnUnlistedToken() public {
    IERC20[] memory tokens = _tokens(address(new MockERC20()));
    vm.expectRevert();
    splitter.splitRevenue(address(hub1), tokens);
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

  function test_splitNativeRevenue_zeroShareSkipped() public {
    vm.deal(address(splitter), 1);

    vm.expectEmit(address(splitter));
    emit TreasuryFeeSplitter.NativeRevenueSplit(0, 1, true, true);
    splitter.splitNativeRevenue();

    assertEq(RECIPIENT_A.balance, 0);
    assertEq(RECIPIENT_B.balance, 1);
  }

  function test_splitNativeRevenue_fuzz(uint256 amount, uint16 splitA) public {
    amount = bound(amount, 1, 1e30);
    splitA = uint16(bound(splitA, 1, 99_99));
    _redeployAndHandOver(splitA);
    vm.deal(address(splitter), amount);

    splitter.splitNativeRevenue();

    _assertSplit(RECIPIENT_A.balance, RECIPIENT_B.balance, amount, splitA);
    assertEq(address(splitter).balance, 0);
  }

  function test_splitNativeRevenue_rejectingRecipientDoesNotBlock() public {
    // recipient A is a contract without receive(): its send fails, B is still paid
    address rejecting = address(new MockERC20());
    splitter = new TreasuryFeeSplitter(
      address(treasurySpoke),
      _hubList(address(hub1)),
      SPLIT_OWNER,
      rejecting,
      RECIPIENT_B,
      SPLIT_A
    );
    vm.deal(address(splitter), 1 ether);

    vm.expectEmit(address(splitter));
    emit TreasuryFeeSplitter.NativeRevenueSplit(0.7 ether, 0.3 ether, false, true);
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
    _supplyAsTreasury(hub1, tokenList.dai, 100e18);
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
        _hubList(address(hub1)),
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

  function _redeployAndHandOver(uint16 splitA) internal {
    splitter = _deploy(splitA);
    _handOver();
  }

  /// @dev A gets floor(amount * splitA / 10_000), B the rest, and nothing is lost.
  function _assertSplit(uint256 toA, uint256 toB, uint256 amount, uint16 splitA) internal pure {
    assertEq(toA, (amount * splitA) / 100_00, 'A floors');
    assertEq(toA + toB, amount, 'conserved');
    assertLe(toA * 100_00, amount * splitA, 'A never above its share');
    assertGe(toB * 100_00, amount * (100_00 - splitA), 'B never below its share');
  }

  /// @dev Real liquidity fees: open debt, accrue a year, mint fee shares to the treasury.
  function _accrueFees() internal {
    _openDebtPosition(spoke1, _getReserveIdByAssetId(spoke1, hub1, daiAssetId), 100e18, true);
    skip(365 days);
    HubActions.mintFeeShares({hub: hub1, assetId: daiAssetId, caller: ADMIN});
  }

  /// @dev Treasury-held balance without waiting on accrual: supply skimmed on the treasury.
  function _supplyAsTreasury(IHub hub, IERC20 token, uint256 amount) internal {
    deal(address(token), address(hub), token.balanceOf(address(hub)) + amount);
    vm.prank(SPLIT_OWNER);
    splitter.executeOnTreasury(
      abi.encodeCall(ITreasurySpoke.supplySkimmed, (address(hub), address(token), amount))
    );
  }

  function _hubList(address a) internal pure returns (address[] memory h) {
    h = new address[](1);
    h[0] = a;
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
