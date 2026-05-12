import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../theme/app_theme.dart';
import '../services/app_config.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  // Now reads everything persistently from AppConfig() singleton directly.

  @override
  void initState() {
    super.initState();
    // Rebuild whenever the IP changes (e.g. from another listener)
    AppConfig().addListener(_onConfigChanged);
  }

  @override
  void dispose() {
    AppConfig().removeListener(_onConfigChanged);
    super.dispose();
  }

  void _onConfigChanged() {
    if (mounted) setState(() {});
  }

  /// Shows a generic input dialog for numerical settings
  Future<void> _showNumericEditDialog({
    required String title,
    required String description,
    required String currentValue,
    required String hintText,
    required String prefixLabel,
    required bool isDecimal,
    required ValueChanged<String> onSave,
  }) async {
    final controller = TextEditingController(text: currentValue);
    final formKey = GlobalKey<FormState>();

    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppTheme.surfaceContainer,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(title, style: AppTheme.bodyLg.copyWith(fontWeight: FontWeight.w700)),
        content: Form(
          key: formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(description, style: AppTheme.bodySm.copyWith(color: AppTheme.onSurfaceVariant)),
              const SizedBox(height: 16),
              TextFormField(
                controller: controller,
                autofocus: true,
                keyboardType: TextInputType.numberWithOptions(decimal: isDecimal),
                style: GoogleFonts.spaceGrotesk(color: AppTheme.onSurface, fontWeight: FontWeight.w600),
                decoration: InputDecoration(
                  labelText: prefixLabel,
                  hintText: hintText,
                  filled: true,
                  fillColor: Colors.white.withOpacity(0.05),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                ),
                validator: (val) {
                  if (val == null || val.trim().isEmpty) return 'Cannot be empty';
                  final numVal = double.tryParse(val.trim());
                  if (numVal == null) return 'Enter a valid number';
                  return null;
                },
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("Cancel"),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.primary,
              foregroundColor: Colors.black,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            onPressed: () {
              if (formKey.currentState!.validate()) {
                onSave(controller.text.trim());
                Navigator.pop(context);
              }
            },
            child: Text("Save", style: GoogleFonts.spaceGrotesk(fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }

  /// Show dialog to edit the ESP32 IP address
  Future<void> _showIpEditDialog() async {
    final controller = TextEditingController(text: AppConfig().ip);
    final formKey = GlobalKey<FormState>();

    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppTheme.surfaceContainer,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            const Icon(Icons.wifi, color: AppTheme.primary, size: 22),
            const SizedBox(width: 10),
            Text(
              "ESP32-CAM IP Address",
              style: AppTheme.bodyLg.copyWith(fontWeight: FontWeight.w700),
            ),
          ],
        ),
        content: Form(
          key: formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                "Enter the IP address shown in your Arduino Serial Monitor after the ESP32 connects to Wi-Fi.",
                style: AppTheme.bodySm.copyWith(
                  color: AppTheme.onSurfaceVariant,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: controller,
                autofocus: true,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                style: GoogleFonts.spaceGrotesk(
                  color: AppTheme.onSurface,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
                decoration: InputDecoration(
                  hintText: "e.g. 10.208.89.81",
                  hintStyle: AppTheme.bodySm.copyWith(color: AppTheme.onSurfaceVariant),
                  filled: true,
                  fillColor: Colors.white.withOpacity(0.05),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: Colors.white.withOpacity(0.1)),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: Colors.white.withOpacity(0.1)),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: AppTheme.primary, width: 1.5),
                  ),
                  errorBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: AppTheme.danger, width: 1.5),
                  ),
                  prefixIcon: const Icon(Icons.router_outlined,
                      color: AppTheme.onSurfaceVariant, size: 20),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                ),
                validator: (val) {
                  if (val == null || val.trim().isEmpty) return 'IP cannot be empty';
                  // Strip optional /24 notation before validating
                  final clean = val.trim().replaceAll(RegExp(r'/\d+$'), '');
                  final parts = clean.split('.');
                  if (parts.length != 4) return 'Enter a valid IPv4 address';
                  for (final p in parts) {
                    final n = int.tryParse(p);
                    if (n == null || n < 0 || n > 255) return 'Each octet must be 0–255';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 8),
              Text(
                "CIDR notation (e.g. /24) is automatically ignored.",
                style: AppTheme.bodySm.copyWith(
                  fontSize: 11,
                  color: AppTheme.onSurfaceVariant.withOpacity(0.6),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text("Cancel",
                style: AppTheme.bodySm.copyWith(color: AppTheme.onSurfaceVariant)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.primary,
              foregroundColor: Colors.black,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
              padding:
                  const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            ),
            onPressed: () async {
              if (formKey.currentState!.validate()) {
                await AppConfig().setIp(controller.text.trim());
                if (context.mounted) Navigator.pop(context);
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        "IP updated to ${AppConfig().ip} — stream reconnecting…",
                      ),
                      backgroundColor: AppTheme.primary.withOpacity(0.9),
                      duration: const Duration(seconds: 3),
                    ),
                  );
                }
              }
            },
            child: Text("Save",
                style: GoogleFonts.spaceGrotesk(fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(gradient: AppTheme.backgroundGradient),
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          children: [
            const SizedBox(height: 16),
            Text("Profile", style: AppTheme.headlineMd),
            const SizedBox(height: 24),
            _buildProfileCard(),
            const SizedBox(height: 24),
            _buildSettingsSection(),
            const SizedBox(height: 16),
            _buildDeviceSection(),
            const SizedBox(height: 16),
            _buildAboutSection(),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }

  Widget _buildProfileCard() {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: AppTheme.glassCard,
      child: Row(
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: const LinearGradient(
                colors: [AppTheme.primary, AppTheme.primaryDim],
              ),
              boxShadow: [
                BoxShadow(
                  color: AppTheme.primary.withOpacity(0.3),
                  blurRadius: 20,
                ),
              ],
            ),
            child: const Icon(Icons.person, color: Colors.black, size: 32),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text("Driver", style: AppTheme.bodyLg.copyWith(
                  fontWeight: FontWeight.w600, fontSize: 20)),
                const SizedBox(height: 4),
                Text("AlertEdge User",
                    style: AppTheme.bodySm.copyWith(color: AppTheme.onSurfaceVariant)),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: AppTheme.primary.withOpacity(0.1),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: AppTheme.primary.withOpacity(0.3)),
            ),
            child: Text("PRO", style: GoogleFonts.spaceGrotesk(
              color: AppTheme.primary,
              fontSize: 12,
              fontWeight: FontWeight.w700,
              letterSpacing: 1,
            )),
          ),
        ],
      ),
    );
  }

  Widget _buildSettingsSection() {
    final config = AppConfig();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text("SETTINGS", style: AppTheme.labelCaps),
        const SizedBox(height: 12),
        Container(
          decoration: AppTheme.glassCardSmall,
          child: Column(
            children: [
              InkWell(
                onTap: () => _showNumericEditDialog(
                  title: "EAR Threshold",
                  description: "The limit below which an eye is considered closed.",
                  currentValue: config.earThreshold.toString(),
                  hintText: "e.g. 0.22",
                  prefixLabel: "Threshold (0.0 - 1.0)",
                  isDecimal: true,
                  onSave: (val) => config.setEarThreshold(double.parse(val)),
                ),
                borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
                child: _buildSettingsTile(
                  icon: Icons.visibility,
                  title: "EAR Threshold",
                  subtitle: "Eye Aspect Ratio limit",
                  trailing: Text(config.earThreshold.toStringAsFixed(2), style: AppTheme.telemetryNumSm.copyWith(
                    fontSize: 16, color: AppTheme.primary)),
                ),
              ),
              _buildDivider(),
              InkWell(
                onTap: () => _showNumericEditDialog(
                  title: "Consecutive Frames",
                  description: "Number of continuous closed frames before warning.",
                  currentValue: config.consecutiveFrames.toString(),
                  hintText: "e.g. 5",
                  prefixLabel: "Frames count",
                  isDecimal: false,
                  onSave: (val) => config.setConsecutiveFrames(int.parse(val)),
                ),
                child: _buildSettingsTile(
                  icon: Icons.timer,
                  title: "Consecutive Frames",
                  subtitle: "Frames before alert triggers",
                  trailing: Text(config.consecutiveFrames.toString(), style: AppTheme.telemetryNumSm.copyWith(
                    fontSize: 16, color: AppTheme.primary)),
                ),
              ),
              _buildDivider(),
              _buildSettingsTile(
                icon: Icons.volume_up,
                title: "Voice Alerts",
                subtitle: "TTS warning on drowsiness",
                trailing: Switch.adaptive(
                  value: config.voiceAlertsEnabled,
                  activeColor: AppTheme.primary,
                  onChanged: (val) {
                    config.setVoiceAlerts(val);
                  },
                ),
              ),
              _buildDivider(),
              _buildSettingsTile(
                icon: Icons.vibration,
                title: "Hardware Buzzer",
                subtitle: "ESP32 buzzer on drowsiness",
                trailing: Switch.adaptive(
                  value: config.hardwareBuzzerEnabled,
                  activeColor: AppTheme.primary,
                  onChanged: (val) {
                    config.setHardwareBuzzer(val);
                  },
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildDeviceSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text("DEVICE", style: AppTheme.labelCaps),
        const SizedBox(height: 12),
        Container(
          decoration: AppTheme.glassCardSmall,
          child: Column(
            children: [
              // ── Tappable IP tile ──────────────────────────────────────
              InkWell(
                onTap: _showIpEditDialog,
                borderRadius: BorderRadius.circular(16),
                child: _buildSettingsTile(
                  icon: Icons.wifi,
                  title: "ESP32-CAM IP Address",
                  subtitle: AppConfig().ip,
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: Colors.grey.withOpacity(0.2),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text("Disconnected",
                            style: AppTheme.bodySm
                                .copyWith(fontSize: 11, color: Colors.grey)),
                      ),
                      const SizedBox(width: 8),
                      const Icon(Icons.edit_outlined,
                          color: AppTheme.onSurfaceVariant, size: 16),
                    ],
                  ),
                ),
              ),
              // ─────────────────────────────────────────────────────────
              _buildDivider(),
              _buildSettingsTile(
                icon: Icons.camera_alt,
                title: "Stream Resolution",
                subtitle: "MJPEG stream quality",
                trailing: Text("CIF", style: AppTheme.bodySm.copyWith(
                  color: AppTheme.onSurface)),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildAboutSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text("ABOUT", style: AppTheme.labelCaps),
        const SizedBox(height: 12),
        Container(
          decoration: AppTheme.glassCardSmall,
          child: Column(
            children: [
              _buildSettingsTile(
                icon: Icons.info_outline,
                title: "Version",
                subtitle: "AlertEdge v1.5.9",
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSettingsTile({
    required IconData icon,
    required String title,
    required String subtitle,
    Widget? trailing,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        children: [
          Icon(icon, color: AppTheme.onSurfaceVariant, size: 22),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: AppTheme.bodyMd.copyWith(fontSize: 15)),
                Text(subtitle, style: AppTheme.bodySm.copyWith(fontSize: 12)),
              ],
            ),
          ),
          if (trailing != null) trailing,
        ],
      ),
    );
  }

  Widget _buildDivider() {
    return Divider(
      height: 1,
      indent: 52,
      color: Colors.white.withOpacity(0.06),
    );
  }
}
