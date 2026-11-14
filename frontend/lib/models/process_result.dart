class ProcessResult {
  final String? courseCode;
  final String? courseName;
  final String? teacher;
  final int totalStudents;
  final String excelPath;
  final String pdfPath;
  final String excelFilename;
  final String pdfFilename;

  ProcessResult({
    this.courseCode,
    this.courseName,
    this.teacher,
    required this.totalStudents,
    required this.excelPath,
    required this.pdfPath,
    required this.excelFilename,
    required this.pdfFilename,
  });

  factory ProcessResult.fromJson(Map<String, dynamic> json) {
    return ProcessResult(
      courseCode: json['course_code'],
      courseName: json['course_name'],
      teacher: json['teacher'],
      totalStudents: json['total_students'] ?? 0,
      excelPath: json['excel_path'] ?? '',
      pdfPath: json['pdf_path'] ?? '',
      excelFilename: json['excel_filename'] ?? '',
      pdfFilename: json['pdf_filename'] ?? '',
    );
  }
}
