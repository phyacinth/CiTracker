import 'package:flutter/services.dart';
import 'nfc_attendance_service.dart';

/// Native ISO-DEP reader; a physical-card NDEF scan cannot read the HCE protocol.
class PhoneNfcReaderService {
  static const _channel = MethodChannel('comptech/phone_nfc_reader');

  Future<Map<String, dynamic>> readIdentity() async {
    try {
      final data = await _channel.invokeMapMethod<String, dynamic>('start')
          .timeout(const Duration(seconds: 65));
      final student = data?['student_id'], fingerprint = data?['key_fingerprint'];
      if (student is! String || !NfcAttendanceService.uuid.hasMatch(student) ||
          fingerprint is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(fingerprint)) {
        throw const NfcAttendanceException('Invalid student phone response.');
      }
      return {'student_id': student, 'key_fingerprint': fingerprint};
    } on PlatformException catch (error) {
      throw NfcAttendanceException(error.message ?? 'Phone NFC scan failed.');
    }
  }

  Future<String> sign(String message) async {
    try {
      final result = await _channel.invokeMethod<String>('sign', {'message': message})
          .timeout(const Duration(seconds: 15));
      if (result == null || result.isEmpty || result.length > 96) {
        throw const NfcAttendanceException('Invalid phone signature response.');
      }
      return result;
    } on PlatformException catch (error) {
      throw NfcAttendanceException(error.message ?? 'Phone connection lost. Retry the tap.');
    }
  }

  Future<void> stop() async {
    try { await _channel.invokeMethod<void>('stop'); } catch (_) { /* Native pause/timeout also stops it. */ }
  }
}
