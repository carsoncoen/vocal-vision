import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';

void main() => runApp(const NativeYOLODemo());

class NativeYOLODemo extends StatelessWidget {
  const NativeYOLODemo({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: LidarDetectionScreen(),
    );
  }
}

class LidarDetectionScreen extends StatefulWidget {
  const LidarDetectionScreen({super.key});

  @override
  State<LidarDetectionScreen> createState() => _LidarDetectionScreenState();
}

class _LidarDetectionScreenState extends State<LidarDetectionScreen> {
  // 1. Define the exact same channel name as in AppDelegate.swift
  static const EventChannel _lidarChannel = EventChannel('com.vocalvision.app/lidar_stream');
  StreamSubscription? _lidarSubscription;

  final FlutterTts _tts = FlutterTts();

  bool _isSpeaking = false;
  bool _detectionEnabled = true;
  bool _toggleSpeaking = false;

  String _statusText = "Initializing LiDAR...";

  // TTS Cooldowns
  DateTime _lastSpoken = DateTime.fromMillisecondsSinceEpoch(0);
  static const Duration _minSpeakInterval = Duration(seconds: 2);

  DateTime _lastDangerSpoken = DateTime.fromMillisecondsSinceEpoch(0);
  static const Duration _minDangerInterval = Duration(seconds: 2);

  // Distances (in feet)
  static const double _maxAlertDistanceFeet = 10.0;
  static const double _dangerDistanceFeet = 4.0;

  final List<String> onGroundObjects = [
    'person', 'dining table', 'table', 'chair', 'dog', 'cat',
    'bicycle', 'suitcase', 'couch', 'bed', 'bus', 'door'
  ];

  @override
  void initState() {
    super.initState();
    _initTts();
    _startListening();
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

  // 2. Listen to the Native iOS Stream
  void _startListening() {
    _lidarSubscription = _lidarChannel.receiveBroadcastStream().listen(
      (dynamic event) {
        if (!_detectionEnabled || _toggleSpeaking) return;

        // Parse the JSON/Dictionary from Swift
        final Map<dynamic, dynamic> data = event as Map<dynamic, dynamic>;
        
        final String rawLabel = data['label'] as String;
        final double distanceFeet = data['distanceFeet'] as double;
        final double confidence = data['confidence'] as double;

        // Feed to TTS Logic
        _processDetectionForTTS(rawLabel, distanceFeet, confidence);
      },
      onError: (dynamic error) {
        print('LiDAR Stream Error: ${error.message}');
      },
    );
  }

  // 3. Process the Data
  Future<void> _processDetectionForTTS(String rawLabel, double distanceFeet, double confidence) async {
    var label = rawLabel.trim().toLowerCase();

    // Label normalization
    if (label == 'dining table') label = 'table';
    if (label == 'dining tables') label = 'tables';

    if (!onGroundObjects.contains(label)) return;
    if (distanceFeet > _maxAlertDistanceFeet) return;

    // --- Urgent / Danger Logic ---
    if (distanceFeet < _dangerDistanceFeet) {
      final String sentence = 'Warning, $label in front of you';

      if (mounted) {
        setState(() => _statusText = sentence);
      }

      final now = DateTime.now();
      if (now.difference(_lastDangerSpoken) < _minDangerInterval) return;

      _lastDangerSpoken = now;
      _lastSpoken = now; // Reset normal spoken timer too

      // Interrupt normal speech
      await _tts.stop();
      _isSpeaking = false;

      await _tts.speak(sentence);
      return;
    }

    // --- Normal Announcement Logic ---
    final double roundedFeet = (distanceFeet * 2).round() / 2.0;
    final String sentence = '$label ahead, around ${roundedFeet.toStringAsFixed(1)} feet';

    if (mounted) {
      setState(() => _statusText = sentence);
    }

    if (_isSpeaking) return;
    
    final now = DateTime.now();
    if (now.difference(_lastSpoken) < _minSpeakInterval) return;

    _lastSpoken = now;
    await _tts.speak(sentence);
  }

  Future<void> _toggleDetection() async {
    _toggleSpeaking = true;
    await _tts.stop();
    _isSpeaking = false;

    final turningOn = !_detectionEnabled;
    setState(() => _detectionEnabled = turningOn);

    await Future.delayed(const Duration(milliseconds: 150));
    await _tts.speak(turningOn ? "Detection on" : "Detection off");
    await Future.delayed(const Duration(milliseconds: 400));

    _lastSpoken = DateTime.fromMillisecondsSinceEpoch(0);
    _toggleSpeaking = false;
  }

  @override
  void dispose() {
    _lidarSubscription?.cancel(); // Important: Stops the ARKit session!
    _tts.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // Visual feedback
          Center(
            child: Icon(
              _detectionEnabled ? Icons.radar : Icons.pause_circle_outline,
              color: _detectionEnabled ? Colors.green : Colors.grey,
              size: 100,
            ),
          ),

          if (!_detectionEnabled)
            Container(
              color: Colors.black.withOpacity(0.6),
              child: const Center(
                child: Text(
                  'Detection Paused',
                  style: TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold),
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
                style: const TextStyle(color: Colors.white, fontSize: 18),
                textAlign: TextAlign.center,
              ),
            ),
          ),

          Positioned(
            bottom: 60,
            left: 40,
            right: 40,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
              onPressed: _toggleDetection,
              child: Text(
                _detectionEnabled ? 'Pause Detection' : 'Resume Detection',
                style: const TextStyle(fontSize: 18),
              ),
            ),
          ),
        ],
      ),
    );
  }
}