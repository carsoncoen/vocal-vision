import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:ultralytics_yolo/yolo.dart';

import 'awareness_config.dart';
import 'awareness_models.dart';

/// Turns raw YOLO detections into one awareness decision for the UI/TTS layer.
///
/// High-level flow:
/// 1. Build valid candidates from raw detections.
/// 2. Check for immediate danger.
/// 3. Group normal candidates by label + direction.
/// 4. Rank groups and apply the person-priority rule.
/// 5. Wait for short-term stability before normal speech.
/// 6. Return one stable spoken summary for the UI/TTS layer.
///
/// This engine decides what the current summary is. The widget layer decides
/// when to speak that summary immediately and when to repeat it at a controlled
/// interval.
class AnnouncementEngine
{
  AnnouncementEngine({AwarenessConfig? config}) : _config = config ?? AwarenessConfig.defaults();

  final AwarenessConfig _config;

  /// Remembers how many consecutive decision cycles each group has survived.
  ///
  /// Example:
  /// - "chair_left" seen this cycle and last cycle -> count grows
  /// - missing in the next cycle -> count resets because it will not be copied
  final Map<String, int> _groupStabilityCounts = <String, int>{};

  // ---------------------------------------------------------------------------
  // Public entry point
  // ---------------------------------------------------------------------------

  /// Main function called by the UI layer for each detection update.
  ///
  /// Returns:
  /// - danger decision if something urgent is close
  /// - normal decision if stable top groups are ready to speak
  /// - none if nothing should be spoken right now
  AnnouncementDecision processDetections(List<YOLOResult> detections)
  {
    if (detections.isEmpty) {
      _groupStabilityCounts.clear();
      return const AnnouncementDecision.none();
    }

    // Stage 1: Convert raw detections into filtered, scored candidates.
    final List<DetectionCandidate> candidates = <DetectionCandidate>[];

    for (final YOLOResult detection in detections) {
      final DetectionCandidate? candidate = _buildCandidate(detection);
      if (candidate != null) {
        candidates.add(candidate);
      }
    }

    if (candidates.isEmpty) {
      _groupStabilityCounts.clear();
      return const AnnouncementDecision.none();
    }

    // Stage 2: Danger path.
    // Danger warnings bypass normal persistence and are spoken immediately.
    final DetectionCandidate? dangerCandidate = _pickDangerCandidate(candidates);
    if (dangerCandidate != null) {
      return _buildDangerDecision(dangerCandidate);
    }

    // Stage 3: Normal awareness path.
    List<CandidateGroup> groups = _groupCandidates(candidates);
    groups = _sortGroups(groups);
    groups = _applyPersonOverride(groups);

    // Stage 4: Persistence / stability.
    final List<CandidateGroup> stableTopGroups = _selectStableTopGroups(groups);
    if (stableTopGroups.isEmpty) {
      return AnnouncementDecision(
        type: AnnouncementType.none,
        spokenText: '',
        statusText: _buildPreviewStatus(groups),
        shouldSpeak: false,
        shouldInterrupt: false,
        summaryKey: '',
        topGroups: groups,
      );
    }

    // Stage 5: Build the final normal summary.
    //
    // The engine always returns the latest stable summary key so the UI layer
    // can decide when to speak it immediately and when to repeat it at a
    // controlled interval.
    final String spokenText = _buildNormalSentence(stableTopGroups);
    final String summaryKey = _buildSummaryKey(stableTopGroups);

    return AnnouncementDecision(
      type: AnnouncementType.normal,
      spokenText: spokenText,
      statusText: spokenText,
      shouldSpeak: true,
      shouldInterrupt: false,
      summaryKey: summaryKey,
      topGroups: stableTopGroups,
    );
  }

  // ---------------------------------------------------------------------------
  // Candidate building
  // ---------------------------------------------------------------------------

  /// Builds one candidate from one raw YOLO detection.
  ///
  /// A candidate is a detection that has passed broad filtering and now has the
  /// extra information needed for ranking, grouping, and speech.
  DetectionCandidate? _buildCandidate(YOLOResult detection)
  {
    final String label = _normalizeLabel(detection.className);

    // Filter 1: Ignore low-confidence detections.
    if (detection.confidence < _config.confidenceThreshold) {
      return null;
    }

    // Filter 2: Ignore labels outside the allowed indoor-object set.
    if (!_config.allowedLabels.contains(label)) {
      return null;
    }

    // Estimate distance when possible. If distance cannot be estimated, fall
    // back to minimum box-height filtering for unknown-distance objects.
    final double? distanceFeet = _estimateDistanceFeet(detection, label);
    final double boxHeight = detection.normalizedBox.height;

    if (distanceFeet != null) {
      if (distanceFeet > _config.maxAlertDistanceFeet) {
        return null;
      }
    } else {
      if (boxHeight < _config.minBoxHeightForUnknownDistance) {
        return null;
      }
    }

    // Extract simple geometry used for direction and scoring.
    final BoxGeometry geometry = _extractGeometry(detection.normalizedBox);
    final RelativeDirection direction = _determineDirection(geometry.centerX);

    // Build one score that represents how relevant this object is right now.
    final double score = _calculateScore(
      label: label,
      confidence: detection.confidence,
      distanceFeet: distanceFeet,
      centerX: geometry.centerX,
      bottomY: geometry.bottomY,
      boxHeight: boxHeight,
      direction: direction,
    );

    return DetectionCandidate(
      detection: detection,
      label: label,
      distanceFeet: distanceFeet,
      boxHeight: boxHeight,
      centerX: geometry.centerX,
      bottomY: geometry.bottomY,
      direction: direction,
      score: score,
    );
  }

  /// Extracts basic box geometry used throughout the engine.
  ///
  /// - centerX decides left / ahead / right
  /// - bottomY is used as a soft vertical relevance signal
  BoxGeometry _extractGeometry(Rect box)
  {
    final double centerX = box.left + (box.width / 2.0);
    final double bottomY = box.top + box.height;

    return BoxGeometry(
      box: box,
      centerX: centerX,
      bottomY: bottomY,
    );
  }

  /// Maps horizontal position to the relative direction spoken to the user.
  RelativeDirection _determineDirection(double centerX)
  {
    if (centerX < _config.leftZoneMaxX) {
      return RelativeDirection.left;
    }

    if (centerX > _config.rightZoneMinX) {
      return RelativeDirection.right;
    }

    return RelativeDirection.ahead;
  }

  /// Estimates object distance in feet using bounding-box height and the
  /// configured average real-world height for that object class.
  ///
  /// This is an approximate monocular estimate, not a precise depth reading.
  double? _estimateDistanceFeet(YOLOResult detection, String normalizedLabel)
  {
    final double? realHeightFeet = _config.averageHeightsFeet[normalizedLabel];
    if (realHeightFeet == null) {
      return null;
    }

    final double boxHeightNorm = detection.normalizedBox.height;
    if (boxHeightNorm <= 0) {
      return null;
    }

    final double fovRadians = _config.cameraVerticalFovDeg * math.pi / 180.0;
    final double rawFeet = realHeightFeet / (2.0 * boxHeightNorm * math.tan(fovRadians / 2.0));

    if (!rawFeet.isFinite || rawFeet <= 0) {
      return null;
    }

    return rawFeet;
  }

  // ---------------------------------------------------------------------------
  // Scoring
  // ---------------------------------------------------------------------------

  /// Combines all scoring features into one relevance score.
  ///
  /// Higher score means the object is more worth talking about right now.
  double _calculateScore({
    required String label,
    required double confidence,
    required double? distanceFeet,
    required double centerX,
    required double bottomY,
    required double boxHeight,
    required RelativeDirection direction,
  })
  {
    final double distanceScore = _buildDistanceScore(distanceFeet, boxHeight);
    final double directionScore = _buildDirectionScore(direction, centerX);
    final double verticalScore = _buildVerticalScore(bottomY);
    final double confidenceScore = _clampDouble(confidence, 0.0, 1.0);
    final double objectImportanceScore = _buildObjectImportanceScore(label);

    return (_config.distanceWeight * distanceScore) +
        (_config.directionWeight * directionScore) +
        (_config.verticalWeight * verticalScore) +
        (_config.confidenceWeight * confidenceScore) +
        (_config.objectImportanceWeight * objectImportanceScore);
  }

  /// Builds the closeness part of the score.
  ///
  /// - If distance exists, closer objects get a higher score.
  /// - If distance is unknown, box height is used as a fallback closeness proxy.
  double _buildDistanceScore(double? distanceFeet, double boxHeight)
  {
    if (distanceFeet != null)
    {
      // _clampDouble() is a helper function that clamps a value between a minimum and maximum value.
      final double clampedDistance = _clampDouble(distanceFeet, 0.0, _config.maxAlertDistanceFeet);
      return 1.0 - (clampedDistance / _config.maxAlertDistanceFeet);
    }

    return _clampDouble(boxHeight, 0.0, 1.0);
  }

  /// Builds the horizontal relevance part of the score.
  ///
  /// Objects in the ahead region get more weight than the side regions. A small
  /// alignment bonus is also added for being closer to the middle of the screen.
  double _buildDirectionScore(RelativeDirection direction, double centerX)
  {
    final double zoneWeight = direction == RelativeDirection.ahead
        ? _config.aheadDirectionBonus
        : _config.sideDirectionBonus;

    final double centerAlignment = 1.0 - ((centerX - 0.5).abs() / 0.5);
    final double alignmentBonus = _clampDouble(centerAlignment, 0.0, 1.0);

    return (0.75 * zoneWeight) + (0.25 * alignmentBonus);
  }

  /// Builds the vertical relevance part of the score.
  ///
  /// Lower-in-frame objects receive a higher score, but this is intentionally a
  /// soft signal because phone angle can vary in real use.
  double _buildVerticalScore(double bottomY)
  {
    return _clampDouble(bottomY, 0.0, 1.0);
  }

  /// Gives extra importance to classes that matter more for the user.
  ///
  /// Sponsor requirement: people should be prioritized above other object types
  /// when it makes sense to do so.
  double _buildObjectImportanceScore(String label)
  {
    if (label == 'person') {
      return 1.0;
    }

    if (label == 'chair' || label == 'dining table' || label == 'door') {
      return 0.7;
    }

    return 0.4;
  }

  // ---------------------------------------------------------------------------
  // Danger path
  // ---------------------------------------------------------------------------

  /// Finds the most urgent danger candidate if any object is inside the danger
  /// distance threshold.
  ///
  /// Danger warnings are prioritized by:
  /// 1. person override rule when applicable
  /// 2. closest distance
  /// 3. higher score as the final tie-breaker
  DetectionCandidate? _pickDangerCandidate(List<DetectionCandidate> candidates)
  {
    final List<DetectionCandidate> dangerCandidates = <DetectionCandidate>[];

    for (final DetectionCandidate candidate in candidates)
    {
      final double? distanceFeet = candidate.distanceFeet;
      if (distanceFeet != null && distanceFeet < _config.dangerDistanceFeet)
      {
        dangerCandidates.add(candidate);
      }
    }

    if (dangerCandidates.isEmpty)
    {
      return null;
    }

    dangerCandidates.sort((DetectionCandidate a, DetectionCandidate b) {
      if (a.label == 'person' && b.label != 'person') {
        if (_canPersonOverride(otherCandidate: b, personCandidate: a)) {
          return -1;
        }
      }

      if (b.label == 'person' && a.label != 'person') {
        if (_canPersonOverride(otherCandidate: a, personCandidate: b)) {
          return 1;
        }
      }

      final double aDistance = a.distanceFeet ?? double.infinity;
      final double bDistance = b.distanceFeet ?? double.infinity;

      if (aDistance < bDistance) {
        return -1;
      }
      if (aDistance > bDistance) {
        return 1;
      }

      if (a.score > b.score) {
        return -1;
      }
      if (a.score < b.score) {
        return 1;
      }

      return 0;
    });

    return dangerCandidates.first;
  }

  /// Builds the immediate warning sentence for danger mode.
  AnnouncementDecision _buildDangerDecision(DetectionCandidate candidate)
  {
    final String spokenLabel = _spokenLabel(candidate.label, count: 1);
    final String directionText = _directionToSpeech(candidate.direction);
    final String sentence = 'Warning, $spokenLabel $directionText';

    return AnnouncementDecision(
      type: AnnouncementType.danger,
      spokenText: sentence,
      statusText: sentence,
      shouldSpeak: true,
      shouldInterrupt: true,
      summaryKey: '',
      topGroups: const <CandidateGroup>[],
    );
  }

  // ---------------------------------------------------------------------------
  // Grouping and ranking
  // ---------------------------------------------------------------------------

  /// Groups candidates by label + direction so speech can say things like:
  /// - "person ahead"
  /// - "2 chairs left, closest 3 feet"
  /// The best group candidate is the one that is closest to the user, and we use best score as a tie-breaker.
  List<CandidateGroup> _groupCandidates(List<DetectionCandidate> candidates)
  {
    final Map<String, List<DetectionCandidate>> groupedMembers = <String, List<DetectionCandidate>>{};

    for (final DetectionCandidate candidate in candidates) {
      final String groupKey = '${candidate.label}_${candidate.direction.name}';
      groupedMembers.putIfAbsent(groupKey, () => <DetectionCandidate>[]);
      groupedMembers[groupKey]!.add(candidate);
    }

    final List<CandidateGroup> groups = <CandidateGroup>[];

    groupedMembers.forEach((String _, List<DetectionCandidate> members) {
      // Inside a group, keep the nearest member first so the group has a clear
      // representative distance and score ordering.
      members.sort((DetectionCandidate a, DetectionCandidate b) {
        final double aDistance = a.distanceFeet ?? double.infinity;
        final double bDistance = b.distanceFeet ?? double.infinity;

        if (aDistance < bDistance) {
          return -1;
        }
        if (aDistance > bDistance) {
          return 1;
        }

        if (a.score > b.score) {
          return -1;
        }
        if (a.score < b.score) {
          return 1;
        }

        return 0;
      });

      double? closestDistanceFeet;
      for (final DetectionCandidate member in members) {
        if (member.distanceFeet != null) {
          if (closestDistanceFeet == null || member.distanceFeet! < closestDistanceFeet) {
            closestDistanceFeet = member.distanceFeet;
          }
        }
      }

      double bestScore = members.first.score;
      for (final DetectionCandidate member in members) {
        if (member.score > bestScore) {
          bestScore = member.score;
        }
      }

      groups.add(
        CandidateGroup(
          label: members.first.label,
          direction: members.first.direction,
          members: members,
          count: members.length,
          closestDistanceFeet: closestDistanceFeet,
          bestScore: bestScore,
        ),
      );
    });

    return groups;
  }

  /// Sorts groups by overall relevance.
  ///
  /// Primary key: best group score
  /// Secondary key: closest distance
  List<CandidateGroup> _sortGroups(List<CandidateGroup> groups)
  {
    groups.sort((CandidateGroup a, CandidateGroup b) {
      if (a.bestScore > b.bestScore) {
        return -1;
      }
      if (a.bestScore < b.bestScore) {
        return 1;
      }

      final double aDistance = a.closestDistanceFeet ?? double.infinity;
      final double bDistance = b.closestDistanceFeet ?? double.infinity;

      if (aDistance < bDistance) {
        return -1;
      }
      if (aDistance > bDistance) {
        return 1;
      }

      return 0;
    });

    return groups;
  }

  /// Applies the sponsor-driven person-priority rule after normal sorting.
  ///
  /// If a person group is only slightly farther away than the group above it,
  /// the person group can move ahead in ranking.
  List<CandidateGroup> _applyPersonOverride(List<CandidateGroup> groups)
  {
    final List<CandidateGroup> rankedGroups = List<CandidateGroup>.from(groups);

    for (int i = 1; i < rankedGroups.length; i++) {
      final CandidateGroup currentGroup = rankedGroups[i];
      final CandidateGroup previousGroup = rankedGroups[i - 1];

      if (currentGroup.label == 'person' && previousGroup.label != 'person') {
        if (_canPersonOverrideGroup(
          otherGroup: previousGroup,
          personGroup: currentGroup,
        )) {
          rankedGroups[i - 1] = currentGroup;
          rankedGroups[i] = previousGroup;
        }
      }
    }

    return rankedGroups;
  }

  /// Per-candidate version of the person-priority rule used in danger mode.
  bool _canPersonOverride({
    required DetectionCandidate otherCandidate,
    required DetectionCandidate personCandidate,
  })
  {
    if (personCandidate.distanceFeet == null || otherCandidate.distanceFeet == null) {
      return false;
    }

    final double distanceGap = personCandidate.distanceFeet! - otherCandidate.distanceFeet!;
    return distanceGap <= _config.personPriorityOverrideFeet;
  }

  /// Group-level version of the person-priority rule used in normal ranking.
  bool _canPersonOverrideGroup({
    required CandidateGroup otherGroup,
    required CandidateGroup personGroup,
  })
  {
    if (personGroup.closestDistanceFeet == null || otherGroup.closestDistanceFeet == null) {
      return false;
    }

    final double distanceGap =
        personGroup.closestDistanceFeet! - otherGroup.closestDistanceFeet!;
    return distanceGap <= _config.personPriorityOverrideFeet;
  }

  // ---------------------------------------------------------------------------
  // Stability and deduplication
  // ---------------------------------------------------------------------------

  /// Keeps only groups that have survived enough consecutive cycles.
  ///
  /// This smooths out short-lived flicker before normal speech is allowed.
  List<CandidateGroup> _selectStableTopGroups(List<CandidateGroup> rankedGroups)
  {
    final Map<String, int> nextStabilityCounts = <String, int>{};
    final List<CandidateGroup> stableGroups = <CandidateGroup>[];

    for (final CandidateGroup group in rankedGroups) {
      final int newCount = (_groupStabilityCounts[group.stableKey] ?? 0) + 1;
      nextStabilityCounts[group.stableKey] = newCount;

      if (newCount >= _config.minStableCycles) {
        stableGroups.add(group);
      }
    }

    _groupStabilityCounts
      ..clear()
      ..addAll(nextStabilityCounts);

    if (stableGroups.isEmpty) {
      return <CandidateGroup>[];
    }

    return stableGroups.take(_config.maxNormalGroupsToSpeak).toList();
  }

  /// Builds a compact summary key for the groups that would be spoken.
  ///
  /// The summary key represents the spoken meaning of the current stable top
  /// groups. The UI layer uses it to decide whether the summary changed or
  /// whether the same summary should be repeated again.
  String _buildSummaryKey(List<CandidateGroup> groups)
  {
    final List<SpokenGroupSnapshot> snapshots = <SpokenGroupSnapshot>[];

    for (final CandidateGroup group in groups) {
      final double? distanceFeet = group.closestDistanceFeet == null ? null : _roundToNearestBucket(group.closestDistanceFeet!, _config.distanceBufferFeet);

      snapshots.add(
        SpokenGroupSnapshot(
          stableKey: group.stableKey,
          count: group.count,
          distanceFeet: distanceFeet,
        ),
      );
    }

    return snapshots
        .map((SpokenGroupSnapshot snapshot) => snapshot.toSummaryToken())
        .join('|');
  }

  // ---------------------------------------------------------------------------
  // Speech formatting
  // ---------------------------------------------------------------------------

  /// Builds the final normal sentence spoken to the user.
  ///
  /// Each group becomes one phrase. Phrases are joined with periods so they are
  /// easier for TTS to speak clearly.
  String _buildNormalSentence(List<CandidateGroup> groups)
  {
    final List<String> parts = <String>[];

    for (final CandidateGroup group in groups) {
      final String spokenLabel = _spokenLabel(group.label, count: group.count);
      final String directionText = _directionToSpeech(group.direction);
      final String distanceText = _buildDistanceSpeech(group);

      if (distanceText.isEmpty) {
        parts.add('$spokenLabel $directionText');
      } else {
        parts.add('$spokenLabel $directionText, $distanceText');
      }
    }

    return parts.join('. ');
  }

  /// Builds the distance phrase for one group.
  ///
  /// For grouped objects, only the nearest distance is spoken.
  String _buildDistanceSpeech(CandidateGroup group)
  {
    if (group.closestDistanceFeet == null) {
      return '';
    }

    /// _roundToNearestBucket() is a helper function that rounds a value to the nearest configured speech bucket, such as 0.5 feet.
    final double roundedDistance = _roundToNearestBucket(group.closestDistanceFeet!, _config.distanceBufferFeet);

    /// _formatDistance() is a helper function that adds 'feet' to the spoken distance.
    final String roundedText = _formatDistance(roundedDistance);

    if (group.count > 1) {
      return 'closest $roundedText';
    }

    return roundedText;
  }

  /// Builds a non-speaking preview string that can still be shown in the UI
  /// while groups are stabilizing.
  String _buildPreviewStatus(List<CandidateGroup> groups)
  {
    if (groups.isEmpty) {
      return '';
    }

    final List<CandidateGroup> previewGroups = groups.take(_config.maxNormalGroupsToSpeak).toList();

    return _buildNormalSentence(previewGroups);
  }

  // ---------------------------------------------------------------------------
  // Small utility helpers
  // ---------------------------------------------------------------------------

  /// Rounds a value to the nearest configured speech bucket, such as 0.5 feet.
  double _roundToNearestBucket(double value, double bucketSize)
  {
    return (value / bucketSize).round() * bucketSize;
  }

  /// Formats distance in a speech-friendly way.
  ///
  /// Example:
  /// - 3.0 -> "3 feet"
  /// - 3.5 -> "3.5 feet"
  String _formatDistance(double distanceFeet)
  {
    if (distanceFeet % 1 == 0) {
      return '${distanceFeet.toStringAsFixed(0)} feet';
    }

    return '${distanceFeet.toStringAsFixed(1)} feet';
  }

  /// Normalizes raw model labels so comparisons stay consistent.
  String _normalizeLabel(String rawLabel)
  {
    return rawLabel.trim().toLowerCase();
  }

  /// Builds the spoken version of a label, including pluralization when needed.
  String _spokenLabel(String label, {required int count})
  {
    String spokenLabel = label;

    if (spokenLabel == 'dining table') {
      spokenLabel = 'table';
    }

    if (count <= 1) {
      return spokenLabel;
    }

    if (spokenLabel == 'person') {
      return '$count people';
    }

    if (spokenLabel.endsWith('s')) {
      return '$count $spokenLabel';
    }

    return '$count ${spokenLabel}s';
  }

  /// Simple clamp helper used by the scoring functions.
  double _clampDouble(double value, double minValue, double maxValue)
  {
    if (value < minValue) {
      return minValue;
    }

    if (value > maxValue) {
      return maxValue;
    }

    return value;
  }

  /// Converts the direction enum into the exact word spoken to the user.
  String _directionToSpeech(RelativeDirection direction)
  {
    switch (direction) {
      case RelativeDirection.left:
        return 'left';
      case RelativeDirection.ahead:
        return 'ahead';
      case RelativeDirection.right:
        return 'right';
    }
  }
}
