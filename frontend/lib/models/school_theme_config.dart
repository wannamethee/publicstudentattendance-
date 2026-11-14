import 'package:flutter/material.dart';

/// Top-level helper to convert Color to Hex string (#RRGGBB)
String colorToHex(Color color) {
  final a = (color.a * 255).round();
  final r = (color.r * 255).round();
  final g = (color.g * 255).round();
  final b = (color.b * 255).round();
  final argb = ((a & 0xFF) << 24) | ((r & 0xFF) << 16) | ((g & 0xFF) << 8) | (b & 0xFF);
  return '#${argb.toRadixString(16).padLeft(8, '0').substring(2).toUpperCase()}';
}

/// Top-level helper to convert Hex string to Color
Color? hexToColor(String hexString, {Color? fallback}) {
  try {
    final buffer = StringBuffer();
    var clean = hexString.replaceAll('#', '').trim();
    if (clean.length == 6) {
      buffer.write('FF$clean');
    } else if (clean.length == 8) {
      buffer.write(clean);
    } else {
      return fallback;
    }
    return Color(int.parse(buffer.toString(), radix: 16));
  } catch (_) {
    return fallback;
  }
}

/// Thai Google Font description model
class SchoolFontOption {
  final String family;
  final String name;
  final String description;
  final String sampleText;

  const SchoolFontOption({
    required this.family,
    required this.name,
    required this.description,
    required this.sampleText,
  });
}

/// Popular School Preset Palette model
class PresetPalette {
  final String id;
  final String name;
  final String description;
  final SchoolThemeConfig config;

  const PresetPalette({
    required this.id,
    required this.name,
    required this.description,
    required this.config,
  });
}

/// School Brand & Appearance Customization Model
/// Controls dynamic school colors (menu, body, primary, secondary) and Thai typography.
class SchoolThemeConfig {
  final Color menuColor;
  final Color bodyColor;
  final Color primaryColor;
  final Color secondaryColor;
  final String fontFamily;

  const SchoolThemeConfig({
    required this.menuColor,
    required this.bodyColor,
    required this.primaryColor,
    required this.secondaryColor,
    required this.fontFamily,
  });

  /// Default Official Brand Colors
  static const SchoolThemeConfig defaultTheme = SchoolThemeConfig(
    menuColor: Color(0xFF24114F),       // Deep Night Purple
    bodyColor: Color(0xFFF7ECC2),       // Warm Mellow Yellow Body
    primaryColor: Color(0xFF351C75),    // Royal Purple Primary
    secondaryColor: Color(0xFFD4AF37),  // Royal Gold Accent
    fontFamily: 'Sarabun',              // Official Thai Sarabun
  );

  /// 6 Supported Thai Fonts (Compiled & Embedded Assets)
  static const List<SchoolFontOption> availableFonts = [
    SchoolFontOption(
      family: 'Sarabun',
      name: 'สารบรรณ (Sarabun)',
      description: 'มาตรฐานราชการ มีหัวชัดเจน',
      sampleText: 'มาตรฐานหนังสือราชการ มีหัวชัดเจน เรียบร้อย สุภาพ — ระบบงาน ปพ.๕',
    ),
    SchoolFontOption(
      family: 'Prompt',
      name: 'พร้อม (Prompt)',
      description: 'โมเดิร์น ไร้หัว สไตล์สากล',
      sampleText: 'โมเดิร์น ไร้หัว สไตล์สากล สะอาดตา อ่านสบาย — Smart Education 2026',
    ),
    SchoolFontOption(
      family: 'Kanit',
      name: 'คณิต (Kanit)',
      description: 'ตัวหนา หนักแน่น คมชัดโดดเด่น',
      sampleText: 'ตัวหนา หนักแน่น เรขาคณิต คมชัดโดดเด่น — บันทึกคะแนนและเวลาเรียน',
    ),
    SchoolFontOption(
      family: 'Mitr',
      name: 'มิตร (Mitr)',
      description: 'อบอุ่น โค้งมน นุ่มนวลเป็นมิตร',
      sampleText: 'อบอุ่น เป็นมิตร โค้งมนนุ่มนวล สบายตา — กิจกรรมพัฒนาผู้เรียนและเยี่ยมบ้าน',
    ),
    SchoolFontOption(
      family: 'Chakra Petch',
      name: 'จักรเพชร (Chakra Petch)',
      description: 'ทรงเหลี่ยม สปอร์ต เทคโนโลยี',
      sampleText: 'ทรงเหลี่ยม เทคโนโลยี ล้ำสมัย วิทยาศาสตร์ — Data Center & SGS System',
    ),
    SchoolFontOption(
      family: 'Noto Sans Thai',
      name: 'โนโตะ ซานส์ (Noto Sans Thai)',
      description: 'สากล คมชัดทุกขนาดหน้าจอ',
      sampleText: 'มาตรฐานสากล คมชัดระดับโลก สบายตาทุกหน้าจอ — ระบบทะเบียนและวัดผล',
    ),
  ];

  /// 8 Popular Thai School Color Presets
  static final List<PresetPalette> popularPresets = [
    PresetPalette(
      id: 'purple_gold',
      name: 'ม่วง - ทอง - ครีมนวล',
      description: 'ค่าเริ่มต้น (ม่วง-ทอง)',
      config: const SchoolThemeConfig(
        menuColor: Color(0xFF24114F),
        bodyColor: Color(0xFFF7ECC2),
        primaryColor: Color(0xFF351C75),
        secondaryColor: Color(0xFFD4AF37),
        fontFamily: 'Sarabun',
      ),
    ),
    PresetPalette(
      id: 'navy_sky',
      name: 'น้ำเงินกรมท่า - ฟ้าสดใส',
      description: 'สุภาพ มั่นคง สง่างาม',
      config: const SchoolThemeConfig(
        menuColor: Color(0xFF0F172A),
        bodyColor: Color(0xFFF0F9FF),
        primaryColor: Color(0xFF0284C7),
        secondaryColor: Color(0xFF38BDF8),
        fontFamily: 'Prompt',
      ),
    ),
    PresetPalette(
      id: 'crimson_gold',
      name: 'แดงเลือดหมู - ทองอร่าม',
      description: 'เข้มขลัง ภาคภูมิใจ มีพลัง',
      config: const SchoolThemeConfig(
        menuColor: Color(0xFF4C0519),
        bodyColor: Color(0xFFFFF1F2),
        primaryColor: Color(0xFFBE123C),
        secondaryColor: Color(0xFFEAB308),
        fontFamily: 'Kanit',
      ),
    ),
    PresetPalette(
      id: 'emerald_yellow',
      name: 'เขียวมรกต - เหลืองทอง',
      description: 'สดชื่น เติบโต ร่มรื่น',
      config: const SchoolThemeConfig(
        menuColor: Color(0xFF064E3B),
        bodyColor: Color(0xFFF0FDF4),
        primaryColor: Color(0xFF059669),
        secondaryColor: Color(0xFFF59E0B),
        fontFamily: 'Mitr',
      ),
    ),
    PresetPalette(
      id: 'azure_silver',
      name: 'ฟ้าคราม - ขาวสะอาด',
      description: 'โปร่งสบาย บริสุทธิ์ สบายตา',
      config: const SchoolThemeConfig(
        menuColor: Color(0xFF1E3A8A),
        bodyColor: Color(0xFFF8FAFC),
        primaryColor: Color(0xFF2563EB),
        secondaryColor: Color(0xFF64748B),
        fontFamily: 'Prompt',
      ),
    ),
    PresetPalette(
      id: 'terracotta_slate',
      name: 'ส้มอิฐ - เทาชาร์โคล',
      description: 'สร้างสรรค์ กระตือรือร้น ทันสมัย',
      config: const SchoolThemeConfig(
        menuColor: Color(0xFF1C1917),
        bodyColor: Color(0xFFFFF7ED),
        primaryColor: Color(0xFFEA580C),
        secondaryColor: Color(0xFF78716C),
        fontFamily: 'Chakra Petch',
      ),
    ),
    PresetPalette(
      id: 'bronze_amber',
      name: 'น้ำตาลบรอนซ์ - ครีมทอง',
      description: 'คลาสสิก อบอุ่น นุ่มนวล',
      config: const SchoolThemeConfig(
        menuColor: Color(0xFF292524),
        bodyColor: Color(0xFFFEFCE8),
        primaryColor: Color(0xFF854D0E),
        secondaryColor: Color(0xFFCA8A04),
        fontFamily: 'Sarabun',
      ),
    ),
    PresetPalette(
      id: 'onyx_gold',
      name: 'ดำการ์ไฟต์ - ทองหรูหรา',
      description: 'พรีเมียม โดดเด่น ชัดเจน',
      config: const SchoolThemeConfig(
        menuColor: Color(0xFF111827),
        bodyColor: Color(0xFFF9FAFB),
        primaryColor: Color(0xFF1F2937),
        secondaryColor: Color(0xFFD97706),
        fontFamily: 'Noto Sans Thai',
      ),
    ),
  ];

  /// Color Swatch Scales for Granular Tuning (10 shades each)
  static const List<Color> menuScaleSwatches = [
    Color(0xFF24114F), // Royal Night Purple (Default)
    Color(0xFF0F172A), // Slate Navy
    Color(0xFF1E1B4B), // Indigo Night
    Color(0xFF4C0519), // Rose Crimson
    Color(0xFF450A0A), // Deep Red
    Color(0xFF064E3B), // Forest Green
    Color(0xFF134E4A), // Deep Teal
    Color(0xFF1E3A8A), // Classic Blue
    Color(0xFF1C1917), // Deep Stone Charcoal
    Color(0xFF111827), // Onyx Black
  ];

  static const List<Color> bodyScaleSwatches = [
    Color(0xFFF7ECC2), // Warm Mellow Yellow (Default)
    Color(0xFFFFFBEB), // Pale Amber Cream
    Color(0xFFFEFCE8), // Light Soft Butter
    Color(0xFFF8FAFC), // Pure Crisp Slate White
    Color(0xFFF1F5F9), // Light Cool Slate
    Color(0xFFF0F9FF), // Sky Ice Blue
    Color(0xFFF0FDF4), // Mint Fresh Tint
    Color(0xFFFFF1F2), // Rose Cloud Tint
    Color(0xFFFDF4FF), // Lilac Blossom Tint
    Color(0xFFFFFFFF), // Pure White
  ];

  static const List<Color> primaryScaleSwatches = [
    Color(0xFF351C75), // Deep Royal Purple
    Color(0xFF4338CA), // Electric Indigo
    Color(0xFF1D4ED8), // Cobalt Blue
    Color(0xFF0284C7), // Sky Blue
    Color(0xFF0F766E), // Pine Teal
    Color(0xFF047857), // Emerald Green
    Color(0xFFB45309), // Amber Brown
    Color(0xFFC2410C), // Terracotta Orange
    Color(0xFFBE123C), // Crimson Red
    Color(0xFF374151), // Dark Slate
  ];

  static const List<Color> secondaryScaleSwatches = [
    Color(0xFFD4AF37), // Royal Gold
    Color(0xFFF59E0B), // Vibrant Amber
    Color(0xFFFACC15), // School Yellow
    Color(0xFF10B981), // Fresh Emerald
    Color(0xFF06B6D4), // Bright Cyan
    Color(0xFF3B82F6), // Azure Blue
    Color(0xFFA855F7), // Orchid Violet
    Color(0xFFF43F5E), // Vivid Rose
    Color(0xFFFB923C), // Warm Tangerine
    Color(0xFF94A3B8), // Metallic Silver
  ];

  SchoolThemeConfig copyWith({
    Color? menuColor,
    Color? bodyColor,
    Color? primaryColor,
    Color? secondaryColor,
    String? fontFamily,
  }) {
    return SchoolThemeConfig(
      menuColor: menuColor ?? this.menuColor,
      bodyColor: bodyColor ?? this.bodyColor,
      primaryColor: primaryColor ?? this.primaryColor,
      secondaryColor: secondaryColor ?? this.secondaryColor,
      fontFamily: fontFamily ?? this.fontFamily,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'menu_color': colorToHex(menuColor),
      'body_color': colorToHex(bodyColor),
      'primary_color': colorToHex(primaryColor),
      'secondary_color': colorToHex(secondaryColor),
      'font_family': fontFamily,
    };
  }

  factory SchoolThemeConfig.fromJson(Map<String, dynamic> json) {
    return SchoolThemeConfig(
      menuColor: hexToColor(json['menu_color']?.toString() ?? '#24114F', fallback: const Color(0xFF24114F))!,
      bodyColor: hexToColor(json['body_color']?.toString() ?? '#F7ECC2', fallback: const Color(0xFFF7ECC2))!,
      primaryColor: hexToColor(json['primary_color']?.toString() ?? '#351C75', fallback: const Color(0xFF351C75))!,
      secondaryColor: hexToColor(json['secondary_color']?.toString() ?? '#D4AF37', fallback: const Color(0xFFD4AF37))!,
      fontFamily: json['font_family']?.toString() ?? 'Sarabun',
    );
  }
}
