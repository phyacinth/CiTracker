import 'package:supabase_flutter/supabase_flutter.dart';

/// The student's gradebook, live: every score the professor saves (Draft or
/// published) and the latest grade summary.
/// See supabase/migrations/20261104050000_live_scores.sql.
class StudentScoresService {
  static Future<Map<String, dynamic>> load() async {
    final client = Supabase.instance.client;
    final userId = client.auth.currentUser?.id;
    if (userId == null) throw StateError('Please sign in to view grades.');
    final result = await client
        .rpc('comptech_my_published_scores')
        .timeout(const Duration(seconds: 20));
    if (client.auth.currentUser?.id != userId) {
      throw StateError('Your account changed. Please sign in again.');
    }
    if (result is! Map) throw const FormatException('Invalid grade response.');
    return Map<String, dynamic>.from(result);
  }

  /// A short fingerprint that changes whenever any of the student's scores
  /// or grade summaries change. Null if it can't be checked right now
  /// (offline, or the SQL file hasn't been run yet).
  static Future<String?> version() async {
    try {
      final result = await Supabase.instance.client
          .rpc('comptech_my_scores_version')
          .timeout(const Duration(seconds: 10));
      return result?.toString();
    } catch (_) {
      return null;
    }
  }
}
