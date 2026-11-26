import 'package:comptech_portal_app/services/grade_scale.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('each range of the grading table', () {
    const table = {
      '1.00': [97, 100],
      '1.25': [94, 96],
      '1.50': [91, 93],
      '1.75': [88, 90],
      '2.00': [85, 87],
      '2.25': [82, 84],
      '2.50': [79, 81],
      '2.75': [76, 78],
      '3.00': [75, 75],
    };
    table.forEach((grade, range) {
      for (var p = range[0]; p <= range[1]; p++) {
        expect(numericalGrade(p.toDouble()), grade, reason: '$p%');
      }
    });
  });

  test('below 75% is 5.00', () {
    expect(numericalGrade(74), '5.00');
    expect(numericalGrade(50), '5.00');
    expect(numericalGrade(0), '5.00');
  });

  test('percentages are rounded to the nearest whole number first', () {
    expect(numericalGrade(98.75), '1.00');
    expect(numericalGrade(96.6), '1.00');
    expect(numericalGrade(96.4), '1.25');
    expect(numericalGrade(74.5), '3.00');
    expect(numericalGrade(74.4), '5.00');
  });
}
