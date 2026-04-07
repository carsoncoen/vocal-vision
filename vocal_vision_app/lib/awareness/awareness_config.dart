import 'dart:io';

/// Central place for awareness tuning knobs.
///
/// Keeping these values in one file makes testing easier because teammates can adjust behavior without digging through detection or TTS code.
class AwarenessConfig {
  const AwarenessConfig({
    required this.confidenceThreshold,
    required this.maxAlertDistanceFeet,
    required this.dangerDistanceFeet,
    required this.minBoxHeightForUnknownDistance,
    required this.leftZoneMaxX,
    required this.rightZoneMinX,
    required this.aheadDirectionBonus,
    required this.sideDirectionBonus,
    required this.distanceWeight,
    required this.directionWeight,
    required this.verticalWeight,
    required this.confidenceWeight,
    required this.objectImportanceWeight,
    required this.personPriorityOverrideFeet,
    required this.minStableCycles,
    required this.distanceBufferFeet,
    required this.maxNormalObjectsToSpeak,
    required this.averageHeightsFeet,
    required this.allowedLabels,
    required this.cameraVerticalFovDeg,
  });

  // Broad filtering
  final double confidenceThreshold;
  final double maxAlertDistanceFeet;
  final double dangerDistanceFeet;
  final double minBoxHeightForUnknownDistance;

  // Direction regions
  final double leftZoneMaxX;
  final double rightZoneMinX;

  // Direction bonuses
  final double aheadDirectionBonus;
  final double sideDirectionBonus;

  // Scoring weights
  final double distanceWeight;
  final double directionWeight;
  final double verticalWeight;
  final double confidenceWeight;
  final double objectImportanceWeight;

  // If a person is within this distance of a higher-ranked non-person object, the person can move ahead in ranking.
  final double personPriorityOverrideFeet;

  // Number of consecutive decision cycles before a normal group is speakable.
  final int minStableCycles;

  // Spoken distance changes only count when they cross this buffer size.
  final double distanceBufferFeet;

  // Maximum number of actual detected objects represented in one normal announcement.
  //
  // Important: this is an object budget, not a group budget. For example, if
  // the top ranked detections are 2 chairs on the right and 1 chair on the
  // left, the spoken output may become "2 chairs right, chair left" because
  // that still represents only 3 real objects total.
  final int maxNormalObjectsToSpeak;

  final Map<String, double> averageHeightsFeet;
  final List<String> allowedLabels;
  final double cameraVerticalFovDeg;

  static AwarenessConfig defaults() {
    return AwarenessConfig(
      confidenceThreshold: 0.30,
      maxAlertDistanceFeet: 10.0,
      dangerDistanceFeet: 2.0,
      minBoxHeightForUnknownDistance: 0.35,

      leftZoneMaxX: 0.33,
      rightZoneMinX: 0.67,

      aheadDirectionBonus: 1.0,
      sideDirectionBonus: 0.78,

      distanceWeight: 0.55,
      directionWeight: 0.18,
      verticalWeight: 0.10,
      confidenceWeight: 0.05,
      objectImportanceWeight: 0.12,

      personPriorityOverrideFeet: 1.0,

      minStableCycles: 5,

      distanceBufferFeet: 0.5,

      maxNormalObjectsToSpeak: 3,

      averageHeightsFeet: const {
        'person': 5.0,
        'bottle': 0.8,
        'dining table': 2.5,
        'tv': 2.0,
        'laptop': 0.6,
        'door': 6.0,
        'chair': 2.6,
      },

      allowedLabels: const [
        'person',
        'dining table',
        'chair',
        'dog',
        'cat',
        'bicycle',
        'suitcase',
        'couch',
        'bed',
        'bus',
        'door',
      ],
      
      //cameraVerticalFovDeg: 70.0, // Android
      cameraVerticalFovDeg: 120.0, // IOS
    );
  }
}