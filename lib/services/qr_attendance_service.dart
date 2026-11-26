import 'dart:async';
import 'dart:convert';

import 'package:supabase_flutter/supabase_flutter.dart';

import 'attendance_location_service.dart';
import 'nfc_attendance_service.dart';

class QrAttendanceException implements Exception {
  const QrAttendanceException(this.message, [this.code = '']);
  final String message;
  final String code;
}

class QrAttendanceService {
  final _client = Supabase.instance.client;
  static final _uuid = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
  );

  Map<String, dynamic> parse(String raw) {
    if (utf8.encode(raw).length > 2048) {
      throw const QrAttendanceException('This is not a valid attendance QR.');
    }
    dynamic decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      throw const QrAttendanceException(
        'Scan the attendance QR shown by your professor.',
      );
    }
    if (decoded is! Map<String, dynamic> ||
        decoded['type'] != 'COMPTECH:ATTENDANCE:QR:V1' ||
        decoded['classId'] is! String ||
        !_uuid.hasMatch(decoded['classId'] as String) ||
        decoded['sessionId'] is! String ||
        !_uuid.hasMatch(decoded['sessionId'] as String) ||
        decoded['token'] is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(decoded['token'] as String)) {
      throw const QrAttendanceException(
        'This QR is not a server-issued attendance code. Ask your professor to refresh it.',
      );
    }
    return {
      'type': decoded['type'],
      'classId': decoded['classId'],
      'sessionId': decoded['sessionId'],
      'token': decoded['token'],
    };
  }

  void _requireAccount(String owner) {
    if (_client.auth.currentUser?.id != owner ||
        _client.auth.currentSession?.user.id != owner) {
      throw const QrAttendanceException(
        'Your account changed. Sign in again.',
        'SIGN_IN_REQUIRED',
      );
    }
  }

  String _explain(String code) {
    const messages = {
      'SIGN_IN_REQUIRED': 'Sign in again before scanning attendance.',
      'STUDENT_REQUIRED':
      'This signed-in account is not registered as a student.',
      'PROFILE_REQUIRED': 'Your student profile or student number is missing. Contact your school administrator.',
      'EMAIL_NOT_CONFIRMED':
      'Confirm your email address before scanning attendance.',
      'QR_SETUP_REQUIRED': 'Student QR check-in is not set up in the database yet. Contact your administrator.',
      'ATTENDANCE_QUERY_FAILED': 'The attendance database could not be checked. Please try again or contact your administrator.',
      'NOT_ENROLLED': 'You are not enrolled in this class.',
      'SESSION_NOT_ACTIVE': 'This class session has ended or is unavailable.',
      'SESSION_NOT_FOUND': 'This class session has ended or is unavailable.',
      'SESSION_POLICY_REQUIRED': 'This session has no shared attendance policy. Ask your professor to check its setup.',
      'GRACE_PERIOD_ENDED': 'The grace period has ended. Ask your professor to confirm your attendance.',
      'QR_EXPIRED': 'This QR expired. Scan the latest code.',
      'QR_INVALID_OR_REPLACED': 'This QR was replaced. Scan the latest code.',
      'QR_NOT_ISSUED': 'Ask your professor to refresh the attendance QR.',
      'INVALID_REQUEST': 'This attendance QR is invalid. Scan the latest code.',
    };
    return messages[code] ??
        'Attendance could not be confirmed. Check your connection and try again.';
  }

  // Student check-in uses its own database functions, not the professor
  // dashboard's `qr-attendance` Edge Function, so their deploys can't break it.
  // See supabase/migrations/20261101000000_student_qr_attendance.sql.
  Future<Map<String, dynamic>> _call(
      String owner,
      String function,
      Map<String, dynamic> params,
      ) async {
    _requireAccount(owner);
    try {
      final data = await _client
          .rpc(function, params: params)
          .timeout(const Duration(seconds: 20));
      _requireAccount(owner);
      if (data is! Map) {
        throw const QrAttendanceException(
          'The attendance server returned an invalid response.',
        );
      }
      return Map<String, dynamic>.from(data);
    } on PostgrestException catch (error) {
      // The SQL functions raise the error code as the message.
      final code = RegExp(r'^[A-Z0-9_]{1,80}$').hasMatch(error.message)
          ? error.message
          : error.code == 'PGRST202'
          ? 'QR_SETUP_REQUIRED'
          : error.code == 'PGRST301'
          ? 'SIGN_IN_REQUIRED'
          : 'SERVER_ERROR';
      throw QrAttendanceException(_explain(code), code);
    }
  }

  Map<String, dynamic> _receipt(
      Map<String, dynamic> result,
      Map<String, dynamic> qr,
      String owner,
      ) {
    final attendance = result['attendance'];
    if (attendance is! Map ||
        attendance['id'] is! String ||
        attendance['student_id'] != owner ||
        attendance['session_id'] != qr['sessionId'] ||
        result['class_id'] != qr['classId']) {
      throw const QrAttendanceException(
        'Attendance was not confirmed. Check Attendance History before retrying.',
      );
    }
    NfcAttendanceService.notifyChanged();
    return result;
  }

  Future<Map<String, dynamic>> submit(
      Map<String, dynamic> qr, {
        AttendanceLocation? location,
      }) async {
    final owner = _client.auth.currentUser?.id;
    if (owner == null) {
      throw const QrAttendanceException('Sign in before scanning attendance.');
    }
    try {
      final result = await _call(owner, 'comptech_student_submit_qr_attendance', {
        'p_class_id': qr['classId'],
        'p_session_id': qr['sessionId'],
        'p_token': qr['token'],
        ...?location?.toParams(),
      });
      return _receipt(result, qr, owner);
    } on QrAttendanceException {
      rethrow;
    } catch (_) {
      // A timeout can happen after the database commits. Recover our own attendance.
      _requireAccount(owner);
      try {
        final recovered = await _call(owner, 'comptech_student_qr_attendance_status', {
          'p_class_id': qr['classId'],
          'p_session_id': qr['sessionId'],
        });
        _requireAccount(owner);
        if (recovered['attendance'] is Map) {
          return _receipt(recovered, qr, owner);
        }
      } catch (_) {
        /* Do not claim a successful submission without a receipt. */
      }
      throw const QrAttendanceException(
        'Attendance could not be confirmed. Check Attendance History before scanning again.',
      );
    }
  }
}
