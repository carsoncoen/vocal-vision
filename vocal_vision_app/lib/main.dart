import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:ultralytics_yolo/yolo.dart';
import 'package:ultralytics_yolo/yolo_view.dart';
import 'package:vibration/vibration.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'awareness/announcement_engine.dart';
import 'awareness/awareness_models.dart';

// Main entry point.
void main() => runApp(const YOLODemo());

/// High-level user modes for the screen.
///
/// Why this exists:
/// - Tutorial is not the same thing as paused detection.
/// - Detecting and paused need slightly different gestures and messaging.
/// - Keeping one explicit mode avoids scattering hidden state checks around
///   the widget tree.
enum AppMode {
  tutorial,
  detecting,
  paused,
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
  State<ObjectDetectionScreen> createState() => _ObjectDetectionScreenState();
}

class _ObjectDetectionScreenState extends State<ObjectDetectionScreen> {
  final FlutterTts _tts = FlutterTts();
  final AnnouncementEngine _announcementEngine = AnnouncementEngine();

  bool _isSpeaking = false;
  bool _detectionEnabled = false;
  bool _toggleSpeaking = false;
  bool _speechInFlight = false;

  // App starts in tutorial mode every time it opens.
  AppMode _appMode = AppMode.tutorial;

  String _statusText = 'Tutorial ready';

  // Holds the exact sentence that is about to be spoken so the visible text can
  // switch at the same moment audio starts.
  String _pendingSpokenText = '';

  DateTime _lastSpoken = DateTime.fromMillisecondsSinceEpoch(0);
  static const Duration _minSpeakInterval = Duration(seconds: 1);

  // User-adjustable speech rate controls.
  double _speechRate = 0.5;
  String _speechRateOverlayText = '';
  Timer? _speechRateOverlayTimer;
  double _speechRateSwipeStartY = 0.0;
  double _speechRateSwipeLatestY = 0.0;

  static const double _minSpeechRate = 0.2;
  static const double _maxSpeechRate = 1.2;
  static const double _speechRateStep = 0.2;
  static const double _speechRateSwipeDistanceThreshold = 60.0;
  static const double _speechRateSwipeVelocityThreshold = 350.0;
  static const Duration _speechRateOverlayDuration = Duration(
    milliseconds: 1200,
  );

  // "Path Clear" announcement when no objects persist.
  static const Duration _pathClearThreshold = Duration(milliseconds: 500);
  DateTime _lastTimeHadAnyGroups = DateTime.fromMillisecondsSinceEpoch(0);
  bool _pathClearAnnouncedSinceLastObjects = false;

  // Normal reminders are repeated at a controlled interval while the same
  // stable summary remains active.
  static const Duration _normalRepeatInterval = Duration(seconds: 3);
  String _lastSpokenNormalSummaryKey = '';

  // Separate cooldown for urgent warnings so they can bypass normal summary
  // timing without speaking every single frame.
  DateTime _lastDangerSpoken = DateTime.fromMillisecondsSinceEpoch(0);
  static const Duration _minDangerInterval = Duration(seconds: 2);

  // Tilt vibration system.
  static const double _minTiltForHapticsDeg = 30.0;
  static const double _maxTiltForHapticsDeg = 90.0;
  static const Duration _minTiltVibrationInterval = Duration(milliseconds: 900);
  static const int _tiltVibrationBaseDurationMs = 200;
  static const int _tiltVibrationExtraDurationMs = 220;

  StreamSubscription<AccelerometerEvent>? _accelerometerSub;
  DateTime _lastTiltVibration = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _tiltVibrationSuppressedUntil =
      DateTime.fromMillisecondsSinceEpoch(0);

  bool _hasVibrator = false;

  // Debug: callback FPS from the YOLO plugin.
  int _debugCallbackCount = 0;
  DateTime _debugCallbackWindowStart = DateTime.now();

  // Spoken onboarding. It starts with value first, then usage, then a short
  // note about constraints and safe expectations.
  static const String _tutorialText =
      'Welcome to Vocal Vision. '
      'This app helps you stay aware of your surroundings by speaking important indoor objects ahead of you, including their relative distance and direction, as you move. '
      'It is designed to complement your cane or guide dog, not replace them. '
      'Hold your phone upright with the camera facing forward. '
      'The app will announce important objects ahead and warn you when something is very close. '
      'If the phone vibrates, that means the phone is tilted and distance estimation may be less accurate. '
      'Stronger or longer vibration means the tilt is worse. '
      'Press and hold anywhere on the screen to skip this tutorial and begin detection. '
      'After detection starts, double tap anywhere on the screen to pause or resume detection. '
      'When detection is paused, press and hold anywhere to hear this tutorial again. '
      'Note: This app is still under development. '
      'The app detects a specific set of important on-ground indoor objects, not everything around you. '
      'Distance estimates may not always be exact, and the app may be less accurate in very busy or chaotic environments. '
      'Please continue using your cane, guide dog, or usual mobility tools while using this app.';

  @override
  void initState() {
    super.initState();
    WakelockPlus.enable();
    _initApp();
  }

  @override
  void dispose() {
    _speechRateOverlayTimer?.cancel();
    _accelerometerSub?.cancel();
    _tts.stop();
    WakelockPlus.disable();
    super.dispose();
  }

  void _initHaptics() {
    Vibration.hasVibrator().then((bool value) {
      if (!mounted) return;
      setState(() => _hasVibrator = value);
    });
  }

  Future<void> _initTts() async {
    await _tts.setLanguage('en-US');

    // Start from a moderate default rate that can later be adjusted with a
    // vertical swipe gesture.
    await _tts.setSpeechRate(_speechRate);

    // Wait for speech completion so _isSpeaking reflects real TTS state.
    await _tts.awaitSpeakCompletion(true);

    _tts.setStartHandler(() {
      if (!mounted) {
        return;
      }

      setState(() {
        _isSpeaking = true;

        // Keep the visible status text aligned with the exact utterance that
        // actually started.
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
        _speechInFlight = false;
        _pendingSpokenText = '';
      });
    });

    _tts.setErrorHandler((_) {
      if (!mounted) {
        return;
      }

      setState(() {
        _isSpeaking = false;
        _speechInFlight = false;
        _pendingSpokenText = '';
      });
    });
  }

  Future<void> _initApp() async {
    final PermissionStatus status = await Permission.camera.request();

    if (status.isGranted) {
      await _initTts();
      _initTiltTracking();
      _initHaptics();

      if (mounted) {
        setState(() {
          _appMode = AppMode.tutorial;
          _detectionEnabled = false;
          _statusText = 'Tutorial ready';
        });
      }

      // Auto-play the tutorial every time the app opens.
      await Future.delayed(const Duration(milliseconds: 300));
      await _speakTutorial();
    } else if (status.isPermanentlyDenied) {
      if (mounted) {
        setState(() {
          _statusText = 'Camera denied. Please enable in Settings.';
        });
      }
      await openAppSettings();
    } else {
      if (mounted) {
        setState(() {
          _statusText = 'Camera access is required for detection.';
        });
      }
    }
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
        final double gravityMagnitude =
            math.sqrt((ax * ax) + (ay * ay) + (az * az));
        if (gravityMagnitude <= 0) {
          return;
        }

        final double cosTheta = (ay.abs() / gravityMagnitude).clamp(0.0, 1.0);
        final double tiltRadians = math.acos(cosTheta);
        final double tiltDegrees = tiltRadians * 180.0 / math.pi;
        final double tilt = (tiltRadians / (math.pi / 2.0)).clamp(0.0, 1.0);
        print(
          'Tilt: ${tilt.toStringAsFixed(3)} '
          '(${tiltDegrees.toStringAsFixed(1)} deg)',
        );

        _tryVibrateForTilt(tiltDegrees);
      },
      onError: (_) {
        // If the sensor is unavailable, just do not vibrate for tilt.
      },
      cancelOnError: false,
    );
  }

  Future<void> _setSpeechRate(double nextRate) async {
    final double clampedRate = nextRate.clamp(_minSpeechRate, _maxSpeechRate);
    if (clampedRate == _speechRate) {
      return;
    }

    setState(() {
      _speechRate = clampedRate;
      _speechRateOverlayText = 'Speech speed ${_speechRate.toStringAsFixed(1)}x';
    });

    _speechRateOverlayTimer?.cancel();
    _speechRateOverlayTimer = Timer(_speechRateOverlayDuration, () {
      if (!mounted) {
        return;
      }

      setState(() {
        _speechRateOverlayText = '';
      });
    });

    await _tts.setSpeechRate(_speechRate);
  }

  Future<void> _adjustSpeechRateByStep(int steps) async {
    if (steps == 0) {
      return;
    }

    await _setSpeechRate(_speechRate + (steps * _speechRateStep));
  }

  void _handleSpeechRateDragStart(DragStartDetails details) {
    _speechRateSwipeStartY = details.globalPosition.dy;
    _speechRateSwipeLatestY = details.globalPosition.dy;
  }

  void _handleSpeechRateDragUpdate(DragUpdateDetails details) {
    if (_toggleSpeaking || !_detectionEnabled) {
      _speechRateSwipeStartY = details.globalPosition.dy;
      _speechRateSwipeLatestY = details.globalPosition.dy;
      return;
    }

    _speechRateSwipeLatestY = details.globalPosition.dy;
  }

  void _handleSpeechRateDragEnd(DragEndDetails details) {
    if (_toggleSpeaking || !_detectionEnabled) {
      _speechRateSwipeStartY = 0.0;
      _speechRateSwipeLatestY = 0.0;
      return;
    }

    final double swipeDistance = _speechRateSwipeStartY - _speechRateSwipeLatestY;
    final double swipeVelocity = -details.velocity.pixelsPerSecond.dy;

    final bool passedDistance =
        swipeDistance.abs() >= _speechRateSwipeDistanceThreshold;
    final bool passedVelocity =
        swipeVelocity.abs() >= _speechRateSwipeVelocityThreshold;

    if (!passedDistance && !passedVelocity) {
      _speechRateSwipeStartY = 0.0;
      _speechRateSwipeLatestY = 0.0;
      return;
    }

    final int stepDirection = passedVelocity
        ? (swipeVelocity.isNegative ? -1 : 1)
        : (swipeDistance.isNegative ? -1 : 1);

    unawaited(_adjustSpeechRateByStep(stepDirection));

    _speechRateSwipeStartY = 0.0;
    _speechRateSwipeLatestY = 0.0;
  }

  void _tryVibrateForTilt(double tiltDegrees) {
    // No tilt haptics during tutorial or paused mode. This prevents the app
    // from buzzing while the user is still learning or while detection is off.
    if (_appMode != AppMode.detecting) {
      return;
    }

    if (!_detectionEnabled || _toggleSpeaking) {
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

    final double rawProgress = ((tiltDegrees - _minTiltForHapticsDeg) /
            (_maxTiltForHapticsDeg - _minTiltForHapticsDeg))
        .clamp(0.0, 1.0);

    // Ease-out makes early increases feel meaningfully stronger.
    final double hapticProgress =
        1.0 - math.pow(1.0 - rawProgress, 3).toDouble();

    final int duration =
        (_tiltVibrationBaseDurationMs + hapticProgress * _tiltVibrationExtraDurationMs)
            .round();
    final int amplitude =
        (90 + hapticProgress * (255 - 90)).round().clamp(1, 255);
    final double sharpness =
        (0.35 + hapticProgress * 0.65).clamp(0.0, 1.0);

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

  // Resets detection timing memory so switching modes does not carry over old
  // state such as summary keys or stale cooldowns.
  void _resetDetectionCycleState() {
    _lastSpoken = DateTime.fromMillisecondsSinceEpoch(0);
    _lastDangerSpoken = DateTime.fromMillisecondsSinceEpoch(0);
    _lastSpokenNormalSummaryKey = '';
    _lastTimeHadAnyGroups = DateTime.fromMillisecondsSinceEpoch(0);
    _pathClearAnnouncedSinceLastObjects = false;
    _lastTiltVibration = DateTime.fromMillisecondsSinceEpoch(0);
    _tiltVibrationSuppressedUntil = DateTime.fromMillisecondsSinceEpoch(0);
  }

  // Speaks one sentence and keeps the on-screen text synchronized with the
  // exact moment speech actually begins.
  Future<void> _speakSynchronized(String text) async {
    if (text.isEmpty) {
      return;
    }

    // This lock covers the small gap between calling _tts.speak() and the TTS
    // start callback. Without it, another callback can sneak in and overlap.
    if (_speechInFlight) {
      return;
    }

    _speechInFlight = true;
    _pendingSpokenText = text;

    await _tts.speak(text);
  }

  // Replays the full onboarding tutorial.
  Future<void> _speakTutorial() async {
    if (_toggleSpeaking) {
      return;
    }

    await _tts.stop();

    if (!mounted) {
      return;
    }

    setState(() {
      _isSpeaking = false;
      _speechInFlight = false;
      _pendingSpokenText = '';
      _statusText = 'Tutorial ready';
    });

    await _speakSynchronized(_tutorialText);
  }

  // Starts live detection after the user completes the tutorial.
  Future<void> _startDetectionFromTutorial() async {
    _toggleSpeaking = true;

    await _tts.stop();

    if (!mounted) {
      _toggleSpeaking = false;
      return;
    }

    setState(() {
      _isSpeaking = false;
      _speechInFlight = false;
      _pendingSpokenText = '';
      _appMode = AppMode.detecting;
      _detectionEnabled = true;
      _statusText = 'Scanning...';
    });

    _tiltVibrationSuppressedUntil =
        DateTime.now().add(const Duration(milliseconds: 500));
    _resetDetectionCycleState();

    await Future.delayed(const Duration(milliseconds: 150));
    await _speakSynchronized('Detection on');

    await Future.delayed(const Duration(milliseconds: 250));
    _toggleSpeaking = false;
  }

  // Pauses or resumes detection after the user is already in the live flow.
  Future<void> _toggleDetection() async {
    // Tutorial should be exited through the dedicated long-press gesture,
    // not by the normal double-tap pause/resume control.
    if (_appMode == AppMode.tutorial) {
      return;
    }

    _toggleSpeaking = true;

    await _tts.stop();

    if (!mounted) {
      _toggleSpeaking = false;
      return;
    }

    setState(() {
      _isSpeaking = false;
      _speechInFlight = false;
      _pendingSpokenText = '';
    });

    final bool turningOn = !_detectionEnabled;

    setState(() {
      _detectionEnabled = turningOn;
      _appMode = turningOn ? AppMode.detecting : AppMode.paused;
      _statusText = turningOn ? 'Scanning...' : 'Detection paused';
    });

    // Prevent any pending tilt haptics from firing right after toggling.
    _tiltVibrationSuppressedUntil =
        DateTime.now().add(const Duration(milliseconds: 500));

    await Future.delayed(const Duration(milliseconds: 150));
    await _speakSynchronized(turningOn ? 'Detection on' : 'Detection off');

    await Future.delayed(const Duration(milliseconds: 400));
    _resetDetectionCycleState();
    _toggleSpeaking = false;
  }

  // Long press is reserved for tutorial control so it does not interfere with
  // the normal pause/resume gesture.
  Future<void> _handleLongPressAction() async {
    if (_toggleSpeaking) {
      return;
    }

    if (_appMode == AppMode.tutorial) {
      await _startDetectionFromTutorial();
      return;
    }

    if (_appMode == AppMode.paused) {
      await _speakTutorial();
    }
  }

  // Prints approximate YOLO callback FPS once per second.
  void _debugLogCallbackFps() {
    _debugCallbackCount++;

    final DateTime now = DateTime.now();
    final int elapsedMs =
        now.difference(_debugCallbackWindowStart).inMilliseconds;

    if (elapsedMs >= 1000) {
      final double callbackFps = _debugCallbackCount * 1000 / elapsedMs;
      print('[DEBUG] YOLO callback FPS: ${callbackFps.toStringAsFixed(1)}');

      _debugCallbackCount = 0;
      _debugCallbackWindowStart = now;
    }
  }

  // Handles the full detection-to-announcement flow.
  Future<void> _handleDetections(List<YOLOResult> detections) async {
    _debugLogCallbackFps();

    if (_toggleSpeaking) {
      return;
    }

    // Tutorial is a protected onboarding state. Live detection should not speak
    // until the user explicitly starts the experience.
    if (_appMode == AppMode.tutorial) {
      return;
    }

    if (!_detectionEnabled) {
      return;
    }

    final AnnouncementDecision decision =
        _announcementEngine.processDetections(detections);
    final DateTime now = DateTime.now();

    final bool hasAnyGroups =
        decision.type != AnnouncementType.none || decision.topGroups.isNotEmpty;
    if (hasAnyGroups) {
      _lastTimeHadAnyGroups = now;
      _pathClearAnnouncedSinceLastObjects = false;
    }

    if (decision.type == AnnouncementType.none && decision.topGroups.isEmpty) {
      _lastSpokenNormalSummaryKey = '';

      final bool thresholdPassed =
          now.difference(_lastTimeHadAnyGroups) >= _pathClearThreshold;
      if (thresholdPassed &&
          !_pathClearAnnouncedSinceLastObjects &&
          !_isSpeaking &&
          !_speechInFlight) {
        _pathClearAnnouncedSinceLastObjects = true;
        _lastSpoken = now;
        await _speakSynchronized('Path Clear');
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

      if (!mounted) {
        return;
      }

      setState(() {
        _isSpeaking = false;
        _speechInFlight = false;
        _pendingSpokenText = '';
      });

      // Pause tilt haptics briefly so the two vibration systems do not overlap.
      _tiltVibrationSuppressedUntil =
          now.add(const Duration(milliseconds: 700));

      await _speakSynchronized(decision.spokenText);
      return;
    }

    if (decision.type != AnnouncementType.normal ||
        decision.summaryKey.isEmpty) {
      return;
    }

    final bool summaryChanged =
        decision.summaryKey != _lastSpokenNormalSummaryKey;
    final bool repeatIntervalElapsed =
        now.difference(_lastSpoken) >= _normalRepeatInterval;

    final bool shouldSpeakNormal = summaryChanged || repeatIntervalElapsed;
    if (!shouldSpeakNormal) {
      return;
    }

    if (_isSpeaking || _speechInFlight) {
      return;
    }

    if (summaryChanged && now.difference(_lastSpoken) < _minSpeakInterval) {
      return;
    }

    _lastSpoken = now;
    _lastSpokenNormalSummaryKey = decision.summaryKey;
    await _speakSynchronized(decision.spokenText);
  }

  Widget _buildTutorialOverlay() {
    return Container(
      color: Colors.black.withOpacity(0.88),
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
      child: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: const [
                Text(
                  'Vocal Vision Tutorial',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                SizedBox(height: 16),
                Text(
                  'Press and hold anywhere on the screen to skip the tutorial and begin detection. '
                  'This tutorial will play each time the app opens.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPausedOverlay() {
    return Container(
      color: Colors.black.withOpacity(0.72),
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
      child: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: const [
                Text(
                  'Detection Paused',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 26,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                SizedBox(height: 12),
                Text(
                  'Double tap anywhere to resume detection. '
                  'Press and hold anywhere to hear the tutorial again.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildStatusBanner() {
    return Positioned(
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
    );
  }

  Widget _buildSpeechRateOverlay() {
    return Positioned(
      top: 110,
      left: 0,
      right: 0,
      child: IgnorePointer(
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.black87,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              _speechRateOverlayText,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Enable GPU on iOS, disable on Android (especially emulators).
    final bool useGpu = Platform.isIOS;

    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onDoubleTap: _toggleDetection,
        onLongPress: _handleLongPressAction,
        onVerticalDragStart: _handleSpeechRateDragStart,
        onVerticalDragUpdate: _handleSpeechRateDragUpdate,
        onVerticalDragEnd: _handleSpeechRateDragEnd,
        child: Stack(
          children: [
            YOLOView(
              modelPath: 'yolo11n',
              task: YOLOTask.detect,
              useGpu: useGpu,
              onResult: _handleDetections,
            ),

            if (_appMode == AppMode.paused) _buildPausedOverlay(),
            if (_appMode == AppMode.tutorial) _buildTutorialOverlay(),

            if (_appMode != AppMode.tutorial) _buildStatusBanner(),
            if (_speechRateOverlayText.isNotEmpty) _buildSpeechRateOverlay(),
          ],
        ),
      ),
    );
  }
}
