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

class _ObjectDetectionScreenState
    extends State<ObjectDetectionScreen> {

  // ---------------------------
  // Distance Estimation Config
  // ---------------------------
  static const Map<String, double> _averageHeightsM = {
  'door': 2.0,
};

  static const double _cameraVerticalFovDeg = 15.8;

  final FlutterTts _tts = FlutterTts();

  bool _isSpeaking = false;
  bool _detectionEnabled = true;
  bool _toggleSpeaking = false;

  String _statusText = "Scanning...";

  DateTime _lastSpoken =
      DateTime.fromMillisecondsSinceEpoch(0);

  static const Duration _minSpeakInterval =
      Duration(seconds: 4);

  static const double _confidenceThreshold = 0.2;

  final List<String> onGroundObjects = [
  'door'
];

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
    _tts.stop();
    super.dispose();
  }

  Future<void> _toggleDetection() async {
    _toggleSpeaking = true;

    await _tts.stop();
    _isSpeaking = false;

    final turningOn = !_detectionEnabled;

    setState(() {
      _detectionEnabled = turningOn;
    });

    await Future.delayed(const Duration(milliseconds: 150));
    await _tts.speak(
        turningOn ? "Detection on" : "Detection off");

    await Future.delayed(const Duration(milliseconds: 400));

    _lastSpoken =
        DateTime.fromMillisecondsSinceEpoch(0);

    _toggleSpeaking = false;
  }

  double? _estimateDistanceMeters(YOLOResult d) {
    final label = d.className.trim().toLowerCase();
    final realHeight = _averageHeightsM[label];
    if (realHeight == null) return null;

    final boxHeightNorm = d.normalizedBox.height;
    if (boxHeightNorm <= 0) return null;

    final fovRad =
        _cameraVerticalFovDeg * math.pi / 180.0;

    final distance =
        realHeight /
            (2.0 *
                boxHeightNorm *
                math.tan(fovRad / 2.0));

    if (!distance.isFinite || distance <= 0) return null;
    return distance;
  }

  Future<void> _speakDetections(
      List<YOLOResult> detections) async {

    if (_toggleSpeaking) return;
    if (!_detectionEnabled) return;
    if (_isSpeaking) return;
    if (detections.isEmpty) return;

    final now = DateTime.now();
    if (now.difference(_lastSpoken) <
        _minSpeakInterval) return;

    final Map<String, int> counts = {};
    final Map<String, List<double>> distances = {};

    for (final d in detections) {
      final label =
          d.className.trim().toLowerCase();

      if (d.confidence < _confidenceThreshold)
        continue;

      if (!onGroundObjects.contains(label))
        continue;

      counts[label] =
          (counts[label] ?? 0) + 1;

      final dist = _estimateDistanceMeters(d);
      if (dist != null) {
        (distances[label] ??= []).add(dist);
      }
    }

    if (counts.isEmpty) return;

    final List<String> parts = [];

    counts.forEach((label, count) {
      String spokenLabel;

      if (count == 1) {
        spokenLabel = label;
      } else if (label == 'person') {
        spokenLabel = 'people';
      } else {
        spokenLabel = '${label}s';
      }

      if (label == 'dining table') {
        if (spokenLabel == 'dining tables') {
          spokenLabel = 'tables';
        } else {
          spokenLabel = 'table';
        }
      }

      String phrase = '$count $spokenLabel';

      final dists = distances[label];
      if (dists != null && dists.isNotEmpty) {
        final minDist = dists.reduce(math.min);
        final rounded =
            (minDist * 2).round() / 2.0;

        phrase +=
            ' around ${rounded.toStringAsFixed(1)} meters away';
      }

      parts.add(phrase);
    });

    final sentence = parts.join(', ');

    setState(() {
      _statusText = sentence;
    });

    _lastSpoken = now;
    await _tts.speak(sentence);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [

          YOLOView(
  modelPath: 'assets/models/door_model.tflite',
  task: YOLOTask.detect,
  useGpu: false,
  onResult: (results) {
    print("RAW DETECTIONS: $results");
    _speakDetections(results);
  },
),

          if (!_detectionEnabled)
            Container(
              color: Colors.black.withOpacity(0.6),
              child: const Center(
                child: Text(
                  'Detection Paused',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),

          Positioned(
            bottom: 150,
            left: 0,
            right: 0,
            child: Container(
              padding: const EdgeInsets.all(12),
              color: Colors.black87,
              child: Text(
                _statusText,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16),
                textAlign: TextAlign.center,
              ),
            ),
          ),

          Positioned(
            bottom: 60,
            left: 40,
            right: 40,
            child: ElevatedButton(
              onPressed: _toggleDetection,
              child: Text(
                _detectionEnabled
                    ? 'Pause Detection'
                    : 'Resume Detection',
              ),
            ),
          ),
        ],
      ),
    );
  }
}
