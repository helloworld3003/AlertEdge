import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'services/background_task_handler.dart';
import 'theme/app_theme.dart';
import 'screens/dashboard_screen.dart';
import 'screens/analytics_screen.dart';
import 'screens/records_screen.dart';
import 'screens/profile_screen.dart';
import 'services/mjpeg_streamer.dart';
import 'services/drowsiness_detector.dart';
import 'services/alarm_service.dart';
import 'services/app_config.dart';
import 'services/gps_speed_service.dart';

// ─── Entry point registered with flutter_foreground_task ─────────────────────
// startCallback is defined in background_task_handler.dart
// It sets BackgroundDetectionTask as the handler for the background isolate.


// ─────────────────────────────────────────────────────────────────────────────
// Foreground service helpers
// ─────────────────────────────────────────────────────────────────────────────
void _initForegroundTask() {
  FlutterForegroundTask.init(
    androidNotificationOptions: AndroidNotificationOptions(
      channelId: 'alertedge_monitor',
      channelName: 'AlertEdge Monitoring',
      channelDescription: 'Keeps drowsiness detection active in background',
      channelImportance: NotificationChannelImportance.HIGH,
      priority: NotificationPriority.HIGH,
    ),
    iosNotificationOptions: const IOSNotificationOptions(
      showNotification: false,
    ),
    foregroundTaskOptions: ForegroundTaskOptions(
      eventAction: ForegroundTaskEventAction.repeat(400), // poll /capture every 400ms
      autoRunOnBoot: false,
      autoRunOnMyPackageReplaced: false,
      allowWakeLock: true,   // CPU wakelock
      allowWifiLock: true,   // Wi-Fi lock — keeps TCP alive (critical for stream)
    ),
  );
}

Future<void> _startForegroundService() async {
  try {
    // Critical: Request notification permission via the plugin's own native helper
    await FlutterForegroundTask.requestNotificationPermission();

    if (await FlutterForegroundTask.isRunningService) return;

    await FlutterForegroundTask.startService(
      serviceId: 1001,
      serviceTypes: [
        ForegroundServiceTypes.connectedDevice,
        ForegroundServiceTypes.dataSync,
      ],
      notificationTitle: '🛡️ AlertEdge Active',
      notificationText: 'Drowsiness monitoring is running',
      notificationIcon: const NotificationIcon(
        metaDataName: 'org.lucasalfare.flutter_foreground_task.NOTIFICATION_ICON',
      ),
      notificationButtons: [],
      callback: startCallback,
    );
    debugPrint('[Service] Start service called.');
  } catch (e, stack) {
    debugPrint('[Service] Error starting service: $e\n$stack');
  }
}

Future<void> _stopForegroundService() async {
  await FlutterForegroundTask.stopService();
}

// ─────────────────────────────────────────────────────────────────────────────
// App entry point
// ─────────────────────────────────────────────────────────────────────────────
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Mandatory for v9.x communication port initialization
  FlutterForegroundTask.initCommunicationPort();

  await AppConfig().load();

  // Disable google_fonts network fetching — phone is on ESP32 hotspot (no internet).
  // With this off, it uses the bundled font assets. Zero network spam.
  GoogleFonts.config.allowRuntimeFetching = false;

  // Configure the foreground service (must be done before starting it)
  _initForegroundTask();

  runApp(const AlertEdgeApp());
}

class AlertEdgeApp extends StatelessWidget {
  const AlertEdgeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AlertEdge',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.darkTheme,
      home: const MainShell(),
    );
  }
}

/// Main shell with bottom navigation — 4 tabs: Dashboard, Analytics, Records, Profile
class MainShell extends StatefulWidget {
  const MainShell({super.key});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _currentIndex = 0;
  bool _isArmed = false;
  bool _drowsinessActive = false;

  late MjpegStreamer _streamer;
  String _currentStreamIp = ''; // Tracking current bound IP to prevent stream reset on non-IP setting changes
  final DrowsinessDetector _detector = DrowsinessDetector();
  final AlarmService _alarmService = AlarmService();
  final GpsSpeedService _gpsService = GpsSpeedService();

  @override
  void initState() {
    super.initState();
    final ip = AppConfig().ip;
    _currentStreamIp = ip;
    _streamer = MjpegStreamer(streamUrl: AppConfig().streamUrl);
    _requestPermissions();
    _detector.init();
    AppConfig().addListener(_onConfigChanged);
  }

  void _onConfigChanged() {
    final newIp = AppConfig().ip;
    if (newIp != _currentStreamIp) {
      debugPrint('[MainShell] IP Changed: $_currentStreamIp -> $newIp. Recreating streamer.');
      _currentStreamIp = newIp;
      _streamer.dispose();
      setState(() {
        _streamer = MjpegStreamer(streamUrl: AppConfig().streamUrl);
      });
    }
  }

  Future<void> _requestPermissions() async {
    // Request notification permission on Android 13+ (required for foreground service notification)
    final notificationStatus = await Permission.notification.request();

    if ((notificationStatus.isDenied || notificationStatus.isPermanentlyDenied) && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text(
              'Notification permission is required to run the foreground monitoring service.'),
          backgroundColor: AppTheme.danger,
          duration: const Duration(seconds: 6),
          action: SnackBarAction(
            label: 'SETTINGS',
            textColor: Colors.white,
            onPressed: () {
              openAppSettings();
            },
          ),
        ),
      );
    }

    final statuses = await [
      Permission.location,
      Permission.locationWhenInUse,
      Permission.nearbyWifiDevices,
    ].request();

    final locationDenied = statuses[Permission.location]?.isDenied ?? true;
    if (locationDenied && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
              'Location permission is required to scan and connect to Wi-Fi networks.'),
          backgroundColor: Colors.redAccent,
          duration: Duration(seconds: 4),
        ),
      );
    }
  }

  /// Called when armed toggle changes.
  /// Starts/stops the Android foreground service and wakelock together.
  Future<void> _onArmedChanged(bool armed) async {
    if (armed) {
      final status = await Permission.notification.status;
      if (status.isDenied || status.isPermanentlyDenied) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text(
                  'Please enable notification permissions first to allow background monitoring.'),
              backgroundColor: AppTheme.danger,
              duration: const Duration(seconds: 6),
              action: SnackBarAction(
                label: 'ENABLE',
                textColor: Colors.white,
                onPressed: () {
                  openAppSettings();
                },
              ),
            ),
          );
        }
        return;
      }
    }

    setState(() => _isArmed = armed);

    if (armed) {
      // Start foreground service — this is what keeps the Dart VM alive
      // when the user opens another app. Android cannot kill a process
      // that holds an active foreground service.
      await _startForegroundService();
      // Also hold a wakelock so the CPU doesn't sleep mid-detection.
      WakelockPlus.enable();
      // Start GPS speed tracking — requests permissions automatically
      _gpsService.start();
    } else {
      await _stopForegroundService();
      WakelockPlus.disable();
      _gpsService.stop();
    }
  }

  @override
  void dispose() {
    AppConfig().removeListener(_onConfigChanged);
    _streamer.dispose();
    _detector.dispose();
    _gpsService.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // WithForegroundTask keeps the foreground service bound to the widget tree.
    // When the activity is destroyed (app closed), it keeps the service alive
    // until stopService() is explicitly called.
    return WithForegroundTask(
      child: Scaffold(
        body: IndexedStack(
          index: _currentIndex,
          children: [
            DashboardScreen(
              streamer: _streamer,
              detector: _detector,
              alarmService: _alarmService,
              gpsService: _gpsService,
              isArmed: _isArmed,
              onArmedChanged: _onArmedChanged,
              onDrowsinessDetected: () {
                setState(() => _drowsinessActive = true);
                Future.delayed(const Duration(seconds: 10), () {
                  if (mounted) setState(() => _drowsinessActive = false);
                });
              },
            ),
            const AnalyticsScreen(),
            const RecordsScreen(),
            const ProfileScreen(),
          ],
        ),
        bottomNavigationBar: _buildBottomNav(),
      ),
    );
  }

  Widget _buildBottomNav() {
    final items = [
      _NavItem(icon: Icons.dashboard_rounded, label: "Dashboard"),
      _NavItem(icon: Icons.analytics_outlined, label: "Analytics"),
      _NavItem(icon: Icons.history_rounded, label: "Records"),
      _NavItem(icon: Icons.person_outline_rounded, label: "Profile"),
    ];

    return Container(
      decoration: BoxDecoration(
        color: AppTheme.surface.withOpacity(0.85),
        border: Border(
          top: BorderSide(color: Colors.white.withOpacity(0.06)),
        ),
      ),
      child: ClipRect(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: List.generate(items.length, (index) {
                  final item = items[index];
                  final isActive = _currentIndex == index;
                  final bool hasAlert = index == 0 && _drowsinessActive;

                  return GestureDetector(
                    onTap: () => setState(() => _currentIndex = index),
                    behavior: HitTestBehavior.opaque,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 250),
                      curve: Curves.easeOut,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 10),
                      decoration: BoxDecoration(
                        color: isActive
                            ? AppTheme.primary.withOpacity(0.1)
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Stack(
                            clipBehavior: Clip.none,
                            children: [
                              Icon(
                                item.icon,
                                size: 24,
                                color: isActive
                                    ? AppTheme.primary
                                    : AppTheme.onSurfaceVariant
                                        .withOpacity(0.6),
                              ),
                              if (hasAlert)
                                Positioned(
                                  right: -4,
                                  top: -4,
                                  child: Container(
                                    width: 8,
                                    height: 8,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: AppTheme.danger,
                                      boxShadow: [
                                        BoxShadow(
                                          color:
                                              AppTheme.danger.withOpacity(0.5),
                                          blurRadius: 6,
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            item.label,
                            style: GoogleFonts.spaceGrotesk(
                              fontSize: 11,
                              fontWeight:
                                  isActive ? FontWeight.w700 : FontWeight.w500,
                              color: isActive
                                  ? AppTheme.primary
                                  : AppTheme.onSurfaceVariant.withOpacity(0.6),
                              letterSpacing: 0.3,
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                }),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _NavItem {
  final IconData icon;
  final String label;
  const _NavItem({required this.icon, required this.label});
}
