import 'dart:async';
import 'dart:typed_data';
import 'package:http/http.dart' as http;

class MjpegStreamer {
  final String streamUrl;
  http.Client? _client;
  StreamSubscription? _subscription;

  /// Whether the USER wants the stream running (armed toggle).
  /// Stays true through network drops — only set to false by stop()/dispose().
  bool _shouldBeRunning = false;

  /// Whether a connection attempt is currently active.
  bool _isConnected = false;

  /// Exponential backoff: 2s, 4s, 8s, capped at 16s.
  int _retryDelaySeconds = 2;
  static const int _maxRetryDelaySeconds = 16;

  Timer? _reconnectTimer;

  final Stopwatch _displayThrottle = Stopwatch();

  // Display stream: throttled to ~10 FPS to keep UI smooth
  final StreamController<Uint8List> _frameController =
      StreamController<Uint8List>.broadcast();
  Stream<Uint8List> get stream => _frameController.stream;

  // ML stream: EVERY frame, no throttle — ML Kit should see closed eyes ASAP
  final StreamController<Uint8List> _mlController =
      StreamController<Uint8List>.broadcast();
  Stream<Uint8List> get mlStream => _mlController.stream;

  MjpegStreamer({required this.streamUrl});

  /// Called by the armed toggle — sets intent and begins connection.
  void start() {
    if (_shouldBeRunning) return; // already intended to run
    _shouldBeRunning = true;
    _retryDelaySeconds = 2; // reset backoff on fresh start
    _connect();
  }

  /// Called by the armed toggle (off) or dispose — cancels intent and all retries.
  void stop() {
    _shouldBeRunning = false;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _disconnect();
  }

  void dispose() {
    stop();
    _frameController.close();
    _mlController.close();
  }

  // ─── Internal connection logic ────────────────────────────────────────────

  void _disconnect() {
    _isConnected = false;
    _subscription?.cancel();
    _subscription = null;
    _client?.close();
    _client = null;
  }

  Future<void> _connect() async {
    // Guard: don't double-connect, don't connect if user stopped
    if (_isConnected || !_shouldBeRunning) return;
    _isConnected = true;

    _client = http.Client();

    try {
      final request = http.Request('GET', Uri.parse(streamUrl));
      final response = await _client!.send(request);

      // Successful connection — reset backoff
      _retryDelaySeconds = 2;

      List<int> buffer = [];
      _displayThrottle..reset()..start();

      _subscription = response.stream.listen(
        (List<int> chunk) {
          if (!_shouldBeRunning) {
            _subscription?.cancel();
            return;
          }

          buffer.addAll(chunk);

          // Process all complete JPEG frames currently in the buffer
          while (buffer.isNotEmpty) {
            int startIndex = _findSequence(buffer, [0xFF, 0xD8]);
            int endIndex   = _findSequence(buffer, [0xFF, 0xD9]);

            if (startIndex == -1 && endIndex == -1) {
              // Neither marker found — keep last 2 bytes in case a marker is split
              if (buffer.length > 2) buffer.removeRange(0, buffer.length - 2);
              break;
            }

            if (startIndex != -1 && (endIndex == -1 || endIndex < startIndex)) {
              if (endIndex != -1 && endIndex < startIndex) {
                // Stale end marker before our start — discard garbage
                buffer.removeRange(0, startIndex);
                continue;
              }
              // Have start but no end yet — protect against unbounded growth
              if (buffer.length > 1000000) buffer.clear();
              break;
            }

            if (startIndex != -1 && endIndex != -1 && endIndex > startIndex) {
              // Complete frame extracted
              final frameBytes =
                  Uint8List.fromList(buffer.sublist(startIndex, endIndex + 2));

              // Always emit to ML stream (unthrottled — detect drowsiness ASAP)
              if (!_mlController.isClosed) _mlController.add(frameBytes);

              // Throttle display to ~10 FPS
              if (_displayThrottle.elapsedMilliseconds > 100) {
                if (!_frameController.isClosed) _frameController.add(frameBytes);
                _displayThrottle.reset();
              }

              buffer.removeRange(0, endIndex + 2);
            } else {
              buffer.clear();
              break;
            }
          }
        },
        onError: (e) {
          print('[MjpegStreamer] Stream error: $e');
          _disconnect();
          _scheduleReconnect();
        },
        onDone: () {
          // ESP32 closed the connection (e.g. reboot, Wi-Fi handoff)
          print('[MjpegStreamer] Stream closed by server.');
          _disconnect();
          _scheduleReconnect();
        },
        cancelOnError: true,
      );
    } catch (e) {
      print('[MjpegStreamer] Connection failed: $e');
      _isConnected = false;
      _client?.close();
      _client = null;
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    if (!_shouldBeRunning) return; // user stopped — don't retry

    print('[MjpegStreamer] Reconnecting in ${_retryDelaySeconds}s…');

    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(Duration(seconds: _retryDelaySeconds), () {
      if (_shouldBeRunning && !_isConnected) {
        _connect();
      }
    });

    // Exponential backoff, capped at _maxRetryDelaySeconds
    _retryDelaySeconds = (_retryDelaySeconds * 2).clamp(2, _maxRetryDelaySeconds);
  }

  // ─── JPEG boundary scanner ────────────────────────────────────────────────

  int _findSequence(List<int> data, List<int> sequence) {
    if (data.isEmpty || sequence.isEmpty || sequence.length > data.length) {
      return -1;
    }
    for (int i = 0; i <= data.length - sequence.length; i++) {
      bool found = true;
      for (int j = 0; j < sequence.length; j++) {
        if (data[i + j] != sequence[j]) {
          found = false;
          break;
        }
      }
      if (found) return i;
    }
    return -1;
  }
}
