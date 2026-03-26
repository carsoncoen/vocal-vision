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

  // Holds the exact sentence that is about to be spoken.
  String _pendingSpokenText = '';

  DateTime _lastSpoken = DateTime.fromMillisecondsSinceEpoch(0);
  static const Duration _minSpeakInterval = Duration(seconds: 3);

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
    await _speakSynchronized(turningOn ? 'Detection on' : 'Detection off');

    await Future.delayed(const Duration(milliseconds: 400));

    _lastSpoken = DateTime.fromMillisecondsSinceEpoch(0);
    _lastDangerSpoken = DateTime.fromMillisecondsSinceEpoch(0);
    _lastSpokenNormalSummaryKey = '';

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