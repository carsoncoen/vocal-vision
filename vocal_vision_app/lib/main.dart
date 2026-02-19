import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:ultralytics_yolo/yolo.dart';
import 'package:ultralytics_yolo/yolo_view.dart';

void main() {
  runApp(const YOLODemo());
}

/// App wrapper (MaterialApp setup).
class YOLODemo extends StatelessWidget {
  const YOLODemo({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: ObjectDetectionScreen(),
    );
  }
}

/// Real-time camera detection screen:
/// - YOLOView runs on-device inference on live camera frames
/// - TTS speaks a summary of what was detected
class ObjectDetectionScreen extends StatefulWidget {
  const ObjectDetectionScreen({super.key});

  @override
  State<ObjectDetectionScreen> createState() => _ObjectDetectionScreenState();
}

class _ObjectDetectionScreenState extends State<ObjectDetectionScreen> {
  // Approximate real-world heights (in meters) for distance estimation.
  static const Map<String, double> _averageHeightsM = <String, double>{
    'person': 1.7,
    'bottle': 0.25,
    'dining table': 0.75,
    'tv': 0.6,
    'keyboard': 0.04,
    'laptop': 0.02,
  };

  // Assumed vertical field-of-view of the device camera (in degrees).
  static const double _cameraVerticalFovDeg = 60.0;

  // Text-to-speech engine.
  final FlutterTts _tts = FlutterTts();

  // Track whether TTS is currently speaking (prevents overlap).
  bool _isSpeaking = false;

  // Last description spoken / to display on screen.
  String _statusText = 'Scanning for objects...';

  // Throttle speech so it doesn’t speak on every single frame.
  DateTime _lastSpoken = DateTime.fromMillisecondsSinceEpoch(0);
  static const Duration _minSpeakInterval = Duration(seconds: 4);

  List<String> onGroundObjects = ['person', 'table', 'chair', 'dog', 'cat', 'bicycle', 'suitcase', 'couch', 'bed', 'toilet', 'refrigerator', 'bus'];

  @override
  void initState() {
    super.initState();
    _initTts();
  }

  /// Configure TTS settings + handlers to update speaking state.
  Future<void> _initTts() async {
    await _tts.setLanguage('en-US');
    await _tts.setSpeechRate(0.5);

    _tts.setStartHandler(() {
      if (!mounted) return;
      setState(() => _isSpeaking = true);
    });

    _tts.setCompletionHandler(() {
      if (!mounted) return;
      setState(() => _isSpeaking = false);
    });

    _tts.setErrorHandler((_) {
      if (!mounted) return;
      setState(() => _isSpeaking = false);
    });
  }

  @override
  void dispose() {
    // Ensure speech stops if the widget is removed.
    _tts.stop();
    super.dispose();
  }

  /// Estimate distance to an object using its normalized bounding-box height.
  ///
  /// Uses a simple pinhole-camera model:
  /// distance ≈ H_real / (2 * h_norm * tan(FOV/2))
  /// where h_norm is the fraction of the image height covered by the box.
  double? _estimateDistanceMeters(YOLOResult detection) {
    final String label = detection.className.trim().toLowerCase();
    final double? realHeightM = _averageHeightsM[label];
    if (realHeightM == null) return null;

    final double boxHeightNorm = detection.normalizedBox.height;
    if (boxHeightNorm <= 0) return null;

    final double fovRad = _cameraVerticalFovDeg * math.pi / 180.0;
    final double distance =
        realHeightM / (2.0 * boxHeightNorm * math.tan(fovRad / 2.0));

    if (!distance.isFinite || distance <= 0) return null;
    return distance;
  }

  /// Called continuously with the latest detections from YOLOView.
  /// Builds a short phrase like "2 people 1 bottle" and speaks it.
  Future<void> _speakDetections(List<YOLOResult> detections) async {
    if (_isSpeaking || detections.isEmpty) return;

    final DateTime now = DateTime.now();
    if (now.difference(_lastSpoken) < _minSpeakInterval) return;

    // Count detections by label (e.g., person -> 2, bottle -> 1)
    // and accumulate distance estimates for each label.
    final Map<String, int> counts = <String, int>{};
    final Map<String, List<double>> distancesByLabel =
        <String, List<double>>{};
    for (final YOLOResult d in detections) {
      String label = d.className.trim().toLowerCase();
      if (label.isEmpty) continue;
      if (label == 'dining table') {
        label = 'table';
      }
      counts[label] = (counts[label] ?? 0) + 1;

      final double? distance = _estimateDistanceMeters(d);
      if (distance != null) {
        (distancesByLabel[label] ??= <double>[]).add(distance);
      }
    }

    if (counts.isEmpty) return;

    // Convert counts + distance estimates into speakable fragments.
    final List<String> parts = <String>[];
    counts.forEach((String label, int count) {
      // Handle basic pluralization.
      if (onGroundObjects.contains(label)) {
        final String spokenLabel;
        if (count == 1) {
          spokenLabel = label;
        } else if (label == 'person') {
          spokenLabel = 'people';
        } else {
          spokenLabel = '${label}s';
        }
        

        String phrase = '$count $spokenLabel';

        // Attach a rough distance estimate if we have one.
        final List<double>? dists = distancesByLabel[label];
        if (dists != null && dists.isNotEmpty) {
          final double minDist = dists.reduce(math.min);
          // Round to the nearest 0.5 meters for more natural speech.
          final double rounded =
              (minDist * 2.0).round().toDouble() / 2.0;
          phrase += ' around ${rounded.toStringAsFixed(1)} meters away';
        }

        parts.add(phrase);
      }
    });

    final String sentence = parts.join(', ');

    if (mounted) {
      setState(() {
        _statusText = 'Detected: $sentence';
      });
    }

    _lastSpoken = now;
    await _tts.speak(sentence);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Object Detection')),

      // YOLOView opens the camera, runs the YOLO model on-device,
      // and emits detections through onResult.
      body: Column(
        children: [
          Expanded(
            child: YOLOView(
              modelPath: 'yolo11n',
              task: YOLOTask.detect,
              useGpu: false, // force CPU so the model loads on emulator
              onResult: _speakDetections,
            ),
          ),
          Container(
            width: double.infinity,
            color: Colors.black87,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Text(
              _statusText,
              style: const TextStyle(color: Colors.white, fontSize: 16),
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }
}