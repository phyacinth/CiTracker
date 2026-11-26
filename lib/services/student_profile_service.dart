import 'package:supabase_flutter/supabase_flutter.dart';

class StudentProfileService {
  StudentProfileService._();

  static Future<void> saveStudentType(String value) async {
    if (value != 'Regular Student' && value != 'Irregular Student') {
      throw ArgumentError('Select a valid student status.');
    }
    await Supabase.instance.client.rpc(
      'comptech_set_student_type',
      params: {'p_student_type': value},
    );
  }

  static Future<Map<String, String>> load() async {
    final client = Supabase.instance.client;
    final user = client.auth.currentUser;
    if (user == null) {
      throw StateError('Please sign in to view your profile.');
    }

    final account = await client
        .from('users')
        .select('id, email, full_name, role, student_number')
        .eq('id', user.id)
        .maybeSingle()
        .timeout(const Duration(seconds: 20));
    if (account == null || account['role'] != 'student') {
      throw StateError('Your student account is missing or unavailable.');
    }
    final details = await client
        .from('student_profiles')
        .select('section, student_type')
        .eq('id', user.id)
        .maybeSingle()
        .timeout(const Duration(seconds: 20));
    if (client.auth.currentUser?.id != user.id) {
      throw StateError('The signed-in account changed.');
    }

    return {
      'email': user.email ?? (account['email'] as String?) ?? '',
      'name': account['full_name'] as String? ?? '',
      'student_number': account['student_number'] as String? ?? '',
      'section': details?['section'] as String? ?? '',
      'status': details?['student_type'] as String? ?? '',
      'profile_missing': details == null ? 'true' : 'false',
    };
  }
}
