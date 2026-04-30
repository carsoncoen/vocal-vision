import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vocal_vision_app/main.dart';
import 'package:ultralytics_yolo/yolo_view.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Vocal Vision App Tests', () {

    testWidgets('App loads and shows tutorial screen', (WidgetTester tester) async {
      await tester.pumpWidget(const YOLODemo());
      await tester.pumpAndSettle();

      expect(find.text('Vocal Vision Tutorial'), findsOneWidget);
    });

    testWidgets('App starts in tutorial mode with correct status', (WidgetTester tester) async {
      await tester.pumpWidget(const YOLODemo());
      await tester.pumpAndSettle();

      expect(find.textContaining('Tutorial'), findsWidgets);
    });

    testWidgets('YOLOView is present in the widget tree', (WidgetTester tester) async {
      await tester.pumpWidget(const YOLODemo());
      await tester.pump();

      expect(find.byType(YOLOView), findsOneWidget);
    });

    testWidgets('Long press exits tutorial and starts detection', (WidgetTester tester) async {
      await tester.pumpWidget(const YOLODemo());
      await tester.pumpAndSettle();

      final gestureArea = find.byType(GestureDetector);

      await tester.longPress(gestureArea);
      await tester.pump();

      expect(find.text('Scanning...'), findsOneWidget);
    });

    testWidgets('Double tap toggles detection (pause)', (WidgetTester tester) async {
      await tester.pumpWidget(const YOLODemo());
      await tester.pumpAndSettle();

      final gestureArea = find.byType(GestureDetector);

      // Start detection first
      await tester.longPress(gestureArea);
      await tester.pump();

      // Double tap to pause
      await tester.tap(gestureArea);
      await tester.tap(gestureArea);
      await tester.pump();

      expect(find.text('Detection Paused'), findsOneWidget);
    });

    testWidgets('Status text updates from tutorial to scanning', (WidgetTester tester) async {
      await tester.pumpWidget(const YOLODemo());
      await tester.pumpAndSettle();

      expect(find.textContaining('Tutorial'), findsWidgets);

      final gestureArea = find.byType(GestureDetector);

      await tester.longPress(gestureArea);
      await tester.pump();

      expect(find.text('Scanning...'), findsOneWidget);
    });

    testWidgets('Swipe changes speech rate and shows overlay', (WidgetTester tester) async {
      await tester.pumpWidget(const YOLODemo());
      await tester.pumpAndSettle();

      final gestureArea = find.byType(GestureDetector);

      // Start detection
      await tester.longPress(gestureArea);
      await tester.pump();

      // Swipe up
      await tester.drag(gestureArea, const Offset(0, -120));
      await tester.pump();

      expect(find.textContaining('Speech speed'), findsOneWidget);
    });

    testWidgets('Pause overlay appears correctly', (WidgetTester tester) async {
      await tester.pumpWidget(const YOLODemo());
      await tester.pumpAndSettle();

      final gestureArea = find.byType(GestureDetector);

      // Start detection
      await tester.longPress(gestureArea);
      await tester.pump();

      // Pause
      await tester.tap(gestureArea);
      await tester.tap(gestureArea);
      await tester.pump();

      expect(find.text('Detection Paused'), findsOneWidget);
    });

    testWidgets('App does not crash during idle runtime', (WidgetTester tester) async {
      await tester.pumpWidget(const YOLODemo());

      // Simulate runtime
      await tester.pump(const Duration(seconds: 2));

      expect(find.byType(YOLODemo), findsOneWidget);
    });

  });
}