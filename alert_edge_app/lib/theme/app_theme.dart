import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// AlertEdge Design System — "Digital Vigilance"
/// Translated from Stitch design tokens.
class AppTheme {
  // =====================================================================
  // Color Palette
  // =====================================================================
  static const Color background = Color(0xFF0D0D12);
  static const Color backgroundEnd = Color(0xFF1B1B26);
  static const Color surface = Color(0xFF131318);
  static const Color surfaceContainer = Color(0xFF1F1F24);
  static const Color surfaceHigh = Color(0xFF2A292F);

  static const Color primary = Color(0xFF00FF88);       // Neon Mint Green
  static const Color primaryDim = Color(0xFF00E479);
  static const Color secondary = Color(0xFF0072FF);     // Electric Blue
  static const Color secondaryLight = Color(0xFF00C6FF);
  static const Color danger = Color(0xFFFF3B3B);        // Alert Red
  static const Color dangerDim = Color(0xFFFF6B6B);
  static const Color warning = Color(0xFFFFB800);       // Amber
  static const Color warningDim = Color(0xFFF57F17);

  static const Color onSurface = Color(0xFFE4E1E9);
  static const Color onSurfaceVariant = Color(0xFFB9CBB9);
  static const Color outline = Color(0xFF849585);
  static const Color outlineVariant = Color(0xFF3B4B3D);

  // =====================================================================
  // Glassmorphism Decorations
  // =====================================================================
  static BoxDecoration get glassCard => BoxDecoration(
    color: Colors.white.withOpacity(0.05),
    borderRadius: BorderRadius.circular(24),
    border: Border.all(color: Colors.white.withOpacity(0.1)),
    boxShadow: [
      BoxShadow(
        color: Colors.black.withOpacity(0.3),
        blurRadius: 20,
        offset: const Offset(0, 10),
      ),
    ],
  );

  static BoxDecoration get glassCardSmall => BoxDecoration(
    color: Colors.white.withOpacity(0.05),
    borderRadius: BorderRadius.circular(16),
    border: Border.all(color: Colors.white.withOpacity(0.1)),
  );

  static BoxDecoration glassCardAccent(Color accentColor) => BoxDecoration(
    color: Colors.white.withOpacity(0.05),
    borderRadius: BorderRadius.circular(24),
    border: Border.all(color: accentColor.withOpacity(0.4), width: 1.5),
    boxShadow: [
      BoxShadow(
        color: accentColor.withOpacity(0.15),
        blurRadius: 20,
        spreadRadius: -2,
      ),
    ],
  );

  static BoxDecoration get alertGlassCard => BoxDecoration(
    color: danger.withOpacity(0.08),
    borderRadius: BorderRadius.circular(16),
    border: Border.all(color: danger.withOpacity(0.3)),
  );

  // =====================================================================
  // Background Gradient
  // =====================================================================
  static const LinearGradient backgroundGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [background, backgroundEnd],
  );

  // =====================================================================
  // Typography — Space Grotesk + Inter
  // =====================================================================
  static TextStyle get displayHero => GoogleFonts.spaceGrotesk(
    fontSize: 48,
    fontWeight: FontWeight.w700,
    color: onSurface,
    height: 1.1,
    letterSpacing: -1,
  );

  static TextStyle get headlineLg => GoogleFonts.spaceGrotesk(
    fontSize: 32,
    fontWeight: FontWeight.w600,
    color: onSurface,
    height: 1.2,
  );

  static TextStyle get headlineMd => GoogleFonts.spaceGrotesk(
    fontSize: 24,
    fontWeight: FontWeight.w600,
    color: onSurface,
    height: 1.3,
  );

  static TextStyle get telemetryNum => GoogleFonts.spaceGrotesk(
    fontSize: 40,
    fontWeight: FontWeight.w700,
    color: onSurface,
    height: 1.0,
  );

  static TextStyle get telemetryNumSm => GoogleFonts.spaceGrotesk(
    fontSize: 28,
    fontWeight: FontWeight.w700,
    color: onSurface,
    height: 1.0,
  );

  static TextStyle get labelCaps => GoogleFonts.spaceGrotesk(
    fontSize: 12,
    fontWeight: FontWeight.w700,
    color: onSurfaceVariant,
    height: 1.0,
    letterSpacing: 1.2,
  );

  static TextStyle get bodyLg => GoogleFonts.inter(
    fontSize: 18,
    fontWeight: FontWeight.w500,
    color: onSurface,
    height: 1.5,
  );

  static TextStyle get bodyMd => GoogleFonts.inter(
    fontSize: 16,
    fontWeight: FontWeight.w400,
    color: onSurface,
    height: 1.5,
  );

  static TextStyle get bodySm => GoogleFonts.inter(
    fontSize: 14,
    fontWeight: FontWeight.w400,
    color: onSurfaceVariant,
    height: 1.5,
  );

  static TextStyle get brandTitle => GoogleFonts.spaceGrotesk(
    fontSize: 28,
    fontWeight: FontWeight.w700,
    color: onSurface,
    fontStyle: FontStyle.italic,
    letterSpacing: 1,
  );

  // =====================================================================
  // ThemeData
  // =====================================================================
  static ThemeData get darkTheme => ThemeData(
    brightness: Brightness.dark,
    scaffoldBackgroundColor: background,
    primaryColor: primary,
    fontFamily: GoogleFonts.inter().fontFamily,
    colorScheme: const ColorScheme.dark(
      primary: primary,
      secondary: secondary,
      error: danger,
      surface: surface,
    ),
  );
}
