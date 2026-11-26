import 'dart:async';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'nfc_attendance_service.dart';

class PhoneNfcTapService {
  static const _channel = MethodChannel('comptech/phone_nfc_tap');
  static StreamSubscription<AuthState>? _auth;
  final _attendance = NfcAttendanceService();

  void _watchAccount() {
    _auth ??= Supabase.instance.client.auth.onAuthStateChange.listen((event) {
      unawaited(_disableIfAccountChanged());
    });
  }

  static Future<void> _disableIfAccountChanged() async {
    try {
      final state = await _channel.invokeMapMethod<String, dynamic>('status');
      final current = Supabase.instance.client.auth.currentUser?.id;
      if (state?['enabled'] == true && state?['student_id'] != current) {
        await _channel.invokeMethod<void>('disable');
      }
    } catch (_) {
      // Native service still enforces expiry and the backend must recheck revocation.
    }
  }

  Future<Map<String, dynamic>> status() async {
    _watchAccount();
    await _disableIfAccountChanged();
    return await _channel.invokeMapMethod<String, dynamic>('status') ?? {};
  }

  Future<Map<String, dynamic>> enable() async {
    _watchAccount();
    final owner = _attendance.accountId;
    final fp = await _attendance.prepareFingerprint();
    _attendance.requireAccount(owner);
    try {
      await _attendance.call('phone_context', {'key_fingerprint': fp});
    } catch (error) {
      // No internet: turn it on anyway. The phone key was checked on the
      // phone above, and the server checks the registered phone again when
      // the tap is recorded (online or uploaded later). Real server answers,
      // like a phone that isn't registered, still stop it.
      if (!_unreachable(error)) rethrow;
    }
    _attendance.requireAccount(owner);
    final state = await _channel.invokeMapMethod<String, dynamic>('enable', {
      'studentId': owner,
      'fingerprint': fp,
    }).timeout(const Duration(seconds: 30));
    try {
      _attendance.requireAccount(owner);
    } catch (_) {
      await disable();
      rethrow;
    }
    return state ?? {};
  }

  static bool _unreachable(Object error) =>
      error is! NfcAttendanceException ||
      error.code == 'FUNCTION_REQUEST_FAILED' ||
      error.code == 'TIMEOUT';

  Future<Map<String, dynamic>> registrationContext() async {
    final owner = _attendance.accountId;
    final fp = await _attendance.prepareFingerprint();
    _attendance.requireAccount(owner);
    final result = await _attendance.call('phone_context', {'key_fingerprint': fp});
    _attendance.requireAccount(owner);
    return result;
  }

  Future<void> disable() => _channel.invokeMethod<void>('disable');
}
