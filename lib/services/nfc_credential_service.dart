import 'package:supabase_flutter/supabase_flutter.dart';

class NfcCredentialStatus {
  const NfcCredentialStatus({
    required this.tagAssigned,
    required this.cardStatus,
  });

  final bool tagAssigned;
  final String? cardStatus;
}

class NfcCredentialService {
  Future<NfcCredentialStatus> getStatus() async {
    final client = Supabase.instance.client;

    if (client.auth.currentUser == null) {
      throw StateError('A signed-in account is required.');
    }

    final result = await client
        .rpc('student_nfc_status')
        .timeout(const Duration(seconds: 15));

    if (result is! Map) {
      throw const FormatException('Invalid NFC status response.');
    }

    final tagAssigned = result['tag_assigned'];
    final cardStatus = result['card_status'];

    if (tagAssigned is! bool ||
        (cardStatus != null && cardStatus is! String)) {
      throw const FormatException('Invalid NFC status fields.');
    }

    return NfcCredentialStatus(
      tagAssigned: tagAssigned,
      cardStatus: cardStatus as String?,
    );
  }
}