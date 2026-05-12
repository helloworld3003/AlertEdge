import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import '../theme/app_theme.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import '../services/mjpeg_streamer.dart';
import '../services/drowsiness_detector.dart';
import '../services/alarm_service.dart';
import '../services/database_helper.dart';
import '../services/app_config.dart';
import '../services/gps_speed_service.dart';
import 'package:http/http.dart' as http;

class DashboardScreen extends StatefulWidget {
  final MjpegStreamer streamer;
  final DrowsinessDetector detector;
  final AlarmService alarmService;
  final GpsSpeedService gpsService;
  final bool isArmed;
  final ValueChanged<bool> onArmedChanged;
  final VoidCallback? onDrowsinessDetected;

  const DashboardScreen({
    super.key,
    required this.streamer,
    required this.detector,
    required this.alarmService,
    required this.gpsService,
    required this.isArmed,
    required this.onArmedChanged,
    this.onDrowsinessDetected,
  });

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  String _status = "System Disarmed";
  Color _statusColor = Colors.grey;
  double _currentEar = 0.0;
  int _alertCount = 0;
  late AnimationController _pulseController;
  late AnimationController _glowController;
  Timer? _clockTimer;
  Timer? _backgroundTransitionTimer;
  String _currentTime = '';
  Duration _tripDuration = Duration.zero;
  Timer? _tripTimer;
  bool _isDemoMode = false;
  bool _isFlashOn = false;
  double _currentSpeedKmh = -1.0; // -1 = no GPS lock
  StreamSubscription<double>? _gpsSub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _pulseController = AnimationController(
      duration: const Duration(milliseconds: 1500),
      vsync: this,
    )..repeat(reverse: true);

    _glowController = AnimationController(
      duration: const Duration(milliseconds: 2000),
      vsync: this,
    )..repeat(reverse: true);

    _updateClock();
    _clockTimer = Timer.periodic(const Duration(seconds: 1), (_) => _updateClock());

    // 1. Live Foreground ML Processing — fast-path eye tracking on the main isolate.
    // This immediately resolves 'Connecting to Camera...' when frames flow.
    bool isProcessingFrame = false;
    widget.streamer.mlStream.listen((Uint8List frame) async {
      if (widget.isArmed && mounted) {
        if (isProcessingFrame) return; // Drop frame if previous is still processing to avoid queue lag
        isProcessingFrame = true;
        try {
          bool? drowsinessDetected = await widget.detector.processFrame(frame);
          if (drowsinessDetected == null) return;

          if (drowsinessDetected == true) {
            // Use live GPS speed; fall back to demo (30 km/h) or no-signal
            final double speed = _isDemoMode ? 30.0 : _currentSpeedKmh;
            if (speed > 10.0) {
              _alertCount++;
              setState(() {
                _status = "DROWSINESS DETECTED!";
                _statusColor = AppTheme.danger;
              });
              widget.alarmService.triggerAlarm();
              widget.onDrowsinessDetected?.call();
            } else {
              setState(() {
                _status = "PARKED - Alarm Suppressed";
                _statusColor = AppTheme.warning;
              });
            }
          } else {
            if (mounted) setState(() {
              _status = "Monitoring... EAR Active";
              _statusColor = AppTheme.primary;
            });
          }
        } finally {
          isProcessingFrame = false;
        }
      }
    });

    // 2. Background Isolate Callback — receives status from BackgroundDetectionTask when backgrounded.
    FlutterForegroundTask.addTaskDataCallback(_onBackgroundTaskData);
    // Let the background task know we are initially starting in the foreground
    FlutterForegroundTask.sendDataToTask({'state': 'foreground'});

    // 3. GPS Speed Stream — hardware GPS chip updates whenever speed changes.
    //    -1.0 means no lock (parked/indoor). Alarm is suppressed below 10 km/h.
    _gpsSub = widget.gpsService.speedStream.listen((double kmh) {
      if (mounted) setState(() => _currentSpeedKmh = kmh);
    });
  } // end initState


  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      if (widget.isArmed) {
        debugPrint('[Dashboard] App paused/backgrounded ($state). Gracefully stopping MJPEG stream.');
        widget.streamer.stop();
        // Cancel any existing background transition timer to avoid duplicate or race conditions
        _backgroundTransitionTimer?.cancel();
        // Give the ESP32-CAM 2 seconds to fully tear down and free up the stream socket
        // before the background task begins polling /capture
        _backgroundTransitionTimer = Timer(const Duration(seconds: 2), () {
          debugPrint('[Dashboard] 2s delay complete. Telling background task to activate polling.');
          FlutterForegroundTask.sendDataToTask({'state': 'background'});
        });
      }
    } else if (state == AppLifecycleState.resumed) {
      // Cancel the background transition timer immediately upon resume
      _backgroundTransitionTimer?.cancel();
      _backgroundTransitionTimer = null;

      if (widget.isArmed) {
        debugPrint('[Dashboard] App resumed. Gracefully restarting MJPEG stream.');
        widget.streamer.start();
        FlutterForegroundTask.sendDataToTask({'state': 'foreground'});
      }
    }
  }

  void _onBackgroundTaskData(Object data) {
    if (!mounted || !widget.isArmed) return;
    if (data is! Map) return;
    final status = data['status'] as String?;

    if (status == 'alert') {
      final double speed = _isDemoMode ? 30.0 : _currentSpeedKmh;
      if (speed > 10.0) {
        _alertCount++;
        setState(() {
          _status = "DROWSINESS DETECTED!";
          _statusColor = AppTheme.danger;
        });
        widget.onDrowsinessDetected?.call();
      } else {
        setState(() {
          _status = "PARKED - Alarm Suppressed";
          _statusColor = AppTheme.warning;
        });
      }
    } else if (status == 'ok') {
      if (mounted) setState(() {
        _status = "Monitoring... EAR Active";
        _statusColor = AppTheme.primary;
      });
    }
  }

  void _updateClock() {
    if (mounted) {
      setState(() {
        _currentTime = DateFormat('hh:mm a').format(DateTime.now());
      });
    }
  }

  void _handleArmedToggle(bool val) {
    widget.onArmedChanged(val);
    setState(() {
      if (val) {
        widget.streamer.start();
        _status = "Connecting to Camera...";
        _statusColor = AppTheme.warning;
        _tripDuration = Duration.zero;
        _tripTimer = Timer.periodic(const Duration(seconds: 1), (_) {
          if (mounted) {
            setState(() {
              _tripDuration += const Duration(seconds: 1);
            });
          }
        });
        // Let the background task know we are currently in the foreground
        Future.delayed(const Duration(milliseconds: 500), () {
          FlutterForegroundTask.sendDataToTask({'state': 'foreground'});
        });
      } else {
        widget.streamer.stop();
        _status = "System Disarmed";
        _statusColor = Colors.grey;
        _tripTimer?.cancel();
      }
    });
  }

  Future<void> _handleFlashToggle(bool val) async {
    setState(() => _isFlashOn = val);
    try {
      await http.get(Uri.parse(AppConfig().toggleFlashUrl))
          .timeout(const Duration(seconds: 5));
    } catch (e) {
      print("Flash toggle error: $e");
    }
  }

  Future<void> _connectToESP32() async {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Please manually connect to the "AlertEdge" Wi-Fi network in your device settings.'),
          backgroundColor: AppTheme.primary.withOpacity(0.9),
          duration: const Duration(seconds: 4),
        ),
      );
    }
  }

  String _formatDuration(Duration d) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    return '${twoDigits(d.inHours)}:${twoDigits(d.inMinutes.remainder(60))}:${twoDigits(d.inSeconds.remainder(60))}';
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pulseController.dispose();
    _glowController.dispose();
    _clockTimer?.cancel();
    _tripTimer?.cancel();
    _backgroundTransitionTimer?.cancel();
    _gpsSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final double streamHeight = MediaQuery.of(context).size.height * 0.38;
    return Container(
      decoration: const BoxDecoration(gradient: AppTheme.backgroundGradient),
      child: SafeArea(
        child: Column(
          children: [
            _buildHeader(),
            _buildStreamCard(streamHeight),
            const SizedBox(height: 10),
            // Scrollable bottom section — metrics + all controls
            Expanded(
              child: SingleChildScrollView(
                physics: const BouncingScrollPhysics(),
                child: Column(
                  children: [
                    _buildMetricsRow(),
                    const SizedBox(height: 10),
                    _buildControlPanel(),
                    const SizedBox(height: 16), // bottom padding
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
      child: Row(
        children: [
          // Brand icon
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: AppTheme.primary.withOpacity(0.5), width: 2),
            ),
            child: const Icon(Icons.sensors, color: AppTheme.primary, size: 20),
          ),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text("ALERTEDGE", style: AppTheme.brandTitle.copyWith(fontSize: 22)),
              Row(
                children: [
                  AnimatedBuilder(
                    animation: _pulseController,
                    builder: (context, child) {
                      return Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: widget.isArmed
                              ? AppTheme.primary.withOpacity(0.5 + _pulseController.value * 0.5)
                              : Colors.grey,
                          boxShadow: widget.isArmed
                              ? [BoxShadow(
                                  color: AppTheme.primary.withOpacity(0.3 * _pulseController.value),
                                  blurRadius: 6,
                                )]
                              : [],
                        ),
                      );
                    },
                  ),
                  const SizedBox(width: 6),
                  Text(
                    widget.isArmed ? "LIVE" : "OFFLINE",
                    style: AppTheme.labelCaps.copyWith(
                      color: widget.isArmed ? AppTheme.primary : Colors.grey,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ],
          ),
          const Spacer(),
          Text(
            _currentTime,
            style: AppTheme.bodySm.copyWith(color: AppTheme.onSurfaceVariant),
          ),
          const SizedBox(width: 12),
          IconButton(
            icon: const Icon(Icons.history, color: AppTheme.onSurface),
            onPressed: () => _showLogs(context),
          ),
        ],
      ),
    );
  }

  Widget _buildStreamCard(double height) {
    return SizedBox(
      height: height,
      child: AnimatedBuilder(
        animation: _glowController,
        builder: (context, child) {
          return Container(
            margin: const EdgeInsets.symmetric(horizontal: 24),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.05),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(
                color: widget.isArmed
                    ? AppTheme.primary.withOpacity(0.2 + _glowController.value * 0.3)
                    : Colors.white.withOpacity(0.1),
                width: widget.isArmed ? 1.5 : 1,
              ),
              boxShadow: widget.isArmed
                  ? [
                      BoxShadow(
                        color: AppTheme.primary.withOpacity(0.08 + _glowController.value * 0.12),
                        blurRadius: 30,
                        spreadRadius: -5,
                      ),
                    ]
                  : [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.3),
                        blurRadius: 20,
                        offset: const Offset(0, 10),
                      ),
                    ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(24),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // Camera feed
                  StreamBuilder<Uint8List>(
                    stream: widget.streamer.stream,
                    builder: (context, snapshot) {
                      if (snapshot.connectionState == ConnectionState.waiting && widget.isArmed) {
                        return const Center(
                          child: CircularProgressIndicator(color: AppTheme.primary),
                        );
                      }
                      if (!snapshot.hasData) {
                        return Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.videocam_off, size: 64,
                                  color: Colors.white.withOpacity(0.2)),
                              const SizedBox(height: 16),
                              Text("Stream Offline",
                                  style: AppTheme.bodySm.copyWith(
                                    color: Colors.white.withOpacity(0.4),
                                  )),
                            ],
                          ),
                        );
                      }
                      return Image.memory(
                        snapshot.data!,
                        gaplessPlayback: true,
                        fit: BoxFit.cover,
                      );
                    },
                  ),
                  // Status overlay
                  Positioned(
                    bottom: 16,
                    left: 16,
                    right: 16,
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.6),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: Colors.white.withOpacity(0.08)),
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 10,
                            height: 10,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: _statusColor,
                              boxShadow: [
                                BoxShadow(
                                  color: _statusColor.withOpacity(0.5),
                                  blurRadius: 8,
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              _status,
                              style: GoogleFonts.inter(
                                color: Colors.white,
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                              decoration: BoxDecoration(
                                color: const Color(0xFF1A237E).withOpacity(0.8),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(Icons.dark_mode, color: Colors.white, size: 14),
                                  const SizedBox(width: 4),
                                  Text(
                                    'Night Mode',
                                    style: GoogleFonts.spaceGrotesk(
                                      color: Colors.white,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildMetricsRow() {
    return SizedBox(
      height: 100,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 24),
        children: [
          _buildMetricCard(
            icon: Icons.speed,
            iconColor: AppTheme.secondary,
            value: _isDemoMode
                ? "30"
                : (_currentSpeedKmh < 0 ? "--" : _currentSpeedKmh.toStringAsFixed(0)),
            unit: "km/h",
            label: "SPEED",
            accentColor: AppTheme.secondary,
          ),
          const SizedBox(width: 12),
          _buildMetricCard(
            icon: Icons.timer_outlined,
            iconColor: AppTheme.onSurfaceVariant,
            value: _formatDuration(_tripDuration),
            unit: "",
            label: "TRIP TIME",
            accentColor: AppTheme.onSurfaceVariant,
          ),
          const SizedBox(width: 12),
          _buildMetricCard(
            icon: Icons.visibility,
            iconColor: _currentEar < AppConfig().earThreshold
                ? AppTheme.danger
                : AppTheme.primary,
            value: _currentEar > 0 ? _currentEar.toStringAsFixed(2) : "—",
            unit: "",
            label: "EAR SCORE",
            accentColor: _currentEar < AppConfig().earThreshold
                ? AppTheme.danger
                : AppTheme.primary,
          ),
          const SizedBox(width: 12),
          _buildMetricCard(
            icon: Icons.warning_amber_rounded,
            iconColor: _alertCount > 0 ? AppTheme.danger : AppTheme.onSurfaceVariant,
            value: "$_alertCount",
            unit: "",
            label: "ALERTS",
            accentColor: _alertCount > 0 ? AppTheme.danger : AppTheme.onSurfaceVariant,
          ),
        ],
      ),
    );
  }

  Widget _buildMetricCard({
    required IconData icon,
    required Color iconColor,
    required String value,
    required String unit,
    required String label,
    required Color accentColor,
  }) {
    return Container(
      width: 140,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.04),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: accentColor.withOpacity(0.2),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: iconColor, size: 20),
          const Spacer(),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                value,
                style: AppTheme.telemetryNumSm.copyWith(
                  color: accentColor == AppTheme.onSurfaceVariant
                      ? AppTheme.onSurface
                      : accentColor,
                  fontSize: 24,
                ),
              ),
              if (unit.isNotEmpty) ...[
                const SizedBox(width: 4),
                Text(unit, style: AppTheme.bodySm.copyWith(fontSize: 12)),
              ],
            ],
          ),
          const SizedBox(height: 2),
          Text(label, style: AppTheme.labelCaps.copyWith(fontSize: 10)),
        ],
      ),
    );
  }

  Widget _buildControlPanel() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
      child: Column(
        children: [
          // System armed toggle
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            decoration: AppTheme.glassCardSmall,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text("System Armed",
                        style: AppTheme.bodyLg.copyWith(fontWeight: FontWeight.w600)),
                    Text("Real-time driver fatigue monitoring",
                        style: AppTheme.bodySm.copyWith(fontSize: 13)),
                  ],
                ),
                Switch.adaptive(
                  value: widget.isArmed,
                  activeColor: AppTheme.primary,
                  activeTrackColor: AppTheme.primary.withOpacity(0.3),
                  onChanged: _handleArmedToggle,
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          // Demo Mode toggle
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            decoration: AppTheme.glassCardSmall,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text("Demo Mode",
                        style: AppTheme.bodyLg.copyWith(fontWeight: FontWeight.w600)),
                    Text("Simulate driving speed (30 km/h)",
                        style: AppTheme.bodySm.copyWith(fontSize: 13)),
                  ],
                ),
                Switch.adaptive(
                  value: _isDemoMode,
                  activeColor: AppTheme.secondary,
                  activeTrackColor: AppTheme.secondary.withOpacity(0.3),
                  onChanged: (val) {
                    setState(() {
                      _isDemoMode = val;
                    });
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          // Flashlight toggle
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            decoration: AppTheme.glassCardSmall,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text("Manual Flashlight",
                        style: AppTheme.bodyLg.copyWith(fontWeight: FontWeight.w600)),
                    Text("Toggle ESP32 LED Flash",
                        style: AppTheme.bodySm.copyWith(fontSize: 13)),
                  ],
                ),
                Switch.adaptive(
                  value: _isFlashOn,
                  activeColor: Colors.amber,
                  activeTrackColor: Colors.amber.withOpacity(0.3),
                  onChanged: _handleFlashToggle,
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          // === LIGHTING MODE SELECTOR ===
          // Connect button
          GestureDetector(
            onTap: _connectToESP32,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 18),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [AppTheme.secondaryLight, AppTheme.secondary],
                ),
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(
                    color: AppTheme.secondary.withOpacity(0.3),
                    blurRadius: 20,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.link, color: Colors.white, size: 20),
                  const SizedBox(width: 10),
                  Text(
                    "CONNECT TO ALERTEDGE",
                    style: GoogleFonts.spaceGrotesk(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _showLogs(BuildContext context) async {
    final logs = await DatabaseHelper.instance.queryAllLogs();

    showModalBottomSheet(
      context: context,
      backgroundColor: AppTheme.surfaceContainer,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        return Container(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text("System Logs", style: AppTheme.headlineMd),
              const SizedBox(height: 16),
              Expanded(
                child: logs.isEmpty
                    ? Center(
                        child: Text("No records found.",
                            style: AppTheme.bodySm),
                      )
                    : ListView.builder(
                        itemCount: logs.length,
                        itemBuilder: (context, index) {
                          final log = logs[index];
                          return Container(
                            margin: const EdgeInsets.only(bottom: 8),
                            padding: const EdgeInsets.all(12),
                            decoration: AppTheme.glassCardSmall,
                            child: Row(
                              children: [
                                Container(
                                  width: 8,
                                  height: 8,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: AppTheme.danger,
                                    boxShadow: [
                                      BoxShadow(
                                        color: AppTheme.danger.withOpacity(0.5),
                                        blurRadius: 6,
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(log['status'],
                                          style: AppTheme.bodyMd),
                                      Text(log['timestamp'],
                                          style: AppTheme.bodySm.copyWith(fontSize: 12)),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}
