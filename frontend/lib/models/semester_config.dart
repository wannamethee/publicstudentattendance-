class SemesterConfigItem {
  final int? id;
  final String term;
  final String year;
  final String title;
  final int displayOrder;
  final bool isActive;
  final bool isDefault;
  final int courseCount;
  final int gradeCount;

  SemesterConfigItem({
    this.id,
    required this.term,
    required this.year,
    required this.title,
    this.displayOrder = 0,
    this.isActive = true,
    this.isDefault = false,
    this.courseCount = 0,
    this.gradeCount = 0,
  });

  factory SemesterConfigItem.fromJson(Map<String, dynamic> json) {
    return SemesterConfigItem(
      id: json['id'] as int?,
      term: json['term'].toString(),
      year: json['year'].toString(),
      title: json['title'] as String? ?? '',
      displayOrder: (json['display_order'] as int?) ?? 0,
      isActive: json['is_active'] == 1 || json['is_active'] == true,
      isDefault: json['is_default'] == 1 || json['is_default'] == true,
      courseCount: (json['course_count'] as int?) ?? 0,
      gradeCount: (json['grade_count'] as int?) ?? 0,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      if (id != null) 'id': id,
      'term': term,
      'year': year,
      'title': title,
      'display_order': displayOrder,
      'is_active': isActive ? 1 : 0,
      'is_default': isDefault ? 1 : 0,
    };
  }

  SemesterConfigItem copyWith({
    int? id,
    String? term,
    String? year,
    String? title,
    int? displayOrder,
    bool? isActive,
    bool? isDefault,
    int? courseCount,
    int? gradeCount,
  }) {
    return SemesterConfigItem(
      id: id ?? this.id,
      term: term ?? this.term,
      year: year ?? this.year,
      title: title ?? this.title,
      displayOrder: displayOrder ?? this.displayOrder,
      isActive: isActive ?? this.isActive,
      isDefault: isDefault ?? this.isDefault,
      courseCount: courseCount ?? this.courseCount,
      gradeCount: gradeCount ?? this.gradeCount,
    );
  }
}
