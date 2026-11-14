class ClassAdvisorItem {
  final int id;
  final String term;
  final String year;
  final String classLevel;
  final String? advisor1;
  final String? advisor2;
  final String? advisor3;
  final String? updatedAt;

  ClassAdvisorItem({
    required this.id,
    required this.term,
    required this.year,
    required this.classLevel,
    this.advisor1,
    this.advisor2,
    this.advisor3,
    this.updatedAt,
  });

  factory ClassAdvisorItem.fromJson(Map<String, dynamic> json) {
    return ClassAdvisorItem(
      id: json['id'] is int ? json['id'] : int.tryParse(json['id']?.toString() ?? '0') ?? 0,
      term: json['term']?.toString() ?? '',
      year: json['year']?.toString() ?? '',
      classLevel: json['class_level']?.toString() ?? '',
      advisor1: json['advisor1']?.toString(),
      advisor2: json['advisor2']?.toString(),
      advisor3: json['advisor3']?.toString(),
      updatedAt: json['updated_at']?.toString(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      if (id > 0) 'id': id,
      'term': term,
      'year': year,
      'class_level': classLevel,
      'advisor1': advisor1 ?? '',
      'advisor2': advisor2 ?? '',
      'advisor3': advisor3 ?? '',
    };
  }

  List<String> get nonNullAdvisors {
    return [
      if (advisor1 != null && advisor1!.trim().isNotEmpty) advisor1!.trim(),
      if (advisor2 != null && advisor2!.trim().isNotEmpty) advisor2!.trim(),
      if (advisor3 != null && advisor3!.trim().isNotEmpty) advisor3!.trim(),
    ];
  }
}
