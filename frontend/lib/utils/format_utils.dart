/// Helper calculations for Course Description and Indicator auto-fitting
int calculateEstimatedLines(String text) {
  final cleanText = text.trim();
  if (cleanText.isEmpty) return 0;
  final lines = cleanText.split('\n');
  const wrapLimit = 95;
  int estLines = 0;
  for (final l in lines) {
    final len = l.trim().length;
    if (len == 0) {
      estLines += 1;
    } else {
      estLines += ((len + wrapLimit - 1) ~/ wrapLimit).clamp(1, 999);
    }
  }
  return estLines;
}

int calculateRecommendedFontSize(String text) {
  final cleanText = text.trim();
  if (cleanText.isEmpty) return 16;
  final estLines = calculateEstimatedLines(cleanText);
  if (estLines <= 20) return 16;
  if (estLines <= 26) return 15;
  if (estLines <= 32) return 14;
  if (estLines <= 38) return 13;
  if (estLines <= 45) return 12;
  return 11;
}
