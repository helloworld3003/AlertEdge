import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart' as ph;

/// GpsSpeedService — Hardware GPS speed tracker.
///
/// - Uses [LocationAccuracy.bestForNavigation] to force the dedicated GPS chip
///   (identical to "Where is my train" strategy — offline, no network needed).
/// - Broadcasts speed in km/h via [speedStream].
/// - Handles the Android 11+ two-step permission flow (foreground → background).
/// - Returns -1.0 when GPS lock is lost or location permission is denied.
class GpsSpeedService {
  static const double _noSignal = -1.0;

  final StreamController<double> _speedController =
      StreamController<double>.broadcast();

  /// Live speed updates in km/h. Emits -1.0 when GPS lock is lost.
  Stream<double> get speedStream => _speedController.stream;

  StreamSubscription<Position>? _positionSub;
  double _lastSpeedKmh = _noSignal;
  double get currentSpeed => _lastSpeedKmh;

  bool _isRunning = false;

  // ─── Public API ────────────────────────────────────────────────────────────

  /// Requests the required permissions and starts streaming GPS speed.
  /// Must be called from the main isolate (UI thread).
  Future<bool> start() async {
    if (_isRunning) return true;

    final granted = await _requestPermissions();
    if (!granted) {
      debugPrint('[GPS] Permission denied. Speed tracking disabled.');
      _speedController.add(_noSignal);
      return false;
    }

    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      debugPrint('[GPS] Location services disabled on device.');
      _speedController.add(_noSignal);
      return false;
    }

    _isRunning = true;

    const locationSettings = LocationSettings(
      accuracy: LocationAccuracy.bestForNavigation, // Forces dedicated GPS chip
      distanceFilter: 0, // Every update, even if stationary
    );

    _positionSub = Geolocator.getPositionStream(
      locationSettings: locationSettings,
    ).listen(
      (Position position) {
        // position.speed is in m/s — convert to km/h
        // Negative speed means GPS lock lost (hardware chip signal too weak)
        final double kmh = position.speed >= 0
            ? position.speed * 3.6
            : _noSignal;

        _lastSpeedKmh = kmh;

        if (!_speedController.isClosed) {
          _speedController.add(kmh);
        }
      },
      onError: (e) {
        debugPrint('[GPS] Position stream error: $e');
        _lastSpeedKmh = _noSignal;
        if (!_speedController.isClosed) {
          _speedController.add(_noSignal);
        }
      },
      cancelOnError: false, // Keep stream alive through temporary errors
    );

    debugPrint('[GPS] Hardware GPS speed tracking started.');
    return true;
  }

  /// Stops the GPS stream and resets speed to no-signal.
  void stop() {
    _positionSub?.cancel();
    _positionSub = null;
    _isRunning = false;
    _lastSpeedKmh = _noSignal;
    debugPrint('[GPS] Speed tracking stopped.');
  }

  void dispose() {
    stop();
    _speedController.close();
  }

  // ─── Permission Handling ───────────────────────────────────────────────────

  /// Android 11+ two-step permission flow:
  ///   Step 1: Request ACCESS_FINE_LOCATION (foreground precision GPS).
  ///   Step 2: Only if granted, request ACCESS_BACKGROUND_LOCATION.
  ///
  /// Without step 2, GPS is killed the moment the screen turns off.
  Future<bool> _requestPermissions() async {
    // Step 1 — Foreground precise location
    final foregroundStatus = await ph.Permission.location.request();
    if (!foregroundStatus.isGranted) {
      debugPrint('[GPS] Foreground location denied.');
      return false;
    }

    // Step 2 — Background location (Android 10+)
    // On Android < 10 this permission doesn't exist, so just return true.
    final backgroundStatus = await ph.Permission.locationAlways.request();
    if (!backgroundStatus.isGranted) {
      // Background denied is non-fatal — GPS will work in foreground only.
      // The user may need to go to Settings > App > Permissions > Location > "Allow all the time".
      debugPrint('[GPS] Background location denied. GPS active in foreground only.');
    } else {
      debugPrint('[GPS] Background location granted.');
    }

    // Foreground grant is sufficient to start — return true either way.
    return true;
  }
}
