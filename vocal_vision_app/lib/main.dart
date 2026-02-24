import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:ultralytics_yolo/yolo.dart';
import 'package:ultralytics_yolo/yolo_view.dart';

// Main entry point
void main() => runApp(const YOLODemo());

// Main widget
class YOLODemo extends StatelessWidget
{
  const YOLODemo({super.key});

  @override
  Widget build(BuildContext context)
  {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: ObjectDetectionScreen(),
    );
  }
}

// Object detection screen
class ObjectDetectionScreen extends StatefulWidget
{
  const ObjectDetectionScreen({super.key});

  @override
  State<ObjectDetectionScreen> createState() => _ObjectDetectionScreenState();
}

// Object detection screen state
class _ObjectDetectionScreenState extends State<ObjectDetectionScreen>
{
  // ---------------------------
  // "In-path" filtering
  // Center corridor: only announce objects roughly "ahead" of the user.
  static const double _pathCorridorLeftX = 0.30;
  static const double _pathCorridorRightX = 0.70;

  // Require the bottom of the box to be low enough in the frame.
  // (Simple proxy for "likely near/on the floor plane".)
  static const double _minBoxBottomY = 0.55;

  // If we can estimate distance, ignore objects beyond this range.
  static const double _maxAlertDistanceMeters = 4.0;

  // If we cannot estimate distance (unknown real height), require a minimum box height
  // to consider it close enough to announce.
  static const double _minBoxHeightForUnknownDistance = 0.35;

  // Returns true if a detection is plausibly "in the user's path" based on box geometry.
  bool _isInPath(YOLOResult d)
  {
    final Rect b = d.normalizedBox;

    // Rect uses left/top, not x/y
    final double centerX = b.left + (b.width / 2.0);
    final double bottomY = b.top + b.height; // same as b.bottom

    final bool withinCenterCorridor = (centerX >= _pathCorridorLeftX && centerX <= _pathCorridorRightX);

    final bool bottomIsLowEnough = (bottomY >= _minBoxBottomY);

    return withinCenterCorridor && bottomIsLowEnough;
  }
  // ---------------------------

  // ---------------------------
  // Distance Estimation Config
  // ---------------------------
  static const Map<String, double> _averageHeightsM = {
    'person': 1.7,
    'bottle': 0.25,
    'dining table': 0.75,
    'tv': 0.6,
  };

  static const double _cameraVerticalFovDeg = 60.0;

  final FlutterTts _tts = FlutterTts();

  bool _isSpeaking = false;
  bool _detectionEnabled = true;
  bool _toggleSpeaking = false;

  String _statusText = "Scanning...";

  DateTime _lastSpoken =
      DateTime.fromMillisecondsSinceEpoch(0);

  static const Duration _minSpeakInterval =
      Duration(seconds: 4);

  static const double _confidenceThreshold = 0.55;

  final List<String> onGroundObjects = [
    'person',
    'dining table',
    'chair',
    'dog',
    'cat',
    'bicycle',
    'suitcase',
    'couch',
    'bed',
    'bus'
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
    if (now.difference(_lastSpoken) < _minSpeakInterval) return;

    // Pick ONE most urgent "ahead" object
    YOLOResult? mostUrgent;
    double bestUrgencyScore = double.infinity; // smaller score = more urgent
    double? chosenDistanceMeters;

    for (final d in detections)
    {
      final label = d.className.trim().toLowerCase();

      if (d.confidence < _confidenceThreshold) continue;

      if (!onGroundObjects.contains(label)) continue;

      if (!_isInPath(d)) continue; // check if the object is in the "in-path" corridor

      final distMeters = _estimateDistanceMeters(d);

      if (distMeters != null)
      {
        // Ignore far-away objects when distance is available
        if (distMeters > _maxAlertDistanceMeters) continue;

        // Urgency = closest distance wins
        if (distMeters < bestUrgencyScore)
        {
          mostUrgent = d;
          bestUrgencyScore = distMeters;
          chosenDistanceMeters = distMeters;
        }
      }
      else
      {
        // Fallback when we can't estimate meters:
        // use bbox height as a closeness proxy (bigger box ≈ closer)
        final boxHeight = d.normalizedBox.height;
        if (boxHeight < _minBoxHeightForUnknownDistance) continue;

        // Convert "bigger box ≈ closer" into "smaller is better"
        final proxyScore = 1.0 / boxHeight;

        if (proxyScore < bestUrgencyScore)
        {
          mostUrgent = d;
          bestUrgencyScore = proxyScore;
          chosenDistanceMeters = null;
        }
      }
    }
    
    // If nothing qualifies as "in path", stay quiet.
    if (mostUrgent == null) return;

    final label = mostUrgent.className.trim().toLowerCase();

    // Sponsor requirement:
    // Repeat alerts at a reasonable interval while the hazard remains in path.
    // We rely on _minSpeakInterval for the repeat rate (no "changed enough" gating).

    String sentence;
    if (chosenDistanceMeters != null) // if distance is available
    {
      final rounded = (chosenDistanceMeters! * 2).round() / 2.0; // round to nearest 0.5 meters
      sentence = '$label ahead, around ${rounded.toStringAsFixed(1)} meters'; // announce the distance
    }
    else // if distance is not available
    {
      sentence = '$label ahead'; // announce the object without distance
    }

    setState(() => _statusText = sentence); // update the status text

    _lastSpoken = now;
    await _tts.speak(sentence); // speak the sentence
  }

  @override
  Widget build(BuildContext context) {
    // Enable GPU on iOS, disable on Android (especially emulators)
    final bool useGpu = Platform.isIOS;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [

          YOLOView(
            modelPath: 'yolo11n',
            task: YOLOTask.detect,
            useGpu: useGpu,
            onResult: _speakDetections,
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
