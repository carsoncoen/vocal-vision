import 'package:flutter/material.dart';
import 'package:ultralytics_yolo/yolo.dart';
import 'package:image_picker/image_picker.dart';
import 'dart:io';
import 'package:ultralytics_yolo/yolo_view.dart';
import 'package:flutter_tts/flutter_tts.dart';

void main() => runApp(YOLODemo());

class YOLODemo extends StatefulWidget {
  @override
  _YOLODemoState createState() => _YOLODemoState();
}

class _YOLODemoState extends State<YOLODemo> {
  YOLO? yolo;
  File? selectedImage;
  List<dynamic> results = [];
  bool isLoading = false;

  final FlutterTts flutterTts = FlutterTts();
  bool isSpeaking = false;
  DateTime lastSpoken = DateTime.now();

  @override
  void initState() {
    super.initState();
    loadYOLO();
  }

  // Configure TTS settings and state handlers
  void _initTts() async {
    await flutterTts.setLanguage("en-US");
    await flutterTts.setSpeechRate(0.5); // 0.0 to 1.0
    
    flutterTts.setStartHandler(() {
      setState(() => isSpeaking = true);
    });
    
    flutterTts.setCompletionHandler(() {
      setState(() => isSpeaking = false);
    });

    flutterTts.setErrorHandler((msg) {
      setState(() => isSpeaking = false);
    });
  }

  Future<void> loadYOLO() async {
    setState(() => isLoading = true);

    yolo = YOLO(
      modelPath: 'yolo11n',
      task: YOLOTask.detect,
    );

    await yolo!.loadModel();
    setState(() => isLoading = false);
  }

  Future<void> pickAndDetect() async {
    final picker = ImagePicker();
    final image = await picker.pickImage(source: ImageSource.gallery);

    if (image != null) {
      setState(() {
        selectedImage = File(image.path);
        isLoading = true;
      });

      final imageBytes = await selectedImage!.readAsBytes();
      final detectionResults = await yolo!.predict(imageBytes);

      setState(() {
        results = detectionResults['boxes'] ?? [];
        isLoading = false;
      });
    }
  }

  // Create the function to parse results and speak
  Future<void> _speakDetections(List<YOLOResult> detections) async {
    // Prevent overlapping speech
    if (isSpeaking || detections.isEmpty) return;

    // Throttle: Only allow it to speak once every 4 seconds
    if (DateTime.now().difference(lastSpoken).inSeconds < 4) return;

    // 1. Map to keep track of object frequencies
    Map<String, int> objectCounts = {};
    for (var object in detections) {
      String label = object.className.toLowerCase();
      objectCounts[label] = (objectCounts[label] ?? 0) + 1;
    }

    if (objectCounts.isNotEmpty) {
      List<String> spokenItems = [];
      
      // Format the output based on the count
      objectCounts.forEach((label, count) {
        if (count > 1) {
          // Manual pluralization
          if (label == 'person') {
            spokenItems.add('$count people');
          } else {
            spokenItems.add('$count ${label}s');
          }
        } else {
          // Singular
          spokenItems.add('$count $label');
        }
      });

      lastSpoken = DateTime.now();
      
      // Join the items naturally (e.g., "4 bottles and 2 people")
      String textToSpeak = spokenItems.join(' ');
      await flutterTts.speak(textToSpeak);
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: Text('Object Detection')),
        body: YOLOView(
          modelPath: 'yolo11n',
          task: YOLOTask.detect,
          onResult: (results) { // detected objects in results list
            // Pass the live results to our speaking function
            _speakDetections(results);
          },

        ),
      ),
    );
  }
}