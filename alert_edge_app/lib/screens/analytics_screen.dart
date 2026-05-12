import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'dart:math';
import '../theme/app_theme.dart';
import '../services/database_helper.dart';

class AnalyticsScreen extends StatefulWidget {
  const AnalyticsScreen({super.key});

  @override
  State<AnalyticsScreen> createState() => _AnalyticsScreenState();
}

class _AnalyticsScreenState extends State<AnalyticsScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _scoreAnimController;
  late Animation<double> _scoreAnimation;
  List<Map<String, dynamic>> _logs = [];
  int _safetyScore = 92;

  @override
  void initState() {
    super.initState();
    _scoreAnimController = AnimationController(
      duration: const Duration(milliseconds: 1500),
      vsync: this,
    );
    _scoreAnimation = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(parent: _scoreAnimController, curve: Curves.easeOutCubic),
    );
    _scoreAnimController.forward();
    _loadLogs();
  }

  Future<void> _loadLogs() async {
    final logs = await DatabaseHelper.instance.queryAllLogs();
    if (mounted) {
      setState(() {
        _logs = logs;
        // Calculate safety score based on alerts (more alerts = lower score)
        _safetyScore = max(0, 100 - (logs.length * 8));
      });
    }
  }

  @override
  void dispose() {
    _scoreAnimController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(gradient: AppTheme.backgroundGradient),
      child: SafeArea(
        child: Column(
          children: [
            _buildHeader(),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                children: [
                  _buildSafetyScoreCard(),
                  const SizedBox(height: 16),
                  _buildTripSummaryGrid(),
                  const SizedBox(height: 16),
                  _buildEarChart(),
                  const SizedBox(height: 16),
                  _buildRecentAlerts(),
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      child: Row(
        children: [
          Text("Analytics", style: AppTheme.headlineMd),
          const Spacer(),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.06),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Colors.white.withOpacity(0.1)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.calendar_today, size: 14, color: AppTheme.onSurfaceVariant),
                const SizedBox(width: 6),
                Text("Today", style: AppTheme.bodySm.copyWith(fontSize: 13)),
                const SizedBox(width: 4),
                const Icon(Icons.keyboard_arrow_down, size: 16, color: AppTheme.onSurfaceVariant),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSafetyScoreCard() {
    Color scoreColor = _safetyScore >= 80
        ? AppTheme.primary
        : _safetyScore >= 50
            ? AppTheme.warning
            : AppTheme.danger;
    String scoreLabel = _safetyScore >= 80
        ? "Excellent - No critical alerts"
        : _safetyScore >= 50
            ? "Fair - Some warnings detected"
            : "Poor - Multiple alerts detected";

    return Container(
      padding: const EdgeInsets.all(28),
      decoration: AppTheme.glassCard,
      child: Column(
        children: [
          AnimatedBuilder(
            animation: _scoreAnimation,
            builder: (context, child) {
              return SizedBox(
                width: 180,
                height: 180,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    // Background ring
                    SizedBox.expand(
                      child: CircularProgressIndicator(
                        value: 1.0,
                        strokeWidth: 10,
                        color: Colors.white.withOpacity(0.06),
                        strokeCap: StrokeCap.round,
                      ),
                    ),
                    // Animated progress ring
                    SizedBox.expand(
                      child: CircularProgressIndicator(
                        value: (_safetyScore / 100) * _scoreAnimation.value,
                        strokeWidth: 10,
                        color: scoreColor,
                        strokeCap: StrokeCap.round,
                        backgroundColor: Colors.transparent,
                      ),
                    ),
                    // Glow effect
                    Container(
                      width: 140,
                      height: 140,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: scoreColor.withOpacity(0.1 * _scoreAnimation.value),
                            blurRadius: 40,
                            spreadRadius: 10,
                          ),
                        ],
                      ),
                    ),
                    // Score text
                    Text(
                      "${(_safetyScore * _scoreAnimation.value).toInt()}%",
                      style: AppTheme.telemetryNum.copyWith(
                        color: scoreColor,
                        fontSize: 48,
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
          const SizedBox(height: 20),
          Text("Driver Safety Score", style: AppTheme.headlineMd.copyWith(fontSize: 22)),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                _safetyScore >= 80 ? Icons.check_circle : Icons.warning_amber,
                color: scoreColor,
                size: 18,
              ),
              const SizedBox(width: 6),
              Text(
                scoreLabel,
                style: AppTheme.bodySm.copyWith(color: scoreColor, fontSize: 14),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildTripSummaryGrid() {
    return Column(
      children: [
        Row(
          children: [
            Expanded(child: _buildSummaryCard(
              icon: Icons.route,
              label: "TOTAL DISTANCE",
              value: "—",
              unit: "km",
              color: AppTheme.primary,
            )),
            const SizedBox(width: 12),
            Expanded(child: _buildSummaryCard(
              icon: Icons.schedule,
              label: "DRIVE TIME",
              value: "—",
              unit: "",
              color: AppTheme.onSurfaceVariant,
            )),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(child: _buildSummaryCard(
              icon: Icons.speed,
              label: "AVG SPEED",
              value: "—",
              unit: "km/h",
              color: AppTheme.secondary,
            )),
            const SizedBox(width: 12),
            Expanded(child: _buildSummaryCard(
              icon: Icons.speed,
              label: "MAX SPEED",
              value: "—",
              unit: "km/h",
              color: AppTheme.warning,
            )),
          ],
        ),
      ],
    );
  }

  Widget _buildSummaryCard({
    required IconData icon,
    required String label,
    required String value,
    required String unit,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: AppTheme.glassCardSmall,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 22),
          const SizedBox(height: 6),
          Text(label, style: AppTheme.labelCaps.copyWith(fontSize: 10)),
          const SizedBox(height: 4),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(value, style: AppTheme.telemetryNumSm.copyWith(fontSize: 26)),
              if (unit.isNotEmpty) ...[
                const SizedBox(width: 4),
                Text(unit, style: AppTheme.bodySm.copyWith(fontSize: 13)),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildEarChart() {
    // Generate sample EAR data for visualization
    final random = Random(42);
    final List<FlSpot> spots = List.generate(30, (i) {
      double base = 0.30 + random.nextDouble() * 0.06 - 0.03;
      // Add a dip around index 15 to show a drowsiness event
      if (i >= 14 && i <= 17) {
        base = 0.18 + random.nextDouble() * 0.04;
      }
      return FlSpot(i.toDouble(), base.clamp(0.10, 0.40));
    });

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: AppTheme.glassCard,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text("Eye Aspect Ratio (Live)", style: AppTheme.bodyLg.copyWith(
                      fontWeight: FontWeight.w600)),
                    Text("Last 30 minutes of telemetry tracking",
                        style: AppTheme.bodySm.copyWith(fontSize: 12)),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: AppTheme.primary.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppTheme.primary.withOpacity(0.3)),
                ),
                child: Text(
                  "0.31",
                  style: AppTheme.telemetryNumSm.copyWith(
                    color: AppTheme.primary,
                    fontSize: 20,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          SizedBox(
            height: 180,
            child: LineChart(
              LineChartData(
                gridData: FlGridData(
                  show: true,
                  horizontalInterval: 0.05,
                  getDrawingHorizontalLine: (value) => FlLine(
                    color: Colors.white.withOpacity(0.05),
                    strokeWidth: 1,
                  ),
                  getDrawingVerticalLine: (value) => FlLine(
                    color: Colors.white.withOpacity(0.03),
                    strokeWidth: 1,
                  ),
                ),
                titlesData: FlTitlesData(show: false),
                borderData: FlBorderData(show: false),
                minX: 0,
                maxX: 29,
                minY: 0.10,
                maxY: 0.40,
                lineBarsData: [
                  LineChartBarData(
                    spots: spots,
                    isCurved: true,
                    color: AppTheme.primary,
                    barWidth: 2.5,
                    dotData: const FlDotData(show: false),
                    belowBarData: BarAreaData(
                      show: true,
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          AppTheme.primary.withOpacity(0.15),
                          AppTheme.primary.withOpacity(0.0),
                        ],
                      ),
                    ),
                  ),
                ],
                // Danger zone line
                extraLinesData: ExtraLinesData(
                  horizontalLines: [
                    HorizontalLine(
                      y: 0.20,
                      color: AppTheme.danger.withOpacity(0.4),
                      strokeWidth: 1,
                      dashArray: [8, 4],
                      label: HorizontalLineLabel(
                        show: true,
                        alignment: Alignment.topLeft,
                        style: AppTheme.labelCaps.copyWith(
                          color: AppTheme.danger.withOpacity(0.7),
                          fontSize: 9,
                        ),
                        labelResolver: (_) => "DANGER",
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRecentAlerts() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text("Recent Alerts", style: AppTheme.bodyLg.copyWith(fontWeight: FontWeight.w600)),
        const SizedBox(height: 12),
        if (_logs.isEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(24),
            decoration: AppTheme.glassCardSmall,
            child: Center(
              child: Text("No alerts recorded yet.",
                  style: AppTheme.bodySm),
            ),
          )
        else
          ..._logs.take(5).map((log) => _buildAlertItem(log)),
      ],
    );
  }

  Widget _buildAlertItem(Map<String, dynamic> log) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(14),
      decoration: AppTheme.glassCardSmall,
      child: Row(
        children: [
          Container(
            width: 10,
            height: 10,
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
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  log['status'] ?? 'Unknown',
                  style: AppTheme.bodyMd.copyWith(fontSize: 14),
                ),
                Text(
                  log['timestamp'] ?? '',
                  style: AppTheme.bodySm.copyWith(fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
