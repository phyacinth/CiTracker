import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'nfc_phone_service.dart';

class NfcCardAssignmentException implements Exception {
  const NfcCardAssignmentException(this.message);

  final String message;

  @override
  String toString() => message;
}

class NfcCardAssignmentStatus {
  const NfcCardAssignmentStatus({
    required this.tagAssigned,
    required this.cardStatus,
  });

  final bool tagAssigned;
  final String? cardStatus;
}

class NfcCardAssignmentChallenge {
  const NfcCardAssignmentChallenge({
    required this.studentId,
    required this.challengeId,
    required this.phoneCredentialId,
    required this.cardUid,
    required this.ndefPayload,
    required this.challengeMessage,
    required this.expiresAt,
  });

  final String studentId;
  final String challengeId;
  final String phoneCredentialId;
  final String cardUid;
  final String ndefPayload;
  final String challengeMessage;
  final DateTime expiresAt;

  bool get isExpired =>
      !expiresAt.isAfter(DateTime.now().toUtc());

  Map<String, dynamic> toJson() {
    return {
      'student_id': studentId,
      'challenge_id': challengeId,
      'phone_credential_id': phoneCredentialId,
      'card_uid': cardUid,
      'ndef_payload': ndefPayload,
      'challenge_message': challengeMessage,
      'expires_at': expiresAt.toUtc().toIso8601String(),
    };
  }

  factory NfcCardAssignmentChallenge.fromJson(
      Map<String, dynamic> json,
      ) {
    final studentId = json['student_id'];
    final challengeId = json['challenge_id'];
    final phoneCredentialId = json['phone_credential_id'];
    final cardUid = json['card_uid'];
    final ndefPayload = json['ndef_payload'];
    final message = json['challenge_message'];
    final expiresAtText = json['expires_at'];

    final uuidPattern = RegExp(
      r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-'
      r'[0-9a-f]{4}-[0-9a-f]{12}$',
    );

    if (studentId is! String ||
        !uuidPattern.hasMatch(studentId) ||
        challengeId is! String ||
        !uuidPattern.hasMatch(challengeId) ||
        phoneCredentialId is! String ||
        !uuidPattern.hasMatch(phoneCredentialId) ||
        cardUid is! String ||
        !RegExp(r'^[0-9a-f]{8,32}$').hasMatch(cardUid) ||
        cardUid.length.isOdd ||
        ndefPayload is! String ||
        !RegExp(
          r'^COMPTECH:NFC:CARD:V1:[0-9a-f]{64}$',
        ).hasMatch(ndefPayload) ||
        message is! String ||
        utf8.encode(message).length > 2048 ||
        expiresAtText is! String) {
      throw const NfcCardAssignmentException(
        'The card-assignment details are invalid.',
      );
    }

    final expiresAt = DateTime.tryParse(expiresAtText);
    final lines = message.split('\n');

    if (expiresAt == null ||
        lines.length != 8 ||
        lines[0] != 'COMPTECH:NFC:ASSIGN:V1' ||
        lines[1] != 'student=$studentId' ||
        lines[2] != 'challenge=$challengeId' ||
        lines[3] != 'credential=$phoneCredentialId' ||
        !RegExp(r'^key=[0-9a-f]{64}$').hasMatch(lines[4]) ||
        lines[5] != 'uid=$cardUid' ||
        !RegExp(r'^token=[0-9a-f]{64}$').hasMatch(lines[6]) ||
        !RegExp(r'^nonce=[0-9a-f]{64}$').hasMatch(lines[7])) {
      throw const NfcCardAssignmentException(
        'The card-assignment challenge is invalid.',
      );
    }

    return NfcCardAssignmentChallenge(
      studentId: studentId,
      challengeId: challengeId,
      phoneCredentialId: phoneCredentialId,
      cardUid: cardUid,
      ndefPayload: ndefPayload,
      challengeMessage: message,
      expiresAt: expiresAt.toUtc(),
    );
  }
}

class NfcCardAssignmentService {
  final _phoneService = NfcPhoneService();

  SupabaseClient get _client => Supabase.instance.client;

  String get currentStudentId {
    final id = _client.auth.currentUser?.id;

    if (id == null) {
      throw const NfcCardAssignmentException(
        'Sign in to your student account first.',
      );
    }

    requireSameAccount(id);
    return id;
  }

  void requireSameAccount(String studentId) {
    final session = _client.auth.currentSession;

    if (session == null ||
        session.user.id != studentId ||
        _client.auth.currentUser?.id != studentId) {
      throw const NfcCardAssignmentException(
        'Your account session changed. Return to the '
            'dashboard and sign in again.',
      );
    }
  }

  void _checkChallenge(NfcCardAssignmentChallenge challenge) {
    requireSameAccount(challenge.studentId);

    if (challenge.isExpired) {
      throw const NfcCardAssignmentException(
        'This assignment challenge has expired. '
            'The server must issue a new challenge before continuing.',
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
      429 => 'CARD_ASSIGNMENT_RATE_LIMITED',
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

      'ACTIVE_PHONE_CREDENTIAL_REQUIRED' =>
      'Register this phone before assigning a card. '
          'If your phone was replaced, use the authorized '
          'phone replacement process.',

      'AUTHORIZED_CARD_REPLACEMENT_REQUIRED' =>
      'Your account already has a card record. '
          'Check its status before continuing. '
          'Replacing a card requires authorization.',

      'CARD_ALREADY_REGISTERED' =>
      'This card UID already has a registration record.',

      'CARD_TOKEN_ALREADY_USED' ||
      'CARD_ASSIGNMENT_CONFLICT' =>
      'The assignment conflicts with an existing record. '
          'Check your saved card status before retrying.',

      'CARD_ASSIGNMENT_RATE_LIMITED' =>
      'Too many assignment attempts. '
          'Wait at least one minute before trying again.',

      'CHALLENGE_EXPIRED' =>
      'The assignment challenge expired. '
          'A new challenge is required.',

      'CHALLENGE_ALREADY_USED' =>
      'This challenge was already used or superseded. '
          'Check your saved card status before retrying.',

      'CHALLENGE_NOT_FOUND' =>
      'This assignment challenge was not found.',

      'CARD_PAYLOAD_MISMATCH' =>
      'The card payload does not match this assignment.',

      'SIGNATURE_INVALID' ||
      'INVALID_SIGNATURE_FORMAT' =>
      'The server could not verify the registered '
          'phone’s signature.',

      'SERVER_CONFIGURATION_ERROR' =>
      'The assignment server configuration needs to be checked.',

      _ => 'Card assignment could not be confirmed ($code).',
    };
  }

  Future<Map<String, dynamic>> _invoke({
    required String name,
    required String studentId,
    required Map<String, dynamic> body,
  }) async {
    requireSameAccount(studentId);

    final token = _client.auth.currentSession!.accessToken;

    try {
      final response = await _client.functions.invoke(
        name,
        body: body,
        headers: {
          'Authorization': 'Bearer $token',
        },
      ).timeout(const Duration(seconds: 30));

      requireSameAccount(studentId);

      final data = response.data;

      if (response.status != 200 || data is! Map) {
        throw const NfcCardAssignmentException(
          'The assignment server returned an unexpected response.',
        );
      }

      return Map<String, dynamic>.from(data);
    } on FunctionException catch (error) {
      throw NfcCardAssignmentException(
        _errorMessage(_readErrorCode(error)),
      );
    } on TimeoutException {
      throw const NfcCardAssignmentException(
        'The server response timed out. '
            'The request may have completed. '
            'Check your saved card status before retrying.',
      );
    }
  }

  Future<NfcCardAssignmentStatus> getStatus({
    required String studentId,
  }) async {
    requireSameAccount(studentId);

    try {
      final dynamic data = await _client
          .rpc('student_nfc_status')
          .timeout(const Duration(seconds: 30));

      requireSameAccount(studentId);

      if (data is! Map) {
        throw const NfcCardAssignmentException(
          'The server returned an invalid card status.',
        );
      }

      final assigned = data['tag_assigned'];
      final status = data['card_status'];

      if (assigned is! bool ||
          (status != null && status is! String) ||
          (assigned &&
              status != 'active' &&
              status != 'inactive' &&
              status != 'replaced') ||
          (!assigned && status != null)) {
        throw const NfcCardAssignmentException(
          'The server returned an invalid card status.',
        );
      }

      return NfcCardAssignmentStatus(
        tagAssigned: assigned,
        cardStatus: status as String?,
      );
    } on TimeoutException {
      throw const NfcCardAssignmentException(
        'Checking card status timed out. '
            'Check your connection and try again.',
      );
    } on PostgrestException {
      throw const NfcCardAssignmentException(
        'Your saved card status could not be checked.',
      );
    }
  }

  Future<NfcCardAssignmentChallenge> beginAssignment({
    required String studentId,
    required String cardUid,
  }) async {
    requireSameAccount(studentId);

    final canonicalUid =
    cardUid.replaceAll(RegExp(r'\s'), '').toLowerCase();

    if (!RegExp(r'^[0-9a-f]{8,32}$').hasMatch(canonicalUid) ||
        canonicalUid.length.isOdd) {
      throw const NfcCardAssignmentException(
        'The card UID is invalid.',
      );
    }

    final data = await _invoke(
      name: 'nfc-card-assignment-start',
      studentId: studentId,
      body: {
        'card_uid': canonicalUid,
      },
    );

    final challenge = NfcCardAssignmentChallenge.fromJson({
      ...data,
      'student_id': studentId,
    });

    if (challenge.cardUid != canonicalUid) {
      throw const NfcCardAssignmentException(
        'The server challenge refers to a different card.',
      );
    }

    _checkChallenge(challenge);

    return challenge;
  }

  // Call before writing so a mismatched phone key is caught early.
  Future<void> verifyPhoneForAssignment(
      NfcCardAssignmentChallenge challenge,
      ) async {
    await _sign(challenge);
  }

  Future<String> _sign(
      NfcCardAssignmentChallenge challenge,
      ) async {
    _checkChallenge(challenge);

    try {
      final signature =
      await _phoneService.signCardAssignmentChallenge(
        studentId: challenge.studentId,
        challengeId: challenge.challengeId,
        phoneCredentialId: challenge.phoneCredentialId,
        cardUid: challenge.cardUid,
        ndefPayload: challenge.ndefPayload,
        message: challenge.challengeMessage,
      );

      _checkChallenge(challenge);
      return signature;
    } on MissingPluginException {
      throw const NfcCardAssignmentException(
        'The Android assignment-signing method is unavailable. '
            'Fully stop the app and run flutter run again.',
      );
    } on PlatformException {
      throw const NfcCardAssignmentException(
        'This phone could not sign the assignment challenge. '
            'Confirm you are using the registered phone and account.',
      );
    } on TimeoutException {
      throw const NfcCardAssignmentException(
        'Phone signing timed out. Try again.',
      );
    }
  }

  Future<String> completeAssignment({
    required NfcCardAssignmentChallenge challenge,
    required String readBackPayload,
  }) async {
    _checkChallenge(challenge);

    if (readBackPayload != challenge.ndefPayload) {
      throw const NfcCardAssignmentException(
        'The data read back from the card does not match '
            'the expected token. Assignment was not submitted.',
      );
    }

    final signature = await _sign(challenge);

    final confirmation = await _invoke(
      name: 'nfc-card-assignment-complete',
      studentId: challenge.studentId,
      body: {
        'challenge_id': challenge.challengeId,
        'signature': signature,
        'ndef_payload': readBackPayload,
      },
    );

    final cardId = confirmation['card_id'];

    if (confirmation['status'] != 'active' ||
        cardId is! String ||
        !RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-'
          r'[0-9a-f]{4}-[0-9a-f]{12}$',
        ).hasMatch(cardId)) {
      throw const NfcCardAssignmentException(
        'Card activation was not confirmed by the server.',
      );
    }

    requireSameAccount(challenge.studentId);

    return cardId;
  }
}