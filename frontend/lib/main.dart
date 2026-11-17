// ระบบบันทึกเวลาเรียนและ ปพ.5 - พัฒนาและออกแบบโดย วรรณเมฑี นามบุดดี (ดู app_credits.dart, LICENSE)
import 'dart:ui' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'services/api_service.dart';
import 'models/logged_in_teacher.dart';
import 'models/school_theme_config.dart';
import 'widgets/teacher_login_dialog.dart';
import 'widgets/recovery_dialog.dart';
import 'widgets/student_portal.dart';
import 'widgets/app_sidebar.dart';
import 'widgets/house_icon.dart';
import 'utils/app_theme.dart';
import 'screens/dashboard_screen.dart';
import 'screens/upload_process_screen.dart';
import 'screens/archive_screen.dart';
import 'screens/attendance_screen.dart';
import 'screens/scores_screen.dart';
import 'screens/timetable_screen.dart';
import 'screens/home_visit_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/exams_screen.dart';
import 'screens/leave_screen.dart';
import 'screens/ai_assistant_screen.dart';

void main() {
  runApp(const SGSApp());
}

class SGSApp extends StatefulWidget {
  const SGSApp({super.key});

  @override
  State<SGSApp> createState() => _SGSAppState();
}

class _SGSAppState extends State<SGSApp> {
  final ApiService _apiService = ApiService();

  @override
  void initState() {
    super.initState();
    _apiService.getSchoolLogoInfo();
    _apiService.getSchoolTheme();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<SchoolThemeConfig>(
      valueListenable: _apiService.themeNotifier,
      builder: (context, themeConfig, _) {
        final theme = AppTheme.buildThemeFromConfig(themeConfig);
        return ValueListenableBuilder<String>(
          valueListenable: _apiService.webTitleNotifier,
          builder: (context, webTitle, _) {
            return MaterialApp(
              title: webTitle,
              debugShowCheckedModeBanner: false,
              theme: theme,
              darkTheme: theme,
              themeMode: ThemeMode.light,
              scrollBehavior: const AppScrollBehavior(),
              home: MainShell(apiService: _apiService),
            );
          },
        );
      },
    );
  }
}

/// Every scroll view can be dragged with a mouse, finger, trackpad or pen. Flutter web
/// ignores mouse drags by default, which made the wide check-in tables impossible to
/// scroll sideways on a PC without Shift+wheel.
class AppScrollBehavior extends MaterialScrollBehavior {
  const AppScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => {
        PointerDeviceKind.touch,
        PointerDeviceKind.mouse,
        PointerDeviceKind.trackpad,
        PointerDeviceKind.stylus,
        PointerDeviceKind.invertedStylus,
      };
}

class MainShell extends StatefulWidget {
  final ApiService apiService;
  const MainShell({super.key, required this.apiService});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _selectedIndex = 0;
  ApiService get _apiService => widget.apiService;

  void _showAccessDeniedSnackBar(String message) {
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(Icons.lock_rounded, color: Colors.amberAccent, size: 22),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                message,
                style: const TextStyle(fontFamily: 'Sarabun', fontSize: 13.5, height: 1.3),
              ),
            ),
          ],
        ),
        backgroundColor: const Color(0xFF2D124D),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 4),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: AppColors.gold, width: 1.5),
        ),
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _apiService.getSchoolLogoInfo();
    _apiService.loadSchoolProfile(); // ชื่อโรงเรียน สังกัด (หัวรายงาน หัวตาราง)
    _apiService.getSemesterConfigs();
    _initAuthSession();
  }

  Future<void> _initAuthSession() async {
    // เครื่องที่ลงใหม่ (ฐานข้อมูลว่าง): ยังไม่มีใครล็อกอินได้ -> เปิดหน้ากู้คืนจากไฟล์สำรองก่อน
    final rec = await _apiService.recoveryStatus();
    if (!mounted) return;
    if (rec['needs_recovery'] == true) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        await RecoveryDialog.show(context, _apiService, local: rec['local'] == true);
        if (mounted) _promptLogin(canCancel: false);
      });
      return;
    }
    final user = await _apiService.loadStoredSession();
    if (!mounted) return;
    if (user == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _promptLogin(canCancel: false);
      });
    }
  }

  Future<void> _promptLogin({bool canCancel = false}) async {
    await TeacherLoginDialog.show(
      context,
      apiService: _apiService,
      canCancel: canCancel,
    );
    if (mounted) setState(() {});
  }

  void _showUserMenu(LoggedInTeacher user) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        final isAdmin = user.isAdmin;
        final isDirector = user.isDirector;
        final isGuest = user.isGuest;

        Color badgeBg;
        Color badgeBorder;
        Color roleColor;
        IconData roleIcon;
        String roleTitle;

        if (isAdmin) {
          badgeBg = AppColors.goldLight;
          badgeBorder = AppColors.gold;
          roleColor = const Color(0xFF78350F);
          roleIcon = Icons.shield_rounded;
          roleTitle = 'ผู้ดูแลระบบ (Admin)';
        } else if (isDirector) {
          badgeBg = const Color(0xFFFEF3C7);
          badgeBorder = AppColors.gold;
          roleColor = const Color(0xFFB45309);
          roleIcon = Icons.stars_rounded;
          roleTitle = 'ผู้อำนวยการโรงเรียน (Director)';
        } else if (isGuest) {
          badgeBg = const Color(0xFFEEF2FF);
          badgeBorder = const Color(0xFFA5B4FC);
          roleColor = const Color(0xFF3730A3);
          roleIcon = Icons.visibility_rounded;
          roleTitle = 'บุคคลทั่วไป (โหมดดูอย่างเดียว)';
        } else {
          badgeBg = cs.primaryContainer;
          badgeBorder = cs.primary.withValues(alpha: 0.3);
          roleColor = cs.primary;
          roleIcon = Icons.person_rounded;
          roleTitle = 'ผู้ใช้งาน (ครูผู้สอน)';
        }

        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    CircleAvatar(
                      radius: 24,
                      backgroundColor: badgeBg,
                      child: Icon(
                        roleIcon,
                        color: roleColor,
                        size: 26,
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            user.name,
                            style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                          ),
                          const SizedBox(height: 2),
                          Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: badgeBg,
                                  borderRadius: BorderRadius.circular(4),
                                  border: Border.all(color: badgeBorder),
                                ),
                                child: Text(
                                  roleTitle,
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                    color: roleColor,
                                  ),
                                ),
                              ),
                              if (!isGuest) ...[
                                const SizedBox(width: 8),
                                Text(
                                  'รหัส: ${user.code}',
                                  style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                                ),
                              ],
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                const Divider(),
                ListTile(
                  leading: const Icon(Icons.switch_account_outlined),
                  title: const Text('สลับผู้ใช้งาน (เปลี่ยนรหัสครู)'),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  onTap: () {
                    Navigator.of(ctx).pop();
                    _promptLogin(canCancel: true);
                  },
                ),
                ListTile(
                  leading: Icon(Icons.logout_rounded, color: Colors.red.shade700),
                  title: Text('ออกจากระบบ', style: TextStyle(color: Colors.red.shade700, fontWeight: FontWeight.w600)),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  onTap: () async {
                    Navigator.of(ctx).pop();
                    await _apiService.logoutTeacher();
                    if (mounted) {
                      _promptLogin(canCancel: false);
                    }
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _openUploadDialog() {
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: const BorderSide(color: AppColors.gold, width: 1.5),
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 900, maxHeight: 750),
          child: Stack(
            children: [
              UploadProcessScreen(apiService: _apiService),
              Positioned(
                top: 12,
                right: 12,
                child: IconButton(
                  icon: const Icon(Icons.close_rounded),
                  onPressed: () => Navigator.of(ctx).pop(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Keep the browser tab title (ชื่อหน้าเว็บ) in sync with the value saved in Settings.
    return ValueListenableBuilder<String>(
      valueListenable: _apiService.webTitleNotifier,
      builder: (context, webTitle, _) => Title(
        title: webTitle,
        color: AppColors.purpleDark,
        child: _buildShell(context),
      ),
    );
  }

  // Pages บุคคลทั่วไป may open: 0 = แดชบอร์ด, 4 = ตารางสอน
  static const Set<int> _guestPages = {0, 4};

  Widget _buildStudentShell() {
    final user = _apiService.currentUser!;
    return Scaffold(
      appBar: AppBar(
        title: Text('นักเรียน ${user.name}', overflow: TextOverflow.ellipsis),
        actions: [
          TextButton.icon(
            icon: const Icon(Icons.logout_rounded),
            label: const Text('ออกจากระบบ'),
            onPressed: () async {
              await _apiService.logoutTeacher();
              if (mounted) {
                setState(() {});
                _promptLogin(canCancel: false);
              }
            },
          ),
        ],
      ),
      body: StudentPortalScreen(apiService: _apiService),
    );
  }

  Widget _buildShell(BuildContext context) {
    final isWide = MediaQuery.of(context).size.width >= 800;

    final isGuest = _apiService.currentUser?.isGuest ?? false;
    // นักเรียน: only their own attendance, no navigation
    if (_apiService.currentUser?.isStudent ?? false) {
      return _buildStudentShell();
    }
    // บุคคลทั่วไป: dashboard (names masked by the server) and timetable only
    final currentIndex = isGuest && !_guestPages.contains(_selectedIndex) ? 0 : _selectedIndex;

    final screens = [
      DashboardScreen(
        apiService: _apiService,
        onNavigateToAttendance: (classLevel) {
          setState(() => _selectedIndex = 2);
        },
        onNavigateToUpload: isGuest ? null : _openUploadDialog,
      ),
      ArchiveScreen(
        apiService: _apiService,
        onNavigateToUpload: isGuest ? null : _openUploadDialog,
      ),
      AttendanceScreen(apiService: _apiService),
      ScoresScreen(apiService: _apiService),
      TimetableScreen(apiService: _apiService),
      HomeVisitScreen(apiService: _apiService),
      ExamsScreen(apiService: _apiService),
      AiAssistantScreen(apiService: _apiService),
      LeaveScreen(apiService: _apiService),
      SettingsScreen(apiService: _apiService),
    ];

    if (isWide) {
      // Desktop / Wide layout with Custom 3D Rectangular Sidebar
      return Scaffold(
        body: Row(
          children: [
            AppSidebar(
              selectedIndex: currentIndex,
              onDestinationSelected: (index) {
                final user = _apiService.currentUser;
                if (user != null && user.isGuest && !_guestPages.contains(index)) {
                  _showAccessDeniedSnackBar('บุคคลทั่วไปดูได้เฉพาะแดชบอร์ด (ไม่แสดงชื่อนักเรียน) และตารางสอน\nกรุณาเข้าสู่ระบบเพื่อดูข้อมูลเพิ่มเติม');
                  return;
                }
                if (index == 3 && user != null && !user.canAccessScores) {
                  _showAccessDeniedSnackBar(
                    'หน้าบันทึกคะแนนสงวนสิทธิ์เฉพาะคุณครูผู้สอนประจำวิชาเท่านั้น\n(ผู้อำนวยการและบุคคลทั่วไปไม่สามารถเข้าถึงได้)',
                  );
                  return;
                }
                if (index == 7 && user != null && !user.canAccessScores) {
                  _showAccessDeniedSnackBar('ตัวช่วย AI ออกข้อสอบสำหรับครูผู้สอนเท่านั้น');
                  return;
                }
                if (index == 9 && user != null && !user.canAccessSettings) {
                  _showAccessDeniedSnackBar('หน้าตั้งค่าสงวนสิทธิ์เฉพาะคณะครูและผู้ดูแลระบบเท่านั้น');
                  return;
                }
                setState(() => _selectedIndex = index);
                if (index == 0) {
                  _apiService.dashboardResetNotifier.value++;
                }
              },
              apiService: _apiService,
              onPromptLogin: () => _promptLogin(canCancel: false),
              onShowUserMenu: _showUserMenu,
            ),
            Expanded(child: screens[currentIndex]),
          ],
        ),
      );
    } else {
      // Narrow / Mobile layout with BottomNavigationBar
      return ValueListenableBuilder<SchoolThemeConfig>(
        valueListenable: _apiService.themeNotifier,
        builder: (context, themeConfig, _) {
          final menuColor = themeConfig.menuColor;
          final secondaryColor = themeConfig.secondaryColor;
          final primaryColor = themeConfig.primaryColor;
          final font = themeConfig.fontFamily;

          return Scaffold(
            appBar: AppBar(
              titleSpacing: 8,
              backgroundColor: menuColor,
              bottom: PreferredSize(
                preferredSize: const Size.fromHeight(1.5),
                child: Divider(height: 1.5, thickness: 1.5, color: secondaryColor),
              ),
              title: Row(
                children: [
                  Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: secondaryColor, width: 1.2),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: Image.network(
                      _apiService.getSchoolLogoUrl(),
                      fit: BoxFit.contain,
                      errorBuilder: (ctx, err, stack) => Icon(Icons.school, size: 20, color: primaryColor),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        ValueListenableBuilder<String>(
                          valueListenable: _apiService.schoolNameNotifier,
                          builder: (context, name, _) => Text(
                            name,
                            style: TextStyle(
                              fontFamily: font,
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: secondaryColor,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        ValueListenableBuilder<LoggedInTeacher?>(
                          valueListenable: _apiService.currentUserNotifier,
                          builder: (context, user, _) {
                            if (user == null) {
                              return Text(
                                'ยังไม่ได้เข้าสู่ระบบ',
                                style: TextStyle(fontFamily: font, fontSize: 10, color: secondaryColor),
                              );
                            }
                            return Text(
                              user.headerTitle,
                              style: TextStyle(
                                fontFamily: font,
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                                color: user.isAdmin ? secondaryColor : Colors.white70,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              actions: [
                IconButton(
                  icon: Icon(Icons.manage_accounts_outlined, color: secondaryColor),
                  tooltip: 'สลับผู้ใช้ / ออกจากระบบ',
                  onPressed: () {
                    final u = _apiService.currentUser;
                    if (u != null) {
                      _showUserMenu(u);
                    } else {
                      _promptLogin(canCancel: false);
                    }
                  },
                ),
              ],
            ),
            body: screens[currentIndex],
            bottomNavigationBar: NavigationBar(
              selectedIndex: currentIndex,
              onDestinationSelected: (index) {
                final user = _apiService.currentUser;
                if (user != null && user.isGuest && !_guestPages.contains(index)) {
                  _showAccessDeniedSnackBar('บุคคลทั่วไปดูได้เฉพาะแดชบอร์ด (ไม่แสดงชื่อนักเรียน) และตารางสอน\nกรุณาเข้าสู่ระบบเพื่อดูข้อมูลเพิ่มเติม');
                  return;
                }
                if (index == 3 && user != null && !user.canAccessScores) {
                  _showAccessDeniedSnackBar(
                    'หน้าบันทึกคะแนนสงวนสิทธิ์เฉพาะคุณครูผู้สอนประจำวิชาเท่านั้น\n(ผู้อำนวยการและบุคคลทั่วไปไม่สามารถเข้าถึงได้)',
                  );
                  return;
                }
                if (index == 7 && user != null && !user.canAccessScores) {
                  _showAccessDeniedSnackBar('ตัวช่วย AI ออกข้อสอบสำหรับครูผู้สอนเท่านั้น');
                  return;
                }
                if (index == 9 && user != null && !user.canAccessSettings) {
                  _showAccessDeniedSnackBar('หน้าตั้งค่าสงวนสิทธิ์เฉพาะคณะครูและผู้ดูแลระบบเท่านั้น');
                  return;
                }
                setState(() => _selectedIndex = index);
              },
              destinations: [
                const NavigationDestination(
                  icon: Icon(Icons.dashboard_outlined),
                  selectedIcon: Icon(Icons.dashboard),
                  label: 'แดชบอร์ด',
                ),
                const NavigationDestination(
                  icon: Icon(Icons.inventory_2_outlined),
                  selectedIcon: Icon(Icons.inventory_2),
                  label: 'คลังข้อมูล',
                ),
                const NavigationDestination(
                  icon: Icon(Icons.fact_check_outlined),
                  selectedIcon: Icon(Icons.fact_check),
                  label: 'เช็คเวลาเรียน',
                ),
                const NavigationDestination(
                  icon: Icon(Icons.rate_review_outlined),
                  selectedIcon: Icon(Icons.rate_review),
                  label: 'บันทึกคะแนน',
                ),
                const NavigationDestination(
                  icon: Icon(Icons.calendar_month_outlined),
                  selectedIcon: Icon(Icons.calendar_month),
                  label: 'ตารางสอน',
                ),
                NavigationDestination(
                  icon: const HouseIcon(size: 22, color: Color(0xFFD8B4FE), isFilled: false),
                  selectedIcon: HouseIcon(size: 22, color: secondaryColor, isFilled: true),
                  label: 'เยี่ยมบ้าน',
                ),
                const NavigationDestination(
                  icon: Icon(Icons.quiz_outlined),
                  selectedIcon: Icon(Icons.quiz),
                  label: 'ข้อสอบ',
                ),
                const NavigationDestination(
                  icon: Icon(Icons.auto_awesome_outlined),
                  selectedIcon: Icon(Icons.auto_awesome),
                  label: 'ตัวช่วย AI',
                ),
                const NavigationDestination(
                  icon: Icon(Icons.event_note_outlined),
                  selectedIcon: Icon(Icons.event_note),
                  label: 'บันทึกการลา',
                ),
                const NavigationDestination(
                  icon: Icon(Icons.settings_outlined),
                  selectedIcon: Icon(Icons.settings),
                  label: 'ตั้งค่า',
                ),
              ],
            ),
          );
        },
      );
    }
  }
}
