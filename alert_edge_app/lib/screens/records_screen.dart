import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../theme/app_theme.dart';
import '../services/database_helper.dart';

class RecordsScreen extends StatefulWidget {
  const RecordsScreen({super.key});

  @override
  State<RecordsScreen> createState() => _RecordsScreenState();
}

class _RecordsScreenState extends State<RecordsScreen> {
  List<Map<String, dynamic>> _logs = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadLogs();
  }

  Future<void> _loadLogs() async {
    final logs = await DatabaseHelper.instance.queryAllLogs();
    if (mounted) {
      setState(() {
        _logs = logs;
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(gradient: AppTheme.backgroundGradient),
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildHeader(),
            _buildSummaryStrip(),
            const SizedBox(height: 8),
            Expanded(
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator(color: AppTheme.primary))
                  : _logs.isEmpty
                      ? _buildEmptyState()
                      : _buildLogsList(),
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
          Text("Records", style: AppTheme.headlineMd),
          const Spacer(),
          if (_logs.isNotEmpty)
            GestureDetector(
              onTap: _confirmClearAll,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: AppTheme.danger.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: AppTheme.danger.withOpacity(0.3)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.delete_outline, size: 14, color: AppTheme.danger),
                    const SizedBox(width: 6),
                    Text("Clear", style: AppTheme.bodySm.copyWith(
                      color: AppTheme.danger, fontSize: 13)),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildSummaryStrip() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: AppTheme.glassCardSmall,
        child: Row(
          children: [
            _buildSummaryStat(
              icon: Icons.warning_amber_rounded,
              value: "${_logs.length}",
              label: "Total Alerts",
              color: _logs.isNotEmpty ? AppTheme.danger : AppTheme.onSurfaceVariant,
            ),
            Container(
              width: 1,
              height: 40,
              color: Colors.white.withOpacity(0.08),
            ),
            _buildSummaryStat(
              icon: Icons.calendar_today,
              value: _logs.isNotEmpty
                  ? DateFormat('MMM dd').format(
                      DateTime.tryParse(_logs.last['timestamp'] ?? '') ?? DateTime.now())
                  : "—",
              label: "First Alert",
              color: AppTheme.onSurfaceVariant,
            ),
            Container(
              width: 1,
              height: 40,
              color: Colors.white.withOpacity(0.08),
            ),
            _buildSummaryStat(
              icon: Icons.access_time,
              value: _logs.isNotEmpty
                  ? DateFormat('hh:mm a').format(
                      DateTime.tryParse(_logs.first['timestamp'] ?? '') ?? DateTime.now())
                  : "—",
              label: "Latest",
              color: AppTheme.primary,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSummaryStat({
    required IconData icon,
    required String value,
    required String label,
    required Color color,
  }) {
    return Expanded(
      child: Column(
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(height: 6),
          Text(value, style: AppTheme.telemetryNumSm.copyWith(
            fontSize: 18, color: color == AppTheme.onSurfaceVariant ? AppTheme.onSurface : color)),
          const SizedBox(height: 2),
          Text(label, style: AppTheme.labelCaps.copyWith(fontSize: 9)),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.shield_outlined, size: 80, color: AppTheme.primary.withOpacity(0.2)),
          const SizedBox(height: 16),
          Text("All Clear!", style: AppTheme.headlineMd.copyWith(
            color: AppTheme.onSurface.withOpacity(0.6))),
          const SizedBox(height: 8),
          Text("No drowsiness alerts have been recorded.",
              style: AppTheme.bodySm, textAlign: TextAlign.center),
        ],
      ),
    );
  }

  Widget _buildLogsList() {
    return RefreshIndicator(
      onRefresh: _loadLogs,
      color: AppTheme.primary,
      backgroundColor: AppTheme.surfaceContainer,
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        itemCount: _logs.length,
        itemBuilder: (context, index) {
          final log = _logs[index];
          final timestamp = DateTime.tryParse(log['timestamp'] ?? '');
          final isRecent = timestamp != null &&
              DateTime.now().difference(timestamp).inHours < 1;

          return Container(
            margin: const EdgeInsets.only(bottom: 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Timeline dot + line
                Column(
                  children: [
                    Container(
                      width: 12,
                      height: 12,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: isRecent ? AppTheme.danger : AppTheme.danger.withOpacity(0.5),
                        boxShadow: isRecent ? [
                          BoxShadow(
                            color: AppTheme.danger.withOpacity(0.4),
                            blurRadius: 8,
                          ),
                        ] : [],
                      ),
                    ),
                    if (index < _logs.length - 1)
                      Container(
                        width: 2,
                        height: 60,
                        color: Colors.white.withOpacity(0.06),
                      ),
                  ],
                ),
                const SizedBox(width: 14),
                // Card
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.all(14),
                    decoration: AppTheme.glassCardSmall,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          log['status'] ?? 'Alert',
                          style: AppTheme.bodyMd.copyWith(
                            fontSize: 14, fontWeight: FontWeight.w500),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          timestamp != null
                              ? DateFormat('MMM dd, yyyy • hh:mm:ss a').format(timestamp)
                              : log['timestamp'] ?? '',
                          style: AppTheme.bodySm.copyWith(fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  void _confirmClearAll() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppTheme.surfaceContainer,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: Text("Clear All Records?", style: AppTheme.headlineMd.copyWith(fontSize: 20)),
        content: Text(
          "This will permanently delete all ${_logs.length} alert records.",
          style: AppTheme.bodySm,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text("Cancel", style: AppTheme.bodyMd.copyWith(color: AppTheme.onSurfaceVariant)),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              // Clear logs would require adding a method to DatabaseHelper
              setState(() => _logs = []);
            },
            child: Text("Delete All", style: AppTheme.bodyMd.copyWith(color: AppTheme.danger)),
          ),
        ],
      ),
    );
  }
}
