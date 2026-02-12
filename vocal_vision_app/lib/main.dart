import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:web_socket_channel/io.dart';
import 'package:image/image.dart' as img;
import 'package:flutter_tts/flutter_tts.dart';

List<CameraDescription>? cameras;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  cameras = await availableCameras();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

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
  CameraController? _controller;
  late IOWebSocketChannel _channel;
  bool _isStreaming = false;
  List<dynamic> _detections = [];
  String _detectedObjectsText = "Waiting for objects...";
  
  // TTS Setup
  final FlutterTts flutterTts = FlutterTts();
  String _lastSpoken = "";
  DateTime _lastSpeakTime = DateTime.now();
  bool _isSpeaking = false;

  // REPLACE WITH YOUR COMPUTER IP
  final String _socketUrl = 'ws://10.245.225.79:8765'; 

  @override
  void initState() {
    super.initState();
    _initializeCamera();
    _initTts(); // Initialize TTS
    _connectWebSocket();
  }

  void _initTts() async {
    await flutterTts.setLanguage("en-US");
    await flutterTts.setPitch(1.0);
    await flutterTts.setSpeechRate(0.5);
    
    // Ensure we don't speak over ourselves
    flutterTts.setCompletionHandler(() {
      _isSpeaking = false;
    });
  }

  void _connectWebSocket() {
    try {
      _channel = IOWebSocketChannel.connect(_socketUrl);
      _channel.stream.listen((message) {
        final List<dynamic> data = jsonDecode(message);
        
        // 1. Count objects
        Map<String, int> counts = {};
        for (var item in data) {
          String cls = item['class'];
          counts[cls] = (counts[cls] ?? 0) + 1;
        }

        // 2. Build Text
        List<String> parts = [];
        counts.forEach((cls, count) {
           String label = cls;
           if (count > 1) {
             if (cls == 'person') label = 'people';
             else if (cls == 'bottle') label = 'bottles';
             else label = '${cls}s';
           }
           parts.add("$count $label");
        });

        String newText = parts.isNotEmpty ? parts.join(", ") : "No objects";

        // 3. Update UI
        if (mounted) {
          setState(() {
            _detections = data;
            _detectedObjectsText = "Detected: $newText";
          });
        }

        // 4. INTELLIGENT SPEECH LOGIC
        _handleSpeech(newText);

      });
    } catch (e) {
      print("Error: $e");
    }
  }

  void _handleSpeech(String text) async {
    if (text == "No objects") return; // Don't say "No objects" repeatedly

    DateTime now = DateTime.now();
    
    // LOGIC: Speak if:
    // A. The text is DIFFERENT from what we just said (new object appeared)
    //    AND it has been at least 2 seconds (to prevent rapid-fire switching)
    // OR
    // B. It has been 5+ seconds since we last spoke (reminder)
    
    bool isNewObject = text != _lastSpoken;
    bool isTimeForReminder = now.difference(_lastSpeakTime).inSeconds > 5;
    bool isCooldownOver = now.difference(_lastSpeakTime).inSeconds > 2;

    if ((isNewObject && isCooldownOver) || isTimeForReminder) {
      if (!_isSpeaking) {
        _isSpeaking = true;
        _lastSpoken = text;
        _lastSpeakTime = now;
        await flutterTts.speak(text);
      }
    }
  }

  Future<void> _initializeCamera() async {
    if (cameras == null || cameras!.isEmpty) return;
    _controller = CameraController(
      cameras![0],
      ResolutionPreset.medium, 
      enableAudio: false,
    );
    await _controller!.initialize();
    if (!mounted) return;
    setState(() {});
  }

  void _toggleStreaming() {
    if (_controller == null || !_controller!.value.isInitialized) return;

    if (_isStreaming) {
      _controller!.stopImageStream();
    } else {
      _controller!.startImageStream((CameraImage image) {
         _sendImageToServer(image);
      });
    }
    setState(() {
      _isStreaming = !_isStreaming;
    });
  }

  bool _isProcessing = false;

  Future<void> _sendImageToServer(CameraImage cameraImage) async {
    if (_isProcessing) return;
    _isProcessing = true;

    try {
      img.Image? image;

      // Handle iOS/Simulator BGRA8888 format
      if (cameraImage.format.group == ImageFormatGroup.bgra8888) {
        final int width = cameraImage.width;
        final int height = cameraImage.height;
        const int bytesPerPixel = 4;
        final int srcStride = cameraImage.planes[0].bytesPerRow;
        final Uint8List srcBytes = cameraImage.planes[0].bytes;

        // Copy only the used portion of each row into a tightly packed buffer
        final Uint8List dstBytes = Uint8List(width * height * bytesPerPixel);
        int dstOffset = 0;
        for (int y = 0; y < height; y++) {
          final int srcRowStart = y * srcStride;
          dstBytes.setRange(
            dstOffset,
            dstOffset + width * bytesPerPixel,
            srcBytes.sublist(srcRowStart, srcRowStart + width * bytesPerPixel),
          );
          dstOffset += width * bytesPerPixel;
        }

        image = img.Image.fromBytes(
          width: width,
          height: height,
          bytes: dstBytes.buffer,
          order: img.ChannelOrder.bgra,
        );
      } 
      // Handle Android YUV420 format
      else if (cameraImage.format.group == ImageFormatGroup.yuv420) {
        image = _convertYUV420ToImage(cameraImage);
      } else {
        print("Image format not supported: ${cameraImage.format.group}");
      }

      if (image != null) {
        // Resize to 320px width to speed up transmission
        img.Image resized = img.copyResize(image, width: 320);
        List<int> jpeg = img.encodeJpg(resized, quality: 60);
        
        // Print to confirm we are actually sending
        // print("Sending frame size: ${jpeg.length} bytes"); 
        
        _channel.sink.add(base64Encode(jpeg));
      } else {
        print("Image format not supported: ${cameraImage.format.group}");
      }
    } catch (e) {
      print("Error sending frame: $e");
    } finally {
      await Future.delayed(const Duration(milliseconds: 50));
      _isProcessing = false;
    }
  }

  // Convert Android YUV420_888 camera image to RGB image
  img.Image _convertYUV420ToImage(CameraImage cameraImage) {
    final int width = cameraImage.width;
    final int height = cameraImage.height;

    final img.Image imgImage = img.Image(width: width, height: height);

    final Plane planeY = cameraImage.planes[0];
    final Plane planeU = cameraImage.planes[1];
    final Plane planeV = cameraImage.planes[2];

    final int uvRowStride = planeU.bytesPerRow;
    final int uvPixelStride = planeU.bytesPerPixel ?? 1;

    for (int y = 0; y < height; y++) {
      final int uvRow = uvRowStride * (y ~/ 2);
      final int rowY = planeY.bytesPerRow * y;

      for (int x = 0; x < width; x++) {
        final int uvIndex = uvRow + (x ~/ 2) * uvPixelStride;
        final int indexY = rowY + x;

        final int yVal = planeY.bytes[indexY];
        final int uVal = planeU.bytes[uvIndex];
        final int vVal = planeV.bytes[uvIndex];

        final double yf = yVal.toDouble();
        final double uf = uVal.toDouble() - 128.0;
        final double vf = vVal.toDouble() - 128.0;

        int r = (yf + 1.402 * vf).round();
        int g = (yf - 0.344136 * uf - 0.714136 * vf).round();
        int b = (yf + 1.772 * uf).round();

        r = r.clamp(0, 255);
        g = g.clamp(0, 255);
        b = b.clamp(0, 255);

        imgImage.setPixelRgba(x, y, r, g, b, 255);
      }
    }

    return imgImage;
  }

  @override
  void dispose() {
    _controller?.dispose();
    _channel.sink.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_controller == null || !_controller!.value.isInitialized) {
      return const Center(child: CircularProgressIndicator());
    }

    return Scaffold(
      appBar: AppBar(title: const Text("YOLO26n JSON Mode")),
      body: Stack(
        children: [
          // 1. Camera Feed
          CameraPreview(_controller!),
          
          // 2. Bounding Box Overlay
          Positioned.fill(
            child: CustomPaint(
              painter: BoundingBoxPainter(
                detections: _detections, 
                // Color for the boxes
                boxColor: Colors.redAccent,
              ),
            ),
          ),

          // 3. UI Overlay for Text
          Positioned(
            bottom: 30,
            left: 20,
            right: 20,
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                _detectedObjectsText,
                style: const TextStyle(color: Colors.white, fontSize: 16),
                textAlign: TextAlign.center,
              ),
            ),
          ),
          
          // 4. Start/Stop Button
          Positioned(
            top: 20,
            right: 20,
            child: FloatingActionButton(
              onPressed: _toggleStreaming,
              backgroundColor: _isStreaming ? Colors.red : Colors.green,
              child: Icon(_isStreaming ? Icons.stop : Icons.play_arrow),
            ),
          ),
        ],
      ),
    );
  }
}

// Custom Painter to draw boxes
class BoundingBoxPainter extends CustomPainter {
  final List<dynamic> detections;
  final Color boxColor;

  BoundingBoxPainter({required this.detections, required this.boxColor});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = boxColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.0;

    final textStyle = TextStyle(
      color: boxColor,
      fontSize: 18,
      fontWeight: FontWeight.bold,
      backgroundColor: Colors.black45,
    );

    for (var detection in detections) {
      // The server sends normalized coordinates [x1, y1, x2, y2] (0.0 to 1.0)
      List<dynamic> box = detection['box'];
      String label = detection['class'];
      double conf = detection['conf'];

      // Convert normalized coords to screen pixels
      double x1 = box[0] * size.width;
      double y1 = box[1] * size.height;
      double x2 = box[2] * size.width;
      double y2 = box[3] * size.height;

      // Draw Rectangle
      canvas.drawRect(
        Rect.fromLTRB(x1, y1, x2, y2),
        paint,
      );

      // Draw Label
      final textSpan = TextSpan(
        text: '$label ${(conf * 100).toInt()}%',
        style: textStyle,
      );
      final textPainter = TextPainter(
        text: textSpan,
        textDirection: TextDirection.ltr,
      );
      textPainter.layout();
      textPainter.paint(canvas, Offset(x1, y1 - 25)); // Draw text above box
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) {
    return true; // Always repaint when new data comes in
  }
}