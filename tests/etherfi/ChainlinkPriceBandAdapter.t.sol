// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from 'forge-std/Test.sol';

import {ChainlinkPriceBandAdapter} from 'src/etherfi/ChainlinkPriceBandAdapter.sol';
import {
  IChainlinkAggregator,
  IChainlinkPriceBandAdapter
} from 'src/etherfi/interfaces/IChainlinkPriceBandAdapter.sol';

/// @dev Minimal Chainlink aggregator whose round history can be driven from a test, including the
///      failure shapes the adapter has to survive: a phase's first round, a reverting
///      `getRoundData`, and a round that answers zero.
contract MockAggregator is IChainlinkAggregator {
  uint8 public decimals;
  string public description;

  uint16 public phaseId = 1;
  uint64 public aggregatorRound;
  bool public revertOnHistory;

  /// @dev Keyed by the PACKED round id (phase << 64 | round), because a real proxy's phases are
  ///      separate aggregators and do not share history. Keying by round alone would let phase 1's
  ///      rounds leak into phase 2 and quietly invalidate the boundary tests.
  mapping(uint80 => int256) public answers;
  mapping(uint80 => uint256) public timestamps;

  constructor(uint8 decimals_, string memory description_) {
    decimals = decimals_;
    description = description_;
  }

  function push(int256 answer, uint256 updatedAt) external {
    aggregatorRound += 1;
    uint80 id = _packed(aggregatorRound);
    answers[id] = answer;
    timestamps[id] = updatedAt;
  }

  /// @dev Writes a round into an arbitrary phase, for the phase-boundary cases.
  function seed(uint16 phase_, uint64 round_, int256 answer, uint256 updatedAt) external {
    uint80 id = uint80((uint256(phase_) << 64) | uint256(round_));
    answers[id] = answer;
    timestamps[id] = updatedAt;
  }

  function setPhase(uint16 phaseId_, uint64 aggregatorRound_) external {
    phaseId = phaseId_;
    aggregatorRound = aggregatorRound_;
  }

  function setRevertOnHistory(bool value) external {
    revertOnHistory = value;
  }

  function _packed(uint64 round) internal view returns (uint80) {
    return uint80((uint256(phaseId) << 64) | uint256(round));
  }

  function latestRound() external view returns (uint256) {
    return _packed(aggregatorRound);
  }

  function latestAnswer() external view returns (int256) {
    return answers[_packed(aggregatorRound)];
  }

  function latestTimestamp() external view returns (uint256) {
    return timestamps[_packed(aggregatorRound)];
  }

  function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
    uint80 id = _packed(aggregatorRound);
    return (id, answers[id], timestamps[id], timestamps[id], id);
  }

  function getRoundData(
    uint80 roundId
  ) external view returns (uint80, int256, uint256, uint256, uint80) {
    require(!revertOnHistory, 'no history');
    return (roundId, answers[roundId], timestamps[roundId], timestamps[roundId], roundId);
  }
}

contract ChainlinkPriceBandAdapterTest is Test {
  uint16 internal constant BAND = 2000; // 20%, the equity Level 3 halt

  MockAggregator internal feed;
  ChainlinkPriceBandAdapter internal adapter;

  function setUp() public {
    feed = new MockAggregator(8, 'MOCK / USD');
    feed.push(100e8, 1000);
    feed.push(100e8, 2000);
    adapter = new ChainlinkPriceBandAdapter(feed, BAND, 'Banded MOCK / USD');
  }

  // --- construction ---------------------------------------------------------------------------

  function test_constructor_copiesDecimalsAndStoresConfig() public view {
    assertEq(adapter.decimals(), 8);
    assertEq(adapter.BAND_BPS(), BAND);
    assertEq(address(adapter.FEED()), address(feed));
    assertEq(adapter.description(), 'Banded MOCK / USD');
  }

  function test_constructor_revertsOnZeroFeed() public {
    vm.expectRevert(IChainlinkPriceBandAdapter.FeedIsZeroAddress.selector);
    new ChainlinkPriceBandAdapter(IChainlinkAggregator(address(0)), BAND, 'x');
  }

  function test_constructor_revertsOnBandTooTight() public {
    uint16 tooTight = adapter.MIN_BAND_BPS() - 1;
    vm.expectRevert(
      abi.encodeWithSelector(IChainlinkPriceBandAdapter.InvalidBand.selector, tooTight)
    );
    new ChainlinkPriceBandAdapter(feed, tooTight, 'x');
  }

  function test_constructor_revertsOnBandTooLoose() public {
    uint16 tooLoose = adapter.MAX_BAND_BPS() + 1;
    vm.expectRevert(
      abi.encodeWithSelector(IChainlinkPriceBandAdapter.InvalidBand.selector, tooLoose)
    );
    new ChainlinkPriceBandAdapter(feed, tooLoose, 'x');
  }

  function test_constructor_revertsOnZeroBand() public {
    vm.expectRevert(
      abi.encodeWithSelector(IChainlinkPriceBandAdapter.InvalidBand.selector, uint16(0))
    );
    new ChainlinkPriceBandAdapter(feed, 0, 'x');
  }

  // --- the band ------------------------------------------------------------------------------

  function test_withinBand_passesThrough() public {
    feed.push(110e8, 3000); // +10% against a 20% band
    assertEq(adapter.latestAnswer(), 110e8);
    assertFalse(adapter.isCapped());
    assertEq(adapter.rawAnswer(), 110e8);
  }

  function test_aboveBand_clampsToCeiling() public {
    feed.push(200e8, 3000); // +100% against a 20% band
    assertEq(adapter.latestAnswer(), 120e8, 'clamped to previous + 20%');
    assertTrue(adapter.isCapped());
    assertEq(adapter.rawAnswer(), 200e8, 'raw still visible');
  }

  function test_exactlyAtCeiling_doesNotClamp() public {
    feed.push(120e8, 3000);
    assertEq(adapter.latestAnswer(), 120e8);
    assertFalse(adapter.isCapped());
  }

  /// @dev The whole point of upward-only: a real crash must reach the oracle immediately, or
  ///      liquidations stop being economically correct and the shortfall lands on suppliers.
  function test_fall_passesThroughUnclamped() public {
    feed.push(10e8, 3000); // -90%
    assertEq(adapter.latestAnswer(), 10e8);
    assertFalse(adapter.isCapped());
  }

  function test_reference_isPreviousRound() public {
    feed.push(150e8, 3000);
    assertEq(adapter.referenceAnswer(), 100e8);
    assertTrue(adapter.hasReference());
    // and the band tracks the reference as it moves
    feed.push(150e8, 4000);
    assertEq(adapter.referenceAnswer(), 150e8);
    assertEq(adapter.latestAnswer(), 150e8);
  }

  function test_latestRoundData_returnsBandedAnswerWithOriginalRoundAndTime() public {
    feed.push(500e8, 7777);
    (
      uint80 roundId,
      int256 answer,
      uint256 startedAt,
      uint256 updatedAt,
      uint80 answeredInRound
    ) = adapter.latestRoundData();
    assertEq(answer, 120e8, 'banded');
    assertEq(updatedAt, 7777, 'underlying timestamp preserved for staleness checks');
    assertEq(startedAt, 7777);
    assertEq(roundId, answeredInRound);
    assertEq(uint64(roundId), 3);
  }

  function test_getRoundData_passesHistoryThroughUnbanded() public {
    feed.push(500e8, 7777);
    (, int256 historical, , , ) = adapter.getRoundData(uint80((uint256(1) << 64) | 3));
    assertEq(historical, 500e8, 'history is what the feed published, not what we would report now');
  }

  function test_revertsWhenLatestAnswerNonPositive() public {
    feed.push(0, 3000);
    vm.expectRevert(IChainlinkPriceBandAdapter.InvalidPrice.selector);
    adapter.latestAnswer();
  }

  // --- fail-open paths, each of which must NOT revert -------------------------------------------

  function test_firstRoundOfPhase_hasNoReferenceAndPassesThrough() public {
    feed.setPhase(2, 1);
    // round 1 of phase 2, with an absurd value and no previous round to measure against
    feed.seed(2, 1, 9999e8, 5000);
    assertFalse(adapter.hasReference(), 'no previous round inside this phase');
    assertEq(adapter.referenceAnswer(), 0);
    assertEq(adapter.latestAnswer(), 9999e8, 'fails open rather than reverting');
    assertFalse(adapter.isCapped());
  }

  function test_historyReverting_failsOpen() public {
    feed.push(500e8, 3000);
    feed.setRevertOnHistory(true);
    assertFalse(adapter.hasReference());
    assertEq(adapter.latestAnswer(), 500e8, 'a reverting getRoundData must not brick the price');
  }

  function test_previousRoundZeroAnswer_failsOpen() public {
    // phase 2 at round 2, whose round 1 was never written -> the reference answers zero
    feed.setPhase(2, 2);
    feed.seed(2, 2, 500e8, 5000);
    assertFalse(adapter.hasReference(), 'a zero-answer reference is not a reference');
    assertEq(adapter.latestAnswer(), 500e8);
  }

  /// @dev Decrementing a packed round id across a phase boundary reads a different aggregator.
  ///      The adapter must preserve the phase, so phase 2 round 1 never references phase 1.
  function test_doesNotReferenceAcrossPhaseBoundary() public {
    // phase 1 rounds 1 and 2 exist from setUp and hold 100e8. If the adapter decremented across
    // the boundary it would band 1000e8 against them and clamp to 120e8.
    feed.setPhase(2, 1);
    feed.seed(2, 1, 1000e8, 5000);
    assertFalse(adapter.hasReference());
    assertEq(adapter.latestAnswer(), 1000e8);
  }

  // --- fuzz ------------------------------------------------------------------------------------

  function testFuzz_neverExceedsCeilingAndNeverRaisesAFall(int256 next, uint16 bandBps) public {
    next = bound(next, 1, int256(1e18));
    bandBps = uint16(bound(bandBps, adapter.MIN_BAND_BPS(), adapter.MAX_BAND_BPS()));

    ChainlinkPriceBandAdapter a = new ChainlinkPriceBandAdapter(feed, bandBps, 'fuzz');
    feed.push(next, 3000);

    int256 reported = a.latestAnswer();
    int256 ceiling = 100e8 + (100e8 * int256(uint256(bandBps))) / 10_000;

    assertLe(reported, ceiling, 'never above the ceiling');
    assertLe(reported, next, 'never above what the feed said');
    if (next <= ceiling) assertEq(reported, next, 'untouched when inside the band');
    assertGt(reported, 0, 'never reports a non-positive price');
  }
}

/// @dev Against the two live Optimism feeds this adapter was built for. Skipped when RPC_OPTIMISM
///      is unset so the default suite stays offline.
contract ChainlinkPriceBandAdapterForkTest is Test {
  address internal constant SPY_USD_OP = 0x5F77134CfAA7DB2906649Ca21C50dA54daE9291d;
  address internal constant PAXG_USD_OP = 0x977CD3bC66A1FA9Fb22F9BEAA966E06996f70512;

  function _fork() internal returns (bool) {
    string memory rpc = vm.envOr('RPC_OPTIMISM', string(''));
    if (bytes(rpc).length == 0) return false;
    vm.createSelectFork(rpc);
    return true;
  }

  function _check(address feed, uint16 band, string memory label) internal {
    ChainlinkPriceBandAdapter a = new ChainlinkPriceBandAdapter(
      IChainlinkAggregator(feed),
      band,
      string.concat('Banded ', label)
    );

    assertEq(a.decimals(), IChainlinkAggregator(feed).decimals(), 'decimals mirrored');
    assertTrue(a.hasReference(), 'live feed must expose a previous round');
    assertGt(a.referenceAnswer(), 0, 'reference positive');

    int256 raw = a.rawAnswer();
    int256 reported = a.latestAnswer();
    assertGt(raw, 0, 'raw positive');
    assertEq(reported, raw, 'a 20% band must not clamp a live feed');
    assertFalse(a.isCapped(), 'not capped in normal markets');
  }

  function test_fork_spy() public {
    if (!_fork()) return;
    _check(SPY_USD_OP, 2000, 'SPY-USD (24/5)');
  }

  function test_fork_paxg() public {
    if (!_fork()) return;
    _check(PAXG_USD_OP, 2000, 'PAXG / USD');
  }

  /// @dev The band must bind on a live feed when the feed itself prints something absurd.
  function test_fork_clampsAnInjectedSpike() public {
    if (!_fork()) return;
    ChainlinkPriceBandAdapter a = new ChainlinkPriceBandAdapter(
      IChainlinkAggregator(SPY_USD_OP),
      2000,
      'Banded SPY'
    );

    int256 refPrice = a.referenceAnswer();
    (uint80 roundId, , uint256 startedAt, uint256 updatedAt, ) = IChainlinkAggregator(SPY_USD_OP)
      .latestRoundData();

    vm.mockCall(
      SPY_USD_OP,
      abi.encodeWithSelector(IChainlinkAggregator.latestRoundData.selector),
      abi.encode(roundId, refPrice * 10, startedAt, updatedAt, roundId)
    );

    assertTrue(a.isCapped(), 'a 10x print must be clamped');
    assertEq(a.latestAnswer(), refPrice + (refPrice * 2000) / 10_000, 'clamped to reference + 20%');
  }
}
