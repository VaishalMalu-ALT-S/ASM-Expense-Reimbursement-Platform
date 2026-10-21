import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';

/// Centralized Enterprise Design System Tokens & Themes for ASM Expense Platform
/// Faithfully reproduces the corporate aesthetics, spacing, typography, and hierarchy
/// of enterprise expense benchmarks (Zoho Expense, SAP Concur).
class AsmTheme {
  // Official Al Seer Marine Brand Colors
  static const Color primaryNavy = Color(0xFF002254); // Official ASM Primary Navy
  static const Color secondaryNavy = Color(0xFF0D253F);
  static const Color darkHeader = Color(0xFF002254); // ASM Navy Header
  static const Color accentGold = Color(0xFFC5A059);
  static const Color brandBlue = Color(0xFF1769AA); // Official ASM Supporting Info Blue

  // Surface & Canvas (60% light ratio)
  static const Color surfaceBackground = Color(0xFFF7F9FC); // Official ASM Very Light Background
  static const Color surfaceCard = Color(0xFFFFFFFF);
  static const Color surfaceMuted = Color(0xFFF2F5F8); // Official ASM Light Surface
  static const Color surfaceLight = Color(0xFFF2F5F8);
  static const Color borderLight = Color(0xFFE3E8EF); // Official ASM Border
  static const Color borderMedium = Color(0xFFCBD5E1);
  static const Color bgCanvas = surfaceBackground;
  static const Color bgMuted = surfaceMuted;

  // Typography Colors (Al Seer Marine corporate scale)
  static const Color textHeading = Color(0xFF172033); // Official ASM Primary Text
  static const Color textBody = Color(0xFF667085); // Official ASM Secondary Text
  static const Color textMuted = Color(0xFF98A2B3); // Official ASM Muted Text
  static const Color textPlaceholder = Color(0xFF98A2B3);
  static const Color textPrimary = textHeading;
  static const Color textSecondary = textBody;

  // Enterprise Status Palette (Official ASM status colors)
  static const Color statusPending = Color(0xFF002254); // ASM Navy/Blue pending
  static const Color statusPendingBg = Color(0xFFE8EEF5);
  static const Color statusApproved = Color(0xFF198754); // Official ASM Success
  static const Color statusApprovedBg = Color(0xFFE8F5E9);
  static const Color statusRejected = Color(0xFFC93636); // Official ASM Error
  static const Color statusRejectedBg = Color(0xFFFDE8E8);
  static const Color statusWarning = Color(0xFFD99000); // Official ASM Warning
  static const Color statusWarningBg = Color(0xFFFFF8E1);
  static const Color statusInfo = Color(0xFF1769AA); // Official ASM Info
  static const Color statusInfoBg = Color(0xFFE3F2FD);

  // Spacing Tokens
  static const double space4 = 4.0;
  static const double space8 = 8.0;
  static const double space12 = 12.0;
  static const double space16 = 16.0;
  static const double space20 = 20.0;
  static const double space24 = 24.0;
  static const double space32 = 32.0;

  // Elevation & Shadows
  static List<BoxShadow> get cardShadow => [
        BoxShadow(
          color: const Color(0xFF0F172A).withValues(alpha: 0.04),
          offset: const Offset(0, 1),
          blurRadius: 3,
        ),
      ];

  static List<BoxShadow> get dropdownShadow => [
        BoxShadow(
          color: const Color(0xFF0F172A).withValues(alpha: 0.08),
          offset: const Offset(0, 4),
          blurRadius: 12,
        ),
      ];

  // Material Theme
  static ThemeData get lightTheme {
    return ThemeData(
      useMaterial3: true,
      scaffoldBackgroundColor: surfaceBackground,
      colorScheme: ColorScheme.fromSeed(
        seedColor: primaryNavy,
        primary: primaryNavy,
        secondary: brandBlue,
        tertiary: accentGold,
        surface: surfaceBackground,
        error: statusRejected,
      ),
      // Inter when available on the device, otherwise the platform's Roboto.
      fontFamily: 'Inter',
      fontFamilyFallback: const ['Roboto'],
      pageTransitionsTheme: const PageTransitionsTheme(builders: {
        TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
        TargetPlatform.windows: FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
        TargetPlatform.linux: FadeForwardsPageTransitionsBuilder(),
      }),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: textHeading,
        contentTextStyle: const TextStyle(color: Colors.white, fontSize: 13),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: surfaceCard,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        titleTextStyle: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: textHeading),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: surfaceCard,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(12))),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: surfaceCard,
        selectedColor: primaryNavy.withValues(alpha: 0.10),
        side: const BorderSide(color: borderLight),
        labelStyle: const TextStyle(fontSize: 12, color: textHeading),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      ),
      tabBarTheme: const TabBarThemeData(
        labelColor: Colors.white,
        unselectedLabelColor: Colors.white70,
        indicatorColor: accentGold,
      ),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: primaryNavy,
        foregroundColor: Colors.white,
        elevation: 1,
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: brandBlue, textStyle: const TextStyle(fontWeight: FontWeight.w600)),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: darkHeader,
        foregroundColor: Colors.white,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w600,
          color: Colors.white,
          letterSpacing: 0.2,
        ),
      ),
      cardTheme: CardThemeData(
        color: surfaceCard,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: const BorderSide(color: borderLight, width: 1),
        ),
        margin: EdgeInsets.zero,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surfaceCard,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: const BorderSide(color: borderMedium),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: const BorderSide(color: borderMedium),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: const BorderSide(color: brandBlue, width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: const BorderSide(color: statusRejected),
        ),
        labelStyle: const TextStyle(color: textMuted, fontSize: 13),
        hintStyle: const TextStyle(color: textPlaceholder, fontSize: 13),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: primaryNavy,
          foregroundColor: Colors.white,
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
          textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, letterSpacing: 0.2),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: textHeading,
          side: const BorderSide(color: borderMedium),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
          textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
      ),
      dividerTheme: const DividerThemeData(
        color: borderLight,
        thickness: 1,
        space: 1,
      ),
    );
  }
}
