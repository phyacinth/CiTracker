import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'login_screen.dart';

import 'package:flutter/services.dart';
import 'package:crypto/crypto.dart';
import 'package:nfc_manager/ndef_record.dart';
import 'package:nfc_manager/nfc_manager.dart';
import 'package:nfc_manager/nfc_manager_android.dart';

import 'package:shared_preferences/shared_preferences.dart';

import '../services/attendance_location_service.dart';
import '../services/nfc_attendance_service.dart';
import '../services/offline_attendance_service.dart';
import '../services/phone_nfc_reader_service.dart';
import '../theme/app_theme.dart';
import '../widgets/app_dropdown.dart';

enum _ScanMode { phone, card }

/// What a scan does: record attendance, or enter hands-on points for the
/// student (supabase/migrations/20261104020000_performance_points.sql).
enum _Purpose { attendance, performance }

/// Notice kinds for scan events, so the professor can tell at a glance
/// without reading the status text.
enum _Pop { detected, recorded, info, missed }

// Temporary authenticated faculty scanner, separate from student navigation.
class NfcProfessorTestScreen extends StatefulWidget {
  const NfcProfessorTestScreen({super.key});

  @override
  State<NfcProfessorTestScreen> createState() => _NfcProfessorTestScreenState();
}

class _NfcProfessorTestScreenState extends State<NfcProfessorTestScreen>
    with WidgetsBindingObserver {
  static Color get backgroundColor => AppColors.background;
  static Color get cardColor => AppColors.card;
  static Color get accentColor => AppColors.accent;
  static Color get buttonColor => AppColors.button;
  static Color get borderColor => AppColors.border;
  static Color get secondaryTextColor => AppColors.secondaryText;

  final _service = NfcAttendanceService();
  final _phoneReader = PhoneNfcReaderService();
  final _offlineQueue = OfflineAttendanceService.instance;
  final _location = AttendanceLocationService();
  StreamSubscription<AuthState>? _authSubscription;
  String? _ownerId;

  // Offline mode (no internet): phone taps are signed by the student's phone
  // and saved here, then uploaded once this phone reconnects. Classes and
  // sessions come from the last list loaded online.
  bool _offline = false;
  AttendanceLocation? _scannerLocation;
  DateTime? _scannerLocationAt;
  // Must match TAP_EXPIRY_OFFSET_S in the comptech-offline-attendance function.
  static const _tapExpiryOffset = Duration(seconds: 45);

  List<Map<String, dynamic>> _classes = [];

  String? _classId;
  String? _sessionId;
  String? _cardReport;
  String? _popText;
  _Pop? _popKind;

  bool _busy = false;
  bool _authorized = false;
  bool _scanning = false;
  _ScanMode _mode = _ScanMode.card;
  _Purpose _purpose = _Purpose.attendance;
  // Performance mode: which term the hands-on points are for.
  String _term = 'midterm';
  // The hands-on column last picked per class and term, so the next student
  // starts on it.
  final Map<String, String> _lastColumn = {};

  int _operation = 0;

  Completer<Map<String, String>>? _scan;

  String _status =
      'Use a faculty/professor account that owns the test class. '
      'Students cannot use this scanner.';

  /// Status text for the notice panel. A new status replaces the last scan
  /// event, so the panel always shows the latest thing that happened.
  String get _message => _status;
  set _message(String value) {
    _status = value;
    _popText = null;
    _popKind = null;
  }

  Map<String, dynamic>? get _selectedClass {
    for (final row in _classes) {
      if (row['class_id'] == _classId) {
        return row;
      }
    }

    return null;
  }

  List<Map<String, dynamic>> get _sessions =>
      NfcAttendanceService.rows(_selectedClass?['sessions'] ?? []);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _ownerId = _service.client.auth.currentUser?.id;
    // Uploads phone taps saved offline once this phone reconnects.
    _offlineQueue.start();
    _authSubscription = _service.client.auth.onAuthStateChange.listen((state) {
      if (state.session?.user.id != _ownerId) {
        ++_operation;
        unawaited(_stopNfc());
        if (mounted) {
          setState(() {
            _authorized = false;
            _busy = false;
            _classes = [];
            _classId = null;
            _sessionId = null;
            _message = 'Your session changed. Log out and sign in again.';
          });
        }
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _perform((_) => _load());
      }
    });
  }

  Future<void> _stopNfc() async {
    await _phoneReader.stop();
    try {
      await NfcManager.instance.stopSession();
    } catch (_) {
      // A session may already have stopped.
    }
  }

  void _check(int operation, String owner) {
    if (!mounted || operation != _operation) {
      throw const NfcAttendanceException('Scanner stopped.');
    }

    _service.requireAccount(owner);
  }

  Future<void> _load() async {
    final owner = _ownerId;
    if (owner == null) {
      throw const NfcAttendanceException('Please sign in as a professor.');
    }
    _service.requireAccount(owner);
    setState(() => _authorized = false);
    Map<String, dynamic> data;
    try {
      if (await OfflineAttendanceService.isOffline()) {
        throw const NfcAttendanceException('No connection.');
      }
      data = await _service.call('scanner_context');
    } catch (error) {
      // An answer from the server (wrong account, etc.) is final; only a
      // missing connection falls back to the saved list.
      if (error is NfcAttendanceException &&
          error.code.isNotEmpty &&
          error.code != 'FUNCTION_REQUEST_FAILED') {
        rethrow;
      }
      if (!await _loadOffline(owner)) {
        throw const NfcAttendanceException(
          'No internet, and this phone has no saved class list yet. Connect '
          'once to load your classes; after that, phone taps work offline.',
        );
      }
      return;
    }
    _service.requireAccount(owner);

    if (!mounted) {
      return;
    }

    final classes = NfcAttendanceService.rows(data['classes']);
    unawaited(_saveClasses(owner, classes));
    unawaited(_offlineQueue.sync());

    setState(() {
      _offline = false;
      _classes = classes;
      _authorized = true;
      _message = 'Professor account verified. Select your class and active NFC session.';

      if (!classes.any((c) => c['class_id'] == _classId)) {
        _classId = classes.isEmpty ? null : classes.first['class_id'] as String;
      }

      _sessionId = _sessions.isEmpty
          ? null
          : _sessions.first['session_id'] as String;
    });
  }

  /// Shows a scan event in the notice panel, with a vibration.
  void _pop(String text, _Pop kind) {
    if (!mounted) return;
    setState(() {
      _popText = text;
      _popKind = kind;
    });
    switch (kind) {
      case _Pop.detected:
        HapticFeedback.selectionClick();
      case _Pop.recorded:
        HapticFeedback.mediumImpact();
      case _Pop.info:
        break;
      case _Pop.missed:
        HapticFeedback.heavyImpact();
    }
  }

  /// Fixed panel under the mode toggle that keeps the latest scan event.
  Widget _buildNotice() {
    final kind = _popKind;
    final (icon, color) = switch (kind) {
      _Pop.detected => (Icons.nfc_rounded, AppColors.accent),
      _Pop.recorded => (Icons.check_circle_rounded, AppColors.success),
      _Pop.info => (Icons.info_outline_rounded, AppColors.accent),
      _Pop.missed => (Icons.error_outline_rounded, AppColors.warning),
      null => (Icons.nfc_rounded, secondaryTextColor),
    };
    final text = _popText ?? _message;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: kind == null ? borderColor : color,
          width: 1.5,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(icon, color: color),
              const SizedBox(width: 12),
              Expanded(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),
                  child: Text(
                    text,
                    key: ValueKey(text),
                    style: TextStyle(
                      color: AppColors.text,
                      fontWeight: kind == null ? FontWeight.w500 : FontWeight.w600,
                      height: 1.4,
                    ),
                  ),
                ),
              ),
            ],
          ),
          if (_busy) ...[
            const SizedBox(height: 12),
            LinearProgressIndicator(color: accentColor),
          ],
          if (_busy && !_scanning)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: _cancelScan,
                child: const Text('Cancel'),
              ),
            ),
        ],
      ),
    );
  }

  static String _classesKey(String owner) => 'comptech_scanner_classes_v1_$owner';

  Future<void> _saveClasses(String owner, List<Map<String, dynamic>> classes) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_classesKey(owner), jsonEncode(classes));
  }

  /// Offline: the class list saved the last time this phone was online.
  Future<bool> _loadOffline(String owner) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_classesKey(owner));
    if (raw == null || !mounted) return false;
    final List<Map<String, dynamic>> classes;
    try {
      classes = NfcAttendanceService.rows(jsonDecode(raw));
    } catch (_) {
      return false;
    }
    setState(() {
      _offline = true;
      _classes = classes;
      _authorized = true;
      _message = 'Offline mode. Phone taps are saved on this phone and '
          'uploaded automatically when it is back online. Card taps need '
          'internet.';
      if (!classes.any((c) => c['class_id'] == _classId)) {
        _classId = classes.isEmpty ? null : classes.first['class_id'] as String;
      }
      _sessionId = _sessions.isEmpty ? null : _sessions.first['session_id'] as String;
    });
    return true;
  }

  /// Offline with no session open: start one on this phone. It is created
  /// on the server with the first uploaded tap.
  void _openOfflineSession(String owner) {
    final id = OfflineAttendanceService.newUuid();
    final session = {
      'session_id': id,
      'started_at': DateTime.now().toUtc().toIso8601String(),
      'offline': true,
    };
    setState(() {
      _classes = [
        for (final c in _classes)
          c['class_id'] == _classId
              ? {
                  ...c,
                  'sessions': [session, ...NfcAttendanceService.rows(c['sessions'] ?? [])],
                }
              : c,
      ];
      _sessionId = id;
      _message = 'Offline session started. The grace period is 10 minutes. '
          'Ask students to enable Tap Phone.';
    });
    unawaited(_saveClasses(owner, _classes));
  }

  DateTime _sessionStartedAt(String sessionId) {
    for (final s in _sessions) {
      if (s['session_id'] == sessionId) {
        return DateTime.tryParse('${s['started_at'] ?? ''}') ?? DateTime.now();
      }
    }
    return DateTime.now();
  }

  /// This phone's location for offline taps; one reading is reused for two
  /// minutes so the line of students isn't slowed down.
  Future<AttendanceLocation?> _currentScannerLocation() async {
    final at = _scannerLocationAt;
    if (_scannerLocation != null &&
        at != null &&
        DateTime.now().difference(at) < const Duration(minutes: 2)) {
      return _scannerLocation;
    }
    final location = await _location.current(
      timeLimit: const Duration(seconds: 10),
      lookupName: false,
    );
    if (location != null) {
      _scannerLocation = location;
      _scannerLocationAt = DateTime.now();
    }
    return location;
  }

  /// Offline phone tap: this scanner makes the challenge (same format as an
  /// online tap), the student's phone signs it, and it is saved here. The
  /// server checks the signature against the registered phone on upload.
  Future<void> _scanPhoneOffline(
    int operation,
    String owner, {
    Map<String, dynamic>? identity,
  }) async {
    final sessionId = _sessionId!;
    final classId = _classId!;
    if (identity == null) {
      await _stopNfc();
      _check(operation, owner);
      setState(() {
        _message = 'Offline mode. Ask the student to enable Tap Phone. Hold '
            'the backs of both unlocked phones together until the signature '
            'is read.';
      });
      identity = await _phoneReader.readIdentity();
      _check(operation, owner);
      _pop('Phone detected. Keep the phones together.', _Pop.detected);
    }
    final studentId = identity['student_id'] as String;
    if (_offlineQueue.hasPhoneTap(studentId, sessionId)) {
      await _phoneReader.stop();
      setState(() => _message = 'This student is already saved for this '
          'session. No duplicate was created.');
      _pop('Already saved for this session. No duplicate.', _Pop.info);
      return;
    }
    final challengeId = OfflineAttendanceService.newUuid();
    final expires = DateTime.now().add(_tapExpiryOffset).millisecondsSinceEpoch ~/ 1000;
    final message = [
      'COMPTECH:NFC:PHONE_TAP:V1',
      'student=$studentId',
      'key=${identity['key_fingerprint']}',
      'challenge=$challengeId',
      'session=$sessionId',
      'class=$classId',
      'scanner=$owner',
      'nonce=${OfflineAttendanceService.newNonce()}',
      'expires=$expires',
    ].join('\n');
    final signature = await _phoneReader.sign(message);
    _check(operation, owner);
    setState(() => _message = 'Signature read. The phones can be separated. '
        'Saving on this phone…');
    await _offlineQueue.savePhoneTap(
      studentId: studentId,
      sessionId: sessionId,
      sessionStartedAt: _sessionStartedAt(sessionId),
      message: message,
      signature: signature,
      challengeId: challengeId,
      scannerLocation: await _currentScannerLocation(),
    );
    _check(operation, owner);
    setState(() => _message = 'Saved offline. It will upload automatically '
        'when this phone is back online.');
    _pop('Saved as present. Uploads when back online.', _Pop.recorded);
  }

  Future<void> _perform(Future<void> Function(int operation) work) async {
    if (_busy) {
      return;
    }

    final operation = ++_operation;

    setState(() => _busy = true);

    try {
      await work(operation);
    } catch (error) {
      if (mounted && operation == _operation) {
        setState(() {
          _message = error is NfcAttendanceException
              ? error.message
              : 'Operation failed. Check the connection and faculty '
                    'sign-in details.';
        });
      }
    } finally {
      if (mounted && operation == _operation) {
        await _stopNfc();

        if (mounted && operation == _operation) {
          setState(() => _busy = false);
        }
      }
    }
  }

  Future<void> _logout() async {
    if (_busy) {
      return;
    }
    setState(() {
      _busy = true;
      _authorized = false;
    });
    ++_operation;
    try {
      await _stopNfc();
      await _service.client.auth.signOut(scope: SignOutScope.local);
      if (!mounted) {
        return;
      }
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute<void>(builder: (_) => const LoginScreen()),
        (_) => false,
      );
    } catch (_) {
      if (mounted) {
        setState(() {
          _busy = false;
          _message = 'Could not finish logout. Try again.';
        });
      }
    }
  }

  // Opens (or reuses) a session when none is selected, then scans students one
  // after another in the selected mode until End scanning is pressed.
  Future<void> _toggleScanning() async {
    if (_scanning) {
      _cancelScan();
      return;
    }
    if (_classId == null || !_authorized) {
      return;
    }
    if (_purpose == _Purpose.performance && _offline) {
      setState(() => _message = 'Performance mode needs internet to save '
          'points. Connect, then tap Refresh classes & sessions.');
      return;
    }
    if (_offline && _mode == _ScanMode.card) {
      setState(() => _message = 'Card taps need internet. Switch to Tap Phone '
          'to save taps offline.');
      return;
    }

    await _perform((operation) async {
      final owner = _service.accountId;
      setState(() {
        _scanning = true;
        _cardReport = null;
        _popText = null;
        _popKind = null;
      });

      try {
        // Performance mode doesn't use attendance sessions.
        if (_purpose == _Purpose.performance) {
          setState(() => _message = 'Performance mode. Scan a student to '
              'enter their points.');
        } else if (_sessionId == null && _offline) {
          _openOfflineSession(owner);
        } else if (_sessionId == null) {
          // The list may be older than a session started on the professor
          // dashboard since; use that one instead of opening a second.
          await _load();
          _check(operation, owner);
          if (_sessionId != null) {
            setState(() => _message = 'Using the session already running '
                'for this class. Students can check in for 30 minutes after '
                'it started.');
          } else if (_offline) {
            _openOfflineSession(owner);
          } else {
            final result = await _service.call('session_open', {
              'class_id': _classId,
            });
            _check(operation, owner);
            await _load();
            _check(operation, owner);
            setState(() {
              _sessionId = result['session_id'] as String;
              _message =
                  'Attendance session opened. Students can check in for 30 '
                  'minutes. Ask them to select this class in Use Card (or '
                  'tap Refresh) and enable readiness, or turn on Tap Phone.';
            });
          }
        }

        while (true) {
          _check(operation, owner);
          try {
            if (_purpose == _Purpose.performance) {
              await _scanPerformanceOnce(operation, owner);
            } else if (_mode == _ScanMode.card) {
              await _scanCardOnce(operation, owner);
            } else if (_offline) {
              await _scanPhoneOffline(operation, owner);
            } else {
              await _scanPhoneOnce(operation, owner);
            }
          } catch (error) {
            if (!mounted || operation != _operation) {
              rethrow;
            }
            final message = error is NfcAttendanceException
                ? error.message
                : 'Scan failed. Ready for the next student.';
            setState(() => _message = message);
            // Nothing came near the reader in time.
            final missed = error is TimeoutException ||
                message.startsWith('No card was detected');
            _pop(
              missed
                  ? _mode == _ScanMode.card
                        ? 'No card detected. Ask the student to try again.'
                        : 'No phone detected. Ask the student to try again.'
                  : message,
              _Pop.missed,
            );
          }
          await _stopNfc();
          // Leave the last result on screen before the next scan starts.
          await Future<void>.delayed(const Duration(seconds: 3));
        }
      } finally {
        if (mounted && operation == _operation) {
          setState(() => _scanning = false);
        }
      }
    });
  }

  Future<void> _closeSession() => _perform((operation) async {
    if (_sessionId == null) {
      return;
    }

    if (_offline) {
      final local = _sessions.any(
        (s) => s['session_id'] == _sessionId && s['offline'] == true,
      );
      if (!local) {
        setState(() => _message = 'No internet. End this session once the '
            'phone is back online.');
        return;
      }
      // Saved taps keep their session and still upload.
      final owner = _service.accountId;
      setState(() {
        _classes = [
          for (final c in _classes)
            {
              ...c,
              'sessions': NfcAttendanceService.rows(c['sessions'] ?? [])
                  .where((s) => s['session_id'] != _sessionId)
                  .toList(),
            },
        ];
        _sessionId = null;
        _message = 'Offline session ended. Its saved taps will still upload.';
      });
      unawaited(_saveClasses(owner, _classes));
      return;
    }

    await _service.call('session_close', {'session_id': _sessionId});

    if (!mounted || operation != _operation) {
      return;
    }

    await _load();

    if (mounted && operation == _operation) {
      setState(() {
        _message = 'NFC test session ended.';
      });
    }
  });

  Future<Map<String, String>> _readCard(int operation, String owner) async {
    final availability = await NfcManager.instance.checkAvailability();

    if (availability != NfcAvailability.enabled) {
      throw const NfcAttendanceException('Enable NFC on this faculty phone.');
    }

    _check(operation, owner);

    final result = Completer<Map<String, String>>();
    _scan = result;

    var processing = false;
    var active = true;

    final timer = Timer(const Duration(seconds: 30), () {
      if (!result.isCompleted) {
        result.completeError(
          const NfcAttendanceException(
            'No card was detected. Try scanning again.',
          ),
        );
      }
    });

    try {
      final values = await Future.wait<dynamic>([
        NfcManager.instance.startSession(
          pollingOptions: {NfcPollingOption.iso14443},
          onDiscovered: (tag) async {
            if (!active || processing || result.isCompleted) {
              return;
            }

            processing = true;

            try {
              _check(operation, owner);

              final android = NfcTagAndroid.from(tag);
              final ndef = NdefAndroid.from(tag);

              if (android == null || ndef == null) {
                throw const NfcAttendanceException(
                  'This is not a readable NDEF card.',
                );
              }

              final message = await ndef.getNdefMessage();

              _check(operation, owner);

              if (message == null || message.records.length != 1) {
                throw const NfcAttendanceException(
                  'Use the assigned attendance card.',
                );
              }

              final record = message.records.single;
              final bytes = record.payload;

              if (record.typeNameFormat != TypeNameFormat.wellKnown ||
                  record.type.length != 1 ||
                  record.type.first != 0x54 ||
                  bytes.isEmpty ||
                  (bytes.first & 0xc0) != 0 ||
                  1 + (bytes.first & 0x3f) > bytes.length) {
                throw const NfcAttendanceException('Unsupported card record.');
              }

              final payload = utf8.decode(
                bytes.sublist(1 + (bytes.first & 0x3f)),
              );

              if (!RegExp(r'^COMPTECH:NFC:CARD:V1:[0-9a-f]{64}$')
                  .hasMatch(payload)) {
                throw const NfcAttendanceException(
                  'This card has no attendance token.',
                );
              }

              if (!result.isCompleted) {
                result.complete({
                  'ndef_payload': payload,
                  'card_uid': android.id
                      .map((b) => b.toRadixString(16).padLeft(2, '0'))
                      .join(),
                });
              }
            } catch (error, stack) {
              if (!result.isCompleted) {
                result.completeError(error, stack);
              }
            }
          },
        ),
        result.future,
      ], eagerError: true);

      return Map<String, String>.from(values[1] as Map);
    } finally {
      active = false;
      timer.cancel();

      if (identical(_scan, result)) {
        _scan = null;
      }
    }
  }

  // Read-only: this path never calls scan, writes NDEF, or changes database rows.
  Future<void> _diagnoseCard() => _perform((operation) async {
    final owner = _service.accountId;
    setState(() {
      _cardReport = null;
      _message =
          'Read-only card check: hold the physical card against this phone. '
          'No attendance will be recorded and no card data will be changed.';
    });
    final card = await _readCard(operation, owner);
    _check(operation, owner);
    await _stopNfc();
    _check(operation, owner);
    const prefix = 'COMPTECH:NFC:CARD:V1:';
    final token = card['ndef_payload']!.substring(prefix.length);
    // Match the existing Edge Function: hash the UTF-8 token text, not decoded
    // hex bytes, and not the complete NDEF payload including the prefix.
    final tokenHash = sha256.convert(utf8.encode(token)).toString();
    final report = const JsonEncoder.withIndent('  ').convert({
      'card_uid': card['card_uid'],
      'card_token_hash': tokenHash,
      'payload_format_valid': true,
      'uid_format_valid':
          RegExp(r'^[0-9a-f]{8,32}$').hasMatch(card['card_uid']!) &&
          card['card_uid']!.length.isEven,
      'read_only': true,
    });
    setState(() {
      _cardReport = report;
      _message =
          'Card read successfully. Remove it now. Copy Card Details and '
          'send the report so we can compare it with the database. '
          'The raw token is not displayed. No registration or attendance was changed.';
    });
  });

  Future<void> _copyCardReport() async {
    final report = _cardReport;
    if (report == null) {
      return;
    }
    await Clipboard.setData(ClipboardData(text: report));
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Read-only card details copied.')),
    );
  }

  Future<void> _scanCardOnce(int operation, String owner) async {
    final sessionId = _sessionId!;

    setState(() {
      _message = 'Hold the student’s assigned card against this phone.';
    });

    final card = await _readCard(operation, owner);

    _check(operation, owner);
    await _stopNfc();
    _check(operation, owner);

    _pop('Card detected. Waiting for the student phone…', _Pop.detected);
    setState(() {
      _message =
          'Card read. Remove it while the student phone '
          'verifies attendance.';
    });

    final result = await _service.call('scan', {
      ...card,
      'session_id': sessionId,
    });

    _check(operation, owner);

    if (result['attendance'] is Map) {
      setState(() {
        _message =
            'Attendance was already recorded for this student/session. '
            'No duplicate was created.';
      });
      _pop('Already recorded. No duplicate was created.', _Pop.info);
      return;
    }

    final challenge = result['challenge_id'];

    if (challenge is! String ||
        !NfcAttendanceService.uuid.hasMatch(challenge)) {
      throw const NfcAttendanceException('Invalid scan response.');
    }

    final deadline = DateTime.now().add(const Duration(seconds: 65));

    while (DateTime.now().isBefore(deadline)) {
      _check(operation, owner);

      final status = await _service.call('scan_status', {
        'challenge_id': challenge,
      });

      _check(operation, owner);

      if (status['attendance'] is Map) {
        setState(() {
          _message =
              'Attendance recorded successfully. The student can '
              'view it in Attendance History.';
        });
        _pop('Recorded as present.', _Pop.recorded);
        return;
      }

      setState(() {
        _message =
            'Waiting for the registered student phone. '
            'Keep its attendance screen open.';
      });

      await Future<void>.delayed(const Duration(seconds: 2));
    }

    throw const NfcAttendanceException(
      'The scan was not confirmed in time. '
      'Check student history before retrying.',
    );
  }

  Future<void> _scanPhoneOnce(int operation, String owner) async {
    final sessionId = _sessionId!;
    await _stopNfc();
    _check(operation, owner);
    setState(() {
      _message = 'Ask the student to enable Tap Phone. Hold the backs of both unlocked phones together until the signature is read.';
    });
    final identity = await _phoneReader.readIdentity();
    _check(operation, owner);
    _pop('Phone detected. Keep the phones together.', _Pop.detected);
    setState(
      () => _message = 'Phone detected. Keep both phones together while the server prepares the challenge.',
    );
    Map<String, dynamic> begin;
    try {
      begin = await _service.call('phone_begin', {
        ...identity,
        'session_id': sessionId,
      });
    } catch (error) {
      // Lost internet mid-tap: finish this tap offline, phones still together.
      if (error is NfcAttendanceException &&
          error.code.isNotEmpty &&
          error.code != 'FUNCTION_REQUEST_FAILED') {
        rethrow;
      }
      if (!await _loadOffline(owner)) rethrow;
      _check(operation, owner);
      setState(() => _sessionId = sessionId);
      await _scanPhoneOffline(operation, owner, identity: identity);
      return;
    }
    _check(operation, owner);
    if (begin['attendance'] is Map) {
      await _phoneReader.stop();
      _check(operation, owner);
      setState(
        () => _message = 'Attendance is already recorded for this student and session. No duplicate was created.',
      );
      _pop('Already recorded. No duplicate was created.', _Pop.info);
      return;
    }
    final challengeId = begin['challenge_id'], message = begin['message'];
    if (challengeId is! String ||
        !NfcAttendanceService.uuid.hasMatch(challengeId) ||
        message is! String) {
      throw const NfcAttendanceException('Invalid phone challenge response.');
    }
    final signature = await _phoneReader.sign(message);
    _check(operation, owner);
    setState(
      () => _message =
          'Signature read. The phones can be separated. Saving attendance…',
    );
    Map<String, dynamic> result;
    try {
      result = await _service.call('phone_complete', {
        'challenge_id': challengeId,
        'signature': signature,
      });
    } catch (_) {
      _check(operation, owner);
      // Recover a committed attendance whose response was lost; never invent success.
      try {
        final recovered = await _service.call('phone_status', {
          'challenge_id': challengeId,
        });
        _check(operation, owner);
        if (recovered['attendance'] is Map) {
          NfcAttendanceService.notifyChanged();
          setState(
            () => _message = 'Phone attendance recorded. The student can view Attendance History.',
          );
          _pop('Recorded as present.', _Pop.recorded);
          return;
        }
      } catch (_) {
        /* Keep the original submission error. */
      }
      rethrow;
    }
    _check(operation, owner);
    if (result['attendance'] is! Map) {
      throw const NfcAttendanceException(
        'Attendance was not confirmed. Check student history before retrying.',
      );
    }
    NfcAttendanceService.notifyChanged();
    setState(
      () => _message =
          'Phone attendance recorded. The student can view Attendance History.',
    );
    _pop('Recorded as present.', _Pop.recorded);
  }

  static String _points(dynamic value) {
    if (value is! num) return '—';
    return value == value.roundToDouble()
        ? value.toStringAsFixed(0)
        : value.toString();
  }

  /// comptech_performance_points: without [points] it only identifies the
  /// student and lists the term's hands-on columns with their scores; with
  /// [points] it saves into the column [assessmentId], replacing the score.
  Future<Map<String, dynamic>> _performancePoints(
    Map<String, dynamic> student, {
    num? points,
    String? assessmentId,
    String? note,
  }) async {
    try {
      final data = await _service.client
          .rpc('comptech_performance_points', params: {
            'p_class_id': _classId,
            'p_term': _term,
            ...student,
            'p_assessment_id': assessmentId,
            'p_points': points,
            'p_note': note,
          })
          .timeout(const Duration(seconds: 20));
      if (data is! Map) {
        throw const NfcAttendanceException(
          'The server returned an invalid response.',
        );
      }
      return Map<String, dynamic>.from(data);
    } on PostgrestException catch (error) {
      final code = error.code == 'PGRST202' ? 'SETUP_REQUIRED' : error.message;
      throw NfcAttendanceException(switch (code) {
        'CARD_NOT_RECOGNIZED' => "This card isn't assigned to a student.",
        'NOT_ENROLLED' => "This student isn't enrolled in the selected class.",
        'CLASS_NOT_OWNED' => 'Select one of your own classes.',
        'COLUMN_NOT_FOUND' =>
          'That hands-on column no longer exists. Scan again and pick another.',
        'SETUP_REQUIRED' =>
          "Performance mode isn't up to date in the database. Run the latest "
              '20261104020000_performance_points.sql in Supabase.',
        _ => 'Points could not be saved. Check the connection and try again.',
      }, code);
    } on TimeoutException {
      throw const NfcAttendanceException(
        'The server took too long. Check the connection and scan again.',
      );
    }
  }

  /// Performance mode: identify the student, then ask for their points.
  Future<void> _scanPerformanceOnce(int operation, String owner) async {
    final Map<String, dynamic> student;
    if (_mode == _ScanMode.card) {
      setState(() => _message = 'Hold the student’s card against this phone.');
      final card = await _readCard(operation, owner);
      _check(operation, owner);
      await _stopNfc();
      student = {
        'p_card_uid': card['card_uid'],
        'p_card_payload': card['ndef_payload'],
      };
    } else {
      await _stopNfc();
      _check(operation, owner);
      setState(() => _message = 'Ask the student to enable Tap Phone, then '
          'hold the backs of both phones together.');
      final identity = await _phoneReader.readIdentity();
      _check(operation, owner);
      await _phoneReader.stop();
      student = {'p_student_id': identity['student_id']};
    }

    _pop('Student detected. Loading their scores…', _Pop.detected);
    final preview = await _performancePoints(student);
    _check(operation, owner);

    // Columns are created on the professor dashboard, never here.
    final columns = (preview['columns'] as List? ?? const [])
        .map((row) => Map<String, dynamic>.from(row as Map))
        .toList();
    if (columns.isEmpty) {
      final term = _term == 'final' ? 'Finals' : 'Midterm';
      final none = 'This class has no $term hands-on columns yet. Add one on '
          'the dashboard (Records → $term ACTIVITIES/Projects), then scan '
          'again.';
      setState(() => _message = none);
      _pop(none, _Pop.info);
      return;
    }

    final entry = await _askPoints(preview, columns);
    _check(operation, owner);
    if (entry == null) {
      final skipped = 'No points saved for ${preview['student_name']}.';
      setState(() => _message = '$skipped Ready for the next student.');
      _pop(skipped, _Pop.info);
      return;
    }

    _lastColumn['$_classId:$_term'] = entry.$2;
    final result = await _performancePoints(
      student,
      points: entry.$1,
      assessmentId: entry.$2,
      note: entry.$3,
    );
    _check(operation, owner);
    final saved = '${result['student_name']}: ${_points(result['score'])} / '
        '${_points(result['max_score'])} in ${result['assessment_title']}';
    setState(() => _message = 'Saved. $saved. Ready for the next student.');
    _pop('Saved. $saved', _Pop.recorded);
  }

  /// The points window: the student, a picker of the term's existing
  /// hands-on columns with the student's current score in the chosen one,
  /// the points (they replace that score) and an optional note.
  /// Returns (points, column id, note).
  Future<(num, String, String?)?> _askPoints(
    Map<String, dynamic> preview,
    List<Map<String, dynamic>> columns,
  ) {
    final controller = TextEditingController();
    final notes = TextEditingController();
    final remembered = _lastColumn['$_classId:$_term'];
    // Starts on the column picked last time, else the newest one.
    var columnId = columns.any((c) => c['id'] == remembered)
        ? remembered!
        : columns.last['id'] as String;
    String? error;

    Map<String, dynamic> chosen() =>
        columns.firstWhere((c) => c['id'] == columnId);

    // Labelled line in the window, e.g. "Student ID   2023123456".
    Widget detail(String label, String value) => Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 84,
            child: Text(
              label,
              style: TextStyle(color: secondaryTextColor, fontSize: 13),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                color: AppColors.text,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );

    return showDialog<(num, String, String?)>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialog) {
          final column = chosen();
          final current = column['current_score'];
          final max = column['max_score'];
          final earlierNotes = (column['remarks'] ?? '').toString().trim();

          void submit() {
            final points = num.tryParse(controller.text.trim());
            if (points == null || points < 0) {
              setDialog(() => error = 'Enter the points (0 or more).');
              return;
            }
            // Notes are optional.
            final note = notes.text.trim();
            Navigator.pop(
              dialogContext,
              (points, columnId, note.isEmpty ? null : note),
            );
          }

          return AlertDialog(
            backgroundColor: cardColor,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            title: Text(
              'Hands-on points',
              style: TextStyle(color: AppColors.text),
            ),
            // A fixed width: the dialog otherwise asks its content for its
            // natural width, which the column dropdown (a LayoutBuilder)
            // can't give, and the window fails to appear.
            content: SizedBox(
              width: double.maxFinite,
              child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  detail('Name', '${preview['student_name'] ?? '—'}'),
                  detail('Student ID', '${preview['student_number'] ?? '—'}'),
                  Divider(color: borderColor, height: 20),
                  AppDropdown<String>(
                    value: columnId,
                    isExpanded: true,
                    dropdownColor: cardColor,
                    borderRadius: BorderRadius.circular(16),
                    style: TextStyle(color: AppColors.text, fontSize: 14),
                    decoration: InputDecoration(
                      labelText: 'Hands-on column',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    items: [
                      for (final c in columns)
                        DropdownMenuItem<String>(
                          value: c['id'] as String,
                          child: Text(
                            '${c['title']}',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: (value) {
                      if (value != null) setDialog(() => columnId = value);
                    },
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Current score: ${_points(current)} / ${_points(max)}',
                    style: TextStyle(color: secondaryTextColor),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: controller,
                    autofocus: true,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    style: TextStyle(color: AppColors.text),
                    decoration: InputDecoration(
                      labelText: 'Points',
                      errorText: error,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    onSubmitted: (_) => submit(),
                  ),
                  if (current != null) ...[
                    const SizedBox(height: 6),
                    Text(
                      'Replaces the current score (${_points(current)}).',
                      style: TextStyle(color: secondaryTextColor, fontSize: 12),
                    ),
                  ],
                  const SizedBox(height: 16),
                  if (earlierNotes.isNotEmpty) ...[
                    Text(
                      'Earlier notes',
                      style: TextStyle(color: secondaryTextColor, fontSize: 12),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      earlierNotes,
                      style: TextStyle(color: AppColors.text, fontSize: 13),
                    ),
                    const SizedBox(height: 12),
                  ],
                  TextField(
                    controller: notes,
                    minLines: 2,
                    maxLines: 4,
                    maxLength: 200,
                    textCapitalization: TextCapitalization.sentences,
                    style: TextStyle(color: AppColors.text),
                    decoration: InputDecoration(
                      labelText: 'Notes (optional)',
                      alignLabelWithHint: true,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                  Text(
                    'Kept between 0 and ${_points(max)}. New columns are '
                    'added on the professor dashboard.',
                    style: TextStyle(color: secondaryTextColor, fontSize: 12),
                  ),
                ],
              ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Skip'),
              ),
              FilledButton(onPressed: submit, child: const Text('Save')),
            ],
          );
        },
      ),
    );
  }

  void _cancelScan() {
    ++_operation;
    final scan = _scan;
    if (scan != null && !scan.isCompleted) {
      scan.completeError(const NfcAttendanceException('Scan stopped.'));
    }
    unawaited(_stopNfc());
    setState(() {
      _busy = false;
      _scanning = false;
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Only actually leaving the app stops scanning. 'inactive' is a brief
    // pause that doesn't mean that: Android pauses the app for a moment each
    // time an NFC tag is delivered to it (e.g. a card still on the phone
    // after it was read), and for the notification shade. Treating that as
    // an interruption cancelled scans whose attendance was then recorded.
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.resumed) {
      return;
    }
    if (_busy) {
      ++_operation;

      final scan = _scan;

      if (scan != null && !scan.isCompleted) {
        scan.completeError(const NfcAttendanceException('Scan interrupted.'));
      }

      unawaited(_stopNfc());

      if (mounted) {
        setState(() {
          _busy = false;
          _scanning = false;
          _message =
              'Scanner interrupted. A submitted challenge may still '
              'complete; check history before retrying.';
        });
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    ++_operation;

    final scan = _scan;

    if (scan != null && !scan.isCompleted) {
      scan.completeError(const NfcAttendanceException('Scanner closed.'));
    }

    unawaited(_stopNfc());

    unawaited(_authSubscription?.cancel());

    super.dispose();
  }

  String _sessionLabel(Map<String, dynamic> session) {
    final started = DateTime.tryParse('${session['started_at'] ?? ''}');
    if (started == null) {
      return 'Session ${session['session_id'].toString().substring(0, 8)}';
    }
    return 'Started ${TimeOfDay.fromDateTime(started.toLocal()).format(context)}';
  }

  InputDecoration _fieldDecoration(String label) {
    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: BorderSide(color: borderColor),
    );
    return InputDecoration(
      labelText: label,
      labelStyle: TextStyle(color: secondaryTextColor, fontSize: 13),
      filled: true,
      fillColor: cardColor,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      border: border,
      enabledBorder: border,
      disabledBorder: border,
      focusedBorder: border.copyWith(
        borderSide: BorderSide(color: accentColor),
      ),
    );
  }

  Widget _buildModeToggle() {
    return _buildSegments<_ScanMode>(
      segments: const [
        ButtonSegment(
          value: _ScanMode.phone,
          icon: Icon(Icons.phonelink_ring),
          label: Text('Tap Phone'),
        ),
        ButtonSegment(
          value: _ScanMode.card,
          icon: Icon(Icons.credit_card),
          label: Text('Use Card'),
        ),
      ],
      selected: _mode,
      onChanged: (value) => setState(() => _mode = value),
    );
  }

  Widget _buildPurposeToggle() {
    return _buildSegments<_Purpose>(
      segments: const [
        ButtonSegment(
          value: _Purpose.attendance,
          icon: Icon(Icons.how_to_reg_outlined),
          label: Text('Attendance'),
        ),
        ButtonSegment(
          value: _Purpose.performance,
          icon: Icon(Icons.star_outline_rounded),
          label: Text('Performance'),
        ),
      ],
      selected: _purpose,
      onChanged: (value) => setState(() => _purpose = value),
    );
  }

  Widget _buildTermToggle() {
    return _buildSegments<String>(
      segments: const [
        ButtonSegment(value: 'midterm', label: Text('Midterm')),
        ButtonSegment(value: 'final', label: Text('Finals')),
      ],
      selected: _term,
      onChanged: (value) => setState(() => _term = value),
    );
  }

  /// The scanner's toggle style, shared by every toggle on this screen.
  Widget _buildSegments<T>({
    required List<ButtonSegment<T>> segments,
    required T selected,
    required ValueChanged<T> onChanged,
  }) {
    return SegmentedButton<T>(
      segments: segments,
      selected: {selected},
      onSelectionChanged: _busy || _scanning
          ? null
          : (selection) => onChanged(selection.single),
      style: ButtonStyle(
        minimumSize: const WidgetStatePropertyAll(Size.fromHeight(52)),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
        side: WidgetStatePropertyAll(BorderSide(color: borderColor)),
        backgroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? buttonColor
              : cardColor,
        ),
        foregroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.disabled)
              ? secondaryTextColor
              : states.contains(WidgetState.selected)
              ? Colors.white
              : AppColors.text,
        ),
      ),
    );
  }

  Widget _buildPickers() {
    final classPicker = AppDropdown<String>(
      key: ValueKey('class:${_classId ?? "none"}'),
      initialValue: _classId,
      isExpanded: true,
      dropdownColor: cardColor,
      // The list that opens has rounded corners like the cards.
      borderRadius: BorderRadius.circular(16),
      style: TextStyle(color: AppColors.text, fontSize: 14),
      decoration: _fieldDecoration('Select Class'),
      items: _classes.map((c) {
        return DropdownMenuItem<String>(
          value: c['class_id'] as String,
          child: Text(
            '${c['subject']} • ${c['section']}',
            overflow: TextOverflow.ellipsis,
          ),
        );
      }).toList(),
      onChanged: _busy
          ? null
          : (value) {
              setState(() {
                _classId = value;
                _sessionId = _sessions.isEmpty
                    ? null
                    : _sessions.first['session_id'] as String;
              });
              // Fetch this class's sessions again, so one started on the
              // dashboard since the list loaded shows up.
              if (!_offline) unawaited(_perform((_) => _load()));
            },
    );
    final sessionPicker = AppDropdown<String>(
      key: ValueKey('session:${_sessionId ?? "none"}'),
      initialValue: _sessionId,
      isExpanded: true,
      dropdownColor: cardColor,
      // The list that opens has rounded corners like the cards.
      borderRadius: BorderRadius.circular(16),
      style: TextStyle(color: AppColors.text, fontSize: 14),
      decoration: _fieldDecoration('Active Session'),
      hint: Text(
        'None',
        style: TextStyle(color: secondaryTextColor, fontSize: 14),
      ),
      items: _sessions.map((s) {
        return DropdownMenuItem<String>(
          value: s['session_id'] as String,
          child: Text(_sessionLabel(s), overflow: TextOverflow.ellipsis),
        );
      }).toList(),
      onChanged: _busy ? null : (value) => setState(() => _sessionId = value),
    );
    // Performance mode: no session, but which term the points are for.
    if (_purpose == _Purpose.performance) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          classPicker,
          const SizedBox(height: 12),
          _buildTermToggle(),
        ],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: classPicker),
        const SizedBox(width: 8),
        Expanded(child: sessionPicker),
      ],
    );
  }

  Widget _buildScanButton() {
    final enabled = _scanning || (!_busy && _authorized && _classId != null);
    return FilledButton.icon(
      onPressed: enabled ? _toggleScanning : null,
      icon: Icon(_scanning ? Icons.stop_circle_outlined : Icons.nfc),
      label: Text(_scanning ? 'End scanning' : 'Start scanning'),
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(52),
        backgroundColor: _scanning ? Colors.redAccent.shade200 : buttonColor,
        foregroundColor: Colors.white,
        disabledBackgroundColor: borderColor,
        disabledForegroundColor: secondaryTextColor,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
      ),
    );
  }

  /// Taps saved offline that are still waiting, and any the server refused.
  Widget _buildOfflineQueue() {
    return ValueListenableBuilder<List<Map<String, dynamic>>>(
      valueListenable: _offlineQueue.pending,
      builder: (context, pending, _) {
        final taps = pending.where((i) => i['kind'] == 'phone_tap').length;
        final refused = _offlineQueue.refused.value
            .where((i) => i['kind'] == 'phone_tap')
            .toList();
        if (taps == 0 && refused.isEmpty) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Divider(color: borderColor),
              if (taps > 0)
                Row(
                  children: [
                    Icon(Icons.cloud_upload_outlined, color: accentColor, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '$taps phone ${taps == 1 ? 'tap' : 'taps'} waiting to upload',
                        style: TextStyle(color: AppColors.text),
                      ),
                    ),
                    TextButton(
                      onPressed: () => _offlineQueue.sync(),
                      child: const Text('Upload now'),
                    ),
                  ],
                ),
              for (final item in refused)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    'A saved tap was not accepted: '
                    '${OfflineAttendanceService.explain(item['code'] as String?)}.',
                    style: TextStyle(color: AppColors.warning, fontSize: 12),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  /// Saved offline taps and read card details, shown only when there are any.
  Widget _buildExtras() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildOfflineQueue(),
        if (_cardReport != null)
          Container(
            margin: const EdgeInsets.only(top: 20),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: cardColor,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: borderColor),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SelectableText(
                  _cardReport!,
                  style: TextStyle(color: secondaryTextColor, fontSize: 12),
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: _busy ? null : _copyCardReport,
                    icon: const Icon(Icons.copy, size: 18),
                    label: const Text('Copy Card Details'),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: backgroundColor,
      appBar: AppBar(
        title: const Text('Professor NFC Scanner'),
        automaticallyImplyLeading: false,
        backgroundColor: backgroundColor,
        foregroundColor: AppColors.text,
        actions: [
          // Less frequent tools stay out of the main layout.
          PopupMenuButton<String>(
            enabled: !_busy,
            color: cardColor,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            onSelected: (value) {
              switch (value) {
                case 'details':
                  _diagnoseCard();
                case 'refresh':
                  _perform((_) => _load());
                case 'end':
                  _closeSession();
                case 'logout':
                  _logout();
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'details',
                enabled: _authorized,
                child: const Text('Read card details (no changes)'),
              ),
              const PopupMenuItem(
                value: 'refresh',
                child: Text('Refresh classes & sessions'),
              ),
              PopupMenuItem(
                value: 'end',
                enabled: _sessionId != null,
                child: const Text('End session'),
              ),
              const PopupMenuItem(value: 'logout', child: Text('Log out')),
            ],
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 24, 16, 24),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 600),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (!_authorized) ...[
                    Text(
                      _busy
                          ? 'Checking professor access…'
                          : 'Professor access has not been verified.',
                      style: TextStyle(color: AppColors.text),
                    ),
                    const SizedBox(height: 12),
                    OutlinedButton(
                      onPressed: _busy ? null : () => _perform((_) => _load()),
                      child: const Text('Check Access Again'),
                    ),
                    const SizedBox(height: 16),
                    _buildNotice(),
                  ] else ...[
                    _buildPurposeToggle(),
                    const SizedBox(height: 12),
                    _buildModeToggle(),
                    const SizedBox(height: 16),
                    _buildNotice(),
                    const SizedBox(height: 16),
                    _buildPickers(),
                    const SizedBox(height: 16),
                    _buildScanButton(),
                    _buildExtras(),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
