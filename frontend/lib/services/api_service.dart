import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/course.dart';
import '../models/student_grade.dart';
import '../models/process_result.dart';
import '../models/semester_config.dart';
import '../models/class_advisor.dart';
import '../models/logged_in_teacher.dart';
import '../models/school_theme_config.dart';
import 'host_page.dart';

import 'package:flutter/foundation.dart';

class ApiService {
  String baseUrl;

  ApiService({String? baseUrl})
      : baseUrl = baseUrl ??
            (kIsWeb && Uri.base.origin.isNotEmpty && !Uri.base.origin.startsWith('file:')
                ? Uri.base.origin
                : 'http://localhost:8000');

  /// Check if the backend server is reachable
  Future<bool> checkHealth() async {
    try {
      final response = await http.get(Uri.parse('$baseUrl/api/health')).timeout(
        const Duration(seconds: 5),
      );
      return response.statusCode == 200;
    } catch (_) {
      // Fallback check on root if api/health is not available
      try {
        final fallback = await http.get(Uri.parse('$baseUrl/')).timeout(
          const Duration(seconds: 3),
        );
        return fallback.statusCode == 200;
      } catch (_) {
        return false;
      }
    }
  }

  /// Upload a SGS PDF and run the full processing pipeline
  Future<ProcessResult> uploadAndProcessPdf(
    Uint8List bytes,
    String filename, {
    String? description,
    String? term,
    String? year,
    String? teacher,
  }) async {
    final uri = Uri.parse('$baseUrl/api/v1/process-pdf');
    final request = http.MultipartRequest('POST', uri)
      ..files.add(http.MultipartFile.fromBytes('file', bytes, filename: filename));

    if (description != null && description.trim().isNotEmpty) {
      request.fields['description'] = description.trim();
    }
    if (term != null && term.isNotEmpty) {
      request.fields['term'] = term;
    }
    if (year != null && year.isNotEmpty) {
      request.fields['year'] = year;
    }
    if (teacher != null && teacher.trim().isNotEmpty) {
      request.fields['teacher'] = teacher.trim();
    }

    final streamedResponse = await request.send().timeout(
      const Duration(minutes: 5),
    );
    final response = await http.Response.fromStream(streamedResponse);

    if (response.statusCode != 200) {
      final body = jsonDecode(response.body);
      throw Exception(body['detail'] ?? 'Processing failed (${response.statusCode})');
    }

    final body = jsonDecode(response.body);
    return ProcessResult.fromJson(body['data']);
  }

  /// Get course description and auto-fitting metrics
  Future<Map<String, dynamic>> getCourseDescription(String courseCode) async {
    final uri = Uri.parse('$baseUrl/api/v1/course-description').replace(
      queryParameters: {'course_code': courseCode},
    );
    final response = await http.get(uri);
    if (response.statusCode != 200) {
      throw Exception('Failed to fetch course description');
    }
    final body = jsonDecode(response.body);
    return body['data'] as Map<String, dynamic>;
  }

  /// Save course description and auto-fit into Excel & PDF
  Future<Map<String, dynamic>> saveCourseDescription(
    String courseCode,
    String description,
  ) async {
    final uri = Uri.parse('$baseUrl/api/v1/course-description');
    final response = await http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'course_code': courseCode,
        'description': description,
      }),
    );
    if (response.statusCode != 200) {
      final body = jsonDecode(response.body);
      throw Exception(body['detail'] ?? 'Failed to save course description');
    }
    final body = jsonDecode(response.body);
    return body['data'] as Map<String, dynamic>;
  }

  /// Fetch student attendance roster for a course
  Future<Map<String, dynamic>> getAttendance(
    String courseCode, {
    String? term,
    String? year,
    bool syncFromDaily = false,
  }) async {
    final params = {'course_code': courseCode};
    if (term != null) params['term'] = term;
    if (year != null) params['year'] = year;
    if (syncFromDaily) params['sync_from_daily'] = 'true';
    final uri = Uri.parse('$baseUrl/api/v1/attendance').replace(queryParameters: params);
    final response = await http.get(uri);
    if (response.statusCode != 200) {
      throw Exception('Failed to fetch attendance');
    }
    final body = jsonDecode(response.body);
    return body['data'] as Map<String, dynamic>;
  }

  /// Upload multiple SGS PDFs at once
  Future<List<Map<String, dynamic>>> uploadAndProcessMultiplePdfs(
    List<({Uint8List bytes, String filename})> files, {
    String? term,
    String? year,
  }) async {
    final uri = Uri.parse('$baseUrl/api/v1/process-multiple-pdfs');
    final request = http.MultipartRequest('POST', uri);
    for (final f in files) {
      request.files.add(http.MultipartFile.fromBytes('files', f.bytes, filename: f.filename));
    }
    if (term != null && term.isNotEmpty) {
      request.fields['term'] = term;
    }
    if (year != null && year.isNotEmpty) {
      request.fields['year'] = year;
    }

    final streamedResponse = await request.send().timeout(
      const Duration(minutes: 15),
    );
    final response = await http.Response.fromStream(streamedResponse);

    if (response.statusCode != 200) {
      final body = jsonDecode(response.body);
      throw Exception(body['detail'] ?? 'Batch processing failed (${response.statusCode})');
    }

    final body = jsonDecode(response.body);
    return List<Map<String, dynamic>>.from(body['results']);
  }

  /// Save attendance records for a course
  Future<Map<String, dynamic>> saveAttendance({
    required String courseCode,
    required List<Map<String, dynamic>> students,
    String? term,
    String? year,
    String? startDate,
    Map<String, dynamic>? schedule,
  }) async {
    final payload = <String, dynamic>{
      'course_code': courseCode,
      'students': students,
    };
    if (term != null) payload['term'] = term;
    if (year != null) payload['year'] = year;
    if (startDate != null) payload['start_date'] = startDate;
    if (schedule != null) payload['schedule'] = schedule;

    final uri = Uri.parse('$baseUrl/api/v1/attendance');
    final response = await http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(payload),
    );
    if (response.statusCode != 200) {
      final body = jsonDecode(response.body);
      throw Exception(body['detail'] ?? 'Failed to save attendance');
    }
    final body = jsonDecode(response.body);
    return body['data'] as Map<String, dynamic>;
  }

  /// Fetch all archived courses
  Future<List<Course>> getCourses() async {
    final response = await http.get(Uri.parse('$baseUrl/api/v1/courses'));
    if (response.statusCode != 200) {
      throw Exception('Failed to fetch courses');
    }
    final body = jsonDecode(response.body);
    final list = body['data'] as List;
    return list.map((e) => Course.fromJson(e)).toList();
  }

  /// Fetch all students
  Future<List<Map<String, dynamic>>> getStudents() async {
    final response = await http.get(Uri.parse('$baseUrl/api/v1/students'));
    if (response.statusCode != 200) {
      throw Exception('Failed to fetch students');
    }
    final body = jsonDecode(response.body);
    return List<Map<String, dynamic>>.from(body['data']);
  }

  /// Fetch grade history by term/year (optional course filter)
  Future<List<StudentGrade>> getGrades({
    required String term,
    required String year,
    String? courseCode,
  }) async {
    final params = {'term': term, 'year': year};
    if (courseCode != null) params['course_code'] = courseCode;
    final uri = Uri.parse('$baseUrl/api/v1/grades').replace(queryParameters: params);
    final response = await http.get(uri);
    if (response.statusCode != 200) {
      throw Exception('Failed to fetch grades');
    }
    final body = jsonDecode(response.body);
    final list = body['data'] as List;
    return list.map((e) => StudentGrade.fromJson(e)).toList();
  }

  /// Fetch a student's full transcript
  Future<List<StudentGrade>> getStudentTranscript(String studentId) async {
    final response = await http.get(
      Uri.parse('$baseUrl/api/v1/student/$studentId/transcript'),
    );
    if (response.statusCode != 200) {
      throw Exception('Failed to fetch transcript');
    }
    final body = jsonDecode(response.body);
    final list = body['data'] as List;
    return list.map((e) => StudentGrade.fromJson({
      ...e,
      'student_id': studentId,
      'full_name': '',
    })).toList();
  }

  /// Build a download URL for a generated file
  String getDownloadUrl(String filename) {
    return '$baseUrl/api/v1/download/${Uri.encodeComponent(filename)}';
  }

  /// Build a download URL for a course ปพ.5 Excel or PDF file
  String getCourseFileUrl(String courseCode, {String format = 'excel', String? term, String? year}) {
    var url = '$baseUrl/api/v1/course-file?course_code=${Uri.encodeComponent(courseCode)}&format=$format';
    if (term != null) url += '&term=$term';
    if (year != null) url += '&year=$year';
    return url;
  }

  /// Build a print viewer URL for a course ปพ.5 PDF file
  String getPrintPdfUrl(String courseCode, {String? term, String? year}) {
    var url = '$baseUrl/api/v1/print-pdf?course_code=${Uri.encodeComponent(courseCode)}';
    if (term != null) url += '&term=$term';
    if (year != null) url += '&year=$year';
    return url;
  }

  /// Get comprehensive verification data for a course
  Future<Map<String, dynamic>> getCoursePreview(String courseCode, {String? term, String? year}) async {
    final params = {'course_code': courseCode};
    if (term != null) params['term'] = term;
    if (year != null) params['year'] = year;
    final uri = Uri.parse('$baseUrl/api/v1/course-preview').replace(queryParameters: params);
    final response = await http.get(uri);
    if (response.statusCode != 200) {
      final body = jsonDecode(utf8.decode(response.bodyBytes));
      throw Exception(body['detail'] ?? 'ไม่สามารถดึงข้อมูลตรวจสอบรายวิชาได้');
    }
    final body = jsonDecode(utf8.decode(response.bodyBytes));
    return body['data'] as Map<String, dynamic>;
  }

  /// Get all real PDF pages and their rendered image URLs
  Future<Map<String, dynamic>> getCoursePdfPages(String courseCode, {String? term, String? year, bool force = false}) async {
    final params = {'course_code': courseCode};
    if (term != null) params['term'] = term;
    if (year != null) params['year'] = year;
    if (force) params['force'] = 'true';
    final uri = Uri.parse('$baseUrl/api/v1/course-pdf-pages').replace(queryParameters: params);
    final response = await http.get(uri);
    if (response.statusCode != 200) {
      final body = jsonDecode(utf8.decode(response.bodyBytes));
      throw Exception(body['detail'] ?? 'ไม่สามารถดึงข้อมูลหน้า PDF ได้');
    }
    return jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
  }

  /// Get all real Excel sheets with tabular rows, merges, and styles for inspection
  Future<Map<String, dynamic>> getCourseExcelSheets(String courseCode, {String? term, String? year}) async {
    final params = {'course_code': courseCode};
    if (term != null) params['term'] = term;
    if (year != null) params['year'] = year;
    final uri = Uri.parse('$baseUrl/api/v1/course-excel-sheets').replace(queryParameters: params);
    final response = await http.get(uri);
    if (response.statusCode != 200) {
      final body = jsonDecode(utf8.decode(response.bodyBytes));
      throw Exception(body['detail'] ?? 'ไม่สามารถดึงข้อมูลแผ่นงาน Excel ได้');
    }
    return jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
  }

  /// Build a URL to open the real Excel full-screen viewer
  String getCourseExcelViewUrl(String courseCode, {String? term, String? year}) {
    var url = '$baseUrl/api/v1/course-excel-view?course_code=${Uri.encodeComponent(courseCode)}';
    if (term != null) url += '&term=$term';
    if (year != null) url += '&year=$year';
    return url;
  }

  /// Update teacher name for a course
  Future<Map<String, dynamic>> updateCourseTeacher({
    required String courseCode,
    required String teacher,
    String? term,
    String? year,
  }) async {
    final uri = Uri.parse('$baseUrl/api/v1/course/teacher');
    final response = await http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'course_code': courseCode,
        'teacher': teacher,
        'term': term,
        'year': year,
      }),
    );
    if (response.statusCode != 200) {
      final body = jsonDecode(utf8.decode(response.bodyBytes));
      throw Exception(body['detail'] ?? 'อัปเดตชื่อครูผู้สอนไม่สำเร็จ');
    }
    return jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
  }

  /// Import one or multiple Excel files (.xlsx) into archive database
  Future<Map<String, dynamic>> importExcelFiles({
    required List<({Uint8List bytes, String filename})> files,
    String? term,
    String? year,
    String? teacher,
  }) async {
    final uri = Uri.parse('$baseUrl/api/v1/import-excel');
    final request = http.MultipartRequest('POST', uri);
    for (final f in files) {
      request.files.add(http.MultipartFile.fromBytes('files', f.bytes, filename: f.filename));
    }
    if (term != null && term.isNotEmpty) request.fields['term'] = term;
    if (year != null && year.isNotEmpty) request.fields['year'] = year;
    if (teacher != null && teacher.trim().isNotEmpty) request.fields['teacher'] = teacher.trim();

    final streamedResponse = await request.send().timeout(
      const Duration(minutes: 15),
    );
    final response = await http.Response.fromStream(streamedResponse);

    if (response.statusCode != 200) {
      final body = jsonDecode(response.body);
      throw Exception(body['detail'] ?? 'การนำเข้าไฟล์ Excel ล้มเหลว (${response.statusCode})');
    }

    final body = jsonDecode(response.body);
    return body as Map<String, dynamic>;
  }

  /// Scan and import all Excel files from a folder path
  Future<Map<String, dynamic>> importExcelFolder({
    required String folderPath,
    String? term,
    String? year,
    String? teacher,
  }) async {
    final uri = Uri.parse('$baseUrl/api/v1/import-excel-folder');
    final payload = <String, dynamic>{
      'folder_path': folderPath,
      'term': term,
      'year': year,
    };
    if (teacher != null && teacher.trim().isNotEmpty) {
      payload['teacher'] = teacher.trim();
    }
    final response = await http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(payload),
    );
    if (response.statusCode != 200) {
      final body = jsonDecode(response.body);
      throw Exception(body['detail'] ?? 'การนำเข้าจากโฟลเดอร์ล้มเหลว (${response.statusCode})');
    }
    final body = jsonDecode(response.body);
    return body as Map<String, dynamic>;
  }

  /// Fetch current semester calculated from system clock by backend
  Future<Map<String, String>> getCurrentSemester() async {
    try {
      final uri = Uri.parse('$baseUrl/api/v1/current-semester');
      final response = await http.get(uri);
      if (response.statusCode == 200) {
        final body = jsonDecode(utf8.decode(response.bodyBytes));
        return {
          'term': body['term']?.toString() ?? '1',
          'year': body['year']?.toString() ?? '2569',
          'title': body['title']?.toString() ?? '',
        };
      }
    } catch (_) {}
    return {};
  }

  /// Fetch all semester configurations
  Future<List<SemesterConfigItem>> getSemesterConfigs() async {
    final uri = Uri.parse('$baseUrl/api/v1/settings/semesters');
    final response = await http.get(uri);
    if (response.statusCode != 200) {
      throw Exception('ไม่สามารถดึงข้อมูลการตั้งค่าภาคเรียนได้');
    }
    final body = jsonDecode(utf8.decode(response.bodyBytes));
    final list = body['data'] as List;
    final configs = list.map((item) => SemesterConfigItem.fromJson(item)).toList();
    // my_mark = ภาคเรียนที่ผู้ใช้คนนี้ mark ไว้ดูเอง; ถ้าไม่ได้ mark ใช้ของโรงเรียน (ที่ผู้ดูแลระบบตั้ง)
    myMarkedSemester = body['my_mark'] as String?;
    if (configs.isNotEmpty) {
      final mine = myMarkedSemester?.split('-');
      SemesterConfigItem? picked;
      if (mine != null && mine.length == 2) {
        for (final s in configs) {
          if (s.term == mine[0] && s.year == mine[1]) picked = s;
        }
      }
      defaultSemesterNotifier.value = picked ??
          configs.firstWhere(
            (s) => s.isDefault,
            orElse: () => configs.firstWhere((s) => s.isActive, orElse: () => configs.first),
          );
    }
    return configs;
  }

  /// ภาคเรียนที่ผู้ใช้คนนี้ mark ไว้ดูเอง ("term-year") — null = ใช้ของโรงเรียน
  String? myMarkedSemester;

  /// Mark ภาคเรียนไว้ดูเอง (ไม่กระทบคนอื่น) ส่ง clear=true เพื่อกลับไปใช้ของโรงเรียน
  Future<void> markMySemester({String? term, String? year, bool clear = false}) async {
    final r = await _examRequest('POST', '/api/v1/settings/semesters/mark-mine',
        body: {'term': term, 'year': year, 'clear': clear});
    myMarkedSemester = ((r['data'] as Map?) ?? const {})['my_mark'] as String?;
  }

  /// ผู้ดูแลระบบ: ไล่ปรับคำนำหน้าตามอายุทันที
  Future<Map<String, dynamic>> refreshStudentPrefixes() async {
    final r = await _examRequest('POST', '/api/v1/students/refresh-prefixes');
    return Map<String, dynamic>.from(r);
  }

  /// คำนำหน้า / ชื่อ / สกุล ของนักเรียน (แยกช่อง)
  Future<Map<String, dynamic>> getStudentName(String studentId) async {
    final r = await _examRequest('GET', '/api/v1/students/$studentId/name');
    return Map<String, dynamic>.from(r['data']);
  }

  /// แก้ชื่อนักเรียน แล้วระบบอัปเดตให้ทุกหน้าและ ปพ.5 ทันที
  Future<Map<String, dynamic>> setStudentName(String studentId,
      {required String prefix, required String firstName, required String lastName}) async {
    final r = await _examRequest('POST', '/api/v1/students/$studentId/name',
        body: {'prefix': prefix, 'first_name': firstName, 'last_name': lastName});
    return Map<String, dynamic>.from(r['data']);
  }

  /// Create or update a semester configuration
  Future<SemesterConfigItem> saveSemesterConfig(SemesterConfigItem config) async {
    final uri = Uri.parse('$baseUrl/api/v1/settings/semesters');
    final response = await http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(config.toJson()),
    );
    if (response.statusCode != 200) {
      final body = jsonDecode(utf8.decode(response.bodyBytes));
      throw Exception(body['detail'] ?? 'ไม่สามารถบันทึกการตั้งค่าภาคเรียนได้');
    }
    final body = jsonDecode(utf8.decode(response.bodyBytes));
    return SemesterConfigItem.fromJson(body['data']);
  }

  /// Delete a semester configuration button
  Future<void> deleteSemesterConfig(int configId) async {
    final uri = Uri.parse('$baseUrl/api/v1/settings/semesters/$configId');
    final response = await http.delete(uri);
    if (response.statusCode != 200) {
      final body = jsonDecode(utf8.decode(response.bodyBytes));
      throw Exception(body['detail'] ?? 'ไม่สามารถลบปุ่มภาคเรียนได้');
    }
  }

  /// Reset semester configuration buttons to defaults
  Future<List<SemesterConfigItem>> resetSemesterConfigsToDefaults() async {
    final uri = Uri.parse('$baseUrl/api/v1/settings/semesters/reset-defaults');
    final response = await http.post(uri);
    if (response.statusCode != 200) {
      final body = jsonDecode(utf8.decode(response.bodyBytes));
      throw Exception(body['detail'] ?? 'ไม่สามารถคืนค่าปุ่มเริ่มต้นได้');
    }
    final body = jsonDecode(utf8.decode(response.bodyBytes));
    final list = body['data'] as List;
    return list.map((item) => SemesterConfigItem.fromJson(item)).toList();
  }

  /// Delete all data for a specific semester
  Future<Map<String, dynamic>> deleteSemesterData({
    required String term,
    required String year,
    bool deleteFiles = false,
    bool backupFirst = false,
    String? backupLabel,
  }) async {
    final uri = Uri.parse('$baseUrl/api/v1/settings/semesters/delete-data');
    final response = await http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'term': term,
        'year': year,
        'delete_files': deleteFiles,
        'backup_first': backupFirst,
        'backup_label': backupLabel,
      }),
    );
    if (response.statusCode != 200) {
      final body = jsonDecode(utf8.decode(response.bodyBytes));
      throw Exception(body['detail'] ?? 'ลบข้อมูลภาคเรียนไม่สำเร็จ');
    }
    final body = jsonDecode(utf8.decode(response.bodyBytes));
    return body['data'] as Map<String, dynamic>;
  }

  /// Reset all data in the system
  Future<Map<String, dynamic>> resetAllData({
    bool deleteFiles = false,
    bool backupFirst = false,
    String? backupLabel,
  }) async {
    final uri = Uri.parse('$baseUrl/api/v1/settings/reset-all-data');
    final response = await http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'delete_files': deleteFiles,
        'backup_first': backupFirst,
        'backup_label': backupLabel,
      }),
    );
    if (response.statusCode != 200) {
      final body = jsonDecode(utf8.decode(response.bodyBytes));
      throw Exception(body['detail'] ?? 'รีเซ็ตข้อมูลทั้งหมดไม่สำเร็จ');
    }
    final body = jsonDecode(utf8.decode(response.bodyBytes));
    return body['data'] as Map<String, dynamic>;
  }

  // ===========================================================================
  // BACKUP & ARCHIVE (การจัดเก็บและกู้คืนข้อมูลสำรอง) METHODS
  // ===========================================================================

  /// List all available backups
  Future<List<Map<String, dynamic>>> getBackups() async {
    final uri = Uri.parse('$baseUrl/api/v1/backups');
    final response = await http.get(uri);
    if (response.statusCode != 200) {
      final body = jsonDecode(utf8.decode(response.bodyBytes));
      throw Exception(body['detail'] ?? 'ไม่สามารถดึงข้อมูลรายการสำรองได้');
    }
    final body = jsonDecode(utf8.decode(response.bodyBytes));
    final list = (body['data'] as List<dynamic>?) ?? [];
    return list.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  /// Create a new backup snapshot
  Future<Map<String, dynamic>> createBackup({
    String? label,
    String? term,
    String? year,
    String backupType = 'full',
  }) async {
    final uri = Uri.parse('$baseUrl/api/v1/backups/create');
    final response = await http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'label': label,
        'term': term,
        'year': year,
        'backup_type': backupType,
      }),
    );
    if (response.statusCode != 200) {
      final body = jsonDecode(utf8.decode(response.bodyBytes));
      throw Exception(body['detail'] ?? 'จัดเก็บข้อมูลสำรองไม่สำเร็จ');
    }
    final body = jsonDecode(utf8.decode(response.bodyBytes));
    return body['data'] as Map<String, dynamic>;
  }

  /// Restore from a backup
  Future<Map<String, dynamic>> restoreBackup({
    required String backupId,
    String mode = 'full',
    String? targetTerm,
    String? targetYear,
    String? srcTerm,
    String? srcYear,
  }) async {
    final uri = Uri.parse('$baseUrl/api/v1/backups/restore');
    final response = await http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'backup_id': backupId,
        'mode': mode,
        'target_term': targetTerm,
        'target_year': targetYear,
        'src_term': srcTerm,
        'src_year': srcYear,
      }),
    );
    if (response.statusCode != 200) {
      final body = jsonDecode(utf8.decode(response.bodyBytes));
      throw Exception(body['detail'] ?? 'กู้คืนข้อมูลสำรองไม่สำเร็จ');
    }
    final body = jsonDecode(utf8.decode(response.bodyBytes));
    return body['data'] as Map<String, dynamic>;
  }

  /// Delete a backup
  Future<void> deleteBackup(String backupId) async {
    final uri = Uri.parse('$baseUrl/api/v1/backups/$backupId');
    final response = await http.delete(uri);
    if (response.statusCode != 200) {
      final body = jsonDecode(utf8.decode(response.bodyBytes));
      throw Exception(body['detail'] ?? 'ลบไฟล์สำรองไม่สำเร็จ');
    }
  }

  // ===========================================================================
  // CLASS ADVISORS (ครูประจำชั้น / ครูที่ปรึกษา) METHODS
  // ===========================================================================

  /// Fetch class advisors for a given semester
  Future<List<ClassAdvisorItem>> getClassAdvisors({required String term, required String year}) async {
    final uri = Uri.parse('$baseUrl/api/v1/advisors?term=$term&year=$year');
    final response = await http.get(uri);
    if (response.statusCode != 200) {
      final body = jsonDecode(utf8.decode(response.bodyBytes));
      throw Exception(body['detail'] ?? 'ไม่สามารถดึงข้อมูลครูที่ปรึกษาได้');
    }
    final body = jsonDecode(utf8.decode(response.bodyBytes));
    final list = (body['data'] as List<dynamic>?) ?? [];
    return list.map((e) => ClassAdvisorItem.fromJson(e as Map<String, dynamic>)).toList();
  }

  /// Create or update a class advisor entry
  Future<Map<String, dynamic>> upsertClassAdvisor(ClassAdvisorItem item) async {
    final uri = Uri.parse('$baseUrl/api/v1/advisors');
    final response = await http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(item.toJson()),
    );
    if (response.statusCode != 200) {
      final body = jsonDecode(utf8.decode(response.bodyBytes));
      throw Exception(body['detail'] ?? 'บันทึกข้อมูลครูที่ปรึกษาไม่สำเร็จ');
    }
    return jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
  }

  /// Delete a class advisor entry
  Future<void> deleteClassAdvisor(int id) async {
    final uri = Uri.parse('$baseUrl/api/v1/advisors/$id');
    final response = await http.delete(uri);
    if (response.statusCode != 200) {
      final body = jsonDecode(utf8.decode(response.bodyBytes));
      throw Exception(body['detail'] ?? 'ลบข้อมูลครูที่ปรึกษาไม่สำเร็จ');
    }
  }

  /// Copy advisors from one semester to another
  Future<Map<String, dynamic>> copyClassAdvisors({
    required String fromTerm,
    required String fromYear,
    required String toTerm,
    required String toYear,
  }) async {
    final uri = Uri.parse('$baseUrl/api/v1/advisors/copy');
    final response = await http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'from_term': fromTerm,
        'from_year': fromYear,
        'to_term': toTerm,
        'to_year': toYear,
      }),
    );
    if (response.statusCode != 200) {
      final body = jsonDecode(utf8.decode(response.bodyBytes));
      throw Exception(body['detail'] ?? 'คัดลอกรายชื่อครูที่ปรึกษาไม่สำเร็จ');
    }
    return jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
  }

  /// Upload bulk advisors file (.xlsx or .csv)
  Future<Map<String, dynamic>> uploadClassAdvisorsFile(
    Uint8List bytes,
    String filename, {
    required String term,
    required String year,
  }) async {
    final uri = Uri.parse('$baseUrl/api/v1/advisors/upload');
    final request = http.MultipartRequest('POST', uri);
    request.fields['term'] = term;
    request.fields['year'] = year;
    request.files.add(http.MultipartFile.fromBytes('file', bytes, filename: filename));

    final streamedResponse = await request.send().timeout(const Duration(minutes: 5));
    final response = await http.Response.fromStream(streamedResponse);

    if (response.statusCode != 200) {
      final body = jsonDecode(utf8.decode(response.bodyBytes));
      throw Exception(body['detail'] ?? 'การนำเข้ารายชื่อครูที่ปรึกษาล้มเหลว');
    }
    return jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
  }

  /// Get download URL for the Excel advisors template
  String getClassAdvisorsTemplateUrl() {
    return '$baseUrl/api/v1/advisors/template';
  }

  /// Get download URL for standard student roster template (.xlsx)
  String getStudentsTemplateUrl() {
    return '$baseUrl/api/v1/students/template';
  }

  /// Get download URL for course structure template (.xlsx or .csv)
  String getCoursesTemplateUrl({String format = 'xlsx'}) {
    return '$baseUrl/api/v1/courses/template?format=$format';
  }

  // ===========================================================================
  // MASTER SCHOOL TEACHERS ROSTER METHODS
  // ===========================================================================

  /// Get all teachers in the school master roster
  Future<List<String>> getSchoolTeachers() async {
    final uri = Uri.parse('$baseUrl/api/v1/teachers');
    final response = await http.get(uri);
    if (response.statusCode != 200) {
      final body = jsonDecode(utf8.decode(response.bodyBytes));
      throw Exception(body['detail'] ?? 'ไม่สามารถดึงรายชื่อครูทั้งหมดได้');
    }
    final body = jsonDecode(utf8.decode(response.bodyBytes));
    final list = (body['data'] as List?)?.map((e) => e.toString()).toList() ?? [];
    return list;
  }

  /// Add a single teacher
  Future<List<String>> addSchoolTeacher(String name) async {
    final uri = Uri.parse('$baseUrl/api/v1/teachers');
    final response = await http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'name': name}),
    );
    if (response.statusCode != 200) {
      final body = jsonDecode(utf8.decode(response.bodyBytes));
      throw Exception(body['detail'] ?? 'ไม่สามารถเพิ่มรายชื่อครูได้');
    }
    final body = jsonDecode(utf8.decode(response.bodyBytes));
    return (body['data'] as List?)?.map((e) => e.toString()).toList() ?? [];
  }

  /// Bulk import multiple teachers
  Future<List<String>> bulkAddSchoolTeachers(List<String> names) async {
    final uri = Uri.parse('$baseUrl/api/v1/teachers');
    final response = await http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'names': names}),
    );
    if (response.statusCode != 200) {
      final body = jsonDecode(utf8.decode(response.bodyBytes));
      throw Exception(body['detail'] ?? 'ไม่สามารถนำเข้ารายชื่อครูได้');
    }
    final body = jsonDecode(utf8.decode(response.bodyBytes));
    return (body['data'] as List?)?.map((e) => e.toString()).toList() ?? [];
  }

  /// Delete a teacher from the master roster
  Future<List<String>> deleteSchoolTeacher(String name) async {
    final encoded = Uri.encodeComponent(name);
    final uri = Uri.parse('$baseUrl/api/v1/teachers/$encoded');
    final response = await http.delete(uri);
    if (response.statusCode != 200) {
      final body = jsonDecode(utf8.decode(response.bodyBytes));
      throw Exception(body['detail'] ?? 'ไม่สามารถลบรายชื่อครูได้');
    }
    final body = jsonDecode(utf8.decode(response.bodyBytes));
    return (body['data'] as List?)?.map((e) => e.toString()).toList() ?? [];
  }

  /// Sync/discover teachers from all courses and advisors in system
  Future<List<String>> syncSchoolTeachers() async {
    final uri = Uri.parse('$baseUrl/api/v1/teachers/sync');
    final response = await http.post(uri);
    if (response.statusCode != 200) {
      final body = jsonDecode(utf8.decode(response.bodyBytes));
      throw Exception(body['detail'] ?? 'ไม่สามารถดึงข้อมูลครูจากระบบได้');
    }
    final body = jsonDecode(utf8.decode(response.bodyBytes));
    return (body['data'] as List?)?.map((e) => e.toString()).toList() ?? [];
  }

  /// Get teachers with their code and id
  Future<List<Map<String, dynamic>>> getSchoolTeachersWithCode() async {
    final uri = Uri.parse('$baseUrl/api/v1/teachers');
    final response = await http.get(uri);
    if (response.statusCode != 200) {
      final body = jsonDecode(utf8.decode(response.bodyBytes));
      throw Exception(body['detail'] ?? 'ไม่สามารถดึงข้อมูลครูได้');
    }
    final body = jsonDecode(utf8.decode(response.bodyBytes));
    if (body['teachers'] != null && body['teachers'] is List) {
      return List<Map<String, dynamic>>.from(body['teachers']);
    }
    final rawList = body['data'] as List? ?? [];
    return rawList.map((t) => {'id': 0, 'name': t.toString(), 'code': ''}).toList();
  }

  /// Add a teacher with optional code and loginPin
  Future<Map<String, dynamic>> addSchoolTeacherWithCode({required String name, String? code, String? loginPin}) async {
    final uri = Uri.parse('$baseUrl/api/v1/teachers');
    final response = await http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'name': name,
        'code': code,
        if (loginPin != null && loginPin.trim().isNotEmpty) 'login_pin': loginPin.trim(),
      }),
    );
    if (response.statusCode != 200) {
      final body = jsonDecode(utf8.decode(response.bodyBytes));
      throw Exception(body['detail'] ?? 'ไม่สามารถเพิ่มครูได้');
    }
    return jsonDecode(utf8.decode(response.bodyBytes));
  }

  /// Update teacher name, code, and optional loginPin
  Future<Map<String, dynamic>> updateSchoolTeacher({required int id, required String name, String? code, String? loginPin}) async {
    final uri = Uri.parse('$baseUrl/api/v1/teachers/$id');
    final response = await http.put(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'name': name,
        'code': code,
        if (loginPin != null && loginPin.trim().isNotEmpty) 'login_pin': loginPin.trim(),
      }),
    );
    if (response.statusCode != 200) {
      final body = jsonDecode(utf8.decode(response.bodyBytes));
      throw Exception(body['detail'] ?? 'ไม่สามารถอัปเดตข้อมูลครูได้');
    }
    return jsonDecode(utf8.decode(response.bodyBytes));
  }

  /// Update teacher login PIN (1 to 4 digits)
  Future<Map<String, dynamic>> updateTeacherPin(String teacherCode, String newPin) async {
    final uri = Uri.parse('$baseUrl/api/v1/teachers/${teacherCode.trim()}/pin');
    final response = await http.put(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'pin': newPin.trim()}),
    );
    final body = jsonDecode(utf8.decode(response.bodyBytes));
    if (response.statusCode != 200) {
      throw Exception(body['detail'] ?? 'ไม่สามารถเปลี่ยนรหัสใช้งานได้');
    }
    if (currentUser != null && currentUser!.code.trim() == teacherCode.trim()) {
      currentUserNotifier.value = currentUser!.copyWith(loginPin: newPin.trim());
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('saved_teacher_pin', newPin.trim());
      } catch (_) {}
    }
    return body as Map<String, dynamic>;
  }

  /// Delete teacher by id or name
  Future<bool> deleteSchoolTeacherByIdOrName(dynamic idOrName) async {
    final encoded = Uri.encodeComponent(idOrName.toString());
    final uri = Uri.parse('$baseUrl/api/v1/teachers/$encoded');
    final response = await http.delete(uri);
    return response.statusCode == 200;
  }

  /// Get courses (subject + class level) taught by a teacher (name or code)
  Future<List<Map<String, dynamic>>> getTeacherCourses({
    required String teacher,
    String? term,
    String? year,
  }) async {
    final params = <String, String>{'teacher': teacher};
    if (term != null && term.isNotEmpty) params['term'] = term;
    if (year != null && year.isNotEmpty) params['year'] = year;
    final uri = Uri.parse('$baseUrl/api/v1/teachers/courses').replace(queryParameters: params);
    final response = await http.get(uri);
    final body = jsonDecode(utf8.decode(response.bodyBytes));
    if (response.statusCode != 200) {
      throw Exception(body['detail'] ?? 'ไม่สามารถดึงรายวิชาของครูได้');
    }
    return List<Map<String, dynamic>>.from(body['data'] ?? []);
  }

  /// Create or update a single course assignment (regenerates PorPor 5 template)
  Future<Map<String, dynamic>> saveCourseItem(Map<String, dynamic> payload) async {
    final uri = Uri.parse('$baseUrl/api/v1/courses/item');
    final response = await http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(payload),
    );
    final body = jsonDecode(utf8.decode(response.bodyBytes));
    if (response.statusCode != 200) {
      throw Exception(body['detail'] ?? 'ไม่สามารถบันทึกรายวิชาได้');
    }
    return body;
  }

  /// Delete a single course assignment
  Future<bool> deleteCourseItem({
    required String courseCode,
    required String term,
    required String year,
  }) async {
    final uri = Uri.parse('$baseUrl/api/v1/courses/item').replace(queryParameters: {
      'course_code': courseCode,
      'term': term,
      'year': year,
    });
    final response = await http.delete(uri);
    if (response.statusCode != 200) {
      final body = jsonDecode(utf8.decode(response.bodyBytes));
      throw Exception(body['detail'] ?? 'ไม่สามารถลบรายวิชาได้');
    }
    final body = jsonDecode(utf8.decode(response.bodyBytes));
    return body['deleted'] == true;
  }

  /// Import course structure and generate PorPor 5 Excel & PDF
  Future<Map<String, dynamic>> importCourses({
    Uint8List? fileBytes,
    String? filename,
    String? csvText,
    required String term,
    required String year,
    bool generateExcel = true,
    bool generatePdf = false,
  }) async {
    final uri = Uri.parse('$baseUrl/api/v1/courses/import');
    final request = http.MultipartRequest('POST', uri);
    request.fields['term'] = term;
    request.fields['year'] = year;
    request.fields['generate_excel'] = generateExcel.toString();
    request.fields['generate_pdf'] = generatePdf.toString();

    if (fileBytes != null && filename != null) {
      request.files.add(http.MultipartFile.fromBytes('file', fileBytes, filename: filename));
    } else if (csvText != null && csvText.trim().isNotEmpty) {
      request.fields['csv_text'] = csvText.trim();
    }

    final streamed = await request.send().timeout(const Duration(minutes: 10));
    final resp = await http.Response.fromStream(streamed);
    final body = jsonDecode(utf8.decode(resp.bodyBytes));
    if (resp.statusCode != 200) {
      throw Exception(body['detail'] ?? 'เกิดข้อผิดพลาดในการนำเข้ารายวิชา');
    }
    return body;
  }

  // ===========================================================================
  // SCHOOL SIGNATORIES (ข้อมูลผู้ลงนามและผู้บริหาร หน้าปก ปพ.5)
  // ===========================================================================

  /// Get school signatories configuration for an academic year
  Future<Map<String, dynamic>> getSignatories({String? year}) async {
    final params = <String, String>{};
    if (year != null && year.trim().isNotEmpty) {
      params['year'] = year.trim();
    }
    final uri = Uri.parse('$baseUrl/api/v1/settings/signatories').replace(queryParameters: params.isNotEmpty ? params : null);
    final response = await http.get(uri);
    if (response.statusCode != 200) {
      final body = jsonDecode(utf8.decode(response.bodyBytes));
      throw Exception(body['detail'] ?? 'ไม่สามารถดึงข้อมูลผู้ลงนามได้');
    }
    final body = jsonDecode(utf8.decode(response.bodyBytes));
    return body['data'] as Map<String, dynamic>;
  }

  /// Save or update school signatories
  Future<Map<String, dynamic>> saveSignatories(Map<String, dynamic> data) async {
    final uri = Uri.parse('$baseUrl/api/v1/settings/signatories');
    final response = await http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(data),
    );
    if (response.statusCode != 200) {
      final body = jsonDecode(utf8.decode(response.bodyBytes));
      throw Exception(body['detail'] ?? 'ไม่สามารถบันทึกข้อมูลผู้ลงนามได้');
    }
    return jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
  }

  /// Copy school signatories from one year to another
  Future<Map<String, dynamic>> copySignatories(String fromYear, String toYear, {bool syncExistingFiles = true}) async {
    final uri = Uri.parse('$baseUrl/api/v1/settings/signatories/copy');
    final response = await http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'from_year': fromYear,
        'to_year': toYear,
        'sync_existing_files': syncExistingFiles,
      }),
    );
    if (response.statusCode != 200) {
      final body = jsonDecode(utf8.decode(response.bodyBytes));
      throw Exception(body['detail'] ?? 'ไม่สามารถคัดลอกข้อมูลผู้ลงนามได้');
    }
    return jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
  }

  // ===========================================================================
  // DAILY SCHOOL ATTENDANCE (ระบบเช็คเวลาเรียนรวมประจำวัน)
  // ===========================================================================

  /// Get available class levels for a semester
  Future<List<String>> getDailyAttendanceClassLevels({
    required String term,
    required String year,
  }) async {
    final uri = Uri.parse('$baseUrl/api/v1/daily-attendance/class-levels').replace(
      queryParameters: {'term': term, 'year': year},
    );
    final response = await http.get(uri);
    if (response.statusCode != 200) {
      final body = jsonDecode(utf8.decode(response.bodyBytes));
      throw Exception(body['detail'] ?? 'ไม่สามารถดึงข้อมูลระดับชั้นได้');
    }
    final body = jsonDecode(utf8.decode(response.bodyBytes));
    return (body['data'] as List?)?.map((e) => e.toString()).toList() ?? [];
  }

  /// Get daily attendance records for a class on a specific date
  Future<Map<String, dynamic>> getDailyAttendance({
    required String term,
    required String year,
    required String classLevel,
    required String date,
  }) async {
    final uri = Uri.parse('$baseUrl/api/v1/daily-attendance').replace(
      queryParameters: {
        'term': term,
        'year': year,
        'class_level': classLevel,
        'date': date,
      },
    );
    final response = await http.get(uri);
    if (response.statusCode != 200) {
      final body = jsonDecode(utf8.decode(response.bodyBytes));
      throw Exception(body['detail'] ?? 'ไม่สามารถดึงข้อมูลเช็คชื่อประจำวันได้');
    }
    final body = jsonDecode(utf8.decode(response.bodyBytes));
    return body['data'] as Map<String, dynamic>;
  }

  /// Save daily attendance records
  Future<Map<String, dynamic>> saveDailyAttendance({
    required String term,
    required String year,
    required String classLevel,
    required String date,
    required List<Map<String, dynamic>> records,
  }) async {
    final uri = Uri.parse('$baseUrl/api/v1/daily-attendance');
    final response = await http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'term': term,
        'year': year,
        'class_level': classLevel,
        'date': date,
        'records': records,
      }),
    );
    if (response.statusCode != 200) {
      final body = jsonDecode(utf8.decode(response.bodyBytes));
      throw Exception(body['detail'] ?? 'ไม่สามารถบันทึกข้อมูลเช็คชื่อประจำวันได้');
    }
    return jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
  }

  /// Get school-wide daily attendance summary for all class levels
  Future<Map<String, dynamic>> getDailyAttendanceSummary({
    required String term,
    required String year,
    required String date,
  }) async {
    final uri = Uri.parse('$baseUrl/api/v1/daily-attendance/summary').replace(
      queryParameters: {'term': term, 'year': year, 'date': date},
    );
    final response = await http.get(uri);
    if (response.statusCode != 200) {
      final body = jsonDecode(utf8.decode(response.bodyBytes));
      throw Exception(body['detail'] ?? 'ไม่สามารถดึงข้อมูลสรุปการมาเรียนได้');
    }
    final body = jsonDecode(utf8.decode(response.bodyBytes));
    return body['data'] as Map<String, dynamic>;
  }

  /// Get 20-week (100 slots, Mon-Fri) daily attendance grid for a class level
  Future<Map<String, dynamic>> getDailyAttendanceGrid({
    required String term,
    required String year,
    required String classLevel,
    String? room,
    String? startDate,
  }) async {
    final params = {'term': term, 'year': year, 'class_level': classLevel};
    if (room != null && room.isNotEmpty && room != 'all' && room != 'ทั้งหมด') {
      params['room'] = room;
    }
    if (startDate != null && startDate.isNotEmpty) {
      params['start_date'] = startDate;
    }
    final uri = Uri.parse('$baseUrl/api/v1/daily-attendance/grid').replace(queryParameters: params);
    final response = await http.get(uri);
    if (response.statusCode != 200) {
      final body = jsonDecode(utf8.decode(response.bodyBytes));
      throw Exception(body['detail'] ?? 'ไม่สามารถดึงตารางเวลาเรียน 20 สัปดาห์ได้');
    }
    final body = jsonDecode(utf8.decode(response.bodyBytes));
    return body['data'] as Map<String, dynamic>;
  }

  /// Save 20-week daily attendance grid for a class level
  Future<Map<String, dynamic>> saveDailyAttendanceGrid({
    required String term,
    required String year,
    required String classLevel,
    required String startDate,
    required List<int> holidays,
    required List<int> lockedCounted,
    required List<Map<String, dynamic>> students,
  }) async {
    final uri = Uri.parse('$baseUrl/api/v1/daily-attendance/grid');
    final response = await http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'term': term,
        'year': year,
        'class_level': classLevel,
        'start_date': startDate,
        'holidays': holidays,
        'locked_counted': lockedCounted,
        'students': students,
      }),
    );
    if (response.statusCode != 200) {
      final body = jsonDecode(utf8.decode(response.bodyBytes));
      throw Exception(body['detail'] ?? 'ไม่สามารถบันทึกตารางเวลาเรียน 20 สัปดาห์ได้');
    }
    return jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
  }

  /// Update and unify semester start date across all class levels
  Future<Map<String, dynamic>> updateDailyAttendanceStartDate({
    required String term,
    required String year,
    required String startDate,
  }) async {
    final uri = Uri.parse('$baseUrl/api/v1/daily-attendance/start-date');
    final response = await http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'term': term,
        'year': year,
        'start_date': startDate,
      }),
    );
    if (response.statusCode != 200) {
      final body = jsonDecode(utf8.decode(response.bodyBytes));
      throw Exception(body['detail'] ?? 'ไม่สามารถอัปเดตวันเริ่มภาคเรียนได้');
    }
    return jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
  }

  /// Reset daily attendance for all 6 class levels or selected levels in a semester
  Future<Map<String, dynamic>> resetAllDailyAttendance({
    required String term,
    required String year,
    String mode = 'empty', // 'empty' or 'all_present'
    List<String>? classLevels,
  }) async {
    final uri = Uri.parse('$baseUrl/api/v1/daily-attendance/reset-all-levels');
    final response = await http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'term': term,
        'year': year,
        'mode': mode,
        if (classLevels != null) 'class_levels': classLevels,
      }),
    );
    if (response.statusCode != 200) {
      final body = jsonDecode(utf8.decode(response.bodyBytes));
      throw Exception(body['detail'] ?? 'ไม่สามารถรีเซ็ตเวลาเรียนได้');
    }
    return jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
  }

  /// Add student to class level (+ button)
  Future<Map<String, dynamic>> addDailyClassStudent({
    required String term,
    required String year,
    required String classLevel,
    required String studentId,
    required String fullName,
    int? studentNo,
    String? note,
  }) async {
    final uri = Uri.parse('$baseUrl/api/v1/daily-attendance/student');
    final response = await http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'term': term,
        'year': year,
        'class_level': classLevel,
        'student_id': studentId,
        'full_name': fullName,
        if (studentNo != null) 'student_no': studentNo,
        if (note != null) 'note': note,
      }),
    );
    if (response.statusCode != 200) {
      final body = jsonDecode(utf8.decode(response.bodyBytes));
      throw Exception(body['detail'] ?? 'ไม่สามารถเพิ่มนักเรียนได้');
    }
    return jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
  }

  /// Remove student from class level (- button)
  Future<Map<String, dynamic>> removeDailyClassStudent({
    required String term,
    required String year,
    required String classLevel,
    required String studentId,
  }) async {
    final uri = Uri.parse('$baseUrl/api/v1/daily-attendance/student').replace(
      queryParameters: {
        'term': term,
        'year': year,
        'class_level': classLevel,
        'student_id': studentId,
      },
    );
    final response = await http.delete(uri);
    if (response.statusCode != 200) {
      final body = jsonDecode(utf8.decode(response.bodyBytes));
      throw Exception(body['detail'] ?? 'ไม่สามารถลบนักเรียนได้');
    }
    return jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
  }

  /// Get student count and summary across all 6 levels
  Future<List<Map<String, dynamic>>> getAllLevelsAttendanceSummary({
    required String term,
    required String year,
  }) async {
    final uri = Uri.parse('$baseUrl/api/v1/daily-attendance/all-levels-summary').replace(
      queryParameters: {'term': term, 'year': year},
    );
    final response = await http.get(uri);
    if (response.statusCode != 200) {
      final body = jsonDecode(utf8.decode(response.bodyBytes));
      throw Exception(body['detail'] ?? 'ไม่สามารถดึงข้อมูลสรุป 6 ระดับชั้นได้');
    }
    final body = jsonDecode(utf8.decode(response.bodyBytes));
    return List<Map<String, dynamic>>.from(body['data'] ?? []);
  }

  /// Get active students roster for a class level
  Future<List<Map<String, dynamic>>> getClassStudents({
    required String term,
    required String year,
    required String classLevel,
    String? room,
  }) async {
    final queryParams = {'term': term, 'year': year, 'class_level': classLevel};
    if (room != null && room.isNotEmpty && room != 'all') {
      queryParams['room'] = room;
    }
    final uri = Uri.parse('$baseUrl/api/v1/daily-attendance/students').replace(
      queryParameters: queryParams,
    );
    final response = await http.get(uri);
    if (response.statusCode != 200) {
      final body = jsonDecode(utf8.decode(response.bodyBytes));
      throw Exception(body['detail'] ?? 'ไม่สามารถดึงรายชื่อนักเรียนได้');
    }
    final body = jsonDecode(utf8.decode(response.bodyBytes));
    return List<Map<String, dynamic>>.from(body['data'] ?? []);
  }

  /// Import students from another semester
  Future<Map<String, dynamic>> importClassStudents({
    required String fromTerm,
    required String fromYear,
    required String toTerm,
    required String toYear,
    String? fromClassLevel,
    String? toClassLevel,
    bool allLevels = false,
    bool overwrite = false,
  }) async {
    final uri = Uri.parse('$baseUrl/api/v1/daily-attendance/import-students');
    final response = await http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'from_term': fromTerm,
        'from_year': fromYear,
        'to_term': toTerm,
        'to_year': toYear,
        if (fromClassLevel != null) 'from_class_level': fromClassLevel,
        if (toClassLevel != null) 'to_class_level': toClassLevel,
        'all_levels': allLevels,
        'overwrite': overwrite,
      }),
    );
    if (response.statusCode != 200) {
      final body = jsonDecode(utf8.decode(response.bodyBytes));
      throw Exception(body['detail'] ?? 'ไม่สามารถนำเข้านักเรียนได้');
    }
    return jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
  }

  /// Get attendance dashboard metrics & top 3 absentees per class level
  Future<Map<String, dynamic>> getAttendanceDashboard({
    required String term,
    required String year,
    String mode = 'subject',
    String? month,
  }) async {
    final qParams = {'term': term, 'year': year, 'mode': mode};
    if (month != null && month.isNotEmpty) {
      qParams['month'] = month;
    }
    final uri = Uri.parse('$baseUrl/api/v1/dashboard/attendance-overview').replace(
      queryParameters: qParams,
    );
    final response = await http.get(uri);
    if (response.statusCode != 200) {
      final body = jsonDecode(utf8.decode(response.bodyBytes));
      throw Exception(body['detail'] ?? 'ไม่สามารถดึงข้อมูลแดชบอร์ดได้');
    }
    final body = jsonDecode(utf8.decode(response.bodyBytes));
    return body['data'] as Map<String, dynamic>;
  }

  /// Early warning for มส. (< 80% attendance): per-student forecast from /api/v1/dashboard/attendance-risk
  Future<Map<String, dynamic>> getAttendanceRisk({
    required String term,
    required String year,
    String? classLevel,
  }) async {
    final qParams = {'term': term, 'year': year};
    if (classLevel != null && classLevel.isNotEmpty) {
      qParams['class_level'] = classLevel;
    }
    final uri = Uri.parse('$baseUrl/api/v1/dashboard/attendance-risk').replace(queryParameters: qParams);
    final response = await http.get(uri);
    if (response.statusCode != 200) {
      final body = jsonDecode(utf8.decode(response.bodyBytes));
      throw Exception(body['detail'] ?? 'ไม่สามารถดึงข้อมูลความเสี่ยง มส. ได้');
    }
    final body = jsonDecode(utf8.decode(response.bodyBytes));
    return body['data'] as Map<String, dynamic>;
  }

  /// Get month-by-month attendance trend and breakdown for a student
  Future<Map<String, dynamic>> getStudentMonthlyAttendance({
    required String term,
    required String year,
    required String studentId,
    String mode = 'subject',
  }) async {
    final uri = Uri.parse('$baseUrl/api/v1/dashboard/student-monthly-attendance').replace(
      queryParameters: {'term': term, 'year': year, 'student_id': studentId, 'mode': mode},
    );
    final response = await http.get(uri);
    if (response.statusCode != 200) {
      final body = jsonDecode(utf8.decode(response.bodyBytes));
      throw Exception(body['detail'] ?? 'ไม่สามารถดึงข้อมูลสถิติรายเดือนของนักเรียนได้');
    }
    final body = jsonDecode(utf8.decode(response.bodyBytes));
    return body['data'] as Map<String, dynamic>;
  }

  // ---------------------------------------------------------------- รูปนักเรียน + ข้อมูลนักเรียน (student_photos.py)

  Map<String, dynamic> _photoBody(http.Response response, String fallback) {
    Map<String, dynamic> body;
    try {
      body = Map<String, dynamic>.from(jsonDecode(utf8.decode(response.bodyBytes)) as Map);
    } catch (_) {
      body = {};
    }
    if (response.statusCode != 200) {
      throw Exception(body['detail'] ?? fallback);
    }
    return body;
  }

  /// ข้อมูลพื้นฐาน ผู้ปกครอง และรูป ของนักเรียนคนหนึ่ง (เลขบัตรประชาชนส่งมาเฉพาะผู้ดูแลระบบ)
  Future<Map<String, dynamic>> getStudentProfile(String studentId, {required String term, required String year}) async {
    final uri = Uri.parse('$baseUrl/api/v1/students/${Uri.encodeComponent(studentId)}/profile')
        .replace(queryParameters: {'term': term, 'year': year});
    final body = _photoBody(await http.get(uri), 'ไม่สามารถดึงข้อมูลนักเรียนได้');
    return Map<String, dynamic>.from(body['data'] as Map);
  }

  /// [version] changes whenever the photo does, so the browser may cache each URL for good
  String studentPhotoUrl(String studentId, dynamic version) =>
      '$baseUrl/api/v1/students/${Uri.encodeComponent(studentId)}/photo?v=$version';

  String studentPortalPhotoUrl(dynamic version) => '$baseUrl/api/v1/student-portal/photo?v=$version';

  String stagedStudentPhotoUrl(String token, String studentId) =>
      '$baseUrl/api/v1/student-photos/stage/$token/${Uri.encodeComponent(studentId)}.jpg';

  /// ชั้นที่อัปโหลดรูปได้ + มีรูปแล้วกี่คน ใครยังไม่มี
  Future<Map<String, dynamic>> getStudentPhotoScope({required String term, required String year}) async {
    final uri = Uri.parse('$baseUrl/api/v1/student-photos/scope').replace(queryParameters: {'term': term, 'year': year});
    final body = _photoBody(await http.get(uri), 'ไม่สามารถตรวจสิทธิ์อัปโหลดรูปได้');
    return Map<String, dynamic>.from(body['data'] as Map);
  }

  /// ส่งรูป/ZIP หนึ่งชุด: เซิร์ฟเวอร์ย่อรูป จับคู่รหัส และพักไว้ (ยังไม่บันทึก) ส่งชุดต่อไปด้วย [token] เดิม
  Future<Map<String, dynamic>> stageStudentPhotos(
    List<MapEntry<String, Uint8List>> files, {
    required String term,
    required String year,
    String? token,
  }) async {
    final request = http.MultipartRequest('POST', Uri.parse('$baseUrl/api/v1/student-photos/stage'));
    request.fields['term'] = term;
    request.fields['year'] = year;
    if (token != null) request.fields['token'] = token;
    for (final f in files) {
      request.files.add(http.MultipartFile.fromBytes('files', f.value, filename: f.key));
    }
    final streamed = await request.send().timeout(const Duration(minutes: 15));
    final body = _photoBody(await http.Response.fromStream(streamed), 'ส่งรูปไม่สำเร็จ');
    return Map<String, dynamic>.from(body['data'] as Map);
  }

  Future<Map<String, dynamic>> commitStudentPhotos(String token) async {
    final response = await http.post(Uri.parse('$baseUrl/api/v1/student-photos/commit'),
        headers: {'Content-Type': 'application/json'}, body: jsonEncode({'token': token}));
    final body = _photoBody(response, 'บันทึกรูปไม่สำเร็จ');
    return Map<String, dynamic>.from(body['data'] as Map);
  }

  Future<void> cancelStudentPhotos(String token) async {
    try {
      await http.post(Uri.parse('$baseUrl/api/v1/student-photos/cancel'),
          headers: {'Content-Type': 'application/json'}, body: jsonEncode({'token': token}));
    } catch (_) {}
  }

  /// รูปของนักเรียนคนเดียว (ถ่ายจากกล้อง / เลือกจากเครื่อง) บันทึกทันที แทนรูปเดิม
  Future<Map<String, dynamic>> uploadStudentPhoto(String studentId, Uint8List bytes, String filename,
      {required String term, required String year}) async {
    final request = http.MultipartRequest('POST', Uri.parse('$baseUrl/api/v1/students/${Uri.encodeComponent(studentId)}/photo'));
    request.fields['term'] = term;
    request.fields['year'] = year;
    request.files.add(http.MultipartFile.fromBytes('file', bytes, filename: filename));
    final streamed = await request.send().timeout(const Duration(minutes: 3));
    final body = _photoBody(await http.Response.fromStream(streamed), 'บันทึกรูปไม่สำเร็จ');
    return {...Map<String, dynamic>.from(body['data'] as Map), 'message': body['message']};
  }

  /// รูปที่บันทึกไว้แล้ว (ไว้จัดตำแหน่ง / ซูมใหม่ ในปุ่ม "แก้ไขรูป")
  Future<Uint8List> getStudentPhotoBytes(String studentId, dynamic version) async {
    final response = await http.get(Uri.parse(studentPhotoUrl(studentId, version)));
    if (response.statusCode == 200) return response.bodyBytes;
    _photoBody(response, 'โหลดรูปเดิมไม่สำเร็จ'); // throws the server's message
    throw Exception('โหลดรูปเดิมไม่สำเร็จ');
  }

  Future<String> deleteStudentPhoto(String studentId, {required String term, required String year}) async {
    final response = await http.post(Uri.parse('$baseUrl/api/v1/students/${Uri.encodeComponent(studentId)}/photo/delete'),
        headers: {'Content-Type': 'application/json'}, body: jsonEncode({'term': term, 'year': year}));
    final body = _photoBody(response, 'ลบรูปไม่สำเร็จ');
    return body['message']?.toString() ?? 'ลบรูปนักเรียนแล้ว';
  }

  /// Get attendance evaluation data (80% and 60% thresholds) for all students
  Future<Map<String, dynamic>> getAttendanceSummaryData({
    required String term,
    required String year,
    String mode = 'daily',
    String threshold = 'all',
    String classLevel = 'all',
    String evalScope = 'current',
  }) async {
    final uri = Uri.parse('$baseUrl/api/v1/dashboard/attendance-summary-data').replace(
      queryParameters: {
        'term': term,
        'year': year,
        'mode': mode,
        'threshold': threshold,
        'class_level': classLevel,
        'eval_scope': evalScope,
      },
    );
    final response = await http.get(uri);
    if (response.statusCode != 200) {
      final body = jsonDecode(utf8.decode(response.bodyBytes));
      throw Exception(body['detail'] ?? 'ไม่สามารถดึงข้อมูลสรุปเวลาเรียนได้');
    }
    final body = jsonDecode(utf8.decode(response.bodyBytes));
    return body['data'] as Map<String, dynamic>;
  }

  /// Build download URL for attendance summary PDF (80% and 60% thresholds)
  String getAttendanceSummaryPdfUrl({
    required String term,
    required String year,
    String mode = 'daily',
    String threshold = 'all',
    String classLevel = 'all',
    String evalScope = 'current',
    bool inline = false,
  }) {
    final uri = Uri.parse('$baseUrl/api/v1/dashboard/attendance-summary-pdf').replace(
      queryParameters: {
        'term': term,
        'year': year,
        'mode': mode,
        'threshold': threshold,
        'class_level': classLevel,
        'eval_scope': evalScope,
        'inline': inline.toString(),
      },
    );
    return uri.toString();
  }

  /// Preview students from DMC Excel or CSV file
  Future<Map<String, dynamic>> previewDmcStudents(
    Uint8List bytes,
    String filename, {
    String? term,
    String? year,
  }) async {
    final uri = Uri.parse('$baseUrl/api/v1/daily-attendance/preview-dmc');
    final request = http.MultipartRequest('POST', uri);
    // with the destination semester the server also compares the file with its roster ("compare")
    if (term != null && year != null) {
      request.fields['term'] = term;
      request.fields['year'] = year;
    }
    request.files.add(http.MultipartFile.fromBytes('file', bytes, filename: filename));

    final streamedResponse = await request.send().timeout(const Duration(minutes: 2));
    final response = await http.Response.fromStream(streamedResponse);

    if (response.statusCode != 200) {
      final body = jsonDecode(utf8.decode(response.bodyBytes));
      throw Exception(body['detail'] ?? 'การตรวจสอบไฟล์ DMC ล้มเหลว');
    }
    return jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
  }

  /// Import students from DMC Excel or CSV file and assign into rooms & classes
  Future<Map<String, dynamic>> importDmcStudents(
    Uint8List bytes,
    String filename, {
    required String term,
    required String year,
    bool overwrite = true,
  }) async {
    final uri = Uri.parse('$baseUrl/api/v1/daily-attendance/import-dmc');
    final request = http.MultipartRequest('POST', uri);
    request.fields['term'] = term;
    request.fields['year'] = year;
    request.fields['overwrite'] = overwrite ? 'true' : 'false';
    request.files.add(http.MultipartFile.fromBytes('file', bytes, filename: filename));

    final streamedResponse = await request.send().timeout(const Duration(minutes: 3));
    final response = await http.Response.fromStream(streamedResponse);

    if (response.statusCode != 200) {
      final body = jsonDecode(utf8.decode(response.bodyBytes));
      throw Exception(body['detail'] ?? 'การนำเข้าไฟล์ DMC ล้มเหลว');
    }
    return jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
  }

  /// Toggle or set student lock status (not calculated, not shown in PorPor5)
  Future<Map<String, dynamic>> toggleStudentLock({
    required String term,
    required String year,
    required String classLevel,
    required String studentId,
    bool? locked,
  }) async {
    final uri = Uri.parse('/api/v1/daily-attendance/student/toggle-lock');
    final response = await http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'term': term,
        'year': year,
        'class_level': classLevel,
        'student_id': studentId,
        if (locked != null) 'locked': locked,
      }),
    );
    if (response.statusCode != 200) {
      final body = jsonDecode(utf8.decode(response.bodyBytes));
      throw Exception(body['detail'] ?? 'การเปลี่ยนสถานะล็อกนักเรียนล้มเหลว');
    }
    return jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
  }
  // ---------------------------------------------------------------------------
  // School Logo & Identity Management
  // ---------------------------------------------------------------------------
  /// ValueNotifier to signal when school logo changes
  final ValueNotifier<int> schoolLogoNotifier = ValueNotifier<int>(0);

  /// ValueNotifier to signal when PP5 logo changes
  final ValueNotifier<int> pp5LogoNotifier = ValueNotifier<int>(0);

  /// ValueNotifier to signal when Dashboard button or School Logo is clicked (resets Dashboard to marked semester)
  final ValueNotifier<int> dashboardResetNotifier = ValueNotifier<int>(0);

  /// ValueNotifier to signal when school name changes
  final ValueNotifier<String> schoolNameNotifier = ValueNotifier<String>('');

  /// ValueNotifier for the browser tab title (ชื่อหน้าเว็บ)
  final ValueNotifier<String> webTitleNotifier = ValueNotifier<String>('ระบบ ปพ.5');

  /// ValueNotifiers for Sidebar bottom footer text ("ระบบงาน ปพ.5 & ทะเบียนวัดผล" / "โรงเรียน...")
  final ValueNotifier<String> sidebarFooterTitleNotifier = ValueNotifier<String>('ระบบงาน ปพ.5 & ทะเบียนวัดผล');
  final ValueNotifier<String> sidebarFooterSubtitleNotifier = ValueNotifier<String>('');

  /// School identity from /api/v1/school-profile (school_profile.py): full_school_name, school_area_office,
  /// school_area_short, school_province ... Empty until a new school has been set up.
  final ValueNotifier<Map<String, String>> schoolProfileNotifier = ValueNotifier<Map<String, String>>(const {});
  String get schoolFullName => schoolProfileNotifier.value['full_school_name'] ?? '';
  String get schoolAreaShort => schoolProfileNotifier.value['school_area_short'] ?? '';
  /// "โรงเรียน…  สำนักงานเขตพื้นที่การศึกษา…" for report and table headers
  String get schoolBannerLine => [schoolFullName, schoolProfileNotifier.value['school_area_office'] ?? '']
      .where((s) => s.isNotEmpty)
      .join('  ');

  Future<void> loadSchoolProfile() async {
    try {
      final response = await http.get(Uri.parse('$baseUrl/api/v1/school-profile'));
      if (response.statusCode != 200) return;
      final body = jsonDecode(utf8.decode(response.bodyBytes));
      final data = (body['data'] as Map?) ?? const {};
      schoolProfileNotifier.value = data.map((k, v) => MapEntry(k.toString(), v?.toString() ?? ''));
    } catch (_) {}
  }

  /// First run of a new school (empty database, server screen only): school identity + first admin.
  Future<Map<String, dynamic>> setupNewSchool(Map<String, String> form) async {
    final response = await http.post(
      Uri.parse('$baseUrl/api/v1/setup/new-school'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(form),
    );
    final body = jsonDecode(utf8.decode(response.bodyBytes));
    if (response.statusCode != 200) {
      throw Exception(body['detail'] ?? 'ตั้งค่าโรงเรียนไม่สำเร็จ');
    }
    await loadSchoolProfile();
    await getSchoolLogoInfo(); // sidebar / login page name
    return body as Map<String, dynamic>;
  }

  /// ตารางสอนรวม: teachers in order with their กลุ่มสาระ (no, key, formal, base, code, dept)
  Future<List<Map<String, String>>> getMasterRoster(String term, String year) async {
    final uri = Uri.parse('$baseUrl/api/v1/timetables/master-roster')
        .replace(queryParameters: {'term': term, 'year': year});
    final response = await http.get(uri);
    if (response.statusCode != 200) return [];
    final body = jsonDecode(utf8.decode(response.bodyBytes));
    return ((body['roster'] as List?) ?? const [])
        .map((e) => (e as Map).map((k, v) => MapEntry(k.toString(), v?.toString() ?? '')))
        .toList();
  }

  /// ValueNotifier to broadcast the marked default semester across all screens
  final ValueNotifier<SemesterConfigItem?> defaultSemesterNotifier = ValueNotifier<SemesterConfigItem?>(null);
  SemesterConfigItem? get defaultSemester => defaultSemesterNotifier.value;

  /// ValueNotifier to broadcast school theme configuration (colors & font)
  final ValueNotifier<SchoolThemeConfig> themeNotifier =
      ValueNotifier<SchoolThemeConfig>(SchoolThemeConfig.defaultTheme);

  // ---------------------------------------------------------------------------
  // Teacher Authentication & System Administrator Management
  // ---------------------------------------------------------------------------
  /// Current logged-in teacher state
  final ValueNotifier<LoggedInTeacher?> currentUserNotifier = ValueNotifier<LoggedInTeacher?>(null);
  LoggedInTeacher? get currentUser => currentUserNotifier.value;
  bool get isLoggedIn => currentUserNotifier.value != null;
  bool get isAdmin => currentUserNotifier.value?.isAdmin ?? false;
  bool get isDirector => currentUserNotifier.value?.isDirector ?? false;
  bool get isPersonnelHead => currentUserNotifier.value?.isPersonnelHead == true;
  bool get isGuest => currentUserNotifier.value?.isGuest ?? false;

  /// Restore the session on app startup from the server's session cookie (/api/v1/auth/me).
  /// The PIN is never stored in the browser.
  Future<LoggedInTeacher?> loadStoredSession() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('saved_teacher_pin'); // left by older versions of the app
      final response = await http.get(Uri.parse('$baseUrl/api/v1/auth/me'));
      if (response.statusCode != 200) return null;
      final body = jsonDecode(utf8.decode(response.bodyBytes));
      final teacherData = Map<String, dynamic>.from(body['teacher'] as Map);
      final user = teacherData['is_guest'] == true
          ? LoggedInTeacher.guest()
          : LoggedInTeacher.fromJson(
              teacherData,
              isAdminOverride: body['is_admin'] == true,
              isDirectorOverride: body['is_director'] == true,
            );
      currentUserNotifier.value = user;
      return user;
    } catch (_) {
      return null;
    }
  }

  /// Login as Guest (บุคคลทั่วไป - ดูได้เฉพาะตารางสอน ไม่ต้องใส่รหัส)
  Future<LoggedInTeacher> loginAsGuest({bool persist = true}) async {
    final response = await http.post(Uri.parse('$baseUrl/api/v1/auth/guest'));
    if (response.statusCode != 200) {
      throw Exception('ไม่สามารถเข้าใช้งานในฐานะบุคคลทั่วไปได้');
    }
    final guest = LoggedInTeacher.guest();
    currentUserNotifier.value = guest;
    return guest;
  }

  /// Login using teacher code and PIN (required). The server answers with a session cookie.
  Future<LoggedInTeacher> loginTeacher(String code, {String? pin, bool persist = true}) async {
    final cleanCode = code.trim();
    final cleanPin = pin?.trim() ?? '';
    if (cleanPin.isEmpty) {
      throw Exception('กรุณาระบุรหัสใช้งาน (PIN)');
    }
    final uri = Uri.parse('$baseUrl/api/v1/auth/login-teacher');
    final response = await http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'code': cleanCode, 'pin': cleanPin}),
    );

    final body = jsonDecode(utf8.decode(response.bodyBytes));
    if (response.statusCode != 200) {
      throw Exception(body['detail'] ?? 'รหัสครูหรือรหัสใช้งานไม่ถูกต้อง');
    }

    final teacherData = body['teacher'] as Map<String, dynamic>;
    final teacher = LoggedInTeacher.fromJson(
      teacherData,
      isAdminOverride: body['is_admin'] == true,
      isDirectorOverride: body['is_director'] == true,
    );
    currentUserNotifier.value = teacher;

    if (persist) {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('saved_teacher_code', cleanCode); // only to prefill the login form
        await prefs.remove('saved_teacher_pin');
      } catch (_) {}
    }
    return teacher;
  }

  /// Student login: student ID (with the leading 0) as both username and password
  Future<LoggedInTeacher> loginStudent(String studentId, String password) async {
    final response = await http.post(
      Uri.parse('$baseUrl/api/v1/auth/login-student'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'student_id': studentId.trim(), 'password': password.trim()}),
    );
    final body = jsonDecode(utf8.decode(response.bodyBytes));
    if (response.statusCode != 200) {
      throw Exception(body['detail'] ?? 'รหัสประจำตัวนักเรียนหรือรหัสผ่านไม่ถูกต้อง');
    }
    final student = LoggedInTeacher.fromJson(Map<String, dynamic>.from(body['teacher'] as Map));
    currentUserNotifier.value = student;
    return student;
  }

  /// The logged-in student's own attendance (daily check-ins up to today, absent days, per-course summary)
  Future<Map<String, dynamic>> getStudentPortal() async {
    final response = await http.get(Uri.parse('$baseUrl/api/v1/student-portal/me'));
    final body = jsonDecode(utf8.decode(response.bodyBytes));
    if (response.statusCode != 200) {
      throw Exception(body['detail'] ?? 'ไม่สามารถดึงข้อมูลการมาเรียนได้');
    }
    return body['data'] as Map<String, dynamic>;
  }

  // ---------------------------------------------------------------- ข้อสอบกลางภาค / ปลายภาค

  Future<dynamic> _examRequest(String method, String path, {Map<String, String>? query, Object? body}) async {
    final uri = Uri.parse('$baseUrl$path').replace(queryParameters: query);
    final response = method == 'GET'
        ? await http.get(uri)
        : await http.post(uri, headers: {'Content-Type': 'application/json'}, body: jsonEncode(body ?? {}));
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (response.statusCode != 200) {
      throw Exception(decoded is Map ? (decoded['detail'] ?? 'เกิดข้อผิดพลาด') : 'เกิดข้อผิดพลาด');
    }
    return decoded;
  }

  /// Own courses (all for admin) with both exam slots, plus the exam windows
  Future<Map<String, dynamic>> getExamCourses({String? term, String? year, String? teacherCode}) async {
    final q = <String, String>{
      if (term != null) 'term': term,
      if (year != null) 'year': year,
      if (teacherCode != null) 'teacher_code': teacherCode,
    };
    return Map<String, dynamic>.from(await _examRequest('GET', '/api/v1/exams/courses', query: q));
  }

  Future<Map<String, dynamic>> saveExamWindow(String term, String year, String examType, String? startAt, String? endAt) async {
    final r = await _examRequest('POST', '/api/v1/exams/windows',
        body: {'term': term, 'year': year, 'exam_type': examType, 'start_at': startAt, 'end_at': endAt});
    return Map<String, dynamic>.from(r['data']);
  }

  /// Admin: mark courses as sitting (locked = false) or not sitting (locked = true) the given exams
  Future<void> setExamLocks(String term, String year, List<String> courseCodes, List<String> examTypes, bool locked) async {
    await _examRequest('POST', '/api/v1/exams/locks',
        body: {'term': term, 'year': year, 'course_codes': courseCodes, 'exam_types': examTypes, 'locked': locked});
  }

  /// Admin: one course's own exam time (both null = follow the school-wide window)
  Future<void> setExamCourseTime(String term, String year, String courseCode, String examType, String? startAt, String? endAt) async {
    await _examRequest('POST', '/api/v1/exams/course-time',
        body: {'term': term, 'year': year, 'course_code': courseCode, 'exam_type': examType, 'start_at': startAt, 'end_at': endAt});
  }

  /// Admin: ปลดล็อกให้สอบได้ก่อนเวลา (opened = false takes it back)
  Future<void> openExamEarly(String term, String year, List<String> courseCodes, String examType, bool opened) async {
    await _examRequest('POST', '/api/v1/exams/open-early',
        body: {'term': term, 'year': year, 'course_codes': courseCodes, 'exam_type': examType, 'opened': opened});
  }

  /// ตารางสอบ grid (days x slots x ม.1–ม.6) with each course's teacher and open state
  Future<Map<String, dynamic>> getExamTimetable(String term, String year, String examType) async {
    final r = await _examRequest('GET', '/api/v1/exams/timetable', query: {'term': term, 'year': year, 'exam_type': examType});
    return Map<String, dynamic>.from(r['data']);
  }

  Future<Map<String, dynamic>> saveExamTimetable(String term, String year, String examType, List<Map<String, dynamic>> days) async {
    final r = await _examRequest('POST', '/api/v1/exams/timetable', body: {'term': term, 'year': year, 'exam_type': examType, 'days': days});
    return Map<String, dynamic>.from(r['data']);
  }

  /// Admin: the timetable form as an image or PDF; a PDF with text comes back as draft_days
  Future<Map<String, dynamic>> uploadExamTimetable(String term, String year, String examType, Uint8List bytes, String filename) async {
    final request = http.MultipartRequest('POST', Uri.parse('$baseUrl/api/v1/exams/timetable/upload'))
      ..fields.addAll({'term': term, 'year': year, 'exam_type': examType})
      ..files.add(http.MultipartFile.fromBytes('file', bytes, filename: filename));
    final response = await http.Response.fromStream(await request.send());
    final body = jsonDecode(utf8.decode(response.bodyBytes));
    if (response.statusCode != 200) throw Exception(body['detail'] ?? 'อัปโหลดตารางสอบไม่สำเร็จ');
    return Map<String, dynamic>.from(body['data']);
  }

  /// ข้อสอบจากไฟล์ Word (.docx / .doc) หรือ PDF -> {questions, notes, counts} สำหรับตัวแก้ไขข้อสอบ
  /// A picture for a question / matching choice; returns its name (stored with the paper)
  Future<String> uploadExamImage(Uint8List bytes, String filename) async {
    final request = http.MultipartRequest('POST', Uri.parse('$baseUrl/api/v1/exams/image'))
      ..files.add(http.MultipartFile.fromBytes('file', bytes, filename: filename));
    final response = await http.Response.fromStream(await request.send());
    final body = jsonDecode(utf8.decode(response.bodyBytes));
    if (response.statusCode != 200) throw Exception(body['detail'] ?? 'อัปโหลดรูปไม่สำเร็จ');
    return '${body['data']['name']}';
  }

  String examImageUrl(String name) => '$baseUrl/api/v1/exam-images/$name';

  /// A paper file -> questions. A scan read by OCR takes minutes: the server answers with a job and this
  /// waits for it, telling [onProgress] how far it is ("กำลังอ่านภาพหน้า 3/33").
  Future<Map<String, dynamic>> parseExamFile(Uint8List bytes, String filename, {void Function(String)? onProgress}) async {
    final request = http.MultipartRequest('POST', Uri.parse('$baseUrl/api/v1/exams/parse-file'))
      ..files.add(http.MultipartFile.fromBytes('file', bytes, filename: filename));
    final response = await http.Response.fromStream(await request.send());
    final body = jsonDecode(utf8.decode(response.bodyBytes));
    if (response.statusCode != 200) throw Exception(body['detail'] ?? 'อ่านไฟล์ข้อสอบไม่สำเร็จ');
    var data = Map<String, dynamic>.from(body['data']);
    final job = data['job'];
    if (job == null) return data;
    onProgress?.call('${data['progress'] ?? ''}');
    while (true) {
      await Future.delayed(const Duration(seconds: 2));
      final r = await http.get(Uri.parse('$baseUrl/api/v1/exams/parse-file/$job'));
      final b = jsonDecode(utf8.decode(r.bodyBytes));
      if (r.statusCode != 200) throw Exception(b['detail'] ?? 'อ่านไฟล์ข้อสอบไม่สำเร็จ');
      data = Map<String, dynamic>.from(b['data']);
      if (data['done'] == true) return Map<String, dynamic>.from(data['result']);
      onProgress?.call('${data['progress'] ?? ''}');
    }
  }

  /// ตารางเรียนของชั้นที่นักเรียนคนนี้อยู่ (นักเรียนเห็นเฉพาะชั้นของตัวเอง)
  Future<Map<String, dynamic>> getStudentTimetable() async {
    final r = await _examRequest('GET', '/api/v1/student-portal/timetable');
    return Map<String, dynamic>.from(r['data']);
  }
  /// ฟอร์มนำเข้าข้อมูลโรงเรียน (admin): blank, or filled with what the database holds for the semester
  /// full = true: ไฟล์ข้อมูลทั้งหมดของภาคเรียน (แผ่น 1-8 + คะแนน เวลาเรียน ตั้งค่า ...) นำเข้ากลับได้ไฟล์เดียว
  String schoolImportTemplateUrl(String term, String year, {bool prefill = true, bool full = false}) =>
      '$baseUrl/api/v1/school-import/template?term=$term&year=$year&prefill=$prefill&full=$full';

  // ---- ไฟล์สำรองทั้งระบบ (.zip): ฐานข้อมูล + CSV ทุกตาราง + รูป/ไฟล์แนบ (+ ปพ.5) ไม่มี PIN ของครู
  Future<List<Map<String, dynamic>>> listArchives() async {
    final response = await http.get(Uri.parse('$baseUrl/api/v1/backups/archives'));
    final body = jsonDecode(utf8.decode(response.bodyBytes));
    if (response.statusCode != 200) throw Exception(body['detail'] ?? 'ดึงรายการไฟล์สำรองไม่ได้');
    return ((body['data'] as List?) ?? []).map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  Future<Map<String, dynamic>> createArchive({bool includeOutputs = false}) async {
    final response = await http.post(Uri.parse('$baseUrl/api/v1/backups/archives/create'),
        headers: {'Content-Type': 'application/json'}, body: jsonEncode({'include_outputs': includeOutputs}));
    final body = jsonDecode(utf8.decode(response.bodyBytes));
    if (response.statusCode != 200) throw Exception(body['detail'] ?? 'สร้างไฟล์สำรองไม่สำเร็จ');
    return Map<String, dynamic>.from(body['data']);
  }

  Future<Map<String, dynamic>> restoreArchive(String name) async {
    final response = await http.post(Uri.parse('$baseUrl/api/v1/backups/archives/${Uri.encodeComponent(name)}/restore'));
    final body = jsonDecode(utf8.decode(response.bodyBytes));
    if (response.statusCode != 200) throw Exception(body['detail'] ?? 'กู้คืนไม่สำเร็จ');
    return Map<String, dynamic>.from(body);
  }

  Future<Map<String, dynamic>> uploadArchive(Uint8List bytes, String filename) async {
    final request = http.MultipartRequest('POST', Uri.parse('$baseUrl/api/v1/backups/archives/upload'))
      ..files.add(http.MultipartFile.fromBytes('file', bytes, filename: filename));
    final response = await http.Response.fromStream(await request.send());
    final body = jsonDecode(utf8.decode(response.bodyBytes));
    if (response.statusCode != 200) throw Exception(body is Map ? (body['detail'] ?? 'อัปโหลดไม่สำเร็จ') : 'อัปโหลดไม่สำเร็จ');
    return Map<String, dynamic>.from(body['data']);
  }

  /// เครื่องที่ลงใหม่: needs_recovery = ฐานข้อมูลว่าง, local = เปิดจากหน้าจอเครื่องเซิร์ฟเวอร์ (กู้คืนได้)
  Future<Map<String, dynamic>> recoveryStatus() async {
    try {
      final response = await http.get(Uri.parse('$baseUrl/api/v1/recovery/status'));
      if (response.statusCode != 200) return {};
      return Map<String, dynamic>.from(jsonDecode(utf8.decode(response.bodyBytes)));
    } catch (_) {
      return {};
    }
  }

  Future<Map<String, dynamic>> recoveryRestore(Uint8List bytes, String filename) async {
    final request = http.MultipartRequest('POST', Uri.parse('$baseUrl/api/v1/recovery/restore'))
      ..files.add(http.MultipartFile.fromBytes('file', bytes, filename: filename));
    final response = await http.Response.fromStream(await request.send());
    final body = jsonDecode(utf8.decode(response.bodyBytes));
    if (response.statusCode != 200) throw Exception(body is Map ? (body['detail'] ?? 'กู้คืนไม่สำเร็จ') : 'กู้คืนไม่สำเร็จ');
    return Map<String, dynamic>.from(body);
  }

  /// สำเนานอกเครื่อง (Google Drive ผ่าน rclone): remote เช่น gdrive:SchoolBackup
  // ---- API สาธารณะ (แสดงแดชบอร์ด/ตารางสอนบนเว็บอื่น) — ผู้ดูแลระบบ
  Future<Map<String, dynamic>> publicApiSettings() async {
    final response = await http.get(Uri.parse('$baseUrl/api/v1/settings/public-api'));
    final body = jsonDecode(utf8.decode(response.bodyBytes));
    if (response.statusCode != 200) throw Exception(body['detail'] ?? 'อ่านการตั้งค่าไม่ได้');
    return Map<String, dynamic>.from(body['data']);
  }

  Future<Map<String, dynamic>> savePublicApiSettings(Map<String, dynamic> change) async {
    final response = await http.post(Uri.parse('$baseUrl/api/v1/settings/public-api'),
        headers: {'Content-Type': 'application/json'}, body: jsonEncode(change));
    final body = jsonDecode(utf8.decode(response.bodyBytes));
    if (response.statusCode != 200) throw Exception(body['detail'] ?? 'บันทึกไม่สำเร็จ');
    return Map<String, dynamic>.from(body['data']);
  }

  Future<String> publicApiSnippet(String view) async {
    final response = await http.get(Uri.parse('$baseUrl/api/v1/settings/public-api/snippet?view=$view'));
    final body = jsonDecode(utf8.decode(response.bodyBytes));
    if (response.statusCode != 200) throw Exception(body['detail'] ?? 'สร้างโค้ดไม่สำเร็จ');
    return '${body['code']}';
  }

  Future<Map<String, dynamic>> offsiteStatus() async {
    final response = await http.get(Uri.parse('$baseUrl/api/v1/backups/offsite'));
    final body = jsonDecode(utf8.decode(response.bodyBytes));
    if (response.statusCode != 200) throw Exception(body['detail'] ?? 'อ่านการตั้งค่าไม่ได้');
    return Map<String, dynamic>.from(body['data']);
  }

  Future<Map<String, dynamic>> setOffsiteRemote(String remote) async {
    final response = await http.post(Uri.parse('$baseUrl/api/v1/backups/offsite'),
        headers: {'Content-Type': 'application/json'}, body: jsonEncode({'remote': remote}));
    final body = jsonDecode(utf8.decode(response.bodyBytes));
    if (response.statusCode != 200) throw Exception(body['detail'] ?? 'บันทึกไม่สำเร็จ');
    return Map<String, dynamic>.from(body['data']);
  }

  Future<Map<String, dynamic>> runOffsiteNow() async {
    final response = await http.post(Uri.parse('$baseUrl/api/v1/backups/offsite/run'));
    final body = jsonDecode(utf8.decode(response.bodyBytes));
    if (response.statusCode != 200) throw Exception(body['detail'] ?? 'ส่งขึ้น Drive ไม่สำเร็จ');
    return Map<String, dynamic>.from(body['data']);
  }

  String archiveDownloadUrl(String name) => '$baseUrl/api/v1/backups/archives/${Uri.encodeComponent(name)}/download';
  /// commit = false: check only (writes nothing); true: check again, back up, save
  Future<Map<String, dynamic>> schoolImport(String term, String year, Uint8List bytes, String filename, {required bool commit}) async {
    final request = http.MultipartRequest('POST', Uri.parse('$baseUrl/api/v1/school-import/${commit ? 'commit' : 'preview'}'))
      ..fields.addAll({'term': term, 'year': year})
      ..files.add(http.MultipartFile.fromBytes('file', bytes, filename: filename));
    final response = await http.Response.fromStream(await request.send());
    final body = jsonDecode(utf8.decode(response.bodyBytes));
    if (response.statusCode != 200) throw Exception(body is Map ? (body['detail'] ?? 'นำเข้าไม่สำเร็จ') : 'นำเข้าไม่สำเร็จ');
    return Map<String, dynamic>.from(body['data']);
  }
  String examTimetableFileUrl(String term, String year, String examType) =>
      '$baseUrl/api/v1/exams/timetable/file?term=$term&year=$year&exam_type=$examType';

  /// นักเรียนไม่มีสิทธิ์สอบ (มส.) of one course, with the teacher's ticks; can_edit = the course teacher / admin
  Future<Map<String, dynamic>> getNoExamRight(String courseCode, String term, String year) async {
    final r = await _examRequest('GET', '/api/v1/exams/no-exam-right', query: {'course_code': courseCode, 'term': term, 'year': year});
    return Map<String, dynamic>.from(r['data']);
  }

  /// course_code -> {count, allowed} for the archive table
  Future<Map<String, dynamic>> getNoExamRightCounts(String term, String year) async {
    final r = await _examRequest('GET', '/api/v1/exams/no-exam-right-counts', query: {'term': term, 'year': year});
    return Map<String, dynamic>.from(r['data']);
  }

  Future<void> setExamPermit(String courseCode, String term, String year, String studentId, bool allowed) async {
    await _examRequest('POST', '/api/v1/exams/permit',
        body: {'course_code': courseCode, 'term': term, 'year': year, 'student_id': studentId, 'allowed': allowed});
  }

  /// Per paper: true = students with มส. cannot sit (unless ticked), false = everyone sits
  Future<void> setExamBlockMs(String courseCode, String term, String year, String examType, bool block) async {
    await _examRequest('POST', '/api/v1/exams/block-ms',
        body: {'course_code': courseCode, 'term': term, 'year': year, 'exam_type': examType, 'block_ms': block});
  }

  Future<Map<String, dynamic>?> getExamPaper(String courseCode, String term, String year, String examType) async {
    final r = await _examRequest('GET', '/api/v1/exams/paper',
        query: {'course_code': courseCode, 'term': term, 'year': year, 'exam_type': examType});
    return r['data'] == null ? null : Map<String, dynamic>.from(r['data']);
  }

  Future<Map<String, dynamic>> saveExamPaper(Map<String, dynamic> paper) async {
    final r = await _examRequest('POST', '/api/v1/exams/paper', body: paper);
    return Map<String, dynamic>.from(r['data']);
  }

  Future<void> deleteExamPaper(String courseCode, String term, String year, String examType) async {
    await _examRequest('POST', '/api/v1/exams/paper/delete',
        body: {'course_code': courseCode, 'term': term, 'year': year, 'exam_type': examType});
  }

  Future<List<Map<String, dynamic>>> parseExamText(String text) async {
    final r = await _examRequest('POST', '/api/v1/exams/parse-text', body: {'text': text});
    return (r['data'] as List).map((e) => Map<String, dynamic>.from(e)).toList();
  }

  Future<Map<String, dynamic>> getExamResults(String courseCode, String term, String year, String examType) async {
    final r = await _examRequest('GET', '/api/v1/exams/results',
        query: {'course_code': courseCode, 'term': term, 'year': year, 'exam_type': examType});
    return Map<String, dynamic>.from(r['data']);
  }

  Future<void> resetExamAttempt(String courseCode, String term, String year, String examType, String studentId) async {
    await _examRequest('POST', '/api/v1/exams/reset-attempt',
        body: {'course_code': courseCode, 'term': term, 'year': year, 'exam_type': examType, 'student_id': studentId});
  }

  // ---------------------------------------------------------------- ตัวช่วย AI ออกข้อสอบ (ai_assist.py)

  /// configured, model, daily_limit, used_today, left_today, kinds, quiz_kinds, levels (+ key_hint for an admin)
  Future<Map<String, dynamic>> getAiStatus() async {
    final r = await _examRequest('GET', '/api/v1/ai/status');
    return Map<String, dynamic>.from(r['data']);
  }

  /// คลังเรื่อง: chapters of one subject and grade; with only the course, its subject and grade are guessed
  Future<Map<String, dynamic>> getAiTopics({required String courseCode, required String term, required String year, String? subject, String? grade}) async {
    final r = await _examRequest('GET', '/api/v1/ai/topics', query: {
      'course_code': courseCode,
      'term': term,
      'year': year,
      if (subject != null) 'subject': subject,
      if (grade != null) 'grade': grade,
    });
    return Map<String, dynamic>.from(r['data']);
  }

  /// ผู้ดูแลระบบ: the key is sent once and never comes back (only its last 4 characters)
  Future<Map<String, dynamic>> saveAiSettings({String? apiKey, String? model, int? dailyLimit, bool clearKey = false}) async {
    final r = await _examRequest('POST', '/api/v1/ai/settings', body: {
      if (apiKey != null) 'api_key': apiKey,
      if (model != null) 'model': model,
      if (dailyLimit != null) 'daily_limit': dailyLimit,
      'clear_key': clearKey,
    });
    return Map<String, dynamic>.from(r['data']);
  }

  Future<String> testAi() async {
    final r = await _examRequest('POST', '/api/v1/ai/test');
    return '${r['message'] ?? 'พร้อมใช้งาน'}';
  }

  /// A draft from the AI: {questions, notes, files, left_today}. Only the indicators and lesson material go out.
  Future<Map<String, dynamic>> aiGenerate(Map<String, dynamic> spec, List<MapEntry<String, List<int>>> files) async {
    final request = http.MultipartRequest('POST', Uri.parse('$baseUrl/api/v1/ai/generate'))..fields['spec'] = jsonEncode(spec);
    for (final f in files) {
      request.files.add(http.MultipartFile.fromBytes('files', f.value, filename: f.key));
    }
    final response = await http.Response.fromStream(await request.send());
    final body = jsonDecode(utf8.decode(response.bodyBytes));
    if (response.statusCode != 200) throw Exception(body is Map ? (body['detail'] ?? 'AI ทำงานไม่สำเร็จ') : 'AI ทำงานไม่สำเร็จ');
    return Map<String, dynamic>.from(body['data']);
  }

  /// Checked questions go after the questions already in the midterm / final paper. Returns {data, added}.
  Future<Map<String, dynamic>> aiAppendExam(String courseCode, String term, String year, String examType, List<Map<String, dynamic>> questions) async {
    final r = await _examRequest('POST', '/api/v1/ai/append-exam',
        body: {'course_code': courseCode, 'term': term, 'year': year, 'exam_type': examType, 'questions': questions});
    return Map<String, dynamic>.from(r);
  }

  // ---------------------------------------------------------------- แบบทดสอบย่อย / หลังเรียน

  /// ครู: a course's quizzes, plus the full score of ช่อง 1-8 (unit_max)
  Future<Map<String, dynamic>> listQuizzes(String courseCode, String term, String year) async {
    final r = await _examRequest('GET', '/api/v1/quizzes', query: {'course_code': courseCode, 'term': term, 'year': year});
    return Map<String, dynamic>.from(r['data']);
  }

  /// course_code -> {count, ready}
  Future<Map<String, dynamic>> getQuizCounts(String term, String year) async {
    final r = await _examRequest('GET', '/api/v1/quizzes/counts', query: {'term': term, 'year': year});
    return Map<String, dynamic>.from(r['data']);
  }

  /// Scores page: slot ("0".."7") -> {quizzes, full, points_max} for the columns filled by quizzes
  Future<Map<String, dynamic>> getQuizLinkedSlots(String courseCode, String term, String year) async {
    final r = await _examRequest('GET', '/api/v1/quizzes/linked-slots', query: {'course_code': courseCode, 'term': term, 'year': year});
    return Map<String, dynamic>.from(r['data']);
  }

  Future<Map<String, dynamic>> getQuiz(int id) async {
    final r = await _examRequest('GET', '/api/v1/quizzes/$id');
    return Map<String, dynamic>.from(r['data']);
  }

  Future<Map<String, dynamic>> saveQuiz(Map<String, dynamic> quiz) async {
    final r = await _examRequest('POST', '/api/v1/quizzes', body: quiz);
    return Map<String, dynamic>.from(r['data']);
  }

  Future<void> deleteQuiz(int id) async {
    await _examRequest('POST', '/api/v1/quizzes/$id/delete');
  }

  /// quiz id -> column index 0..7 (null = not linked)
  Future<Map<String, dynamic>> saveQuizLinks(String courseCode, String term, String year, Map<String, int?> links) async {
    final r = await _examRequest('POST', '/api/v1/quizzes/links',
        body: {'course_code': courseCode, 'term': term, 'year': year, 'links': links});
    return Map<String, dynamic>.from(r['data']);
  }

  Future<Map<String, dynamic>> getQuizResults(int id) async {
    final r = await _examRequest('GET', '/api/v1/quizzes/$id/results');
    return Map<String, dynamic>.from(r['data']);
  }

  Future<void> resetQuizAttempts(int id, String studentId) async {
    await _examRequest('POST', '/api/v1/quizzes/$id/reset', body: {'student_id': studentId});
  }

  /// นักเรียน: enrolled courses with their quizzes
  Future<Map<String, dynamic>> getStudentQuizzes() async {
    final r = await _examRequest('GET', '/api/v1/student-portal/quizzes');
    return Map<String, dynamic>.from(r['data']);
  }

  Future<Map<String, dynamic>> startStudentQuiz(int id) async {
    final r = await _examRequest('POST', '/api/v1/student-portal/quizzes/$id/start');
    return Map<String, dynamic>.from(r['data']);
  }

  Future<void> saveStudentQuizAnswers(int id, Map<String, dynamic> answers) async {
    await _examRequest('POST', '/api/v1/student-portal/quizzes/$id/answers', body: {'answers': answers});
  }

  Future<Map<String, dynamic>> submitStudentQuiz(int id, Map<String, dynamic> answers) async {
    final r = await _examRequest('POST', '/api/v1/student-portal/quizzes/$id/submit', body: {'answers': answers});
    return Map<String, dynamic>.from(r['data']);
  }

  /// นักเรียน: exam buttons grouped into กลางภาค / ปลายภาค
  Future<Map<String, dynamic>> getStudentExams() async {
    final r = await _examRequest('GET', '/api/v1/student-portal/exams');
    return Map<String, dynamic>.from(r['data']);
  }

  Future<Map<String, dynamic>> startStudentExam(int examId) async {
    final r = await _examRequest('POST', '/api/v1/student-portal/exams/$examId/start');
    return Map<String, dynamic>.from(r['data']);
  }

  Future<void> saveStudentExamAnswers(int examId, Map<String, dynamic> answers) async {
    await _examRequest('POST', '/api/v1/student-portal/exams/$examId/answers', body: {'answers': answers});
  }

  /// นักเรียน: a photo of a written answer (camera or gallery)
  Future<Map<String, dynamic>> uploadStudentExamPhoto(int examId, int question, Uint8List bytes, String filename) async {
    final request = http.MultipartRequest('POST', Uri.parse('$baseUrl/api/v1/student-portal/exams/$examId/photo'))
      ..fields['question'] = '$question'
      ..files.add(http.MultipartFile.fromBytes('file', bytes, filename: filename));
    final response = await http.Response.fromStream(await request.send());
    final body = jsonDecode(utf8.decode(response.bodyBytes));
    if (response.statusCode != 200) throw Exception(body['detail'] ?? 'ส่งรูปไม่สำเร็จ');
    return Map<String, dynamic>.from(body['data']);
  }

  Future<Map<String, dynamic>> deleteStudentExamPhoto(int examId, int question, String name) async {
    final r = await _examRequest('POST', '/api/v1/student-portal/exams/$examId/photo/delete', body: {'question': question, 'name': name});
    return Map<String, dynamic>.from(r['data']);
  }

  String studentExamPhotoUrl(int examId, String name) => '$baseUrl/api/v1/student-portal/exams/$examId/photo/$name';

  /// ครู: one student's answers next to the key, and the photos to mark
  Future<Map<String, dynamic>> getExamAttempt(String courseCode, String term, String year, String examType, String studentId) async {
    final r = await _examRequest('GET', '/api/v1/exams/attempt',
        query: {'course_code': courseCode, 'term': term, 'year': year, 'exam_type': examType, 'student_id': studentId});
    return Map<String, dynamic>.from(r['data']);
  }

  Future<Map<String, dynamic>> markExamPhotos(String courseCode, String term, String year, String examType, String studentId,
      Map<String, dynamic> marks) async {
    final r = await _examRequest('POST', '/api/v1/exams/mark', body: {
      'course_code': courseCode, 'term': term, 'year': year, 'exam_type': examType, 'student_id': studentId, 'marks': marks,
    });
    return Map<String, dynamic>.from(r['data']);
  }

  String teacherExamPhotoUrl(String courseCode, String term, String year, String examType, String studentId, String name) =>
      Uri.parse('$baseUrl/api/v1/exams/photo').replace(queryParameters: {
        'course_code': courseCode, 'term': term, 'year': year, 'exam_type': examType, 'student_id': studentId, 'name': name,
      }).toString();

  Future<Map<String, dynamic>> submitStudentExam(int examId, Map<String, dynamic> answers) async {
    final r = await _examRequest('POST', '/api/v1/student-portal/exams/$examId/submit', body: {'answers': answers});
    return Map<String, dynamic>.from(r['data']);
  }

  /// Logout: the server clears the session cookie
  Future<void> logoutTeacher() async {
    currentUserNotifier.value = null;
    try {
      await http.post(Uri.parse('$baseUrl/api/v1/auth/logout'));
    } catch (_) {}
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('saved_teacher_pin');
    } catch (_) {}
  }

  /// Get list of system admins
  Future<List<Map<String, dynamic>>> getSystemAdmins() async {
    final uri = Uri.parse('$baseUrl/api/v1/system/admins');
    final response = await http.get(uri);
    final body = jsonDecode(utf8.decode(response.bodyBytes));
    if (response.statusCode != 200) {
      throw Exception(body['detail'] ?? 'ไม่สามารถดึงข้อมูลผู้ดูแลระบบได้');
    }
    return List<Map<String, dynamic>>.from(body['admins'] ?? []);
  }

  /// Add a system admin (max 3)
  Future<List<Map<String, dynamic>>> addSystemAdmin(String teacherCode) async {
    final uri = Uri.parse('$baseUrl/api/v1/system/admins');
    final response = await http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'teacher_code': teacherCode.trim()}),
    );
    final body = jsonDecode(utf8.decode(response.bodyBytes));
    if (response.statusCode != 200) {
      throw Exception(body['detail'] ?? 'ไม่สามารถแต่งตั้งผู้ดูแลระบบได้');
    }
    return List<Map<String, dynamic>>.from(body['admins'] ?? []);
  }

  /// Remove a system admin
  Future<List<Map<String, dynamic>>> removeSystemAdmin(String teacherCode) async {
    final uri = Uri.parse('$baseUrl/api/v1/system/admins/${teacherCode.trim()}');
    final response = await http.delete(uri);
    final body = jsonDecode(utf8.decode(response.bodyBytes));
    if (response.statusCode != 200) {
      throw Exception(body['detail'] ?? 'ไม่สามารถถอดถอนผู้ดูแลระบบได้');
    }
    return List<Map<String, dynamic>>.from(body['admins'] ?? []);
  }

  /// Mark a specific semester as the pinned default semester shown on Dashboard & refresh
  Future<Map<String, dynamic>> setDefaultSemester({
    required String term,
    required String year,
  }) async {
    final uri = Uri.parse('$baseUrl/api/v1/settings/semesters/set-default');
    final response = await http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'term': term, 'year': year}),
    );
    final body = jsonDecode(utf8.decode(response.bodyBytes));
    if (response.statusCode != 200) {
      throw Exception(body['detail'] ?? 'ไม่สามารถปักหมุดภาคเรียนหลักได้');
    }
    final updatedRaw = (body['data'] as List?) ?? [];
    if (updatedRaw.isNotEmpty) {
      final configs = updatedRaw.map((e) => SemesterConfigItem.fromJson(e as Map<String, dynamic>)).toList();
      final def = configs.firstWhere(
        (s) => s.isDefault,
        orElse: () => configs.firstWhere((s) => s.isActive, orElse: () => configs.first),
      );
      defaultSemesterNotifier.value = def;
    } else {
      defaultSemesterNotifier.value = SemesterConfigItem(
        term: term,
        year: year,
        title: 'ปีการศึกษา  ภาคเรียนที่ ',
        isDefault: true,
      );
    }
    return body as Map<String, dynamic>;
  }

  /// The logo's URL path from the server: first the one in the tab icon of index.html (the same URL, so the
  /// browser downloads the logo only once), later the one the server answers with. null = not known.
  String? _schoolLogoPath = pageSchoolLogoPath();

  String getSchoolLogoUrl() {
    final path = _schoolLogoPath ?? '/api/v1/settings/school-logo?v=${schoolLogoNotifier.value}';
    return '$baseUrl$path';
  }

  Future<Map<String, dynamic>> getSchoolLogoInfo() async {
    final uri = Uri.parse('$baseUrl/api/v1/settings/school-logo/info');
    final response = await http.get(uri);
    if (response.statusCode != 200) {
      return {'status': 'error', 'has_logo': false};
    }
    final body = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    final logoUrl = body['logo_url'];
    if (logoUrl is String && logoUrl.isNotEmpty && logoUrl != _schoolLogoPath) {
      _schoolLogoPath = logoUrl; // the logo changed since index.html was loaded (or no index.html)
      schoolLogoNotifier.value++;
    }
    if (body['full_school_name'] != null && (body['full_school_name'] as String).isNotEmpty) {
      schoolNameNotifier.value = body['full_school_name'];
    } else if (body['school_name'] != null && (body['school_name'] as String).isNotEmpty) {
      final s = (body['school_name'] as String).replaceFirst(RegExp(r'^โรงเรียน\s*'), '').trim();
      schoolNameNotifier.value = 'โรงเรียน$s';
    }
    if (body['sidebar_footer_title'] != null && body['sidebar_footer_title'].toString().trim().isNotEmpty) {
      sidebarFooterTitleNotifier.value = body['sidebar_footer_title'].toString().trim();
    }
    if (body['sidebar_footer_subtitle'] != null && body['sidebar_footer_subtitle'].toString().trim().isNotEmpty) {
      sidebarFooterSubtitleNotifier.value = body['sidebar_footer_subtitle'].toString().trim();
    } else {
      sidebarFooterSubtitleNotifier.value = schoolNameNotifier.value;
    }
    if (body['web_title'] != null && body['web_title'].toString().trim().isNotEmpty) {
      webTitleNotifier.value = body['web_title'].toString().trim();
    }
    // Also load school theme colors & font concurrently
    getSchoolTheme().ignore();
    return body;
  }

  /// Save the browser tab title (ชื่อหน้าเว็บ). An empty string resets to the default.
  Future<String> updateWebTitle(String title) async {
    final uri = Uri.parse('$baseUrl/api/v1/settings/web-title');
    final response = await http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'web_title': title.trim()}),
    );
    final body = jsonDecode(utf8.decode(response.bodyBytes));
    if (response.statusCode != 200) {
      throw Exception(body['detail'] ?? 'ไม่สามารถบันทึกชื่อหน้าเว็บได้');
    }
    final saved = (body['web_title'] ?? '').toString().trim();
    if (saved.isNotEmpty) webTitleNotifier.value = saved;
    return saved;
  }

  Future<void> updateSchoolName(
    String name, {
    String? sidebarFooterTitle,
    String? sidebarFooterSubtitle,
  }) async {
    final clean = name.replaceFirst(RegExp(r'^โรงเรียน\s*'), '').trim();
    final uri = Uri.parse('$baseUrl/api/v1/settings/school-info');
    final payload = <String, dynamic>{
      'school_name': clean,
      if (sidebarFooterTitle != null) 'sidebar_footer_title': sidebarFooterTitle.trim(),
      if (sidebarFooterSubtitle != null) 'sidebar_footer_subtitle': sidebarFooterSubtitle.trim(),
    };
    final response = await http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(payload),
    );
    if (response.statusCode != 200) {
      final body = jsonDecode(utf8.decode(response.bodyBytes));
      throw Exception(body['detail'] ?? 'ไม่สามารถบันทึกชื่อสถานศึกษาได้');
    }
    schoolNameNotifier.value = 'โรงเรียน$clean';
    if (sidebarFooterTitle != null) {
      final ft = sidebarFooterTitle.trim();
      sidebarFooterTitleNotifier.value = ft.isNotEmpty ? ft : 'ระบบงาน ปพ.5 & ทะเบียนวัดผล';
    }
    if (sidebarFooterSubtitle != null) {
      final fs = sidebarFooterSubtitle.trim();
      sidebarFooterSubtitleNotifier.value = fs.isNotEmpty ? fs : 'โรงเรียน$clean';
    }
  }

  Future<Map<String, dynamic>> uploadSchoolLogo(Uint8List bytes, String filename) async {
    final uri = Uri.parse('$baseUrl/api/v1/settings/school-logo');
    final request = http.MultipartRequest('POST', uri);
    request.files.add(http.MultipartFile.fromBytes('file', bytes, filename: filename));
    final streamedResponse = await request.send();
    final response = await http.Response.fromStream(streamedResponse);
    final responseText = utf8.decode(response.bodyBytes);
    Map<String, dynamic> body = {};
    try {
      final decoded = jsonDecode(responseText);
      if (decoded is Map<String, dynamic>) {
        body = decoded;
      }
    } catch (_) {
      if (response.statusCode != 200) {
        throw Exception('เซิร์ฟเวอร์ขัดข้อง (รหัส ${response.statusCode})');
      }
    }
    if (response.statusCode != 200) {
      throw Exception(body['detail'] ?? 'ไม่สามารถอัปโหลดโลโก้โรงเรียนได้ (รหัส ${response.statusCode})');
    }
    final logoUrl = body['logo_url'];
    _schoolLogoPath = logoUrl is String && logoUrl.isNotEmpty ? logoUrl : null;
    schoolLogoNotifier.value++;
    return body;
  }

  Future<Map<String, dynamic>> deleteSchoolLogo() async {
    final uri = Uri.parse('$baseUrl/api/v1/settings/school-logo');
    final response = await http.delete(uri);
    final responseText = utf8.decode(response.bodyBytes);
    Map<String, dynamic> body = {};
    try {
      final decoded = jsonDecode(responseText);
      if (decoded is Map<String, dynamic>) {
        body = decoded;
      }
    } catch (_) {
      if (response.statusCode != 200) {
        throw Exception('เซิร์ฟเวอร์ขัดข้อง (รหัส ${response.statusCode})');
      }
    }
    if (response.statusCode != 200) {
      throw Exception(body['detail'] ?? 'ไม่สามารถลบโลโก้โรงเรียนได้ (รหัส ${response.statusCode})');
    }
    _schoolLogoPath = null;
    schoolLogoNotifier.value++;
    return body;
  }

  String getPp5LogoUrl({bool forceCustomOnly = false}) {
    if (forceCustomOnly) {
      return '$baseUrl/api/v1/settings/pp5-logo/custom?v=${pp5LogoNotifier.value}';
    }
    return '$baseUrl/api/v1/settings/pp5-logo?v=${pp5LogoNotifier.value}_${schoolLogoNotifier.value}';
  }

  Future<Map<String, dynamic>> getPp5LogoInfo() async {
    final uri = Uri.parse('$baseUrl/api/v1/settings/pp5-logo/info');
    final response = await http.get(uri);
    if (response.statusCode != 200) {
      return {'status': 'error', 'has_custom_pp5_logo': false, 'active_logo_source': 'school_default'};
    }
    return jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> uploadPp5Logo(Uint8List bytes, String filename) async {
    final uri = Uri.parse('$baseUrl/api/v1/settings/pp5-logo');
    final request = http.MultipartRequest('POST', uri);
    request.files.add(http.MultipartFile.fromBytes('file', bytes, filename: filename));
    final streamedResponse = await request.send();
    final response = await http.Response.fromStream(streamedResponse);
    final responseText = utf8.decode(response.bodyBytes);
    Map<String, dynamic> body = {};
    try {
      final decoded = jsonDecode(responseText);
      if (decoded is Map<String, dynamic>) {
        body = decoded;
      }
    } catch (_) {
      if (response.statusCode != 200) {
        throw Exception('เซิร์ฟเวอร์ขัดข้อง (รหัส ${response.statusCode})');
      }
    }
    if (response.statusCode != 200) {
      throw Exception(body['detail'] ?? 'ไม่สามารถอัปโหลดตรา ปพ.5 ได้ (รหัส ${response.statusCode})');
    }
    pp5LogoNotifier.value++;
    return body;
  }

  Future<Map<String, dynamic>> resetPp5LogoToDefault() async {
    final uri = Uri.parse('$baseUrl/api/v1/settings/pp5-logo');
    final response = await http.delete(uri);
    final responseText = utf8.decode(response.bodyBytes);
    Map<String, dynamic> body = {};
    try {
      final decoded = jsonDecode(responseText);
      if (decoded is Map<String, dynamic>) {
        body = decoded;
      }
    } catch (_) {
      if (response.statusCode != 200) {
        throw Exception('เซิร์ฟเวอร์ขัดข้อง (รหัส ${response.statusCode})');
      }
    }
    if (response.statusCode != 200) {
      throw Exception(body['detail'] ?? 'ไม่สามารถคืนค่าตรา ปพ.5 ได้ (รหัส ${response.statusCode})');
    }
    pp5LogoNotifier.value++;
    return body;
  }

  /// Load school custom theme colors and font configuration
  Future<SchoolThemeConfig> getSchoolTheme() async {
    try {
      final uri = Uri.parse('$baseUrl/api/v1/settings/school-theme');
      final response = await http.get(uri);
      if (response.statusCode == 200) {
        final body = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
        final config = SchoolThemeConfig.fromJson(body);
        themeNotifier.value = config;
        return config;
      }
    } catch (e) {
      debugPrint('Error loading school theme: $e');
    }
    return themeNotifier.value;
  }

  /// Update school custom theme colors and font configuration
  Future<SchoolThemeConfig> updateSchoolTheme(SchoolThemeConfig config) async {
    final uri = Uri.parse('$baseUrl/api/v1/settings/school-theme');
    final response = await http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(config.toJson()),
    );
    final body = jsonDecode(utf8.decode(response.bodyBytes));
    if (response.statusCode != 200) {
      throw Exception(body['detail'] ?? 'ไม่สามารถบันทึกสีและฟอนต์ประจำโรงเรียนได้');
    }
    final savedConfig = SchoolThemeConfig.fromJson(body);
    themeNotifier.value = savedConfig;
    return savedConfig;
  }

  /// Reset school custom theme colors and font configuration to defaults
  Future<SchoolThemeConfig> resetSchoolTheme() async {
    final uri = Uri.parse('$baseUrl/api/v1/settings/school-theme/reset');
    final response = await http.post(uri);
    final body = jsonDecode(utf8.decode(response.bodyBytes));
    if (response.statusCode != 200) {
      throw Exception(body['detail'] ?? 'ไม่สามารถรีเซ็ตสีและฟอนต์ได้');
    }
    final resetConfig = SchoolThemeConfig.fromJson(body);
    themeNotifier.value = resetConfig;
    return resetConfig;
  }

  /// Retrieve Sheet (4) รวมคะแนน max scores and student scores for a course
  Future<Map<String, dynamic>> getCourseScoresSheet({
    required String courseCode,
    required String term,
    required String year,
  }) async {
    final uri = Uri.parse('$baseUrl/api/v1/courses/scores').replace(
      queryParameters: {
        'course_code': courseCode,
        'term': term,
        'year': year,
      },
    );
    final response = await http.get(uri);
    final body = jsonDecode(utf8.decode(response.bodyBytes));
    if (response.statusCode != 200) {
      throw Exception(body['detail'] ?? 'ไม่สามารถดึงข้อมูลคะแนนรายวิชาได้');
    }
    return body as Map<String, dynamic>;
  }

  /// Save Sheet (4) รวมคะแนน max scores, student scores, and remark overrides
  Future<Map<String, dynamic>> saveCourseScoresSheet({
    required String courseCode,
    required String term,
    required String year,
    String? scoreRatio,
    required Map<String, dynamic> scoreConfig,
    required List<Map<String, dynamic>> students,
  }) async {
    final uri = Uri.parse('$baseUrl/api/v1/courses/scores');
    final response = await http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'course_code': courseCode,
        'term': term,
        'year': year,
        'score_ratio': scoreRatio,
        'score_config': scoreConfig,
        'students': students,
      }),
    );
    final body = jsonDecode(utf8.decode(response.bodyBytes));
    if (response.statusCode != 200) {
      throw Exception(body['detail'] ?? 'ไม่สามารถบันทึกข้อมูลคะแนนรายวิชาได้');
    }
    return body as Map<String, dynamic>;
  }

  /// Vertical header labels of a course's ปพ.5: {labels: {indicators[8], attributes[8], reading[5]}, can_edit,
  /// standard_attributes, max_len}
  Future<Map<String, dynamic>> getPp5Labels({
    required String courseCode,
    required String term,
    required String year,
  }) async {
    final uri = Uri.parse('$baseUrl/api/v1/courses/pp5-labels').replace(
      queryParameters: {'course_code': courseCode, 'term': term, 'year': year},
    );
    final response = await http.get(uri);
    final body = jsonDecode(utf8.decode(response.bodyBytes));
    if (response.statusCode != 200) {
      throw Exception(body['detail'] ?? 'ไม่สามารถดึงข้อความหัวตาราง ปพ.5 ได้');
    }
    return body as Map<String, dynamic>;
  }

  /// Save the groups given (others stay as they are); the server writes them into the ปพ.5 Excel at once.
  Future<Map<String, dynamic>> savePp5Labels({
    required String courseCode,
    required String term,
    required String year,
    List<String>? indicators,
    List<String>? attributes,
    List<String>? reading,
  }) async {
    final response = await http.post(
      Uri.parse('$baseUrl/api/v1/courses/pp5-labels'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'course_code': courseCode,
        'term': term,
        'year': year,
        if (indicators != null) 'indicators': indicators,
        if (attributes != null) 'attributes': attributes,
        if (reading != null) 'reading': reading,
      }),
    );
    final body = jsonDecode(utf8.decode(response.bodyBytes));
    if (response.statusCode != 200) {
      throw Exception(body['detail'] ?? 'ไม่สามารถบันทึกข้อความหัวตาราง ปพ.5 ได้');
    }
    return body as Map<String, dynamic>;
  }

  // ---------------------------------------------------------------------------
  // Master Course Catalog (คลังรายชื่อวิชามาตรฐาน เทอม 1 และ เทอม 2)
  // ---------------------------------------------------------------------------
  Future<List<Map<String, dynamic>>> getCourseCatalog({
    String? term,
    String? stage,
    String? courseType,
    String? subjectPrefix,
    String? search,
  }) async {
    final params = <String, String>{};
    if (term != null && term.isNotEmpty && term != 'all') params['term'] = term;
    if (stage != null && stage.isNotEmpty && stage != 'all') params['stage'] = stage;
    if (courseType != null && courseType.isNotEmpty && courseType != 'all') params['course_type'] = courseType;
    if (subjectPrefix != null && subjectPrefix.isNotEmpty && subjectPrefix != 'all') params['subject_prefix'] = subjectPrefix;
    if (search != null && search.trim().isNotEmpty) params['search'] = search.trim();

    final uri = Uri.parse('$baseUrl/api/v1/catalog').replace(
      queryParameters: params.isEmpty ? null : params,
    );
    final response = await http.get(uri);
    final body = jsonDecode(utf8.decode(response.bodyBytes));
    if (response.statusCode != 200) {
      throw Exception(body['detail'] ?? 'ไม่สามารถดึงข้อมูลคลังรายวิชามาตรฐานได้');
    }
    return List<Map<String, dynamic>>.from(body['courses'] ?? []);
  }

  Future<Map<String, dynamic>> saveCatalogCourse(Map<String, dynamic> data) async {
    final uri = Uri.parse('$baseUrl/api/v1/catalog');
    final response = await http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(data),
    );
    final body = jsonDecode(utf8.decode(response.bodyBytes));
    if (response.statusCode != 200) {
      throw Exception(body['detail'] ?? 'ไม่สามารถบันทึกรายวิชาลงคลังได้');
    }
    return body as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> deleteCatalogCourse(String courseCode) async {
    final uri = Uri.parse('$baseUrl/api/v1/catalog/${Uri.encodeComponent(courseCode)}');
    final response = await http.delete(uri);
    final body = jsonDecode(utf8.decode(response.bodyBytes));
    if (response.statusCode != 200) {
      throw Exception(body['detail'] ?? 'ไม่สามารถลบรายวิชาออกจากคลังได้');
    }
    return body as Map<String, dynamic>;
  }


  // ---------------------------------------------------------------------------
  // Teacher Timetables & Smart Late Period Integration
  // ---------------------------------------------------------------------------
  Future<Map<String, dynamic>> getTimetables({
    required String term,
    required String year,
    String? teacherName,
    String? classLevel,
  }) async {
    final params = <String, String>{
      'term': term,
      'year': year,
    };
    if (teacherName != null && teacherName.isNotEmpty) {
      params['teacher_name'] = teacherName;
    }
    if (classLevel != null && classLevel.isNotEmpty) {
      params['class_level'] = classLevel;
    }
    final uri = Uri.parse('$baseUrl/api/v1/timetables').replace(queryParameters: params);
    final response = await http.get(uri);
    final body = jsonDecode(utf8.decode(response.bodyBytes));
    if (response.statusCode != 200) {
      throw Exception(body['detail'] ?? 'ไม่สามารถดึงข้อมูลตารางสอนได้');
    }
    return body as Map<String, dynamic>;
  }

  /// บันทึกคาบสอน ถ้าชั้นนั้นมีคาบของครูคนอื่นอยู่แล้ว จะโยน [TimetableClashException] (needsConfirm) ให้ถามยืนยัน
  /// แล้วส่งใหม่พร้อม `force: true`
  Future<Map<String, dynamic>> upsertTimetableSlot(Map<String, dynamic> data) async {
    final uri = Uri.parse('$baseUrl/api/v1/timetables');
    final response = await http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(data),
    );
    final body = jsonDecode(utf8.decode(response.bodyBytes));
    if (response.statusCode == 409) {
      throw TimetableClashException('${body['detail'] ?? 'เวลานี้มีคาบชนอยู่'}', needsConfirm: body['needs_confirm'] == true);
    }
    if (response.statusCode != 200) {
      throw Exception(body['detail'] ?? 'ไม่สามารถบันทึกคาบสอนได้');
    }
    return body as Map<String, dynamic>;
  }

  /// ย้ายคาบสอนไปวัน/คาบใหม่ในขั้นตอนเดียว (ระบบปรับตารางเรียน เวลาเรียน และ ปพ.5 ให้)
  Future<Map<String, dynamic>> moveTimetableSlot(int id, {required int dayOfWeek, required int periodNum, bool force = false}) async {
    final uri = Uri.parse('$baseUrl/api/v1/timetables/$id/move');
    final response = await http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'day_of_week': dayOfWeek, 'period_num': periodNum, 'force': force}),
    );
    final body = jsonDecode(utf8.decode(response.bodyBytes));
    if (response.statusCode == 409) {
      throw TimetableClashException('${body['detail'] ?? 'เวลานี้มีคาบชนอยู่'}', needsConfirm: body['needs_confirm'] == true);
    }
    if (response.statusCode != 200) {
      throw Exception(body['detail'] ?? 'ย้ายคาบสอนไม่สำเร็จ');
    }
    return body as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> deleteTimetableSlot(int id) async {
    final uri = Uri.parse('$baseUrl/api/v1/timetables/$id');
    final response = await http.delete(uri);
    final body = jsonDecode(utf8.decode(response.bodyBytes));
    if (response.statusCode != 200) {
      throw Exception(body['detail'] ?? 'ไม่สามารถลบคาบสอนได้');
    }
    return body as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> getTeacherCoursesForTimetable({
    required String term,
    required String year,
    required String teacherName,
  }) async {
    final uri = Uri.parse('$baseUrl/api/v1/timetables/teacher-courses').replace(
      queryParameters: {
        'term': term,
        'year': year,
        'teacher_name': teacherName,
      },
    );
    final response = await http.get(uri);
    final body = jsonDecode(utf8.decode(response.bodyBytes));
    if (response.statusCode != 200) {
      throw Exception(body['detail'] ?? 'ไม่สามารถดึงรายวิชาของครูได้');
    }
    return body as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> previewLateCascade({
    required String term,
    required String year,
    required String classLevel,
    required int dayOfWeek,
    required int arrivedPeriod,
  }) async {
    final uri = Uri.parse('$baseUrl/api/v1/timetables/preview-late').replace(
      queryParameters: {
        'term': term,
        'year': year,
        'class_level': classLevel,
        'day_of_week': dayOfWeek.toString(),
        'arrived_period': arrivedPeriod.toString(),
      },
    );
    final response = await http.get(uri);
    final body = jsonDecode(utf8.decode(response.bodyBytes));
    if (response.statusCode != 200) {
      throw Exception(body['detail'] ?? 'ไม่สามารถตรวจสอบข้อมูลคาบเรียนได้');
    }
    return body['data'] as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> cascadeLateStudent(Map<String, dynamic> data) async {
    final uri = Uri.parse('$baseUrl/api/v1/timetables/cascade-late');
    final response = await http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(data),
    );
    final body = jsonDecode(utf8.decode(response.bodyBytes));
    if (response.statusCode != 200) {
      throw Exception(body['detail'] ?? 'ไม่สามารถบันทึกการมาสายและตัดขาดรายวิชาได้');
    }
    return body as Map<String, dynamic>;
  }

  String getTimetableTemplateUrl({
    required String term,
    required String year,
    String? teacherName,
    String? classLevel,
  }) {
    final params = <String, String>{
      'term': term,
      'year': year,
    };
    if (teacherName != null && teacherName.isNotEmpty) {
      params['teacher_name'] = teacherName;
    }
    if (classLevel != null && classLevel.isNotEmpty) {
      params['class_level'] = classLevel;
    }
    final uri = Uri.parse('$baseUrl/api/v1/timetables/template').replace(
      queryParameters: params,
    );
    return uri.toString();
  }

  Future<Map<String, dynamic>> uploadTimetableFile({
    required Uint8List bytes,
    required String filename,
    required String term,
    required String year,
    String? teacherName,
  }) async {
    final uri = Uri.parse('$baseUrl/api/v1/timetables/upload');
    final request = http.MultipartRequest('POST', uri)
      ..files.add(http.MultipartFile.fromBytes('file', bytes, filename: filename))
      ..fields['term'] = term
      ..fields['year'] = year;
    if (teacherName != null && teacherName.trim().isNotEmpty) {
      request.fields['teacher_name'] = teacherName.trim();
    }
    final streamed = await request.send();
    final response = await http.Response.fromStream(streamed);
    final body = jsonDecode(utf8.decode(response.bodyBytes));
    if (response.statusCode != 200) {
      throw Exception(body['detail'] ?? 'ไม่สามารถอัพโหลดตารางสอนได้');
    }
    return body as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> syncTimetablesToArchive({
    String term = '1',
    String year = '2569',
  }) async {
    final uri = Uri.parse('$baseUrl/api/v1/timetables/sync-archive').replace(
      queryParameters: {
        'term': term,
        'year': year,
      },
    );
    final response = await http.post(uri);
    final body = jsonDecode(utf8.decode(response.bodyBytes));
    if (response.statusCode != 200) {
      throw Exception(body['detail'] ?? 'ไม่สามารถเชื่อมโยงรายวิชาเข้าคลังได้');
    }
    return body as Map<String, dynamic>;
  }


  // -------------------------------------------------------------
  // HOME VISIT SYSTEM (ระบบเยี่ยมบ้านนักเรียน)
  // -------------------------------------------------------------

  /// Get school-wide home visit summary & class comparisons
  Future<Map<String, dynamic>> getHomeVisitSummary({
    String term = '1',
    String year = '2569',
  }) async {
    final uri = Uri.parse('$baseUrl/api/v1/home-visits').replace(
      queryParameters: {'term': term, 'year': year},
    );
    final response = await http.get(uri);
    final body = jsonDecode(utf8.decode(response.bodyBytes));
    if (response.statusCode != 200) {
      throw Exception(body['detail'] ?? 'ไม่สามารถโหลดข้อมูลสรุปการเยี่ยมบ้านได้');
    }
    return body['data'] as Map<String, dynamic>;
  }

  /// Get specific class home visit report
  Future<Map<String, dynamic>> getHomeVisitClass(
    String classLevel, {
    String term = '1',
    String year = '2569',
  }) async {
    final uri = Uri.parse('$baseUrl/api/v1/home-visits/$classLevel').replace(
      queryParameters: {'term': term, 'year': year},
    );
    final response = await http.get(uri);
    final body = jsonDecode(utf8.decode(response.bodyBytes));
    if (response.statusCode != 200) {
      throw Exception(body['detail'] ?? 'ไม่สามารถโหลดข้อมูลการเยี่ยมบ้านชั้น $classLevel ได้');
    }
    return body as Map<String, dynamic>;
  }

  /// Save / update class home visit report
  Future<Map<String, dynamic>> saveHomeVisitClass(
    String classLevel, {
    required String term,
    required String year,
    required String advisorName,
    String? recordedByName,
    required Map<String, dynamic> fields,
    List<String>? photos,
    Map<String, String>? photoCaptions,
  }) async {
    final uri = Uri.parse('$baseUrl/api/v1/home-visits/$classLevel');
    final response = await http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'term': term,
        'year': year,
        'advisor_name': advisorName,
        if (recordedByName != null) 'recorded_by_name': recordedByName,
        'fields': fields,
        if (photos != null) 'photos': photos,
        if (photoCaptions != null) 'photo_captions': photoCaptions,
      }),
    );
    final body = jsonDecode(utf8.decode(response.bodyBytes));
    if (response.statusCode != 200) {
      throw Exception(body['detail'] ?? 'บันทึกข้อมูลการเยี่ยมบ้านไม่สำเร็จ');
    }
    return body as Map<String, dynamic>;
  }

  /// Upload photo evidence for a class home visit
  Future<Map<String, dynamic>> uploadHomeVisitPhoto(
    String classLevel, {
    required String term,
    required String year,
    required List<int> bytes,
    required String filename,
  }) async {
    final uri = Uri.parse('$baseUrl/api/v1/home-visits/$classLevel/upload-photo');
    final request = http.MultipartRequest('POST', uri)
      ..fields['term'] = term
      ..fields['year'] = year
      ..files.add(http.MultipartFile.fromBytes('file', bytes, filename: filename));

    final streamed = await request.send();
    final response = await http.Response.fromStream(streamed);
    final body = jsonDecode(utf8.decode(response.bodyBytes));
    if (response.statusCode != 200) {
      throw Exception(body['detail'] ?? 'อัปโหลดรูปภาพไม่สำเร็จ');
    }
    return body as Map<String, dynamic>;
  }

  /// Delete photo from class home visit
  Future<Map<String, dynamic>> deleteHomeVisitPhoto(
    String classLevel, {
    required String term,
    required String year,
    required String photoName,
  }) async {
    final uri = Uri.parse('$baseUrl/api/v1/home-visits/$classLevel/photo').replace(
      queryParameters: {
        'term': term,
        'year': year,
        'photo_name': photoName,
      },
    );
    final response = await http.delete(uri);
    final body = jsonDecode(utf8.decode(response.bodyBytes));
    if (response.statusCode != 200) {
      throw Exception(body['detail'] ?? 'ลบรูปภาพไม่สำเร็จ');
    }
    return body as Map<String, dynamic>;
  }

  /// URL for photo preview
  String getHomeVisitPhotoUrl(String year, String term, String classLevel, String filename) {
    return '$baseUrl/api/v1/home-visit-photos/${year}_$term/$classLevel/$filename';
  }

  /// URLs for downloads
  String getHomeVisitClassDocxUrl(String classLevel, {required String term, required String year, bool frameless = false}) {
    final fl = frameless ? '&frameless=true' : '';
    return '$baseUrl/api/v1/home-visits/$classLevel/docx?term=$term&year=$year$fl';
  }

  String getHomeVisitClassPdfUrl(String classLevel, {required String term, required String year}) {
    return '$baseUrl/api/v1/home-visits/$classLevel/pdf?term=$term&year=$year';
  }

  String getHomeVisitClassPdfPreviewUrl(String classLevel, {required String term, required String year}) {
    return '$baseUrl/api/v1/home-visits/$classLevel/pdf-preview?term=$term&year=$year';
  }

  String getHomeVisitSummaryDocxUrl({required String term, required String year, bool frameless = false}) {
    final fl = frameless ? '&frameless=true' : '';
    return '$baseUrl/api/v1/home-visits-summary/docx?term=$term&year=$year$fl';
  }

  String getHomeVisitSummaryPdfUrl({required String term, required String year}) {
    return '$baseUrl/api/v1/home-visits-summary/pdf?term=$term&year=$year';
  }

  String getHomeVisitSummaryPdfPreviewUrl({required String term, required String year}) {
    return '$baseUrl/api/v1/home-visits-summary/pdf-preview?term=$term&year=$year';
  }

  /// Get available DMC column definitions
  Future<List<Map<String, dynamic>>> getDmcColumns() async {
    final uri = Uri.parse('$baseUrl/api/v1/students/dmc-columns');
    final response = await http.get(uri);
    if (response.statusCode != 200) {
      throw Exception('ไม่สามารถดึงข้อมูลคอลัมน์ DMC ได้');
    }
    final body = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    final list = (body['data'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    return list;
  }

  /// Build download URL for DMC student roster export
  String getExportDmcUrl({
    required String term,
    required String year,
    required String classLevel,
    String room = 'all',
    List<String>? studentIds,
    List<String>? columns,
  }) {
    final params = <String, String>{
      'term': term,
      'year': year,
      'class_level': classLevel,
      'room': room,
    };
    if (studentIds != null && studentIds.isNotEmpty) {
      params['student_ids'] = studentIds.join(',');
    }
    if (columns != null && columns.isNotEmpty) {
      params['columns'] = columns.join(',');
    }
    final base = Uri.parse('$baseUrl/api/v1/students/export-dmc');
    final uri = base.replace(queryParameters: params);
    return uri.toString();
  }

  /// Export students DMC via POST (returns Uint8List bytes)
  Future<Uint8List> exportDmcStudentsBytes({
    required String term,
    required String year,
    required String classLevel,
    String room = 'all',
    List<String>? studentIds,
    List<String>? columns,
  }) async {
    final uri = Uri.parse('$baseUrl/api/v1/students/export-dmc');
    final response = await http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'term': term,
        'year': year,
        'class_level': classLevel,
        'room': room,
        if (studentIds != null && studentIds.isNotEmpty) 'student_ids': studentIds,
        if (columns != null && columns.isNotEmpty) 'columns_subset': columns,
      }),
    );
    if (response.statusCode != 200) {
      throw Exception('ไม่สามารถนำออกไฟล์ DMC ได้ (สถานะ: ${response.statusCode})');
    }
    return response.bodyBytes;
  }

  // -------------------------------------------------------------
  // TEACHER LEAVE & LATE ARRIVALS (ระบบบันทึกการลา / ขอเข้าสาย)
  // -------------------------------------------------------------

  /// Get leave records for currently logged-in teacher
  Future<List<Map<String, dynamic>>> getMyLeaves() async {
    final uri = Uri.parse('$baseUrl/api/v1/leaves/my');
    final response = await http.get(uri);
    if (response.statusCode != 200) {
      throw Exception('ไม่สามารถโหลดข้อมูลการลาได้ (${response.statusCode})');
    }
    final body = jsonDecode(utf8.decode(response.bodyBytes));
    final list = body['data'] as List<dynamic>? ?? [];
    return list.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  /// Create a new leave or late arrival request
  Future<Map<String, dynamic>> createLeave({
    required String leaveType,
    required String startDate,
    String? endDate,
    String? expectedArrivalTime,
    String? reason,
    String? contactPhone,
    String? teacherCode,
    String? teacherName,
  }) async {
    final uri = Uri.parse('$baseUrl/api/v1/leaves');
    final Map<String, dynamic> bodyMap = {
      'leave_type': leaveType,
      'start_date': startDate,
      'end_date': endDate,
      'expected_arrival_time': expectedArrivalTime,
      'reason': reason,
      'contact_phone': contactPhone,
    };
    if (teacherCode != null && teacherCode.isNotEmpty) {
      bodyMap['teacher_code'] = teacherCode;
    }
    if (teacherName != null && teacherName.isNotEmpty) {
      bodyMap['teacher_name'] = teacherName;
    }
    final response = await http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(bodyMap),
    );
    final body = jsonDecode(utf8.decode(response.bodyBytes));
    if (response.statusCode != 200) {
      throw Exception(body['detail'] ?? 'ไม่สามารถบันทึกข้อมูลการลาได้');
    }
    return body['data'] as Map<String, dynamic>;
  }

  /// Update a leave request (for Personnel Head / Admin / Owner)
  Future<Map<String, dynamic>> updateLeave(int leaveId, {
    String? leaveType,
    String? startDate,
    String? endDate,
    String? expectedArrivalTime,
    String? reason,
    String? contactPhone,
  }) async {
    final uri = Uri.parse('$baseUrl/api/v1/leaves/$leaveId');
    final Map<String, dynamic> bodyMap = {};
    if (leaveType != null) bodyMap['leave_type'] = leaveType;
    if (startDate != null) bodyMap['start_date'] = startDate;
    if (endDate != null) bodyMap['end_date'] = endDate;
    if (expectedArrivalTime != null) bodyMap['expected_arrival_time'] = expectedArrivalTime;
    if (reason != null) bodyMap['reason'] = reason;
    if (contactPhone != null) bodyMap['contact_phone'] = contactPhone;

    final response = await http.put(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(bodyMap),
    );
    final body = jsonDecode(utf8.decode(response.bodyBytes));
    if (response.statusCode != 200) {
      throw Exception(body['detail'] ?? 'ไม่สามารถแก้ไขข้อมูลการลาได้');
    }
    return body['data'] as Map<String, dynamic>;
  }

  /// Delete a leave request
  Future<void> deleteLeave(int leaveId) async {
    final uri = Uri.parse('$baseUrl/api/v1/leaves/$leaveId');
    final response = await http.delete(uri);
    if (response.statusCode != 200) {
      final body = jsonDecode(utf8.decode(response.bodyBytes));
      throw Exception(body['detail'] ?? 'ไม่สามารถลบรายการลาได้');
    }
  }

  /// Get all leaves for the school (for Admin / Director / Overview)
  Future<List<Map<String, dynamic>>> getAllLeaves({
    String? startDate,
    String? endDate,
    String? leaveType,
  }) async {
    final params = <String, String>{};
    if (startDate != null && startDate.isNotEmpty) params['start_date'] = startDate;
    if (endDate != null && endDate.isNotEmpty) params['end_date'] = endDate;
    if (leaveType != null && leaveType.isNotEmpty) params['leave_type'] = leaveType;

    final uri = Uri.parse('$baseUrl/api/v1/leaves/all').replace(queryParameters: params.isEmpty ? null : params);
    final response = await http.get(uri);
    if (response.statusCode != 200) {
      throw Exception('ไม่สามารถโหลดข้อมูลการลาทั้งหมดได้ (${response.statusCode})');
    }
    final body = jsonDecode(utf8.decode(response.bodyBytes));
    final list = body['data'] as List<dynamic>? ?? [];
    return list.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  /// Update leave status (approve / reject)
  Future<void> updateLeaveStatus(int leaveId, String status) async {
    final uri = Uri.parse('$baseUrl/api/v1/leaves/$leaveId/status');
    final response = await http.patch(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'status': status}),
    );
    if (response.statusCode != 200) {
      final body = jsonDecode(utf8.decode(response.bodyBytes));
      throw Exception(body['detail'] ?? 'ไม่สามารถอัปเดตสถานะการลาได้');
    }
  }

  /// Get leaves summary grouped by teacher for Director / Admin Dashboard
  Future<List<Map<String, dynamic>>> getLeavesSummaryByTeacher() async {
    final uri = Uri.parse('$baseUrl/api/v1/leaves/summary-by-teacher');
    final response = await http.get(uri);
    if (response.statusCode != 200) {
      throw Exception('ไม่สามารถโหลดข้อมูลสถิติการลาของครูได้ (${response.statusCode})');
    }
    final body = jsonDecode(utf8.decode(response.bodyBytes));
    final list = body['data'] as List<dynamic>? ?? [];
    return list.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  /// ตารางลงเวลาครู: / มา อัตโนมัติ 06:00, ส มาสาย, ขส ขอเข้าสาย, ล ลา, ร ไปราชการ
  /// (หัวหน้างานบุคคล ผู้ดูแลระบบ ผู้อำนวยการ เห็นครูทุกคน ครูคนอื่นเห็นเฉพาะแถวของตัวเอง)
  Future<Map<String, dynamic>> getTeacherAttendanceGrid({required String term, required String year}) async {
    final r = await _examRequest('GET', '/api/v1/leaves/attendance-grid', query: {'term': term, 'year': year});
    return Map<String, dynamic>.from(r['data'] as Map);
  }

  /// ใครลา / ไปราชการ / ขอเข้าสาย / มาสาย ในวันนั้น พร้อมคาบสอนของคนนั้น (ผู้อำนวยการ ผู้ดูแลระบบ หัวหน้างานบุคคล)
  Future<Map<String, dynamic>> getTeacherDayOverview({required String term, required String year, required String date}) async {
    final r = await _examRequest('GET', '/api/v1/leaves/day-overview', query: {'term': term, 'year': year, 'date': date});
    return Map<String, dynamic>.from(r['data'] as Map);
  }

  /// หัวหน้างานบุคคล / ผู้ดูแลระบบ: ลง ส (มาสาย) หรือ ร (ไปราชการ) ส่ง status '' เพื่อกลับเป็น มา
  Future<void> setTeacherAttendanceMark({
    required String term,
    required String year,
    required String teacherCode,
    required String date,
    required String status,
  }) async {
    await _examRequest('POST', '/api/v1/leaves/attendance-mark',
        body: {'term': term, 'year': year, 'teacher_code': teacherCode, 'date': date, 'status': status});
  }
}


/// คาบสอนชนกัน: needsConfirm = ชั้นนั้นมีคาบของครูคนอื่น (ยืนยันแล้วส่ง force ได้)
/// ไม่ needsConfirm = ครูคนเดิมมีคาบอยู่แล้วที่เวลานั้น (ต้องเลือกเวลาอื่น)
class TimetableClashException implements Exception {
  final String message;
  final bool needsConfirm;
  TimetableClashException(this.message, {this.needsConfirm = false});
  @override
  String toString() => message;
}
