import 'package:http/http.dart' as http;
import 'package:flutter_tts/flutter_tts.dart';
import 'database_helper.dart';
import 'app_config.dart';

class AlarmService {
  /// Always read live from AppConfig — updates the moment user changes IP
  String get alarmUrl => AppConfig().alarmUrl;
  final FlutterTts flutterTts = FlutterTts();
  bool _isSpeaking = false;

  /// Hardware cooldown: prevents hammering the ESP32 with multiple HTTP
  /// requests if the detector fires in quick succession.
  /// Even if triggerAlarm() is called twice, the ESP32 only receives ONE
  /// request per cooldown window — protecting the MJPEG stream connection.
  bool _hardwareAlarmActive = false;
  static const Duration _hardwareCooldown = Duration(seconds: 5);

  AlarmService() {
    _initTts();
  }

  void _initTts() async {
    await flutterTts.setLanguage("en-US");
    await flutterTts.setSpeechRate(0.5);
    await flutterTts.setVolume(1.0);
    await flutterTts.setPitch(1.0);

    flutterTts.setCompletionHandler(() {
      _isSpeaking = false;
    });
  }

  Future<void> triggerAlarm() async {
    // 1. Fire TTS immediately — only if enabled in user settings
    if (AppConfig().voiceAlertsEnabled && !_isSpeaking) {
      _isSpeaking = true;
      flutterTts.speak("Alert Edge Warning. Wake up!"); // No await — instant
    }

    // 2. Hardware alarm — rate-limited & conditionally enabled
    if (AppConfig().hardwareBuzzerEnabled && !_hardwareAlarmActive) {
      _hardwareAlarmActive = true;
      _triggerHardwareAsync();

      // Release the gate after cooldown
      Future.delayed(_hardwareCooldown, () {
        _hardwareAlarmActive = false;
      });
    }

    // 3. Log event
    await DatabaseHelper.instance.insertLog('Drowsiness Detected (Alarm Triggered)');
  }

  /// Sends the alarm request to ESP32 with retry logic.
  /// Runs entirely in the background — never blocks the UI or TTS.
  void _triggerHardwareAsync() async {
    for (int attempt = 1; attempt <= 3; attempt++) {
      try {
        await http.get(Uri.parse(alarmUrl)).timeout(const Duration(seconds: 4));
        print("Hardware Alarm Triggered (attempt $attempt)");
        return; // Success — stop retrying
      } catch (e) {
        print("ESP32 attempt $attempt failed: $e");
        if (attempt < 3) await Future.delayed(const Duration(milliseconds: 200));
      }
    }
    print("ESP32 hardware alarm unreachable after 3 attempts.");
  }
}
