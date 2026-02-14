# vocal_vision_app

A new Flutter project.

## Getting Started

### Installing iOS and Android dependencies

- YOLO
    - ultralytics_yolo: ^0.1.25
    - image_picker: ^0.8.7
    - Dowloading and adding yolo26n file (https://github.com/ultralytics/yolo-flutter-app/releases/tag/v0.2.0):
        - For iOS: Drag and drop mlpackage/mlmodel directly into ios/Runner.xcworkspace and set target to Runner.
        - For Android: Place the yolo11n.tflite file in android/app/src/main/assets/ (the Android native assets folder, not the Flutter assets folder).
    - For more info about using YOLO in Flutter, visit https://github.com/ultralytics/yolo-flutter-app/tree/main
