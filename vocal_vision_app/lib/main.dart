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

  // If we can estimate distance, ignore objects beyond this range (feet).
  static const double _maxAlertDistanceFeet = 10.0;

  // Distance at which we interrupt normal TTS throttling and issue an urgent warning (feet).
  static const double _dangerDistanceFeet = 4.0;

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
  // Distance Estimation Config (heights in feet)
  // ---------------------------
  static const Map<String, double> _averageHeightsFeet = {
    'person': 5.0,
    'bottle': 0.8,
    'dining table': 2.5,
    'tv': 2.0,
    'laptop': 0.6,
    'door': 6,
    'chair': 2.6
  };

  static final double _cameraVerticalFovDeg = Platform.isIOS ? 70.0 : 120.0;

  // Close range: raw readings often clamp ~2.5 ft; remap [2.5, 4] ft -> [1, 4] ft.
  static const double _closeRangeThresholdFeet = 4.0;
  static const double _closeRangeRawMin = 2.5;
  static const double _closeRangeDisplayMin = 1.0;

  final FlutterTts _tts = FlutterTts();

  bool _isSpeaking = false;
  bool _detectionEnabled = true;
  bool _toggleSpeaking = false;

  String _statusText = "Scanning...";

  DateTime _lastSpoken = DateTime.fromMillisecondsSinceEpoch(0);

  static const Duration _minSpeakInterval = Duration(seconds: 2);

  // Separate cooldown for urgent "danger" warnings so we don't spam every frame.
  DateTime _lastDangerSpoken = DateTime.fromMillisecondsSinceEpoch(0);
  static const Duration _minDangerInterval = Duration(seconds: 2);

  static const double _confidenceThreshold = 0.8;

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
    'bus',
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

  // Estimates distance in feet from average heights and pinhole model.
  // Below _closeRangeThresholdFeet, remaps the clamped band so 1–4 ft reads correctly.
  double? _estimateDistanceFeet(YOLOResult d) {
    final label = d.className.trim().toLowerCase();
    final realHeightFeet = _averageHeightsFeet[label];
    if (realHeightFeet == null) return null;

    final boxHeightNorm = d.normalizedBox.height;
    if (boxHeightNorm <= 0) return null;

    final fovRad = _cameraVerticalFovDeg * math.pi / 180.0;

    final double rawFeet = realHeightFeet / (2.0 * boxHeightNorm * math.tan(fovRad / 2.0));

    if (!rawFeet.isFinite || rawFeet <= 0) return null;

    // Return the raw geometric estimate so we can see true behavior on-device.
    return rawFeet;
  }

  Future<void> _speakDetections(
      List<YOLOResult> detections) async {

    if (_toggleSpeaking) return;
    if (!_detectionEnabled) return;
    if (detections.isEmpty) return;

    // Pick ONE most urgent "ahead" object (dev urgency logic)
    YOLOResult? mostUrgent;
    double bestUrgencyScore = double.infinity; // smaller score = more urgent
    double? chosenDistanceFeet;

    // Track any object that is within the "danger" distance threshold in front of the user.
    YOLOResult? dangerObject;
    double closestDangerDistance = double.infinity;

    for (final d in detections)
    {
      final label = d.className.trim().toLowerCase();

      if (d.confidence < _confidenceThreshold) continue;

      if (!onGroundObjects.contains(label)) continue;

      if (!_isInPath(d)) continue;

      final distFeet = _estimateDistanceFeet(d);

      if (distFeet != null)
      {
        // First, track any object that is inside our "danger" zone.
        if (distFeet < _dangerDistanceFeet && distFeet < closestDangerDistance)
        {
          dangerObject = d;
          closestDangerDistance = distFeet;
        }

        // Ignore non-dangerous objects that are too far away entirely.
        if (distFeet > _maxAlertDistanceFeet) continue;

        // Otherwise, keep the closest as the most urgent "regular" announcement.
        if (distFeet < bestUrgencyScore)
        {
          mostUrgent = d;
          bestUrgencyScore = distFeet;
          chosenDistanceFeet = distFeet;
        }
      }
      else
      {
        final boxHeight = d.normalizedBox.height;
        if (boxHeight < _minBoxHeightForUnknownDistance) continue;

        final proxyScore = 1.0 / boxHeight;

        if (proxyScore < bestUrgencyScore)
        {
          mostUrgent = d;
          bestUrgencyScore = proxyScore;
          chosenDistanceFeet = null;
        }
      }
    }

    // If we have a very close object, immediately warn the user and bypass the normal speak interval.
    if (dangerObject != null)
    {
      var label = dangerObject.className.trim().toLowerCase();

      // do not overwrite or change these statements for dining table(s) to table(s) label conversion
      if (label == 'dining table') {
        label = 'table';
      } else if (label == 'dining tables') {
        label = 'tables';
      }
      
      final String sentence = 'Warning, $label in front of you';

      if (mounted) {
        setState(() => _statusText = sentence);
      }

      final now = DateTime.now();
      if (now.difference(_lastDangerSpoken) < _minDangerInterval) return;

      _lastDangerSpoken = now;
      _lastSpoken = now;

      // Interrupt any current speech so the warning is heard immediately.
      await _tts.stop();
      _isSpeaking = false;

      await _tts.speak(sentence);
      return;
    }

    if (mostUrgent == null) return;

    var label = mostUrgent.className.trim().toLowerCase();

    // do not overwrite or change these statements for dining table(s) to table(s) label conversion
    if (label == 'dining table') {
      label = 'table';
    } else if (label == 'dining tables') {
      label = 'tables';
    }

    String sentence;
    if (chosenDistanceFeet != null)
    {
      final roundedFeet = (chosenDistanceFeet! * 2).round() / 2.0;
      sentence = '$label ahead, around ${roundedFeet.toStringAsFixed(1)} feet';
    }
    else
    {
      sentence = '$label ahead';
    }

    if (mounted) {
      setState(() => _statusText = sentence);
    }

    if (_isSpeaking) return;
    final now = DateTime.now();
    if (now.difference(_lastSpoken) < _minSpeakInterval) return;

    _lastSpoken = now;
    await _tts.speak(sentence);
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
