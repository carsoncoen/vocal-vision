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
  // Text-to-speech engine.
  final FlutterTts _tts = FlutterTts();

  // Track whether TTS is currently speaking (prevents overlap).
  bool _isSpeaking = false;

  // Throttle speech so it doesn’t speak on every single frame.
  DateTime _lastSpoken = DateTime.fromMillisecondsSinceEpoch(0);
  static const Duration _minSpeakInterval = Duration(seconds: 4);

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

  /// Called continuously with the latest detections from YOLOView.
  /// Builds a short phrase like "2 people 1 bottle" and speaks it.
  Future<void> _speakDetections(List<YOLOResult> detections) async {
    if (_isSpeaking || detections.isEmpty) return;

    final DateTime now = DateTime.now();
    if (now.difference(_lastSpoken) < _minSpeakInterval) return;

    // Count detections by label (e.g., person -> 2, bottle -> 1).
    final Map<String, int> counts = <String, int>{};
    for (final YOLOResult d in detections) {
      final String label = d.className.trim().toLowerCase();
      if (label.isEmpty) continue;
      counts[label] = (counts[label] ?? 0) + 1;
    }

    if (counts.isEmpty) return;

    // Convert counts into a list of speakable fragments.
    final List<String> parts = <String>[];
    counts.forEach((String label, int count) {
      if (count == 1) {
        parts.add('1 $label');
      } else if (label == 'person') {
        parts.add('$count people');
      } else {
        parts.add('$count ${label}s');
      }
    });

    _lastSpoken = now;
    await _tts.speak(parts.join(' '));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Object Detection')),

      // YOLOView opens the camera, runs the YOLO model on-device,
      // and emits detections through onResult.
      body: YOLOView(
        modelPath: 'yolo11n',
        task: YOLOTask.detect,
        useGpu: false, // force CPU so the model loads on emulator
        onResult: _speakDetections,
      ),
    );
  }
}