import 'package:flutter/material.dart';
import '../models/school_theme_config.dart';

/// School Brand Identity Design System (default purple-gold & customizable school themes)
/// Theme Colors: Deep Royal Purple (ม่วงเข้ม), School Yellow (เหลือง), Royal Gold (ทอง)
/// Default colours: purple and gold (each school picks its own in ตั้งค่า → ธีม)
class AppColors {
  // Brand Deep Royal Purple (ม่วงเข้ม)
  static const Color purplePrimary = Color(0xFF351C75);      // Official site purple (#351c75)
  static const Color purpleDark = Color(0xFF24114F);         // Deep Night Purple (Navigation & Headers)
  static const Color purpleDeeper = Color(0xFF190938);       // 3D Button Rim & Deep Shadow
  static const Color purpleLight = Color(0xFF4C279E);        // Hover / Active Purple
  static const Color purpleContainer = Color(0xFFF3E8FF);    // Soft Lavender / Lilac
  static const Color purpleBorder = Color(0xFFD8B4FE);       // Delicate Purple Border

  // Brand Gold & Amber (ทอง & เหลือง)
  static const Color gold = Color(0xFFD4AF37);               // Classic Royal Gold
  static const Color goldWarm = Color(0xFFC59B27);           // Warm Metallic Gold (Borders & Trims)
  static const Color goldDark = Color(0xFF9A7415);           // Dark Antique Gold (3D Rim)
  static const Color goldLight = Color(0xFFFEF3C7);          // Champagne Gold Highlight
  static const Color goldContainer = Color(0xFFFFFBEB);      // Very light warm gold surface
  static const Color yellowSchool = Color(0xFFFACC15);       // Bright School Yellow (Emblem Shield)
  static const Color yellowDark = Color(0xFFEAB308);         // Rich Amber Yellow

  // Neutral Surfaces & Canvas
  static const Color background = Color(0xFFF7ECC2);         // Rich Warm Mellow Yellow (เหลืองนวลเข้ม)
  static const Color bodyBg = Color(0xFFF7ECC2);             // Body Background
  static const Color surface = Colors.white;                 // Pure white card face
  static const Color surfaceMuted = Color(0xFFFBF4D8);       // Warm cream surface
  static const Color borderSubtle = Color(0xFFEADBAB);       // Warm subtle separator line
  static const Color borderGold = Color(0xFFD4AF37);         // Gold border accent
}

class AppTheme {
  /// Builds a dynamic ThemeData based on customizable school branding (colors & font)
  static ThemeData buildThemeFromConfig(SchoolThemeConfig config) {
    final primary = config.primaryColor;
    final secondary = config.secondaryColor;
    final menu = config.menuColor;
    final body = config.bodyColor;
    final font = config.fontFamily;

    // Derived tones for button states and shadows
    final hslPrimary = HSLColor.fromColor(primary);
    final primaryDark = hslPrimary.withLightness((hslPrimary.lightness - 0.15).clamp(0.0, 1.0)).toColor();
    final primaryLight = hslPrimary.withLightness((hslPrimary.lightness + 0.12).clamp(0.0, 1.0)).toColor();
    final primaryContainer = hslPrimary.withLightness(0.92).withSaturation(0.35).toColor();

    final hslSecondary = HSLColor.fromColor(secondary);
    final secondaryDark = hslSecondary.withLightness((hslSecondary.lightness - 0.15).clamp(0.0, 1.0)).toColor();
    final secondaryLight = hslSecondary.withLightness(0.94).withSaturation(0.40).toColor();

    return ThemeData(
      useMaterial3: true,
      fontFamily: font,
      brightness: Brightness.light,
      scaffoldBackgroundColor: body,
      colorScheme: ColorScheme.fromSeed(
        seedColor: primary,
        primary: primary,
        onPrimary: Colors.white,
        primaryContainer: primaryContainer,
        onPrimaryContainer: primaryDark,
        secondary: secondary,
        onSecondary: Colors.white,
        secondaryContainer: secondaryLight,
        onSecondaryContainer: secondaryDark,
        tertiary: secondary,
        onTertiary: Colors.white,
        surface: AppColors.surface,
        onSurface: const Color(0xFF1F1B24),
        surfaceContainerLow: body,
        surfaceContainer: AppColors.surfaceMuted,
        outline: secondary,
        outlineVariant: primary.withValues(alpha: 0.3),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: menu,
        foregroundColor: Colors.white,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          fontFamily: font,
          color: secondary,
          fontSize: 18,
          fontWeight: FontWeight.bold,
        ),
      ),
      // 3D Tactile Button Global Defaults (กดแล้วยุบตัวสมจริง)
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ButtonStyle(
          backgroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.disabled)) return Colors.grey.shade300;
            if (states.contains(WidgetState.pressed)) return primaryDark;
            if (states.contains(WidgetState.hovered)) return primaryLight;
            return primary;
          }),
          foregroundColor: WidgetStateProperty.all(Colors.white),
          elevation: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.pressed)) return 0.5; // ยุบตัวลงเมื่อกด
            if (states.contains(WidgetState.hovered)) return 4.0;
            return 3.0; // นูน 3 มิติตั้งต้น
          }),
          shadowColor: WidgetStateProperty.all(primaryDark),
          padding: WidgetStateProperty.all(const EdgeInsets.symmetric(horizontal: 18, vertical: 12)),
          shape: WidgetStateProperty.all(RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: BorderSide(color: secondary, width: 1.2), // ขอบสีตัดขอบ
          )),
          textStyle: WidgetStateProperty.all(TextStyle(fontFamily: font, fontWeight: FontWeight.bold)),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: ButtonStyle(
          backgroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.disabled)) return Colors.grey.shade300;
            if (states.contains(WidgetState.pressed)) return primaryDark;
            if (states.contains(WidgetState.hovered)) return primaryLight;
            return primary;
          }),
          foregroundColor: WidgetStateProperty.all(Colors.white),
          elevation: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.pressed)) return 0.5;
            if (states.contains(WidgetState.hovered)) return 4.0;
            return 3.0;
          }),
          shadowColor: WidgetStateProperty.all(primaryDark),
          padding: WidgetStateProperty.all(const EdgeInsets.symmetric(horizontal: 18, vertical: 12)),
          shape: WidgetStateProperty.all(RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: BorderSide(color: secondary, width: 1.2),
          )),
          textStyle: WidgetStateProperty.all(TextStyle(fontFamily: font, fontWeight: FontWeight.bold)),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: ButtonStyle(
          foregroundColor: WidgetStateProperty.all(primary),
          side: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.pressed)) return BorderSide(color: secondaryDark, width: 2.0);
            return BorderSide(color: secondary, width: 1.4);
          }),
          backgroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.pressed)) return secondaryLight;
            if (states.contains(WidgetState.hovered)) return secondaryLight.withValues(alpha: 0.5);
            return Colors.white;
          }),
          elevation: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.pressed)) return 0.0;
            return 1.5;
          }),
          shadowColor: WidgetStateProperty.all(secondary.withValues(alpha: 0.4)),
          padding: WidgetStateProperty.all(const EdgeInsets.symmetric(horizontal: 16, vertical: 11)),
          shape: WidgetStateProperty.all(RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          )),
          textStyle: WidgetStateProperty.all(TextStyle(fontFamily: font, fontWeight: FontWeight.bold)),
        ),
      ),
      cardTheme: CardThemeData(
        color: Colors.white,
        elevation: 2.0,
        shadowColor: primaryDark.withValues(alpha: 0.08),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: secondary, width: 1.2), // ขอบสีรองตัดกรอบ
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: Colors.white,
        elevation: 6.0,
        shadowColor: primaryDark.withValues(alpha: 0.25),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(color: secondary, width: 1.5),
        ),
        titleTextStyle: TextStyle(fontFamily: font, fontSize: 18, fontWeight: FontWeight.bold, color: primary),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: const Color(0xFFFCFAFF),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: secondary.withValues(alpha: 0.45)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: secondary.withValues(alpha: 0.45)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: const BorderRadius.all(Radius.circular(10)),
          borderSide: BorderSide(color: primary, width: 2.0),
        ),
        labelStyle: TextStyle(color: primary, fontWeight: FontWeight.w600, fontFamily: font),
        prefixIconColor: primary,
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: menu,
        selectedIconTheme: IconThemeData(color: secondary, size: 26),
        unselectedIconTheme: IconThemeData(color: Colors.white.withValues(alpha: 0.7), size: 22),
        selectedLabelTextStyle: TextStyle(
          fontFamily: font,
          color: secondary,
          fontWeight: FontWeight.bold,
          fontSize: 12,
        ),
        unselectedLabelTextStyle: TextStyle(
          fontFamily: font,
          color: Colors.white.withValues(alpha: 0.7),
          fontSize: 11,
        ),
        indicatorColor: primary,
        indicatorShape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: secondary, width: 1.2),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: menu,
        indicatorColor: primary,
        indicatorShape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: secondary, width: 1.2),
        ),
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return TextStyle(
              fontFamily: font,
              color: secondary,
              fontWeight: FontWeight.bold,
              fontSize: 11,
            );
          }
          return TextStyle(
            fontFamily: font,
            color: Colors.white.withValues(alpha: 0.7),
            fontSize: 10,
          );
        }),
        iconTheme: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return IconThemeData(color: secondary);
          }
          return IconThemeData(color: Colors.white.withValues(alpha: 0.7));
        }),
      ),
    );
  }

  /// Default theme backwards compatibility
  static ThemeData get lightTheme => buildThemeFromConfig(SchoolThemeConfig.defaultTheme);
}
