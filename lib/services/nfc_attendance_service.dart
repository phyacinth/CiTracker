import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class NfcAttendanceException implements Exception {
  const NfcAttendanceException(this.message, [this.code = '']);
  final String message;
  final String code;
  @override
  String toString() => message;
}

class NfcAttendanceService {
  static final ValueNotifier<int> changes = ValueNotifier<int>(0);
  static void notifyChanged() => changes.value++;
  SupabaseClient get client => Supabase.instance.client;
  static const _channel = MethodChannel('comptech/nfc_credential');
  static final uuid = RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$');

  String get accountId {
    final id = client.auth.currentUser?.id;
    if (id == null) throw const NfcAttendanceException('Sign in again.');
    return id;
  }
  void requireAccount(String id) {
    if (client.auth.currentUser?.id != id || client.auth.currentSession?.user.id != id) {
      throw const NfcAttendanceException('Your signed-in account changed. Return to the dashboard.');
    }
  }
  static String explain(String code) => switch (code) {
    'SIGN_IN_REQUIRED' => 'Sign in again to verify your session.',
    'FACULTY_REQUIRED' => 'Use an existing faculty/professor account for this scanner.',
    'PROFILE_REQUIRED' => 'This account has no completed application profile.',
    'STUDENT_REQUIRED' => 'A completed student account is required.',
    'CLASS_NOT_OWNED' => 'This session must belong to the signed-in faculty account.',
    'REGISTERED_PHONE_REQUIRED' => 'Use the phone registered to this student account.',
    'ACTIVE_CARD_REQUIRED' => 'Assign an active attendance card first.',
    'NOT_ENROLLED' => 'The student is not enrolled in this class.',
    'STUDENT_NOT_READY' => 'The student must open Use NFC for Attendance, select this session, and enable attendance readiness.',
    'SESSION_NOT_ACTIVE' || 'NFC_TEST_SESSION_REQUIRED' => 'Open an active NFC test session on the faculty scanner first.',
    'READY_EXPIRED' || 'READY_NOT_FOUND' => 'The attendance-ready period ended. Start it again.',
    'CHALLENGE_EXPIRED' => 'The scan expired. Enable readiness and tap the card again.',
    'ATTENDANCE_ALREADY_RECORDED' => 'Attendance is already recorded for this session. Refresh Attendance History.',
    'CHALLENGE_ALREADY_USED' => 'This scan was already processed. Check Attendance History before retrying.',
    'LATE_REQUIRES_FACULTY_CONFIRMATION' => 'The grace period has ended. Ask your professor to confirm your attendance.',
    'CARD_UID_MISMATCH' => 'The token was read, but the card UID does not match the registered card.',
    'SIGNATURE_INVALID' => 'The registered phone signature could not be verified.',
    'ATTENDANCE_CANCELLED' => 'The student stopped readiness or the session ended.',
    'RATE_LIMITED' => 'Too many readiness attempts. Wait one minute.',
    'FUNCTION_REQUEST_FAILED' =>
      'Could not reach the attendance server. Check your internet connection and try again.',
    _ => 'Attendance could not be confirmed ($code).',
  };

  Future<Map<String, dynamic>> call(String action, [Map<String, dynamic> body = const {}]) async {
    final id = accountId;
    requireAccount(id);
    try {
      final response = await client.functions.invoke('nfc-attendance',
        body: {...body, 'action': action},
        headers: {'Authorization': 'Bearer ${client.auth.currentSession!.accessToken}'},
      ).timeout(const Duration(seconds: 20));
      requireAccount(id);
      if (response.status != 200 || response.data is! Map) {
        throw const NfcAttendanceException('The attendance server returned an invalid response.');
      }
      return Map<String, dynamic>.from(response.data as Map);
    } on FunctionException catch (error) {
      dynamic details = error.details;
      if (details is String && details.length <= 4096) {
        try { details = jsonDecode(details); } catch (_) { details = null; }
      }
      final value = details is Map ? details['error'] : null;
      final code = value is String && RegExp(r'^[A-Z0-9_]{1,80}$').hasMatch(value)
          ? value : error.status == 401 ? 'SIGN_IN_REQUIRED' : 'FUNCTION_REQUEST_FAILED';
      throw NfcAttendanceException(explain(code), code);
    } on TimeoutException {
      throw const NfcAttendanceException('The server response timed out. The request may have completed; check Attendance History before retrying.', 'TIMEOUT');
    }
  }

  Future<String> prepareFingerprint() async {
    final id = accountId;
    final exists = await _channel.invokeMethod<bool>('hasPhoneKey',
        {'studentId': id}).timeout(const Duration(seconds: 10));
    requireAccount(id);
    if (exists != true) {
      throw const NfcAttendanceException(
        'This installation has no phone key. Open Phone Registration / Setup. '
            'If already registered, request authorized recovery; checking attendance will not create a replacement key.',
        'LOCAL_PHONE_KEY_MISSING',
      );
    }
    final result = await _channel.invokeMapMethod<String, dynamic>('preparePhoneKey',
        {'studentId': id}).timeout(const Duration(seconds: 30));
    requireAccount(id);
    final fp = result?['key_fingerprint'];
    if (fp is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(fp) || result?['self_test_passed'] != true) {
      throw const NfcAttendanceException('Phone key preparation failed.');
    }
    return fp;
  }

  static List<Map<String, dynamic>> rows(dynamic value) {
    if (value is! List) throw const NfcAttendanceException('The server returned an invalid list.');
    return value.map((v) => Map<String, dynamic>.from(v as Map)).toList();
  }

  Future<List<Map<String, dynamic>>> history(String classId) async {
    final id = accountId;
    final data = await client.rpc('student_get_attendance', params: {'p_class_id': classId})
        .timeout(const Duration(seconds: 20));
    requireAccount(id);
    return rows(data);
  }
}
