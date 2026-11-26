import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class StudentHomeService {
  StudentHomeService._();

  /// Set when a "new activity" notification is tapped: the class it's for
  /// ('' if unknown). Home switches to that class and reloads its activities.
  static final ValueNotifier<String?> activitiesRequested =
      ValueNotifier<String?>(null);

  static void showActivities(String? classId) {
    // Reset first so asking for the same class twice still notifies.
    activitiesRequested.value = null;
    activitiesRequested.value = classId ?? '';
  }

  static Future<Map<String, dynamic>> load() async {
    final client = Supabase.instance.client;
    final userId = client.auth.currentUser?.id;
    if (userId == null) {
      throw StateError('Please sign in to view your dashboard.');
    }
    final result = await client
        .rpc('comptech_student_home')
        .timeout(const Duration(seconds: 20));
    if (client.auth.currentUser?.id != userId) {
      throw StateError('The signed-in account changed.');
    }
    if (result is! Map) {
      throw const FormatException('Unexpected dashboard response.');
    }
    return Map<String, dynamic>.from(result);
  }
  static Future<List<Map<String, dynamic>>> loadActivities() async {
    final client = Supabase.instance.client;
    final userId = client.auth.currentUser?.id;
    if (userId == null) throw StateError('Please sign in again.');
    final result = await client.rpc('comptech_student_upcoming_activities')
        .timeout(const Duration(seconds: 20));
    if (client.auth.currentUser?.id != userId) {
      throw StateError('The signed-in account changed.');
    }
    if (result is! List) throw const FormatException('Unexpected activity response.');
    return result.map((row) => Map<String, dynamic>.from(row as Map)).toList();
  }
}
