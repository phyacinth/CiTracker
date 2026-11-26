import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show AppLifecycleListener;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'attendance_location_service.dart';
import 'nfc_attendance_service.dart';

class OfflineAttendanceException implements Exception {
  const OfflineAttendanceException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Fallback for when there's no internet: attendance is signed with the
/// registered phone key, saved on the phone, and sent to the
/// `comptech-offline-attendance` Edge Function once the phone reconnects.
/// Online attendance doesn't use any of this.
/// See supabase/migrations/20261103030000_offline_attendance.sql.
///
/// Items are kept per account: QR scans and tap locations (students) and
/// phone taps (the professor's offline scanner).
class OfflineAttendanceService {
  OfflineAttendanceService._();

  static final instance = OfflineAttendanceService._();

  static const _channel = MethodChannel('comptech/nfc_credential');
  static const _function = 'comptech-offline-attendance';
  static const _actions = {
    'qr': 'qr',
    'location': 'location',
    'phone_tap': 'phone_taps',
  };

  /// Items still waiting to be sent, for the signed-in account.
  final ValueNotifier<List<Map<String, dynamic>>> pending =
      ValueNotifier<List<Map<String, dynamic>>>([]);

  /// Items the server finally refused, kept for the day so the student or
  /// professor can see why.
  final ValueNotifier<List<Map<String, dynamic>>> refused =
      ValueNotifier<List<Map<String, dynamic>>>([]);

  /// Why waiting items haven't been sent yet, or null when nothing is wrong
  /// (or the phone is simply offline).
  final ValueNotifier<String?> lastError = ValueNotifier<String?>(null);

  SupabaseClient get _client => Supabase.instance.client;
  AppLifecycleListener? _lifecycle;
  StreamSubscription<List<ConnectivityResult>>? _connectivity;
  StreamSubscription<AuthState>? _auth;
  Timer? _timer;
  Timer? _retry;
  bool _syncing = false;
  bool _syncAgain = false;
  String? _owner;

  // Seconds to wait between quick tries after reconnecting; the periodic
  // timer takes over after the last one.
  static const _quickRetries = [0, 2, 5, 10, 20];

  static String _queueKey(String owner) => 'comptech_offline_queue_v1_$owner';
  static String _refusedKey(String owner) => 'comptech_offline_refused_v1_$owner';

  void start() {
    _connectivity ??= Connectivity().onConnectivityChanged.listen((result) {
      if (result.any((r) => r != ConnectivityResult.none)) _syncSoon();
    });
    _auth ??= _client.auth.onAuthStateChange.listen((_) => unawaited(_load()));
    _lifecycle ??= AppLifecycleListener(onResume: _syncSoon);
    _timer ??= Timer.periodic(const Duration(seconds: 30), (_) {
      if (pending.value.isNotEmpty) unawaited(sync());
    });
    unawaited(_load().then((_) => _syncSoon()));
  }

  /// Sends right away and, while items are still waiting, tries again a few
  /// times within the next half minute. Just after reconnecting, the network
  /// is often up before the internet actually works.
  void _syncSoon([int attempt = 0]) {
    _retry?.cancel();
    if (attempt >= _quickRetries.length) return;
    _retry = Timer(Duration(seconds: _quickRetries[attempt]), () async {
      await sync();
      if (pending.value.isNotEmpty) _syncSoon(attempt + 1);
    });
  }

  /// No network at all. A connected network can still lack internet, so
  /// callers also fall back to saving offline when a request fails.
  static Future<bool> isOffline() async {
    try {
      final result = await Connectivity().checkConnectivity();
      return result.every((r) => r == ConnectivityResult.none);
    } catch (_) {
      return false;
    }
  }

  static String newUuid() {
    final bytes = List<int>.generate(16, (_) => Random.secure().nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  static String newNonce() => List<int>.generate(
    32,
    (_) => Random.secure().nextInt(256),
  ).map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  /// "lat,lng,accuracy,mock" exactly as the phone key accepts it.
  static String _point(AttendanceLocation? location) => location == null
      ? 'none'
      : '${location.latitude.toStringAsFixed(7)},'
            '${location.longitude.toStringAsFixed(7)},'
            '${location.accuracyM.clamp(0, 999999).toStringAsFixed(1)},'
            '${location.isMocked ? 1 : 0}';

  static int _now() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  Future<void> _load() async {
    final owner = _client.auth.currentUser?.id;
    _owner = owner;
    if (owner == null) {
      pending.value = [];
      refused.value = [];
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    if (_client.auth.currentUser?.id != owner) return;
    pending.value = _decode(prefs.getString(_queueKey(owner)));
    final today = DateTime.now().toIso8601String().substring(0, 10);
    refused.value = _decode(prefs.getString(_refusedKey(owner)))
        .where((r) => (r['created_at'] ?? '').toString().startsWith(today))
        .toList();
  }

  static List<Map<String, dynamic>> _decode(String? raw) {
    if (raw == null) return [];
    try {
      return (jsonDecode(raw) as List)
          .map((item) => Map<String, dynamic>.from(item as Map))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> _store(String owner) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_queueKey(owner), jsonEncode(pending.value));
    await prefs.setString(_refusedKey(owner), jsonEncode(refused.value));
  }

  Future<void> _add(String owner, Map<String, dynamic> item) async {
    if (_owner != owner) await _load();
    pending.value = [...pending.value, item];
    await _store(owner);
  }

  Future<String> _sign(String studentId, String message) async {
    final signature = await _channel.invokeMethod<String>(
      'signOfflineProof',
      {'studentId': studentId, 'message': message},
    ).timeout(const Duration(seconds: 30));
    if (signature == null || signature.isEmpty) {
      throw const OfflineAttendanceException('The phone key did not sign.');
    }
    return signature;
  }

  /// The registered phone key's fingerprint; works offline.
  Future<String> _fingerprint() async {
    try {
      return await NfcAttendanceService().prepareFingerprint();
    } on NfcAttendanceException {
      throw const OfflineAttendanceException(
        'Saving attendance offline needs a registered phone. Set it up in '
        'NFC phone registration while you have internet.',
      );
    }
  }

  /// QR scan with no internet: signed now, sent when back online.
  Future<void> saveQr({
    required String classId,
    required String sessionId,
    required String token,
    AttendanceLocation? location,
  }) async {
    final owner = _client.auth.currentUser?.id;
    if (owner == null) {
      throw const OfflineAttendanceException('Sign in before scanning attendance.');
    }
    if (_owner != owner) await _load();
    if (pending.value.any(
      (i) => i['kind'] == 'qr' && i['session_id'] == sessionId,
    )) {
      throw const OfflineAttendanceException(
        'Already saved for this session. It will be sent when you are back online.',
      );
    }
    final fingerprint = await _fingerprint();
    final uploadId = newUuid();
    final message = [
      'COMPTECH:OFFLINE:QR:V1',
      'student=$owner',
      'key=$fingerprint',
      'upload=$uploadId',
      'class=$classId',
      'session=$sessionId',
      'token=${sha256.convert(utf8.encode(token))}',
      'time=${_now()}',
      'location=${_point(location)}',
    ].join('\n');
    final signature = await _sign(owner, message);
    await _add(owner, {
      'kind': 'qr',
      'upload_id': uploadId,
      'class_id': classId,
      'session_id': sessionId,
      'message': message,
      'signature': signature,
      'token': token,
      'latitude': location?.latitude,
      'longitude': location?.longitude,
      'created_at': DateTime.now().toIso8601String(),
    });
  }

  /// A signed location for an NFC tap, made right away so its time is the
  /// tap's. Pass it to [saveLocation] if it can't be sent now.
  Future<Map<String, dynamic>?> signLocation(AttendanceLocation location) async {
    final owner = _client.auth.currentUser?.id;
    if (owner == null) return null;
    try {
      final fingerprint = await _fingerprint();
      final uploadId = newUuid();
      final message = [
        'COMPTECH:OFFLINE:LOCATION:V1',
        'student=$owner',
        'key=$fingerprint',
        'upload=$uploadId',
        'time=${_now()}',
        'location=${_point(location)}',
      ].join('\n');
      return {
        'kind': 'location',
        'owner': owner,
        'upload_id': uploadId,
        'message': message,
        'signature': await _sign(owner, message),
        'latitude': location.latitude,
        'longitude': location.longitude,
        'created_at': DateTime.now().toIso8601String(),
      };
    } catch (_) {
      // No registered phone key: the location simply isn't saved.
      return null;
    }
  }

  Future<void> saveLocation(Map<String, dynamic> signed) async {
    final owner = signed.remove('owner') as String?;
    if (owner == null || _client.auth.currentUser?.id != owner) return;
    await _add(owner, signed);
  }

  /// A student's phone tap saved by the professor's offline scanner.
  Future<void> savePhoneTap({
    required String studentId,
    required String sessionId,
    required DateTime sessionStartedAt,
    required String message,
    required String signature,
    String? challengeId,
    AttendanceLocation? scannerLocation,
  }) async {
    final owner = _client.auth.currentUser?.id;
    if (owner == null) {
      throw const OfflineAttendanceException('Sign in again.');
    }
    await _add(owner, {
      'kind': 'phone_tap',
      'upload_id': challengeId ?? newUuid(),
      'student_id': studentId,
      'session_id': sessionId,
      'session_started_at': sessionStartedAt.toUtc().toIso8601String(),
      'message': message,
      'signature': signature,
      'latitude': scannerLocation?.latitude,
      'longitude': scannerLocation?.longitude,
      'accuracy_m': scannerLocation?.accuracyM,
      'is_mocked': scannerLocation?.isMocked ?? false,
      'created_at': DateTime.now().toIso8601String(),
    });
  }

  bool hasPhoneTap(String studentId, String sessionId) => pending.value.any(
    (i) =>
        i['kind'] == 'phone_tap' &&
        i['student_id'] == studentId &&
        i['session_id'] == sessionId,
  );

  /// Sends everything waiting. Items stay until the server gives a final
  /// answer; network and server trouble just means trying again later.
  Future<void> sync() async {
    final owner = _client.auth.currentUser?.id;
    if (owner == null || _client.auth.currentSession == null) return;
    if (_syncing) {
      // Run once more when this one finishes, so nothing waits for the timer.
      _syncAgain = true;
      return;
    }
    _syncing = true;
    try {
      if (_owner != owner) await _load();
      var recorded = false;
      var serverFailed = false;
      for (final entry in _actions.entries) {
        final items = pending.value.where((i) => i['kind'] == entry.key).take(50).toList();
        if (items.isEmpty) continue;

        // Place names are looked up together, not one after another.
        final payload = await Future.wait(items.map((item) async {
          final place = item['latitude'] is num && item['kind'] != 'phone_tap'
              ? await AttendanceLocationService().lookupPlace(
                  (item['latitude'] as num).toDouble(),
                  (item['longitude'] as num).toDouble(),
                )
              : null;
          return {...item, 'place_name': place};
        }));

        final response = await _client.functions
            .invoke(_function, body: {'action': entry.value, 'items': payload})
            .timeout(const Duration(seconds: 30));
        if (_client.auth.currentUser?.id != owner || response.data is! Map) return;
        final results = (response.data as Map)['results'];
        if (results is! List) continue;

        final done = <String, Map<String, dynamic>>{};
        for (final result in results) {
          if (result is! Map) continue;
          final status = result['status'];
          if (status == 'error') serverFailed = true;
          if (status == 'recorded' ||
              status == 'already_recorded' ||
              status == 'rejected') {
            done[result['upload_id'].toString()] = Map<String, dynamic>.from(result);
            if (status == 'recorded') recorded = true;
          }
        }
        if (done.isEmpty) continue;

        refused.value = [
          ...refused.value,
          for (final item in items)
            if (done[item['upload_id']]?['status'] == 'rejected')
              {
                'kind': item['kind'],
                'session_id': item['session_id'],
                'class_id': item['class_id'],
                'code': done[item['upload_id']]?['code'],
                'saved_at': item['created_at'],
                'created_at': DateTime.now().toIso8601String(),
              },
        ];
        pending.value = pending.value
            .where((i) => !done.containsKey(i['upload_id']))
            .toList();
        await _store(owner);
      }
      // Reached the server, but it couldn't check some items (for example a
      // database function is missing). Say so instead of waiting silently.
      lastError.value = serverFailed
          ? 'The server could not check it yet. It will try again.'
          : null;
      if (recorded) NfcAttendanceService.notifyChanged();
    } on FunctionException catch (error) {
      // Reached the server, which couldn't take it: say why.
      lastError.value = error.status == 404
          ? "The server isn't set up for offline uploads yet "
                '(comptech-offline-attendance). Ask your administrator.'
          : error.status == 401
          ? 'Your sign-in expired. Open the app online and sign in again.'
          : 'The server could not take it yet (error ${error.status}). '
                'It will try again.';
    } catch (_) {
      // Still offline, or the connection dropped; try again later.
      lastError.value = await isOffline()
          ? null
          : 'Could not reach the server. It will try again.';
    } finally {
      _syncing = false;
      if (_syncAgain) {
        _syncAgain = false;
        unawaited(sync());
      }
    }
  }

  static String explain(String? code) => switch (code) {
    'GRACE_PERIOD_ENDED' => 'it was scanned after the check-in period',
    'QR_INVALID' => 'the QR code was not valid at that time',
    'UPLOAD_TOO_LATE' => 'it was sent after the end of that day',
    'NOT_ENROLLED' => 'you are not enrolled in that class',
    'SESSION_NOT_FOUND' || 'SESSION_NOT_ACTIVE' => 'that class session was not open',
    'REGISTERED_PHONE_REQUIRED' || 'SIGNATURE_INVALID' || 'CREDENTIAL_INVALID' =>
      'it was not signed by your registered phone',
    _ => 'it could not be verified',
  };
}
