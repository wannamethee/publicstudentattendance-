class Course {
  final String courseCode;
  final String courseName;
  final String term;
  final String year;
  final String? teacher;
  final String? teacherCode;
  final String? courseDescription;
  final int studentCount;
  final String? classLevel;

  Course({
    required this.courseCode,
    required this.courseName,
    required this.term,
    required this.year,
    this.teacher,
    this.teacherCode,
    this.courseDescription,
    this.studentCount = 0,
    this.classLevel,
  });

  factory Course.fromJson(Map<String, dynamic> json) {
    return Course(
      courseCode: json['course_code'] ?? '',
      courseName: json['course_name'] ?? '',
      term: json['term'] ?? '',
      year: json['year'] ?? '',
      teacher: json['teacher'],
      teacherCode: json['teacher_code']?.toString(),
      courseDescription: json['course_description'],
      studentCount: (json['student_count'] as num?)?.toInt() ?? 0,
      classLevel: json['class_level'],
    );
  }

  Course copyWith({
    String? courseCode,
    String? courseName,
    String? term,
    String? year,
    String? teacher,
    String? teacherCode,
    String? courseDescription,
    int? studentCount,
    String? classLevel,
  }) {
    return Course(
      courseCode: courseCode ?? this.courseCode,
      courseName: courseName ?? this.courseName,
      term: term ?? this.term,
      year: year ?? this.year,
      teacher: teacher ?? this.teacher,
      teacherCode: teacherCode ?? this.teacherCode,
      courseDescription: courseDescription ?? this.courseDescription,
      studentCount: studentCount ?? this.studentCount,
      classLevel: classLevel ?? this.classLevel,
    );
  }

  String get displaySemester => 'ภาคเรียนที่ $term ปีการศึกษา $year';
}
