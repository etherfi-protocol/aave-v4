// SPDX-License-Identifier: LicenseRef-BUSL
pragma solidity 0.8.28;

/// @title IChainlinkAggregator
/// @notice The subset of the Chainlink aggregator surface this adapter consumes and re-exposes.
/// @dev Deliberately minimal. `getRoundData` and `latestRound` are the two members that make a
///      previous-round reference possible without any stored state.
interface IChainlinkAggregator {
  function decimals() external view returns (uint8);

  function description() external view returns (string memory);

  function latestAnswer() external view returns (int256);

  function latestTimestamp() external view returns (uint256);

  function latestRound() external view returns (uint256);

  function latestRoundData()
    external
    view
    returns (
      uint80 roundId,
      int256 answer,
      uint256 startedAt,
      uint256 updatedAt,
      uint80 answeredInRound
    );

  function getRoundData(
    uint80 roundId
  )
    external
    view
    returns (
      uint80 id,
      int256 answer,
      uint256 startedAt,
      uint256 updatedAt,
      uint80 answeredInRound
    );
}

/// @title IChainlinkPriceBandAdapter
/// @notice A Chainlink feed wrapped so a single round cannot raise the reported price by more than
///         a configured percentage over the feed's own previous round.
interface IChainlinkPriceBandAdapter is IChainlinkAggregator {
  /// @notice Thrown when the wrapped feed reports a non-positive answer.
  error InvalidPrice();
  /// @notice Thrown when the feed address is zero.
  error FeedIsZeroAddress();
  /// @notice Thrown when the configured band is outside [MIN_BAND_BPS, MAX_BAND_BPS].
  error InvalidBand(uint16 bandBps);
  /// @notice Thrown when the widen period is outside [MIN_WIDEN_PERIOD, MAX_WIDEN_PERIOD].
  error InvalidWidenPeriod(uint32 widenPeriod);
  /// @notice Thrown when the reference age is outside [MIN_REFERENCE_AGE, MAX_REFERENCE_AGE].
  error InvalidReferenceAge(uint32 referenceAge);

  /// @notice The wrapped Chainlink feed.
  function FEED() external view returns (IChainlinkAggregator);

  /// @notice Base band, in basis points, applied to a freshly published round.
  function BAND_BPS() external view returns (uint16);

  /// @notice Seconds of round age that add one further `BAND_BPS` to the band.
  /// @dev The band widens linearly with the age of the latest round, so a clamp decays instead of
  ///      holding until the feed happens to publish again.
  function WIDEN_PERIOD() external view returns (uint32);

  /// @notice The band actually in force right now, in basis points, given the latest round's age.
  function effectiveBandBps() external view returns (uint256);

  /// @notice Seconds since the latest round was published.
  function roundAge() external view returns (uint256);

  /// @notice How far back in time the reference round must sit, in seconds.
  /// @dev This is what makes the band a bound per unit of TIME rather than per round. Without it,
  ///      anyone able to produce rounds can post several in one block, each inside the band against
  ///      its immediate predecessor, and walk the price anywhere.
  function REFERENCE_AGE() external view returns (uint32);

  /// @notice Whether the reference actually met `REFERENCE_AGE`.
  /// @dev False means the lookback was exhausted before finding a round that old, so the oldest
  ///      reachable round was used instead. In normal operation this is always true; false is the
  ///      signature of an unusual burst of rounds and is worth alerting on.
  function referenceIsAnchored() external view returns (bool);

  /// @notice The feed's unmodified latest answer, before the band is applied.
  function rawAnswer() external view returns (int256);

  /// @notice The previous round's answer, which the band is measured against.
  /// @return answer The reference answer, or 0 when no reference is available.
  function referenceAnswer() external view returns (int256 answer);

  /// @notice Whether a previous-round reference could be read.
  /// @dev False means the band is inert for this round and the raw answer passes through: the
  ///      feed is on the first round of a phase, or `getRoundData` reverted. Monitor this — a view
  ///      contract cannot emit, so this getter is the only signal that the band is not protecting.
  function hasReference() external view returns (bool);

  /// @notice Whether the band is currently clamping the reported price.
  function isCapped() external view returns (bool);
}
