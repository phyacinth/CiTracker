import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'nfc_phone_service.dart';

class NfcRegistrationException implements Exception {
  const NfcRegistrationException(this.message, [this.code = '']);

  final String message;
  final String code;

  @override
  String toString() => message;
}

class NfcPhoneRegistrationService {
  final _phoneService = NfcPhoneService();

  SupabaseClient get _client => Supabase.instance.client;

  void _requireSameAccount(String studentId) {
    final session = _client.auth.currentSession;

    if (session == null ||
        session.user.id != studentId ||
        _client.auth.currentUser?.id != studentId) {
      throw const NfcRegistrationException(
        'Your account session changed. '
            'Return to the dashboard and sign in again.',
      );
    }
  }

  String _readErrorCode(FunctionException error) {
    dynamic details = error.details;

    if (details is String && details.length <= 4096) {
      try {
        details = jsonDecode(details);
      } catch (_) {
        details = null;
      }
    }

    final code = details is Map ? details['error'] : null;

    if (code is String &&
        RegExp(r'^[A-Z0-9_]{1,80}$').hasMatch(code)) {
      return code;
    }

    return switch (error.status) {
      401 => 'SIGN_IN_REQUIRED',
      429 => 'REGISTRATION_RATE_LIMITED',
      _ => 'FUNCTION_REQUEST_FAILED',
    };
  }

  String _errorMessage(String code) {
    return switch (code) {
      'SIGN_IN_REQUIRED' ||
      'INVALID_OR_EXPIRED_SESSION' =>
      'Your session could not be verified. Sign in again.',

      'STUDENT_PROFILE_REQUIRED' =>
      'A completed student profile is required.',

      'AUTHORIZED_PHONE_REPLACEMENT_REQUIRED' =>
      'A phone credential already exists or was revoked. '
          'An authorized phone replacement is required.',

      'KEY_ALREADY_REGISTERED' =>
      'This phone key is already linked to another account.',

      'REGISTRATION_RATE_LIMITED' =>
      'Too many registration attempts. '
          'Wait at least one minute before trying again.',

      'CHALLENGE_EXPIRED' ||
      'CHALLENGE_ALREADY_USED' ||
      'CHALLENGE_NOT_FOUND' =>
      'The registration attempt expired or was superseded. '
          'Tap Register This Phone to start a fresh attempt.',

      'SIGNATURE_INVALID' ||
      'INVALID_SIGNATURE_FORMAT' =>
      'The server could not verify the phone signature. '
          'Registration was not confirmed.',

      'SERVER_CONFIGURATION_ERROR' =>
      'The registration server configuration needs to be checked.',

      _ => 'Phone registration could not be confirmed ($code).',
    };
  }

  Future<Map<String, dynamic>> _callFunction({
    required String name,
    required String studentId,
    required Map<String, dynamic> body,
  }) async {
    _requireSameAccount(studentId);

    final token = _client.auth.currentSession!.accessToken;

    try {
      final response = await _client.functions.invoke(
        name,
        body: body,
        headers: {
          'Authorization': 'Bearer $token',
        },
      ).timeout(const Duration(seconds: 30));

      _requireSameAccount(studentId);

      final data = response.data;

      if (response.status != 200 || data is! Map) {
        throw const NfcRegistrationException(
          'The registration server returned an unexpected response.',
        );
      }

      return Map<String, dynamic>.from(data);
    } on FunctionException catch (error) {
      final code = _readErrorCode(error);
      throw NfcRegistrationException(_errorMessage(code), code);
    }
  }

  /// Whether this account already has an active registered phone, or null if
  /// the server couldn't be asked (for example, the SQL isn't installed).
  Future<bool?> accountHasRegisteredPhone() async {
    try {
      final result = await _client
          .rpc('comptech_my_phone_registered')
          .timeout(const Duration(seconds: 15));
      return result is bool ? result : null;
    } catch (_) {
      return null;
    }
  }

  Future<String> registerPhone({
    required void Function(String message) onProgress,
  }) async {
    final studentId = _client.auth.currentUser?.id;

    if (studentId == null) {
      throw const NfcRegistrationException(
        'Sign in to your student account first.',
      );
    }

    try {
      _requireSameAccount(studentId);

      onProgress('Preparing your phone key…');

      final key = await _phoneService.preparePhoneKey(studentId, createIfMissing: true);

      _requireSameAccount(studentId);

      onProgress('Requesting a registration challenge…');

      final challenge = await _callFunction(
        name: 'quick-service',
        studentId: studentId,
        body: {
          'public_key': key.publicKey,
        },
      );

      final challengeId = challenge['challenge_id'];
      final message = challenge['challenge_message'];
      final expiresAt = challenge['expires_at'];

      if (challengeId is! String ||
          message is! String ||
          message.isEmpty ||
          expiresAt is! String ||
          DateTime.tryParse(expiresAt) == null) {
        throw const NfcRegistrationException(
          'The server returned an invalid registration challenge.',
        );
      }

      _requireSameAccount(studentId);

      onProgress('Signing the registration challenge…');

      final signature = await _phoneService.signRegistrationChallenge(
        studentId: studentId,
        message: message,
      );

      _requireSameAccount(studentId);

      onProgress('Verifying your phone with the server…');

      final confirmation = await _callFunction(
        name: 'nfc-phone-registration-complete',
        studentId: studentId,
        body: {
          'challenge_id': challengeId,
          'signature': signature,
        },
      );

      final credentialId = confirmation['credential_id'];

      if (confirmation['status'] != 'active' ||
          credentialId is! String ||
          credentialId.isEmpty) {
        throw const NfcRegistrationException(
          'Phone registration was not confirmed by the server.',
        );
      }

      _requireSameAccount(studentId);

      return credentialId;
    } on TimeoutException {
      throw const NfcRegistrationException(
        'Registration could not be confirmed before the request '
            'timed out. Check your connection and retry. '
            'The existing phone key will be reused.',
      );
    } on PlatformException {
      throw const NfcRegistrationException(
        'The phone could not prepare or sign the challenge. '
            'Confirm the latest Android code was fully rebuilt.',
      );
    } on MissingPluginException {
      throw const NfcRegistrationException(
        'The Android signing method is unavailable. '
            'Fully stop the app and run flutter run again.',
      );
    }
  }
}