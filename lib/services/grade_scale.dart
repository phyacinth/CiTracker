/// The university grading scale: a percentage (0–100) to its numerical grade.
///
/// The percentage is rounded to the nearest whole number first, which is how
/// ranges like "94–96%" are applied: 96.6% counts as 97% (1.00) and 96.4% as
/// 96% (1.25). 4.00 (conditional) and Inc. (incomplete) are given by the
/// professor rather than computed, so they never come out of here.
String numericalGrade(double percent) {
  final rounded = percent.round();
  if (rounded >= 97) return '1.00';
  if (rounded >= 94) return '1.25';
  if (rounded >= 91) return '1.50';
  if (rounded >= 88) return '1.75';
  if (rounded >= 85) return '2.00';
  if (rounded >= 82) return '2.25';
  if (rounded >= 79) return '2.50';
  if (rounded >= 76) return '2.75';
  if (rounded >= 75) return '3.00';
  return '5.00';
}
