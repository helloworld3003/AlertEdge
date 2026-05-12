import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Central config singleton.
/// All services read ESP32 URLs from here — change the IP once, everything updates.
class AppConfig extends ChangeNotifier {
  static final AppConfig _instance = AppConfig._internal();
  factory AppConfig() => _instance;
  AppConfig._internal();

  static const _kIpKey = 'esp32_ip';
  static const _kVoiceKey = 'voice_alerts';
  static const _kBuzzerKey = 'hw_buzzer';
  static const _kThresholdKey = 'ear_thresh';
  static const _kFramesKey = 'cons_frames';

  static const _kDefaultIp = '10.208.89.81';
  static const _kDefaultVoice = true;
  static const _kDefaultBuzzer = true;
  static const _kDefaultThresh = 0.22;
  static const _kDefaultFrames = 5;

  String _ip = _kDefaultIp;
  bool _voiceAlertsEnabled = _kDefaultVoice;
  bool _hardwareBuzzerEnabled = _kDefaultBuzzer;
  double _earThreshold = _kDefaultThresh;
  int _consecutiveFrames = _kDefaultFrames;

  /// The raw IP address (e.g. "10.208.89.81")
  String get ip => _ip;
  bool get voiceAlertsEnabled => _voiceAlertsEnabled;
  bool get hardwareBuzzerEnabled => _hardwareBuzzerEnabled;
  double get earThreshold => _earThreshold;
  int get consecutiveFrames => _consecutiveFrames;

  /// Port 80 — camera web UI
  String get baseUrl => 'http://$_ip';

  /// Port 81 — MJPEG stream
  String get streamUrl => 'http://$_ip:81/stream';

  /// Port 82 — alarm / flash
  String get alarmUrl       => 'http://$_ip:82/alarm';
  String get toggleFlashUrl => 'http://$_ip:82/toggle_flash';

  /// Load persisted values on app start. Call once from main() before runApp.
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _ip = prefs.getString(_kIpKey) ?? _kDefaultIp;
    _voiceAlertsEnabled = prefs.getBool(_kVoiceKey) ?? _kDefaultVoice;
    _hardwareBuzzerEnabled = prefs.getBool(_kBuzzerKey) ?? _kDefaultBuzzer;
    _earThreshold = prefs.getDouble(_kThresholdKey) ?? _kDefaultThresh;
    _consecutiveFrames = prefs.getInt(_kFramesKey) ?? _kDefaultFrames;
  }

  /// Persist a new IP and notify all listeners.
  Future<void> setIp(String newIp) async {
    final clean = newIp.trim().replaceAll(RegExp(r'/\d+$'), ''); // strip /24 notation
    if (clean == _ip) return;
    _ip = clean;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kIpKey, clean);
    notifyListeners();
  }

  Future<void> setVoiceAlerts(bool val) async {
    if (val == _voiceAlertsEnabled) return;
    _voiceAlertsEnabled = val;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kVoiceKey, val);
    notifyListeners();
  }

  Future<void> setHardwareBuzzer(bool val) async {
    if (val == _hardwareBuzzerEnabled) return;
    _hardwareBuzzerEnabled = val;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kBuzzerKey, val);
    notifyListeners();
  }

  Future<void> setEarThreshold(double val) async {
    if (val == _earThreshold) return;
    _earThreshold = val;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_kThresholdKey, val);
    notifyListeners();
  }

  Future<void> setConsecutiveFrames(int val) async {
    if (val == _consecutiveFrames) return;
    _consecutiveFrames = val;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kFramesKey, val);
    notifyListeners();
  }
}
