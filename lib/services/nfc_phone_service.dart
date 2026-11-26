import 'package:flutter/services.dart';

class NfcPhoneKey {
  const NfcPhoneKey({
    required this.publicKey,
    required this.algorithm,
  });

  final String publicKey;
  final String algorithm;
}

class NfcPhoneService {
  static const _channel = MethodChannel(
    'comptech/nfc_credential',
  );

  Future<bool> supportsCardEmulation() async {
    final supported = await _channel
        .invokeMethod<bool>('supportsCardEmulation')
        .timeout(const Duration(seconds: 10));

    if (supported == null) {
      throw StateError(
        'No card-emulation result was returned.',
      );
    }

    return supported;
  }

  Future<bool> hasPhoneKey(String studentId) async {
    return await _channel.invokeMethod<bool>(
      'hasPhoneKey', {'studentId': studentId},
    ).timeout(const Duration(seconds: 10)) ?? false;
  }

  Future<NfcPhoneKey> preparePhoneKey(
      String studentId, {bool createIfMissing = false}
      ) async {
    final result = await _channel.invokeMapMethod<String, dynamic>(
      createIfMissing ? 'createPhoneKey' : 'preparePhoneKey',
      {'studentId': studentId},
    ).timeout(const Duration(seconds: 30));

    final publicKey = result?['public_key'];
    final algorithm = result?['algorithm'];

    if (publicKey is! String ||
        publicKey.isEmpty ||
        algorithm != 'ECDSA_P256_SHA256' ||
        result?['self_test_passed'] != true) {
      throw StateError(
        'Phone key preparation was not confirmed.',
      );
    }

    return NfcPhoneKey(
      publicKey: publicKey,
      algorithm: algorithm as String,
    );
  }

  Future<String> signRegistrationChallenge({
    required String studentId,
    required String message,
  }) async {
    final signature = await _channel.invokeMethod<String>(
      'signRegistrationChallenge',
      {
        'studentId': studentId,
        'message': message,
      },
    ).timeout(const Duration(seconds: 30));

    if (signature == null || signature.isEmpty) {
      throw StateError(
        'The registration challenge was not signed.',
      );
    }

    return signature;
  }

  Future<String> signCardAssignmentChallenge({
    required String studentId,
    required String challengeId,
    required String phoneCredentialId,
    required String cardUid,
    required String ndefPayload,
    required String message,
  }) async {
    final signature = await _channel.invokeMethod<String>(
      'signCardAssignmentChallenge',
      {
        'studentId': studentId,
        'challengeId': challengeId,
        'phoneCredentialId': phoneCredentialId,
        'cardUid': cardUid,
        'ndefPayload': ndefPayload,
        'message': message,
      },
    ).timeout(const Duration(seconds: 30));

    if (signature == null || signature.isEmpty) {
      throw StateError(
        'The card-assignment challenge was not signed.',
      );
    }

    return signature;
  }

  Future<String> signAttendanceChallenge({
    required String studentId,
    required String message,
    required Map<String, String> context,
  }) async {
    final signature = await _channel.invokeMethod<String>(
      'signAttendanceChallenge',
      {'studentId': studentId, 'message': message, 'context': context},
    ).timeout(const Duration(seconds: 20));
    if (signature == null || signature.isEmpty) {
      throw StateError('The attendance challenge was not signed.');
    }
    return signature;
  }
}
