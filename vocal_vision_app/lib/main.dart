import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:ultralytics_yolo/yolo.dart';
import 'package:ultralytics_yolo/yolo_view.dart';

void main() {
  runApp(const YOLODemo());
}

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

class ObjectDetectionScreen extends StatefulWidget {
  const ObjectDetectionScreen({super.key});

  @override
  State<ObjectDetectionScreen> createState() =>
      _ObjectDetectionScreenState();
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

  bool _isSpeaking = false;
  bool _detectionEnabled = true;
  bool _ttsReady = false;

  DateTime _lastSpoken =
      DateTime.fromMillisecondsSinceEpoch(0);

  static const Duration _minSpeakInterval =
      Duration(seconds: 4);

  static const double _personConfidence = 0.55;
  static const double _otherConfidence = 0.75;
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

  Future<void> _initTts() async {
    await _tts.setLanguage('en-US');
    await _tts.setSpeechRate(0.5);
    await _tts.awaitSpeakCompletion(true);

    _tts.setStartHandler(() {
      if (!mounted) return;
      _isSpeaking = true;
    });

    _tts.setCompletionHandler(() {
      if (!mounted) return;
      _isSpeaking = false;
    });

    _tts.setErrorHandler((_) {
      if (!mounted) return;
      _isSpeaking = false;
    });

    _ttsReady = true;
  }

  @override
  void dispose() {
    _tts.stop();
    super.dispose();
  }

  Future<void> _toggleDetection() async {

  // Disable detection immediately
  setState(() {
    _detectionEnabled = !_detectionEnabled;
  });

  // Hard stop any speech
  await _tts.stop();
  _isSpeaking = false;

  // Small stabilization delay
  await Future.delayed(const Duration(milliseconds: 200));

  // Speak toggle message FIRST
  await _tts.speak(
      _detectionEnabled ? "Detection on" : "Detection off");

  // Reset last spoken so detection doesn't instantly fire
  _lastSpoken =
      DateTime.fromMillisecondsSinceEpoch(0);
}


  Future<void> _speakDetections(
      List<YOLOResult> detections) async {

    if (!_detectionEnabled) return;
    if (!_ttsReady) return;
    if (_isSpeaking) return;
    if (detections.isEmpty) return;

    final now = DateTime.now();
    if (now.difference(_lastSpoken) <
        _minSpeakInterval) return;
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

    final Map<String, int> counts = {};

    for (final d in detections) {

      final label =
          d.className.trim().toLowerCase();
      final confidence = d.confidence;

      if (label.isEmpty) continue;

      if (label == 'person') {
        if (confidence < _personConfidence) continue;
      } else {
        if (confidence < _otherConfidence) continue;
      }

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
      backgroundColor: Colors.black,
      body: Stack(
        children: [

          // ALWAYS mounted — camera never rebuilds
          YOLOView(
            modelPath: 'yolo11n',
            task: YOLOTask.detect,
            useGpu: false,
            onResult: _speakDetections,
          ),

          // Overlay when paused (camera still running)
          if (!_detectionEnabled)
            Container(
              color: Colors.black.withOpacity(0.6),
              child: const Center(
                child: Text(
                  'Detection Paused',
                  style: TextStyle(
                    fontSize: 24,
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),

          // Status text
          Positioned(
            top: 60,
            left: 0,
            right: 0,
            child: Center(
              child: Text(
                _detectionEnabled
                    ? 'Detection Active'
                    : 'Detection Off',
                style: const TextStyle(
                  fontSize: 20,
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),

          // Toggle button
          Positioned(
            bottom: 80,
            left: 40,
            right: 40,
            child: SizedBox(
              height: 70,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor:
                      _detectionEnabled
                          ? Colors.orange
                          : Colors.green,
                  shape: RoundedRectangleBorder(
                    borderRadius:
                        BorderRadius.circular(18),
                  ),
                  textStyle: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                onPressed: _toggleDetection,
                child: Text(
                  _detectionEnabled
                      ? 'Pause Detection'
                      : 'Resume Detection',
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
