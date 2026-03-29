import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:vibration/vibration.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:ultralytics_yolo/yolo.dart';
import 'package:ultralytics_yolo/yolo_view.dart';

import 'awareness/announcement_engine.dart';
import 'awareness/awareness_models.dart';

// Main entry point
void main() => runApp(const YOLODemo());

// Main widget
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
  final FlutterTts _tts = FlutterTts();
  final AnnouncementEngine _announcementEngine = AnnouncementEngine();

  bool _isSpeaking = false;
  bool _detectionEnabled = true;
  bool _toggleSpeaking = false;

  String _statusText = 'Scanning...';

  // Holds the exact sentence that is about to be spoken.
  String _pendingSpokenText = '';

  DateTime _lastSpoken = DateTime.fromMillisecondsSinceEpoch(0);
  static const Duration _minSpeakInterval = Duration(seconds: 3);

  // "Path Clear" announcement when no objects persist.
  static const Duration _pathClearThreshold = Duration(milliseconds: 500);
  DateTime _lastTimeHadAnyGroups = DateTime.fromMillisecondsSinceEpoch(0);
  bool _pathClearAnnouncedSinceLastObjects = false;

  // Normal reminders are repeated at a controlled interval while the same
  // stable summary remains active.
  static const Duration _normalRepeatInterval = Duration(seconds: 3);
  String _lastSpokenNormalSummaryKey = '';

  // Separate cooldown for urgent warnings so they can bypass normal summary timing
  // without speaking every single frame.
  DateTime _lastDangerSpoken = DateTime.fromMillisecondsSinceEpoch(0);
  static const Duration _minDangerInterval = Duration(seconds: 2);
  //static const int _dangerVibrationDurationMs = 250;

  // Tilt vibration system
  static const double _minTiltForHapticsDeg = 30.0;
  static const double _maxTiltForHapticsDeg = 90.0;
  static const Duration _minTiltVibrationInterval = Duration(milliseconds: 900);
  static const int _tiltVibrationBaseDurationMs = 200;
  static const int _tiltVibrationExtraDurationMs = 220;

  // Tilt tracking (0 = upright, 1 = flat/fully tilted).
  StreamSubscription<AccelerometerEvent>? _accelerometerSub;
  DateTime _lastTiltVibration = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _tiltVibrationSuppressedUntil = DateTime.fromMillisecondsSinceEpoch(0);

  bool _hasVibrator = false;

  // -------------------- Debug: callback FPS --------------------
  // Counts how many YOLO result callbacks happen in the current time window.
  // We use this to estimate how often Dart receives fresh detection results.
  int _debugCallbackCount = 0;

  // Marks the beginning of the current FPS measurement window.
  // About once per second, we print the average callback rate and reset.
  DateTime _debugCallbackWindowStart = DateTime.now();

  @override
  void initState() {
    super.initState();
    _initTts();
    _initTiltTracking();
    _initHaptics();
  }

  void _initHaptics() {
    Vibration.hasVibrator().then((bool value) {
      if (!mounted) return;
      setState(() => _hasVibrator = value);
    });
  }

  Future<void> _initTts() async {
    await _tts.setLanguage('en-US');

    // The sponsor is comfortable with faster speech, so this is intentionally
    // quicker than the original value. It keeps mandatory distance callouts from
    // sounding too delayed.
    await _tts.setSpeechRate(0.5);

    // We still wait for completion so _isSpeaking reflects real TTS state.
    await _tts.awaitSpeakCompletion(true);

    _tts.setStartHandler(() {
      if (!mounted) {
        return;
      }

      setState(() {
        _isSpeaking = true;

        // Synchronize the written text with the exact moment speech starts.
        // This keeps the bottom text aligned with actual audio output,
        // even if the speech rate changes later.
        if (_pendingSpokenText.isNotEmpty) {
          _statusText = _pendingSpokenText;
        }
      });
    });

    _tts.setCompletionHandler(() {
      if (!mounted) {
        return;
      }

      setState(() {
        _isSpeaking = false;

        // Clear the pending text once this utterance is finished.
        _pendingSpokenText = '';
      });
    });

    _tts.setErrorHandler((_) {
      if (!mounted) {
        return;
      }

      setState(() {
        _isSpeaking = false;

        // Also clear pending text if TTS fails.
        _pendingSpokenText = '';
      });
    });

  }

  @override
  void dispose() {
    _accelerometerSub?.cancel();
    _tts.stop();
    super.dispose();
  }

  void _initTiltTracking() {
    _accelerometerSub = accelerometerEventStream().listen(
      (AccelerometerEvent event) {
        final double ax = event.x;
        final double ay = event.y;
        final double az = event.z;

        // Compute a true "upright -> flat" angle using gravity magnitude:
        // - 0 deg when gravity aligns with device Y axis (phone upright)
        // - 90 deg when gravity is perpendicular to Y axis (phone flat)
        final double gravityMagnitude = math.sqrt((ax * ax) + (ay * ay) + (az * az));
        if (gravityMagnitude <= 0) {
          return;
        }

        final double cosTheta = (ay.abs() / gravityMagnitude).clamp(0.0, 1.0);
        final double tiltRadians = math.acos(cosTheta); // 0..pi/2
        final double tiltDegrees = tiltRadians * 180.0 / math.pi;
        final double tilt = (tiltRadians / (math.pi / 2.0)).clamp(0.0, 1.0);
        print('Tilt: ${tilt.toStringAsFixed(3)} (${tiltDegrees.toStringAsFixed(1)} deg)');

        _tryVibrateForTilt(tiltDegrees);
      },
      onError: (_) {
        // If the sensor is unavailable, just don't vibrate for tilt.
      },
      cancelOnError: false,
    );
  }

  void _tryVibrateForTilt(double tiltDegrees) {
    // If TTS is effectively disabled (we're "Detection off"), don't vibrate.
    if (!_detectionEnabled) {
      return;
    }
    if (_toggleSpeaking) {
      return;
    }

    if (tiltDegrees < _minTiltForHapticsDeg) {
      return;
    }

    final DateTime now = DateTime.now();
    if (now.isBefore(_tiltVibrationSuppressedUntil)) {
      return;
    }

    if (now.difference(_lastTiltVibration) < _minTiltVibrationInterval) {
      return;
    }

    _lastTiltVibration = now;

    // Convert degrees above threshold into a 0..1 progression.
    final double rawProgress = ((tiltDegrees - _minTiltForHapticsDeg) / (_maxTiltForHapticsDeg - _minTiltForHapticsDeg)).clamp(0.0, 1.0);
    
    // Ease-out makes early increases (e.g., +15 deg) feel meaningfully stronger.
    final double hapticProgress = 1.0 - math.pow(1.0 - rawProgress, 3).toDouble();

    // Duration: 200ms at threshold, then ramps aggressively with tilt.
    final int duration = (_tiltVibrationBaseDurationMs + hapticProgress * _tiltVibrationExtraDurationMs).round();
    final int amplitude = (90 + hapticProgress * (255 - 90)).round().clamp(1, 255);
    final double sharpness = (0.35 + hapticProgress * 0.65).clamp(0.0, 1.0);

    if (!_hasVibrator) {
      return;
    }

    print(
      'Vibrating for tilt: ${tiltDegrees.toStringAsFixed(1)} deg -> '
      '$duration ms, $amplitude, $sharpness',
    );
    unawaited(
      Vibration.vibrate(
        duration: duration,
        amplitude: amplitude,
        sharpness: sharpness,
      ),
    );
  }

  Future<void> _toggleDetection() async {
    _toggleSpeaking = true;

    await _tts.stop();
    _isSpeaking = false;

    final bool turningOn = !_detectionEnabled;

    setState(() {
      _detectionEnabled = turningOn;
    });

    // Prevent any pending tilt haptics from firing right after toggling.
    _tiltVibrationSuppressedUntil = DateTime.now().add(const Duration(milliseconds: 500));

    await Future.delayed(const Duration(milliseconds: 150));
    await _speakSynchronized(turningOn ? 'Detection on' : 'Detection off');

    await Future.delayed(const Duration(milliseconds: 400));

    _lastSpoken = DateTime.fromMillisecondsSinceEpoch(0);
    _lastDangerSpoken = DateTime.fromMillisecondsSinceEpoch(0);
    _lastSpokenNormalSummaryKey = '';
    _lastTimeHadAnyGroups = DateTime.fromMillisecondsSinceEpoch(0);
    _pathClearAnnouncedSinceLastObjects = false;
    _lastTiltVibration = DateTime.fromMillisecondsSinceEpoch(0);
    _tiltVibrationSuppressedUntil = DateTime.fromMillisecondsSinceEpoch(0);

    _toggleSpeaking = false;
  }

  /// Speaks one sentence and keeps the on-screen text synchronized with
  /// the exact moment speech actually begins.
  ///
  /// Why this helper exists:
  /// - We store the next utterance in _pendingSpokenText
  /// - The TTS start handler copies that text into _statusText
  /// - So the visible text changes when audio starts, not earlier
  Future<void> _speakSynchronized(String text) async {
    if (text.isEmpty) {
      return;
    }

    // Store the exact text that is about to be spoken.
    // The TTS start callback will move this into _statusText.
    _pendingSpokenText = text;

    await _tts.speak(text);
  }

  /// Prints approximate YOLO callback FPS once per second.
  ///
  /// Important:
  /// This is callback FPS, not screen-render FPS.
  /// It tells us how often the YOLO plugin is calling _handleDetections()
  /// with fresh results. That is the number we care about for awareness timing.
  void _debugLogCallbackFps() {
    _debugCallbackCount++;

    final DateTime now = DateTime.now();
    final int elapsedMs = now.difference(_debugCallbackWindowStart).inMilliseconds;

    // Print about once every second so the console stays readable.
    if (elapsedMs >= 1000) {
      final double callbackFps = _debugCallbackCount * 1000 / elapsedMs;

      print('[DEBUG] YOLO callback FPS: ${callbackFps.toStringAsFixed(1)}');

      // Reset for the next measurement window.
      _debugCallbackCount = 0;
      _debugCallbackWindowStart = now;
    }
  }

  /// Handles the full detection-to-announcement flow.
  ///
  /// The awareness engine decides what the current stable summary is. This
  /// widget decides when that summary should actually be spoken.
  ///
  /// Normal reminders work like this:
  /// - speak immediately when the stable summary changes
  /// - keep repeating the same summary at a controlled interval
  /// - stop repeating when the path clears
  Future<void> _handleDetections(List<YOLOResult> detections) async {
    _debugLogCallbackFps();
    
    if (_toggleSpeaking) {
      return;
    }

    if (!_detectionEnabled) {
      return;
    }

    final AnnouncementDecision decision = _announcementEngine.processDetections(detections);
    final DateTime now = DateTime.now();

    final bool hasAnyGroups = decision.type != AnnouncementType.none || decision.topGroups.isNotEmpty;
    if (hasAnyGroups) {
      _lastTimeHadAnyGroups = now;
      _pathClearAnnouncedSinceLastObjects = false;
    }

    if (decision.statusText.isNotEmpty && mounted && _statusText != decision.statusText) {
      setState(() => _statusText = decision.statusText);
    }

    // If nothing stable is active anymore, clear the remembered normal summary
    // so it can be spoken again if it later reappears.
    if (decision.type == AnnouncementType.none && decision.topGroups.isEmpty) {
      _lastSpokenNormalSummaryKey = '';

      final bool thresholdPassed = now.difference(_lastTimeHadAnyGroups) >= _pathClearThreshold;
      if (thresholdPassed && !_pathClearAnnouncedSinceLastObjects && !_isSpeaking) {
        _pathClearAnnouncedSinceLastObjects = true;
        _lastSpoken = now;
        if (mounted && _statusText != 'Path Clear') {
          setState(() => _statusText = 'Path Clear');
        }
        await _tts.speak('Path Clear');
      }

      return;
    }

    if (!decision.shouldSpeak) {
      return;
    }

    if (decision.type == AnnouncementType.danger) {
      if (now.difference(_lastDangerSpoken) < _minDangerInterval) {
        return;
      }

      _lastDangerSpoken = now;
      _lastSpoken = now;

      // Danger alerts are allowed to interrupt current speech.
      await _tts.stop();
      _isSpeaking = false;

      // print('Vibrating for danger: ${_dangerVibrationDurationMs} ms');
      // if (_hasVibrator) {
      //   await Vibration.vibrate(duration: _dangerVibrationDurationMs);
      // }

      // Pause tilt haptics briefly so the two vibration systems don't overlap.
      _tiltVibrationSuppressedUntil = now.add(const Duration(milliseconds: 700));


      // Keep the visible text synchronized with the actual start of speech.
      await _speakSynchronized(decision.spokenText);
      return;
    }

    if (decision.type != AnnouncementType.normal || decision.summaryKey.isEmpty) {
      return;
    }

    final bool summaryChanged = decision.summaryKey != _lastSpokenNormalSummaryKey;
    final bool repeatIntervalElapsed = now.difference(_lastSpoken) >= _normalRepeatInterval;

    // Speak if this is a new stable summary, or if the same stable summary has
    // stayed active long enough to deserve another reminder.
    final bool shouldSpeakNormal = summaryChanged || repeatIntervalElapsed;
    if (!shouldSpeakNormal) {
      return;
    }

    if (_isSpeaking) {
      return;
    }

    if (summaryChanged && now.difference(_lastSpoken) < _minSpeakInterval) {
      return;
    }

    _lastSpoken = now;
    _lastSpokenNormalSummaryKey = decision.summaryKey;

    // Keep the visible text synchronized with the actual start of speech.
    await _speakSynchronized(decision.spokenText);
  }

  @override
  Widget build(BuildContext context) {
  // Enable GPU on iOS, disable on Android (especially emulators)
  final bool useGpu = Platform.isIOS;

  return Scaffold(
    backgroundColor: Colors.black,
    body: GestureDetector( 
      behavior: HitTestBehavior.opaque,
      onDoubleTap: _toggleDetection, 
      child: Stack(
        children: [
          YOLOView(
            modelPath: 'yolo11n',
            task: YOLOTask.detect,
            useGpu: useGpu,
            onResult: _handleDetections,
          ),
          if (!_detectionEnabled)
            Container(
              color: Colors.black.withOpacity(0.6),
              child: const Center(
                child: Text(
                  'Detection Paused\nDouble tap to resume', 
                  textAlign: TextAlign.center,
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
                  fontSize: 16,
                ),
                textAlign: TextAlign.center,
              ),
            ),
          ),


        ],
      ),
    ),
  );
}}