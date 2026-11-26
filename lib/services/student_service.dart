import 'package:supabase_flutter/supabase_flutter.dart';

/// New student accounts must use this email domain. Accounts made before the
/// rule keep working (supabase/migrations/20261104000000_bulsu_student_email.sql).
const bulsuEmailDomain = '@ms.bulsu.edu.ph';

class StudentService {
  StudentService._();
  static SupabaseClient get _client => Supabase.instance.client;

  static Future<void> completeProfile({
    required String fullName,
    required String studentNumber,
    required String section,
  }) async {
    await _client.rpc(
      'student_complete_registration',
      params: {
        'p_full_name': fullName.trim(),
        'p_student_number': studentNumber.trim(),
        'p_section': section.trim(),
      },
    );
  }

  static Future<Map<String, dynamic>> signIn({
    required String email,
    required String password,
    bool allowFaculty = false,
  }) async {
    final response = await _client.auth.signInWithPassword(
      email: email.trim(),
      password: password,
    );
    if (response.user == null || response.session == null) {
      throw Exception('Login failed. Please try again.');
    }
    var stage = 'loading your student profile';
    try {
      if (allowFaculty) {
        stage = 'checking your account role';
        final account = await _client.from('users').select('role')
            .eq('id', response.user!.id).maybeSingle();
        if (_client.auth.currentUser?.id != response.user!.id) {
          throw Exception('The signed-in account changed. Please try again.');
        }
        final role = account?['role']?.toString().toLowerCase();
        if (role == 'faculty' || role == 'professor') {
          return {'id': response.user!.id, 'role': role};
        }
        if (role != null && role != 'student') {
          throw Exception('This account role is not supported by this app.');
        }
        if (role == null && await _isFacultyProfile(response.user!.id)) {
          return {'id': response.user!.id, 'role': 'faculty'};
        }
      }
      stage = 'loading your student profile';
      var profile = await currentProfile();
      if (profile == null) {
        // Signup metadata contains claimed profile details, never permissions.
        // The database checks the account and assigns role/status itself.
        final metadata = response.user!.userMetadata ?? <String, dynamic>{};
        final name = metadata['full_name'];
        final number = metadata['student_number'];
        final section = metadata['section'];
        if (name is! String ||
            name.trim().isEmpty ||
            number is! String ||
            number.trim().isEmpty ||
            section is! String ||
            section.trim().isEmpty) {
          throw Exception(
            'No completed student profile was found. Open Register, enter '
                'your details, and use Complete existing account to finish setup.'
                'This account has no student profile or saved registration details. '
                'The database account needs to be checked.',
          );
        }
        stage = 'saving your student profile';
        await completeProfile(
          fullName: name,
          studentNumber: number,
          section: section,
        );
        stage = 'reloading your student profile';
        profile = await currentProfile();
      }
      if (profile == null) {
        throw Exception('Student profile could not be loaded. Please retry.');
      }
      return profile;
    } on PostgrestException catch (error) {
      try {
        await _client.auth.signOut();
      } catch (_) {}
      throw Exception(
        'Your credentials were accepted, but $stage failed. '
            'Database error ${error.code}: ${error.message}',
      );
    } catch (_) {
      // Preserve the original failure even if signing out also fails.
      try {
        await _client.auth.signOut();
      } catch (_) {}
      rethrow;
    }
  }

  // Professors created in the professor dashboard may only have a
  // faculty_profiles row, not a users row.
  static Future<bool> _isFacultyProfile(String id) async {
    try {
      final row = await _client.from('faculty_profiles').select('role')
          .eq('id', id).maybeSingle();
      if (_client.auth.currentUser?.id != id) {
        throw Exception('The signed-in account changed. Please try again.');
      }
      final role = row?['role']?.toString().toLowerCase();
      return role == 'faculty' || role == 'professor';
    } on PostgrestException {
      // Not readable: continue with the student check, as before.
      return false;
    }
  }

  static Future<Map<String, dynamic>?> currentProfile() async {
    if (_client.auth.currentUser == null) return null;
    final result = await _client.rpc('student_get_profile');
    if (result == null) return null;
    // The SQL function returns only the caller's student profile.
    return {...Map<String, dynamic>.from(result as Map), 'role': 'student'};
  }

  static Future<void> signOut() => _client.auth.signOut();
}