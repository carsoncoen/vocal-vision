# Vocal Vision (Flutter)

Vocal Vision is a mobile Flutter app that uses on-device object detection (Ultralytics YOLO) to identify nearby obstacles and announce them using text-to-speech (TTS). It’s designed for hands-free use and includes haptics for device-tilt feedback.

## Features

- **Real-time object detection** using `ultralytics_yolo`
- **Spoken awareness** (“person ahead”, “chair left…”) via `flutter_tts`
- **Danger warnings** when objects are very close
- **Tilt haptics** to help keep the phone oriented
- **Keeps screen awake** while the detection screen is open (`wakelock_plus`)
- **Double-tap to pause/resume** detection

## Requirements

- **Flutter SDK** installed (Dart 3 compatible)
- A real device is recommended for camera + performance

## Setup

### 1) Install dependencies

From the `vocal_vision_app` directory:

```bash
flutter pub get
```

### 2) YOLO model setup

This app uses the Ultralytics Flutter YOLO plugin. You must add the model file(s) expected by the plugin for your platform.

- **Android**
  - Put the YOLO `.tflite` file in:
    - `android/app/src/main/assets/`
  - Ensure the file name matches what the plugin expects (the app currently uses `modelPath: 'yolo11n'` in code).

- **iOS**
  - Add the YOLO `.mlmodel` / `.mlpackage` to the iOS Runner target in Xcode so it’s bundled in the app.

Ultralytics reference:
- Repo: `https://github.com/ultralytics/yolo-flutter-app`

## Run

```bash
flutter run
```

## How to use the app

- **Open the app** and allow **Camera** permission.
- The app will start **scanning** and announcing objects.
- **Double-tap anywhere** to toggle detection:
  - When paused, the screen shows “Detection Paused”
  - When resumed, scanning restarts

## Permissions

- **Camera**: required for detection

If permission is denied permanently, the app will prompt you to open system settings.

## Project structure (high level)

- `lib/main.dart`
  - App UI + camera view (`YOLOView`)
  - Calls the awareness engine and speaks announcements
  - Controls wakelock (prevents screen from turning off)
- `lib/awareness/announcement_engine.dart`
  - Converts raw detections into a single “what should we say now?” decision
  - Handles danger vs normal announcements and stability timing
- `lib/awareness/awareness_config.dart`
  - Tunable thresholds/weights (confidence, danger distance, etc.)
- `lib/awareness/awareness_models.dart`
  - Shared data models (directions, decision types, groups)

## Troubleshooting

- **Black screen / no camera**
  - Confirm camera permission is granted
  - Prefer testing on a physical device

- **No announcements**
  - Check device volume and ringer/silent settings
  - Verify the app is not paused (double-tap toggles)

- **Model not found / detection not working**
  - Re-check that the model files are placed correctly for your platform
  - Ensure model naming matches the plugin configuration used in `YOLOView(modelPath: ...)`

## Notes

- This project currently targets real-time, accessible feedback. Accuracy and distance estimation are approximate and should be tested in the intended environment.
