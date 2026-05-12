import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_tts/flutter_tts.dart'; // Imported for background TTS
import 'drowsiness_detector.dart';
import 'app_config.dart';

/// ─── Entry point for the background isolate ──────────────────────────────────
/// This function is called when the foreground service starts.
/// @pragma keeps it from being tree-shaken by the compiler.
@pragma('vm:entry-point')
void startCallback() {
  FlutterForegroundTask.setTaskHandler(BackgroundDetectionTask());
}

/// ─── Background Detection Task ───────────────────────────────────────────────
///
/// Runs in a separate Flutter isolate (background service).
/// Uses single-frame HTTP capture (/capture endpoint, port 80) instead of
/// MJPEG streaming — avoids the need for a persistent TCP connection that
/// Android kills when the app is backgrounded.
///
/// Detection loop:
///   Every 400ms → GET http://{ip}/capture → ML Kit → if drowsy → alarm
///
class BackgroundDetectionTask extends TaskHandler {
  DrowsinessDetector? _detector;
  final FlutterTts _tts = FlutterTts(); // Isolated TTS instance
  bool _isProcessing = false;
  bool _alarmCoolingDown = false;
  bool _appInBackground = false;
  int _tickCount = 0;

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    await AppConfig().load();
    
    // Initialize background TTS parameters
    try {
      await _tts.setLanguage("en-US");
      await _tts.setSpeechRate(0.5);
      await _tts.setVolume(1.0);
      await _tts.setPitch(1.0);
    } catch (e) {
      debugPrint('[BGTask] Error setting up background TTS: $e');
    }

    _detector = DrowsinessDetector();
    await _detector!.init();
    debugPrint('[BGTask] Detection started. Polling /capture when backgrounded.');
  }

  @override
  void onRepeatEvent(DateTime timestamp) async {
    // Skip background polling if the app is in the foreground (already streaming via main isolate)
    // or if we are already processing a previous frame.
    if (!_appInBackground || _isProcessing || _detector == null) return;

    _tickCount++;
    if (_tickCount < 3) return; // Only poll once every 1200ms (3 ticks of 400ms) to give ESP32 breathing room
    _tickCount = 0;

    _isProcessing = true;
    final client = http.Client();
    try {
      // Single-frame capture — much simpler than MJPEG in background.
      // The ESP32 /capture endpoint returns one JPEG frame on demand.
      final response = await client
          .get(
            Uri.parse('http://${AppConfig().ip}/capture'),
            headers: {'Connection': 'close'},
          )
          .timeout(const Duration(milliseconds: 1500));

      if (response.statusCode == 200) {
        final Uint8List frame = response.bodyBytes;
        final bool? drowsy = await _detector!.processFrame(frame);

        // Send status to main isolate (for UI if app is in foreground)
        FlutterForegroundTask.sendDataToMain(
          {'status': drowsy == true ? 'alert' : 'ok'},
        );

        if (drowsy == true && !_alarmCoolingDown) {
          await _triggerAlarm();
        }
      }
    } catch (e) {
      if (e is TimeoutException) {
        debugPrint('[BGTask] Frame capture timeout. ESP32 busy or Wi-Fi lagging.');
      } else {
        debugPrint('[BGTask] Frame capture error: $e');
      }
    } finally {
      client.close();
      _isProcessing = false;
    }
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    debugPrint('[BGTask] Detection stopped.');
    try { await _tts.stop(); } catch (_) {}
    _detector?.dispose();
    _detector = null;
  }

  @override
  void onReceiveData(Object data) {
    debugPrint('[BGTask] Received from main: $data');
    if (data is Map) {
      final state = data['state'] as String?;
      if (state == 'background') {
        _appInBackground = true;
        _tickCount = 2; // Trigger the very first background poll on the next repeat tick, then every 3 ticks (1200ms)
        debugPrint('[BGTask] App moved to background. Polling active.');
      } else if (state == 'foreground') {
        _appInBackground = false;
        debugPrint('[BGTask] App moved to foreground. Polling paused.');
      }
    }
  }

  // ── Alarm ─────────────────────────────────────────────────────────────────

  Future<void> _triggerAlarm() async {
    _alarmCoolingDown = true;
    final config = AppConfig();

    // Show high-priority foreground notification to wake the user
    await FlutterForegroundTask.updateService(
      notificationTitle: '⚠️ DROWSINESS DETECTED — Wake Up!',
      notificationText: 'AlertEdge has detected you may be falling asleep.',
    );

    // 1. Play Voice Alert if user enabled it
    if (config.voiceAlertsEnabled) {
      try {
        await _tts.speak("Alert Edge Warning. Wake up!");
      } catch (e) {
        debugPrint('[BGTask] Background voice error: $e');
      }
    }

    // 2. Trigger ESP32 hardware alarm if user enabled it
    if (config.hardwareBuzzerEnabled) {
      try {
        await http
            .get(
              Uri.parse(config.alarmUrl),
              headers: {'Connection': 'close'},
            )
            .timeout(const Duration(seconds: 2));
      } catch (_) {}
    }

    // Reset notification text after 5s and allow next alarm after 10s
    await Future.delayed(const Duration(seconds: 5));
    await FlutterForegroundTask.updateService(
      notificationTitle: '🛡️ AlertEdge Active',
      notificationText: 'Drowsiness monitoring is running',
    );
    await Future.delayed(const Duration(seconds: 5));
    _alarmCoolingDown = false;
  }
}
