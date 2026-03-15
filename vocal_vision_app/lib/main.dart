import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
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

  DateTime _lastSpoken = DateTime.fromMillisecondsSinceEpoch(0);
  static const Duration _minSpeakInterval = Duration(seconds: 2);

  // Normal reminders are repeated at a controlled interval while the same
  // stable summary remains active.
  static const Duration _normalRepeatInterval = Duration(seconds: 4);
  String _lastSpokenNormalSummaryKey = '';

  // Separate cooldown for urgent warnings so they can bypass normal summary timing
  // without speaking every single frame.
  DateTime _lastDangerSpoken = DateTime.fromMillisecondsSinceEpoch(0);
  static const Duration _minDangerInterval = Duration(seconds: 2);

  @override
  void initState() {
    super.initState();
    _initTts();
  }

  Future<void> _initTts() async {
    await _tts.setLanguage('en-US');

    // The sponsor is comfortable with faster speech, so this is intentionally
    // quicker than the original value. It keeps mandatory distance callouts from
    // sounding too delayed.
    await _tts.setSpeechRate(0.7);

    // We still wait for completion so _isSpeaking reflects real TTS state.
    await _tts.awaitSpeakCompletion(true);

    _tts.setStartHandler(() {
      if (!mounted) {
        return;
      }
      setState(() => _isSpeaking = true);
    });

    _tts.setCompletionHandler(() {
      if (!mounted) {
        return;
      }
      setState(() => _isSpeaking = false);
    });

    _tts.setErrorHandler((_) {
      if (!mounted) {
        return;
      }
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

    final bool turningOn = !_detectionEnabled;

    setState(() {
      _detectionEnabled = turningOn;
    });

    await Future.delayed(const Duration(milliseconds: 150));
    await _tts.speak(turningOn ? 'Detection on' : 'Detection off');

    await Future.delayed(const Duration(milliseconds: 400));

    _lastSpoken = DateTime.fromMillisecondsSinceEpoch(0);
    _lastDangerSpoken = DateTime.fromMillisecondsSinceEpoch(0);
    _lastSpokenNormalSummaryKey = '';

    _toggleSpeaking = false;
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
    if (_toggleSpeaking) {
      return;
    }

    if (!_detectionEnabled) {
      return;
    }

    final AnnouncementDecision decision = _announcementEngine.processDetections(detections);

    if (decision.statusText.isNotEmpty && mounted && _statusText != decision.statusText) {
      setState(() => _statusText = decision.statusText);
    }

    // If nothing stable is active anymore, clear the remembered normal summary
    // so it can be spoken again if it later reappears.
    if (decision.type == AnnouncementType.none && decision.topGroups.isEmpty) {
      _lastSpokenNormalSummaryKey = '';
      return;
    }

    if (!decision.shouldSpeak) {
      return;
    }

    final DateTime now = DateTime.now();

    if (decision.type == AnnouncementType.danger) {
      if (now.difference(_lastDangerSpoken) < _minDangerInterval) {
        return;
      }

      _lastDangerSpoken = now;
      _lastSpoken = now;

      // Danger alerts are allowed to interrupt current speech.
      await _tts.stop();
      _isSpeaking = false;
      await _tts.speak(decision.spokenText);
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
    await _tts.speak(decision.spokenText);
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
            onResult: _handleDetections,
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
                  fontSize: 16,
                ),
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
                _detectionEnabled ? 'Pause Detection' : 'Resume Detection',
              ),
            ),
          ),
        ],
      ),
    );
  }
}
