import 'course.dart';

class LoggedInTeacher {
  final String code;
  final String name;
  final bool isAdmin;
  final bool isDirector;
  final bool isPersonnelHead; // หัวหน้าบุคคล (server: school_profile.personnel_head_code)
  final bool isGuest;
  final bool isStudent; // นักเรียน: sees only own attendance (student portal)
  final String loginPin;

  LoggedInTeacher({
    required this.code,
    required this.name,
    required this.isAdmin,
    this.isDirector = false,
    this.isPersonnelHead = false,
    this.isGuest = false,
    this.isStudent = false,
    this.loginPin = '',
  });

  /// Factory for Guest session (บุคคลทั่วไป - โหมดดูอย่างเดียว ไม่ต้องใส่รหัส)
  factory LoggedInTeacher.guest() {
    return LoggedInTeacher(
      code: 'GUEST',
      name: 'ผู้เยี่ยมชมระบบ',
      isAdmin: false,
      isDirector: false,
      isPersonnelHead: false,
      isGuest: true,
      loginPin: '',
    );
  }

  factory LoggedInTeacher.fromJson(
    Map<String, dynamic> json, {
    bool? isAdminOverride,
    bool? isDirectorOverride,
  }) {
    final code = (json['code'] ?? '').toString().trim();
    final name = (json['name'] ?? '').toString().trim();
    final isGuest = json['is_guest'] == true || code.toUpperCase() == 'GUEST';
    final isStudent = json['is_student'] == true;

    // Auto-detect director by code 1234 or is_director flag or name
    bool directorFlag = isDirectorOverride ?? (json['is_director'] == true);
    if (!directorFlag && !isGuest && !isStudent) {
      if (code == '1234' ||
          name.contains('สภกริษฐ์') ||
          name.startsWith('ผู้อำนวยการ') ||
          name.startsWith('ผอ.')) {
        directorFlag = true;
      }
    }

    final isPersonnelHead = json['is_personnel_head'] == true;

    return LoggedInTeacher(
      code: code,
      name: name,
      isAdmin: isAdminOverride ?? (json['is_admin'] == true),
      isDirector: directorFlag,
      isPersonnelHead: isPersonnelHead,
      isGuest: isGuest,
      isStudent: isStudent,
      loginPin: (json['login_pin'] ?? json['code'] ?? '').toString().trim(),
    );
  }

  LoggedInTeacher copyWith({
    String? code,
    String? name,
    bool? isAdmin,
    bool? isDirector,
    bool? isPersonnelHead,
    bool? isGuest,
    String? loginPin,
  }) {
    return LoggedInTeacher(
      code: code ?? this.code,
      name: name ?? this.name,
      isAdmin: isAdmin ?? this.isAdmin,
      isDirector: isDirector ?? this.isDirector,
      isPersonnelHead: isPersonnelHead ?? this.isPersonnelHead,
      isGuest: isGuest ?? this.isGuest,
      isStudent: isStudent,
      loginPin: loginPin ?? this.loginPin,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'code': code,
      'name': name,
      'is_admin': isAdmin,
      'is_director': isDirector,
      'is_personnel_head': isPersonnelHead,
      'is_guest': isGuest,
      'is_student': isStudent,
      'login_pin': loginPin,
    };
  }

  String get roleDisplay {
    if (isAdmin) return 'ผู้ดูแลระบบ';
    if (isDirector) return 'ผู้อำนวยการโรงเรียน';
    if (isPersonnelHead) return 'หัวหน้าบุคคล';
    if (isGuest) return 'ผู้เยี่ยมชม';
    if (isStudent) return 'นักเรียน';
    return 'ครูผู้สอน';
  }

  /// Whether user can access the scores record screen (หน้าบันทึกคะแนน)
  /// User requirement: "หน้าบันทึกคะแนน ดูไม่ได้ ล็อกปุ่มนี้สำหรับ บุคคลทั่วไป กับผู้อำนวยการ"
  bool get canAccessScores => !isGuest && !isDirector && !isStudent;

  /// Whether user can access system settings (หน้าตั้งค่า)
  /// บุคคลทั่วไปและนักเรียนเข้าไม่ได้ และผู้อำนวยการก็ถูกล็อกไว้เช่นเดียวกับหน้าบันทึกคะแนน
  bool get canAccessSettings => !isGuest && !isStudent && !isDirector;

  /// Whether user may change school data at all (แก้ไขชื่อนักเรียน ฯลฯ)
  /// ผู้อำนวยการ บุคคลทั่วไป และนักเรียน ดูได้อย่างเดียว
  bool get canEditData => !isGuest && !isStudent && !isDirector;

  /// Whether user may save a file from the system (ดาวน์โหลด / นำออก / แบบฟอร์ม)
  /// ผู้อำนวยการดูข้อมูลบนหน้าจอได้ทุกหน้า แต่ดาวน์โหลดไฟล์ไม่ได้ (เซิร์ฟเวอร์บังคับอีกชั้น)
  bool get canDownload => !isGuest && !isStudent && !isDirector;

  /// Whether user can edit home visit surveys (หน้าเยี่ยมบ้าน: กรอก/แก้ไขผลสำรวจ)
  /// User requirement: "หน้าเยี่ยมบ้าน ดูได้เเค่ข้อมูลแดชบอร์ดของแต่ละห้อง และแดชบอร์ดรวม แต่เข้าดูหน้า กรอก แก้ไขผลสำรวจไม่ได้"
  bool get canEditHomeVisit => !isGuest && !isStudent;

  /// Whether user is in strict read-only mode
  bool get isReadOnly => isGuest || isStudent;

  /// Role label for display in UI badge
  String get roleLabel {
    if (isAdmin) return 'ผู้ดูแลระบบ';
    if (isDirector) return 'ผู้อำนวยการ';
    if (isGuest) return 'บุคคลทั่วไป';
    if (isStudent) return 'นักเรียน';
    return 'ผู้ใช้งาน';
  }

  /// Strips honorifics (นาย, นางสาว, นาง, etc.) to get clean base name
  String get baseName {
    String clean = name.trim();
    final prefixes = [
      'ผู้อำนวยการโรงเรียน',
      'ว่าที่ร้อยตรี',
      'ว่าที่ ร.ต.',
      'นางสาว',
      'นาย',
      'นาง',
      'ครู',
      'ผอ.',
      'ดร.',
    ];
    for (final p in prefixes) {
      if (clean.startsWith(p)) {
        clean = clean.substring(p.length).trim();
        break;
      }
    }
    return clean;
  }

  /// Formatted header title: "ผู้ดูแลระบบ ครู...", "ผู้อำนวยการ ...", "บุคคลทั่วไป" or "ผู้ใช้งาน ครู..."
  String get headerTitle {
    if (isAdmin) return 'ผู้ดูแลระบบ ครู$baseName';
    if (isDirector) return 'ผู้อำนวยการ $name';
    if (isGuest) return 'บุคคลทั่วไป (ผู้เยี่ยมชม)';
    if (isStudent) return 'นักเรียน $name';
    return 'ผู้ใช้งาน ครู$baseName';
  }

  /// Normalized representation for comparing different spelling or prefix variants
  static String normalize(String? s) {
    if (s == null) return '';
    var clean = s.trim();
    final prefixes = [
      'ผู้อำนวยการโรงเรียน',
      'ว่าที่ร้อยตรี',
      'ว่าที่ ร.ต.',
      'นางสาว',
      'นาย',
      'นาง',
      'ครู',
      'ผอ.',
      'ดร.',
    ];
    for (final p in prefixes) {
      if (clean.startsWith(p)) {
        clean = clean.substring(p.length).trim();
        break;
      }
    }
    return clean.replaceAll(RegExp(r'\s+'), '');
  }

  /// Check whether the logged-in user can edit or download a course
  bool canManageCourse(Course course) {
    if (isGuest || isDirector || isStudent) return false;
    if (isAdmin) return true;
    if (course.teacherCode != null && course.teacherCode!.trim().isNotEmpty) {
      if (course.teacherCode!.trim() == code.trim()) return true;
    }
    final cNameNorm = normalize(course.teacher);
    final myNorm = normalize(name);
    if (cNameNorm.isEmpty || myNorm.isEmpty) return false;
    return cNameNorm == myNorm || cNameNorm.contains(myNorm) || myNorm.contains(cNameNorm);
  }

  /// Check whether the logged-in user can edit a timetable slot or teacher timetable
  bool canManageTimetable(String? timetableTeacher) {
    if (isGuest || isStudent) return false;
    if (isAdmin) return true;
    if (timetableTeacher == null || timetableTeacher.trim().isEmpty) return false;
    final tNorm = normalize(timetableTeacher);
    final myNorm = normalize(name);
    if (tNorm.isEmpty || myNorm.isEmpty) return false;
    return tNorm == myNorm || tNorm.contains(myNorm) || myNorm.contains(tNorm);
  }
}
