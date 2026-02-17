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

  // Stop anything currently speaking
  await _tts.stop();

  // Reset speaking state manually
  setState(() {
    _isSpeaking = false;
    _detectionEnabled = !_detectionEnabled;
  });

  // Small delay to allow TTS engine to stabilize
  await Future.delayed(const Duration(milliseconds: 250));

  if (_detectionEnabled) {
    await _tts.speak('Detection on');
  } else {
    await _tts.speak('Detection off');
  }
}


  Future<void> _speakDetections(
      List<YOLOResult> detections) async {

    if (!_detectionEnabled) return;
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

    _lastSpoken = now;
    await _tts.speak(parts.join(', '));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [

          // Camera or paused screen
          _detectionEnabled
              ? YOLOView(
                  modelPath: 'yolo11n',
                  task: YOLOTask.detect,
                  useGpu: false,
                  onResult: _speakDetections,
                )
              : const Center(
                  child: Text(
                    'Detection Paused',
                    style: TextStyle(
                      fontSize: 24,
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),

          // Top status text
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

          // Single large control button
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
