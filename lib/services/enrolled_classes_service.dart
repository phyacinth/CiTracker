import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'archived_classes_service.dart';

class EnrolledClassesService {
  EnrolledClassesService._();

  static final ValueNotifier<int> changes = ValueNotifier<int>(0);

  static void notifyChanged() {
    changes.value++;
  }

  /// Current classes only: archived classes aren't offered as subject choices.
  static Future<List<Map<String, String>>> load() async {
    final classes = await loadAll();
    return classes.where((c) => c['status'] != archivedStatus).toList();
  }

  static const archivedStatus = 'Archived';

  /// Every enrolled class; archived ones have status [archivedStatus].
  static Future<List<Map<String, String>>> loadAll() async {
    final client = Supabase.instance.client;
    final userId = client.auth.currentUser?.id;

    if (userId == null) {
      throw StateError('Please sign in to load your classes.');
    }

    final response = await client
        .rpc('comptech_my_enrolled_classes')
        .timeout(const Duration(seconds: 20));

    if (client.auth.currentUser?.id != userId) {
      throw StateError('The signed-in account changed.');
    }

    if (response is! List) {
      throw const FormatException('Unexpected class response.');
    }

    final classes = response.map<Map<String, String>>((item) {
      final row = Map<String, dynamic>.from(item as Map);

      return {
        'id': row['class_id'] as String,
        'subject': row['subject'] as String,
        'professor': row['professor'] as String? ?? 'Not available',
        'section': row['section'] as String? ?? '',
        'status': 'Enrolled',
      };
    }).toList();
    final archived = await ArchivedClassesService.load();
    return [
      for (final c in classes)
        archived.contains(c['id']) ? {...c, 'status': archivedStatus} : c,
    ];
  }
}
