import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart';

class StudentPhotoService {
  static const _bucket = 'student-profile-photos';
  static String _path(String uid) => '$uid/profile';

  static Future<Uint8List?> load() async {
    final client = Supabase.instance.client;
    final uid = client.auth.currentUser?.id;
    if (uid == null) throw StateError('Please sign in.');
    try {
      final bytes = await client.storage.from(_bucket).download(_path(uid));
      if (client.auth.currentUser?.id != uid) {
        throw StateError('Account changed.');
      }
      return bytes;
    } on StorageException catch (error) {
      if (error.statusCode == '404' ||
          error.statusCode == '400' &&
              error.message.toLowerCase().contains('not found')) {
        return null;
      }
      rethrow;
    }
  }

  static Future<void> upload(Uint8List bytes, String expectedUid) async {
    final client = Supabase.instance.client;
    if (client.auth.currentUser?.id != expectedUid) {
      throw StateError('Account changed.');
    }
    if (bytes.isEmpty || bytes.length > 5 * 1024 * 1024) {
      throw const FormatException('Choose a photo smaller than 5 MB.');
    }
    String? mime;
    if (bytes.length >= 3 &&
        bytes[0] == 255 &&
        bytes[1] == 216 &&
        bytes[2] == 255) {
      mime = 'image/jpeg';
    } else if (bytes.length >= 8 &&
        bytes[0] == 137 &&
        bytes[1] == 80 &&
        bytes[2] == 78 &&
        bytes[3] == 71) {
      mime = 'image/png';
    } else if (bytes.length >= 12 &&
        String.fromCharCodes(bytes.sublist(0, 4)) == 'RIFF' &&
        String.fromCharCodes(bytes.sublist(8, 12)) == 'WEBP') {
      mime = 'image/webp';
    }
    if (mime == null) {
      throw const FormatException('Choose a JPG, PNG or WebP photo.');
    }
    await client.storage
        .from(_bucket)
        .uploadBinary(
      _path(expectedUid),
      bytes,
      fileOptions: FileOptions(
        upsert: true,
        contentType: mime,
        cacheControl: '0',
      ),
    );
    if (client.auth.currentUser?.id != expectedUid) {
      throw StateError('Account changed.');
    }
  }
}
