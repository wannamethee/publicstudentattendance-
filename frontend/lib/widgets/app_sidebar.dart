import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/api_service.dart';
import '../models/logged_in_teacher.dart';
import '../models/school_theme_config.dart';
import '../utils/app_theme.dart';
import 'app_3d_button.dart';
import 'house_icon.dart';

/// Interactive navigation item metadata
class SidebarDestination {
  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final Widget Function(Color color, bool isSelected)? customIconBuilder;

  const SidebarDestination({
    required this.icon,
    required this.selectedIcon,
    required this.label,
    this.customIconBuilder,
  });
}

/// Custom Desktop Sidebar for customizable school branding
/// Features:
/// - 3D tactile rectangular menu items that extrude/pop up on hover ("เป็นปุ่มสี่เหลี่ยม นูนขึ้นมาด้วย")
/// - 3 levels larger font size (16.5px) for clear Thai readability
/// - Two-line user role & name badge ("ผู้ดูแลระบบ อยู่ด้านบน และชื่อคนอยู่ด้านล่างคนละบรรทัด")
/// - Dynamic responsive school branding colors & Thai Google Fonts
class AppSidebar extends StatelessWidget {
  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  final ApiService apiService;
  final VoidCallback onPromptLogin;
  final ValueChanged<LoggedInTeacher> onShowUserMenu;

  static const double sidebarWidth = 248.0;

  static final List<SidebarDestination> destinations = [
    SidebarDestination(
      icon: Icons.dashboard_outlined,
      selectedIcon: Icons.dashboard_rounded,
      label: 'แดชบอร์ด',
    ),
    SidebarDestination(
      icon: Icons.inventory_2_outlined,
      selectedIcon: Icons.inventory_2_rounded,
      label: 'คลังข้อมูล',
    ),
    SidebarDestination(
      icon: Icons.fact_check_outlined,
      selectedIcon: Icons.fact_check_rounded,
      label: 'เช็คเวลาเรียน',
    ),
    SidebarDestination(
      icon: Icons.edit_note_outlined,
      selectedIcon: Icons.edit_note_rounded,
      label: 'บันทึกคะแนน',
    ),
    SidebarDestination(
      icon: Icons.calendar_month_outlined,
      selectedIcon: Icons.calendar_month_rounded,
      label: 'ตารางสอนครู',
    ),
    SidebarDestination(
      icon: Icons.home_rounded,
      selectedIcon: Icons.home_rounded,
      label: 'เยี่ยมบ้าน',
      customIconBuilder: (color, isSelected) => HouseIcon(
        size: 22,
        color: color,
        isFilled: isSelected,
      ),
    ),
    SidebarDestination(
      icon: Icons.quiz_outlined,
      selectedIcon: Icons.quiz_rounded,
      label: 'ข้อสอบ',
    ),
    SidebarDestination(
      icon: Icons.event_note_outlined,
      selectedIcon: Icons.event_note_rounded,
      label: 'บันทึกการลา',
    ),
    SidebarDestination(
      icon: Icons.settings_outlined,
      selectedIcon: Icons.settings_rounded,
      label: 'ตั้งค่า',
    ),
  ];

  const AppSidebar({
    super.key,
    required this.selectedIndex,
    required this.onDestinationSelected,
    required this.apiService,
    required this.onPromptLogin,
    required this.onShowUserMenu,
  });

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<SchoolThemeConfig>(
      valueListenable: apiService.themeNotifier,
      builder: (context, themeConfig, _) {
        final menuColor = themeConfig.menuColor;
        final secondaryColor = themeConfig.secondaryColor;
        final font = themeConfig.fontFamily;

        return Container(
          width: sidebarWidth,
          height: double.infinity,
          decoration: BoxDecoration(
            color: menuColor,
            border: Border(
              right: BorderSide(
                color: secondaryColor.withValues(alpha: 0.35),
                width: 1.5,
              ),
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.25),
                blurRadius: 10,
                offset: const Offset(3, 0),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // -------------------------------------------------------------
              // 1. TOP HEADER: School Logo, School Name, & Two-line User Badge
              // -------------------------------------------------------------
              _buildHeader(context, themeConfig),

              const SizedBox(height: 10),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Divider(
                  height: 1,
                  thickness: 1,
                  color: secondaryColor.withValues(alpha: 0.25),
                ),
              ),
              const SizedBox(height: 12),

              // -------------------------------------------------------------
              // 2. NAV ITEMS LIST: Rectangular 3D Tactile Buttons
              // -------------------------------------------------------------
              Expanded(
                child: ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  itemCount: destinations.length,
                  itemBuilder: (context, index) {
                    final dest = destinations[index];
                    final isSelected = selectedIndex == index;

                    final user = apiService.currentUser;
                    bool isLocked = false;
                    String lockTooltip = '';

                    // index 3: บันทึกคะแนน -> ผู้อำนวยการ และ บุคคลทั่วไป ล็อกปุ่มนี้
                    if (index == 3) {
                      if (user != null && !user.canAccessScores) {
                        isLocked = true;
                        lockTooltip = 'หน้าบันทึกคะแนนสงวนสิทธิ์เฉพาะคุณครูผู้สอนประจำวิชาเท่านั้น\n(ผู้อำนวยการและบุคคลทั่วไปไม่สามารถเข้าถึงได้)';
                      }
                    }

                    // ตั้งค่า -> ผู้อำนวยการ และ บุคคลทั่วไป ล็อกปุ่มนี้
                    if (dest.label == 'ตั้งค่า') {
                      if (user != null && !user.canAccessSettings) {
                        isLocked = true;
                        lockTooltip = 'หน้าตั้งค่าสงวนสิทธิ์เฉพาะคณะครูและผู้ดูแลระบบเท่านั้น\n(ผู้อำนวยการและบุคคลทั่วไปไม่สามารถเข้าถึงได้)';
                      }
                    }

                    return Sidebar3DNavItem(
                      key: ValueKey('nav_item_$index'),
                      themeConfig: themeConfig,
                      icon: isSelected ? dest.selectedIcon : dest.icon,
                      customIconBuilder: dest.customIconBuilder,
                      label: dest.label,
                      isSelected: isSelected,
                      isLocked: isLocked,
                      lockTooltip: lockTooltip,
                      onTap: () {
                        if (isLocked) {
                          ScaffoldMessenger.of(context).hideCurrentSnackBar();
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Row(
                                children: [
                                  const Icon(Icons.lock_rounded, color: Colors.amberAccent, size: 22),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Text(
                                      lockTooltip,
                                      style: TextStyle(fontFamily: font, fontSize: 13.5, height: 1.3),
                                    ),
                                  ),
                                ],
                              ),
                              backgroundColor: const Color(0xFF2D124D),
                              behavior: SnackBarBehavior.floating,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                                side: BorderSide(color: secondaryColor, width: 1.5),
                              ),
                            ),
                          );
                          return;
                        }
                        onDestinationSelected(index);
                      },
                    );
                  },
                ),
              ),

              // -------------------------------------------------------------
              // 3. BOTTOM FOOTER
              // -------------------------------------------------------------
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Divider(
                      height: 1,
                      thickness: 1,
                      color: secondaryColor.withValues(alpha: 0.2),
                    ),
                    const SizedBox(height: 8),
                    ValueListenableBuilder<String>(
                      valueListenable: apiService.sidebarFooterTitleNotifier,
                      builder: (context, footerTitle, _) {
                        return Text(
                          footerTitle,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontFamily: font,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: secondaryColor.withValues(alpha: 0.85),
                            letterSpacing: 0.2,
                          ),
                        );
                      },
                    ),
                    const SizedBox(height: 2),
                    ValueListenableBuilder<String>(
                      valueListenable: apiService.sidebarFooterSubtitleNotifier,
                      builder: (context, footerSubtitle, _) {
                        return Text(
                          footerSubtitle,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontFamily: font,
                            fontSize: 10,
                            color: Colors.white.withValues(alpha: 0.55),
                          ),
                        );
                      },
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildHeader(BuildContext context, SchoolThemeConfig themeConfig) {
    final secondaryColor = themeConfig.secondaryColor;
    final primaryColor = themeConfig.primaryColor;
    final font = themeConfig.fontFamily;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 18, 12, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Logo & Return to Dashboard Action
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              hoverColor: primaryColor.withValues(alpha: 0.2),
              onTap: () => onDestinationSelected(0),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ValueListenableBuilder<int>(
                      valueListenable: apiService.schoolLogoNotifier,
                      builder: (context, logoVersion, _) {
                        return Container(
                          width: 54,
                          height: 54,
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: secondaryColor, width: 1.8),
                            boxShadow: [
                              BoxShadow(
                                color: primaryColor.withValues(alpha: 0.6),
                                offset: const Offset(0, 3.5),
                                blurRadius: 0, // Solid 3D bottom shelf
                              ),
                              const BoxShadow(
                                color: Colors.black26,
                                offset: Offset(0, 4),
                                blurRadius: 6,
                              ),
                            ],
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: Image.network(
                            apiService.getSchoolLogoUrl(),
                            fit: BoxFit.contain,
                            errorBuilder: (ctx, err, stack) => Icon(
                              Icons.school_rounded,
                              size: 34,
                              color: primaryColor,
                            ),
                          ),
                        );
                      },
                    ),
                    const SizedBox(height: 8),
                    ValueListenableBuilder<String>(
                      valueListenable: apiService.schoolNameNotifier,
                      builder: (context, schoolName, _) {
                        return Text(
                          schoolName,
                          textAlign: TextAlign.center,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontFamily: font,
                            fontSize: 16.5, // ขนาดฟอนต์ชัดเจน
                            fontWeight: FontWeight.bold,
                            color: secondaryColor,
                            height: 1.3,
                            shadows: const [
                              Shadow(
                                color: Colors.black45,
                                offset: Offset(0, 1.5),
                                blurRadius: 2,
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ],
                ),
              ),
            ),
          ),

          const SizedBox(height: 10),

          // Two-Line User / Admin Badge:
          // "ให้ ผู้ใช้งาน และผู้ดูแลระบบ อยู่ด้านบน และชื่อคนอยู่ด้านล่างคนละบรรทัด"
          ValueListenableBuilder<LoggedInTeacher?>(
            valueListenable: apiService.currentUserNotifier,
            builder: (context, user, _) {
              if (user == null) {
                return App3DButton.gold(
                  onPressed: onPromptLogin,
                  fullWidth: true,
                  borderRadius: 10,
                  depth: 2.8,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.login_rounded, size: 16, color: Color(0xFF451A03)),
                      const SizedBox(width: 6),
                      Text(
                        'เข้าสู่ระบบครู / บุคลากร',
                        style: TextStyle(
                          fontFamily: font,
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          color: const Color(0xFF451A03),
                        ),
                      ),
                    ],
                  ),
                );
              }

              final isAdmin = user.isAdmin;
              final isDirector = user.isDirector;
              final isGuest = user.isGuest;

              Color badgeBg;
              Color badgeBorder;
              Color shelfColor;
              Color roleColor;
              Color nameColor;
              IconData roleIcon;
              String roleText;
              String nameText;

              if (isAdmin) {
                // 1. ผู้ดูแลระบบ (Admin)
                badgeBg = AppColors.goldLight;
                badgeBorder = secondaryColor;
                shelfColor = AppColors.goldDark;
                roleColor = const Color(0xFF78350F);
                nameColor = const Color(0xFF451A03);
                roleIcon = Icons.shield_rounded;
                roleText = 'ผู้ดูแลระบบ';
                nameText = isDirector ? 'ผอ.${user.baseName}' : 'ครู${user.baseName}';
              } else if (isDirector) {
                // 2. ผู้อำนวยการ (Director)
                badgeBg = primaryColor.withValues(alpha: 0.7);
                badgeBorder = secondaryColor;
                shelfColor = secondaryColor.withValues(alpha: 0.6);
                roleColor = secondaryColor;
                nameColor = const Color(0xFFFEF08A);
                roleIcon = Icons.stars_rounded;
                roleText = 'ผู้อำนวยการ';
                nameText = user.name;
              } else if (isGuest) {
                // 3. บุคคลทั่วไป (Guest)
                badgeBg = const Color(0xFF1E1B4B);
                badgeBorder = const Color(0xFFA5B4FC);
                shelfColor = const Color(0xFF312E81);
                roleColor = const Color(0xFFA5B4FC);
                nameColor = Colors.white;
                roleIcon = Icons.visibility_rounded;
                roleText = 'บุคคลทั่วไป';
                nameText = 'ผู้เยี่ยมชม (โหมดดูอย่างเดียว)';
              } else {
                // 4. ผู้ใช้งานทั่วไป (Teacher)
                badgeBg = primaryColor.withValues(alpha: 0.5);
                badgeBorder = secondaryColor.withValues(alpha: 0.7);
                shelfColor = primaryColor.withValues(alpha: 0.8);
                roleColor = secondaryColor;
                nameColor = Colors.white;
                roleIcon = Icons.person_rounded;
                roleText = 'ผู้ใช้งาน';
                nameText = 'ครู${user.baseName}';
              }

              return Tooltip(
                message: '${user.headerTitle} (รหัส: ${user.code})\nคลิกเพื่อสลับผู้ใช้หรือออกจากระบบ',
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: InkWell(
                    onTap: () => onShowUserMenu(user),
                    borderRadius: BorderRadius.circular(10),
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                        color: badgeBg,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: badgeBorder, width: 1.5),
                        boxShadow: [
                          BoxShadow(
                            color: shelfColor,
                            offset: const Offset(0, 2.5),
                            blurRadius: 0, // 3D shelf
                          ),
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.15),
                            blurRadius: 4,
                            offset: const Offset(0, 3),
                          ),
                        ],
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // Line 1: Role on top ("ผู้อำนวยการ", "ผู้ดูแลระบบ", "บุคคลทั่วไป", "ผู้ใช้งาน")
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                roleIcon,
                                size: 14,
                                color: roleColor,
                              ),
                              const SizedBox(width: 5),
                              Text(
                                roleText,
                                style: TextStyle(
                                  fontFamily: font,
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w800,
                                  color: roleColor,
                                  height: 1.3,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 3),
                          // Line 2: Name on bottom on separate line
                          Text(
                            nameText,
                            textAlign: TextAlign.center,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontFamily: font,
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                              color: nameColor,
                              height: 1.3,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

/// A specialized rectangular 3D tactile button for sidebar navigation
/// Pops up into a 3D raised button on hover and depresses on press
class Sidebar3DNavItem extends StatefulWidget {
  final SchoolThemeConfig themeConfig;
  final IconData icon;
  final Widget Function(Color color, bool isSelected)? customIconBuilder;
  final String label;
  final bool isSelected;
  final bool isLocked;
  final String? lockTooltip;
  final VoidCallback onTap;

  const Sidebar3DNavItem({
    super.key,
    required this.themeConfig,
    required this.icon,
    this.customIconBuilder,
    required this.label,
    required this.isSelected,
    this.isLocked = false,
    this.lockTooltip,
    required this.onTap,
  });

  @override
  State<Sidebar3DNavItem> createState() => _Sidebar3DNavItemState();
}

class _Sidebar3DNavItemState extends State<Sidebar3DNavItem> {
  bool _isHovered = false;
  bool _isPressed = false;

  @override
  Widget build(BuildContext context) {
    final isSelected = widget.isSelected;
    final isLocked = widget.isLocked;
    final themeConfig = widget.themeConfig;
    final primary = themeConfig.primaryColor;
    final secondary = themeConfig.secondaryColor;
    final font = themeConfig.fontFamily;

    final hslSecondary = HSLColor.fromColor(secondary);
    final secondaryDark = hslSecondary.withLightness((hslSecondary.lightness - 0.15).clamp(0.0, 1.0)).toColor();

    final hslPrimary = HSLColor.fromColor(primary);
    final primaryLight = hslPrimary.withLightness((hslPrimary.lightness + 0.12).clamp(0.0, 1.0)).toColor();
    final primaryDark = hslPrimary.withLightness((hslPrimary.lightness - 0.12).clamp(0.0, 1.0)).toColor();

    // Translation values for physical 3D lift/drop
    double offsetY = 0.0;
    double shelfHeight = 0.0;
    Color shelfColor = Colors.transparent;
    Color bgColor = Colors.transparent;
    Border border = Border.all(color: Colors.transparent, width: 1.5);
    Color textColor = isLocked ? const Color(0xFF94A3B8) : Colors.white.withValues(alpha: 0.85);
    Color iconColor = isLocked ? const Color(0xFF94A3B8) : Colors.white.withValues(alpha: 0.85);

    if (isLocked) {
      // Locked state: subtle feedback, do not pop up aggressively
      if (_isHovered) {
        bgColor = const Color(0x15EF4444);
        border = Border.all(color: const Color(0x44EF4444), width: 1.2);
      }
    } else if (_isPressed) {
      // Pressed state: depresses downwards
      offsetY = 1.8;
      shelfHeight = 0.8;
      shelfColor = secondaryDark;
      bgColor = primaryDark;
      border = Border.all(color: secondary, width: 1.6);
      textColor = secondary;
      iconColor = secondary;
    } else if (isSelected) {
      // Selected state: Solid 3D rectangular extrusion
      offsetY = -1.2;
      shelfHeight = 3.2;
      shelfColor = secondaryDark;
      bgColor = primary;
      border = Border.all(color: secondary, width: 1.8);
      textColor = secondary;
      iconColor = secondary;
    } else if (_isHovered) {
      // Hovered state: Pops up into a raised 3D rectangular button!
      offsetY = -2.4;
      shelfHeight = 3.5;
      shelfColor = secondary;
      bgColor = primaryLight;
      border = Border.all(color: secondary, width: 1.5);
      textColor = secondary;
      iconColor = secondary;
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _isHovered = true),
        onExit: (_) => setState(() {
          _isHovered = false;
          _isPressed = false;
        }),
        child: Listener(
          onPointerDown: (_) {
            HapticFeedback.lightImpact();
            setState(() => _isPressed = true);
          },
          onPointerUp: (_) => setState(() => _isPressed = false),
          onPointerCancel: (_) => setState(() => _isPressed = false),
          child: GestureDetector(
            onTap: widget.onTap,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 70),
              curve: Curves.easeOutQuad,
              transform: Matrix4.translationValues(0, offsetY, 0),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: bgColor,
                borderRadius: BorderRadius.circular(10), // สี่เหลี่ยมมุมมน
                border: border,
                boxShadow: shelfHeight > 0
                    ? [
                        // Solid 3D bottom extrusion shelf
                        BoxShadow(
                          color: shelfColor,
                          offset: Offset(0, shelfHeight),
                          blurRadius: 0,
                        ),
                        // Ambient soft shadow
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.2),
                          offset: Offset(0, shelfHeight + 1.5),
                          blurRadius: 4,
                        ),
                      ]
                    : null,
              ),
              child: Row(
                children: [
                  // Active indicator bar on the left edge
                  if (isSelected)
                    Container(
                      width: 4,
                      height: 22,
                      margin: const EdgeInsets.only(right: 10),
                      decoration: BoxDecoration(
                        color: secondary,
                        borderRadius: BorderRadius.circular(2),
                        boxShadow: [
                          BoxShadow(
                            color: secondary,
                            blurRadius: 4,
                          ),
                        ],
                      ),
                    ),

                  if (widget.customIconBuilder != null)
                    widget.customIconBuilder!(iconColor, isSelected)
                  else
                    Icon(
                      widget.icon,
                      size: 22,
                      color: iconColor,
                    ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      widget.label,
                      style: TextStyle(
                        fontFamily: font,
                        fontSize: 16.5, // เพิ่มขนาดฟอนต์อีก 3 เลเวล (เดิม 13.5 -> 16.5)
                        fontWeight: isSelected ? FontWeight.w800 : FontWeight.w700,
                        color: textColor,
                        height: 1.35, // ป้องกันสระลอยตัดทอน
                      ),
                    ),
                  ),

                  // Lock icon or small arrow indicator
                  if (isLocked)
                    Tooltip(
                      message: widget.lockTooltip ?? 'ล็อกการเข้าถึง',
                      child: const Icon(
                        Icons.lock_rounded,
                        size: 16,
                        color: Color(0xFFF87171), // Soft red lock
                      ),
                    )
                  else if (_isHovered || isSelected)
                    Icon(
                      Icons.chevron_right_rounded,
                      size: 18,
                      color: secondary,
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
