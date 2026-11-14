class StudentGrade {
  final int? id;
  final String studentId;
  final String fullName;
  final String courseCode;
  final String? courseName;
  final String? teacher;
  final String term;
  final String year;
  final Map<String, dynamic> scores;
  final Map<String, dynamic> attendance;
  final Map<String, dynamic> attributes;
  final String? finalGrade;
  final String? createdAt;

  StudentGrade({
    this.id,
    required this.studentId,
    required this.fullName,
    required this.courseCode,
    this.courseName,
    this.teacher,
    required this.term,
    required this.year,
    this.scores = const {},
    this.attendance = const {},
    this.attributes = const {},
    this.finalGrade,
    this.createdAt,
  });

  factory StudentGrade.fromJson(Map<String, dynamic> json) {
    return StudentGrade(
      id: json['id'],
      studentId: json['student_id'] ?? '',
      fullName: json['full_name'] ?? '',
      courseCode: json['course_code'] ?? '',
      courseName: json['course_name'],
      teacher: json['teacher'],
      term: json['term'] ?? '',
      year: json['year'] ?? '',
      scores: json['scores'] is Map ? Map<String, dynamic>.from(json['scores']) : {},
      attendance: json['attendance'] is Map ? Map<String, dynamic>.from(json['attendance']) : {},
      attributes: json['attributes'] is Map ? Map<String, dynamic>.from(json['attributes']) : {},
      finalGrade: json['final_grade']?.toString(),
      createdAt: json['created_at'],
    );
  }

  String get totalScore {
    final total = scores['total_score'];
    return total != null ? total.toString() : '-';
  }

  String get gradeDisplay => finalGrade ?? '-';
}
