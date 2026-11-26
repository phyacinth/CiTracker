import 'package:supabase_flutter/supabase_flutter.dart';

/// Archived classes are hidden from every subject list in the student app.
/// The professor dashboard archives a class; the class lists come from
/// several functions, so they're all filtered here in one place.
/// See supabase/migrations/20261104010000_archived_classes.sql.
class ArchivedClassesService {
  ArchivedClassesService._();

  /// The signed-in student's archived class IDs. Never throws: if the lookup
  /// fails (offline, or the function isn't set up), nothing is hidden.
  static Future<Set<String>> load() async {
    try {
      final data = await Supabase.instance.client
          .rpc('comptech_my_archived_class_ids')
          .timeout(const Duration(seconds: 15));
      if (data is! List) return {};
      return data.map((id) => id.toString()).toSet();
    } catch (_) {
      return {};
    }
  }

  /// [rows] without the archived classes; [idKey] names the class ID field.
  static Future<List<T>> withoutArchived<T extends Map>(
    List<T> rows, {
    String idKey = 'id',
  }) async {
    if (rows.isEmpty) return rows;
    final archived = await load();
    if (archived.isEmpty) return rows;
    return rows.where((row) => !archived.contains('${row[idKey]}')).toList();
  }
}
