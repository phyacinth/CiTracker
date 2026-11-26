import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// The signed-in student's notifications, shared by every bell so marking
/// them read on one tab clears the badge on all of them.
/// See supabase/migrations/20261103010000_student_notifications.sql.
class StudentNotificationService {
  StudentNotificationService._();

  static final instance = StudentNotificationService._();

  final ValueNotifier<List<Map<String, dynamic>>> items =
      ValueNotifier<List<Map<String, dynamic>>>([]);

  SupabaseClient get _client => Supabase.instance.client;
  StreamSubscription<List<Map<String, dynamic>>>? _rows;
  StreamSubscription<AuthState>? _auth;
  Timer? _retry;
  String? _owner;

  int get unreadCount => items.value.where((n) => n['read_at'] == null).length;

  void start() {
    _auth ??= _client.auth.onAuthStateChange.listen((_) => _listen());
    _listen();
  }

  void _listen({bool force = false}) {
    final owner = _client.auth.currentUser?.id;
    if (!force && owner == _owner && (_rows != null || owner == null)) return;

    _retry?.cancel();
    unawaited(_rows?.cancel());
    _rows = null;
    if (owner != _owner) items.value = [];
    _owner = owner;
    if (owner == null) return;

    // Realtime keeps the list current; row-level security only returns the
    // student's own rows.
    _rows = _client
        .from('comptech_student_notifications')
        .stream(primaryKey: ['id'])
        .eq('student_id', owner)
        .order('created_at', ascending: false)
        .limit(50)
        .listen(
          (rows) {
            if (_client.auth.currentUser?.id == owner) items.value = rows;
          },
          onError: (_) {
            // Keep the last list and reconnect, e.g. after losing signal.
            _retry?.cancel();
            _retry = Timer(const Duration(seconds: 15), () => _listen(force: true));
          },
        );
  }

  Future<void> markAllRead() async {
    if (unreadCount == 0) return;
    final owner = _owner;
    try {
      await _client
          .rpc('comptech_mark_my_notifications_read')
          .timeout(const Duration(seconds: 20));
      if (_client.auth.currentUser?.id != owner) return;
      final now = DateTime.now().toUtc().toIso8601String();
      items.value = [
        for (final n in items.value) {...n, 'read_at': n['read_at'] ?? now},
      ];
    } catch (_) {
      // The badge stays until the next successful attempt.
    }
  }
}
