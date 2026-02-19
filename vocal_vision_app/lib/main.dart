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

      counts[label] = (counts[label] ?? 0) + 1;
    }

    if (counts.isEmpty) return;

    final List<String> parts = [];

    if (counts.containsKey('person')) {
      final count = counts['person']!;
      parts.add(count == 1
          ? '1 person ahead'
          : '$count people ahead');
    }

    counts.forEach((label, count) {
      if (label == 'person') return;
      parts.add(count == 1
          ? '1 $label'
          : '$count ${label}s');
    });

    final speech = parts.join(', ');

    _lastSpoken = now;
    _isSpeaking = true;

    await _tts.speak(speech);
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
