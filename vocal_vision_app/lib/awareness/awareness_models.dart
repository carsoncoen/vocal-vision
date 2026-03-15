import 'package:flutter/material.dart';
import 'package:ultralytics_yolo/yolo.dart';

/// Relative direction spoken to the user.
enum RelativeDirection {
  left,
  ahead,
  right,
}

/// Type of announcement returned by the awareness engine.
enum AnnouncementType {
  none,
  normal,
  danger,
}

/// A detection that passed the broad awareness filter and now has derived features.
class DetectionCandidate {
  final YOLOResult detection;
  final String label;
  final double? distanceFeet;
  final double boxHeight;
  final double centerX;
  final double bottomY;
  final RelativeDirection direction;
  final double score;

  DetectionCandidate({
    required this.detection,
    required this.label,
    required this.distanceFeet,
    required this.boxHeight,
    required this.centerX,
    required this.bottomY,
    required this.direction,
    required this.score,
  });
}

/// Multiple detections of the same class in the same direction are spoken as one group.
class CandidateGroup {
  final String label;
  final RelativeDirection direction;
  final List<DetectionCandidate> members;
  final int count;
  final double? closestDistanceFeet;
  final double bestScore;

  CandidateGroup({
    required this.label,
    required this.direction,
    required this.members,
    required this.count,
    required this.closestDistanceFeet,
    required this.bestScore,
  });

  /// Stable key is used to identify and group similar announcements. For example, "chair left" and "chair left" are the same announcement, which will be spoken as "2 chairs left".
  String get stableKey => '${label}_${direction.name}';
}

/// Full result returned from the engine to the UI/TTS layer.
class AnnouncementDecision {
  final AnnouncementType type;
  final String spokenText;
  final String statusText;
  final bool shouldSpeak;
  final bool shouldInterrupt;
  final String summaryKey;
  final List<CandidateGroup> topGroups;

  const AnnouncementDecision({
    required this.type,
    required this.spokenText,
    required this.statusText,
    required this.shouldSpeak,
    required this.shouldInterrupt,
    required this.summaryKey,
    required this.topGroups,
  });

  const AnnouncementDecision.none()
      : type = AnnouncementType.none,
        spokenText = '',
        statusText = '',
        shouldSpeak = false,
        shouldInterrupt = false,
        summaryKey = '',
        topGroups = const [];
}

/// A snapshot of a spoken group is used to compare what was actually spoken previously, not just raw detections.
class SpokenGroupSnapshot {
  final String stableKey;
  final int count;
  final double? distanceFeet;

  const SpokenGroupSnapshot({
    required this.stableKey,
    required this.count,
    required this.distanceFeet,
  });

  /// Builds one compact token that represents the spoken version of this group.
  String toSummaryToken() {
    final String distance = distanceFeet?.toStringAsFixed(1) ?? 'unknown';

    return '${stableKey}_${count}_$distance';
  }
}

/// Geometry helpers shared by the engine.
class BoxGeometry {
  final Rect box;
  final double centerX;
  final double bottomY;

  const BoxGeometry({
    required this.box,
    required this.centerX,
    required this.bottomY,
  });
}
