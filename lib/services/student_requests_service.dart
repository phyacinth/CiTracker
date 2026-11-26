import 'package:supabase_flutter/supabase_flutter.dart';

class StudentRequestsService {
  static const specialRequestHeading =
      'Request for Special Exam/Quiz/Activity\n\n';
  final _client = Supabase.instance.client;

  Future<List<Map<String, dynamic>>> load() async {
    final userId = _client.auth.currentUser?.id;
    if (userId == null) throw StateError('Please sign in again.');
    final result = await _client.rpc('comptech_my_student_requests');
    if (_client.auth.currentUser?.id != userId) {
      throw StateError('Account changed. Reopen this screen.');
    }
    if (result is! List) {
      throw const FormatException('Unexpected request response.');
    }
    return result.map((row) => Map<String, dynamic>.from(row as Map)).toList();
  }

  Future<void> submit({
    required String classId,
    required String kind,
    DateTime? date,
    required String message,
  }) async {
    final userId = _client.auth.currentUser?.id;
    if (userId == null) throw StateError('Please sign in again.');
    if (!const ['excuse', 'concern', 'special'].contains(kind)) {
      throw ArgumentError('Select a valid submission type.');
    }
    final isSpecial = kind == 'special';
    // Use the existing concern route so the deployed two-kind RPC stays compatible.
    // The professor sees the explicit request label in the message.
    final requestMessage = isSpecial
        ? '$specialRequestHeading${message.trim()}'
        : message.trim();
    if (message.trim().length < 10 || requestMessage.length > 3000) {
      throw ArgumentError(
        'Your message is too short or exceeds the character limit.',
      );
    }
    String two(int v) => v.toString().padLeft(2, '0');
    await _client.rpc(
      'comptech_submit_student_request',
      params: {
        'p_class_id': classId,
        'p_kind': isSpecial ? 'concern' : kind,
        'p_date': isSpecial || date == null
            ? null
            : '${date.year}-${two(date.month)}-${two(date.day)}',
        'p_message': requestMessage,
      },
    );
    if (_client.auth.currentUser?.id != userId) {
      throw StateError('Account changed. Reopen this screen.');
    }
  }
}
