import 'dart:async';
import 'package:flutter/material.dart';
import '../services/archived_classes_service.dart';
import '../services/attendance_location_service.dart';
import '../services/enrolled_classes_service.dart';
import '../services/offline_attendance_service.dart';
import '../services/nfc_attendance_service.dart';
import '../services/nfc_phone_service.dart';
import '../services/phone_nfc_tap_service.dart';
import 'nfc_phone_setup_screen.dart';
import '../theme/app_theme.dart';
import '../widgets/app_dropdown.dart';

/// One route for both NFC attendance methods. Backend protocols remain separate.
class NfcAttendanceScreen extends StatefulWidget {
  const NfcAttendanceScreen({super.key, this.initialTab = 0});

  final int initialTab;

  @override
  State<NfcAttendanceScreen> createState() => _NfcAttendanceScreenState();
}

class _NfcAttendanceScreenState extends State<NfcAttendanceScreen> {
  late int _selected;

  @override
  void initState() {
    super.initState();
    _selected = widget.initialTab == 1 ? 1 : 0;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('NFC Attendance'),
        backgroundColor: AppColors.background,
        foregroundColor: AppColors.text,
        surfaceTintColor: Colors.transparent,
      ),
      body: Column(
        children: [
          SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560),
                  child: SizedBox(
                    width: double.infinity,
                    child: SegmentedButton<int>(
                      segments: const [
                        ButtonSegment<int>(
                          value: 0,
                          icon: Icon(Icons.phonelink_ring),
                          label: Text('Tap Phone'),
                        ),
                        ButtonSegment<int>(
                          value: 1,
                          icon: Icon(Icons.credit_card),
                          label: Text('Use Card'),
                        ),
                      ],
                      selected: {_selected},
                      onSelectionChanged: (selection) {
                        setState(() => _selected = selection.single);
                      },
                      style: SegmentedButton.styleFrom(
                        foregroundColor: AppColors.text,
                        selectedForegroundColor: AppColors.selectedOnButton,
                        backgroundColor: AppColors.card,
                        selectedBackgroundColor: AppColors.button,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          // Only the visible panel is mounted. Switching away from the card panel
          // disposes it and closes its foreground readiness window.
          Expanded(
            child: _selected == 0
                ? const _PhoneNfcTapPanel(
              key: ValueKey('phone-panel'),
            )
                : const _NfcCardAttendancePanel(
              key: ValueKey('card-panel'),
            ),
          ),
        ],
      ),
    );
  }
}

class _PhoneNfcTapPanel extends StatefulWidget {
  const _PhoneNfcTapPanel({super.key});

  @override
  State<_PhoneNfcTapPanel> createState() => _PhoneNfcTapPanelState();
}

class _PhoneNfcTapPanelState extends State<_PhoneNfcTapPanel>
    with WidgetsBindingObserver {
  final _service = PhoneNfcTapService();
  final _location = AttendanceLocationService();

  Timer? _timer;
  Map<String, dynamic> _state = {};

  // Time of the last tap a location was sent for. The native status message
  // stays "NFC proof prepared." for the whole window, so taps are told apart
  // by `proof_at` instead.
  int? _lastProofAt;

  bool _busy = false;
  bool _refreshing = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_location.prepare());
    unawaited(_refresh());

    _timer = Timer.periodic(const Duration(seconds: 2), (_) {
      unawaited(_refresh());
    });
  }

  static bool _tapDetected(Map<String, dynamic> state) =>
      state['enabled'] == true &&
          (state['message'] ?? '').toString().startsWith('NFC proof prepared.');

  /// The professor's phone saves phone-tap attendance, so attach the location
  /// once the check-in exists; retry for about a minute.
  Future<void> _attachTapLocation() async {
    final offline = await OfflineAttendanceService.isOffline();
    final location = await _location.current(
      timeLimit: Duration(seconds: offline ? 30 : 5),
      lookupName: !offline,
    );
    if (location == null) return;
    // Signed now, so its time is the tap's, in case it has to wait.
    final signed = await OfflineAttendanceService.instance.signLocation(location);
    if (!offline &&
        await _location.attachToCheckIn(location, attempts: 12)) {
      return;
    }
    // No internet (here or on the professor's phone): send it later.
    if (signed != null) {
      await OfflineAttendanceService.instance.saveLocation(signed);
    }
  }

  Future<void> _refresh() async {
    if (_busy || _refreshing) return;

    _refreshing = true;

    try {
      final state = await _service.status();
      final proofAt = state['proof_at'];
      // Only recent taps: a tap from long before this screen opened may have
      // happened somewhere else.
      if (proofAt is int &&
          proofAt != _lastProofAt &&
          _tapDetected(state) &&
          DateTime.now().millisecondsSinceEpoch - proofAt <
              const Duration(minutes: 1).inMilliseconds) {
        unawaited(_attachTapLocation());
      }
      if (proofAt is int) _lastProofAt = proofAt;
      if (mounted) setState(() => _state = state);
    } catch (_) {
      if (mounted) {
        setState(() {
          _error =
          'Phone NFC is unavailable. Fully rebuild the Android app.';
        });
      }
    } finally {
      _refreshing = false;
    }
  }

  Future<void> _toggle() async {
    if (_busy) return;

    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      if (_state['enabled'] == true) {
        await _service.disable();
      } else {
        await _service.enable();
      }
    } on NfcAttendanceException catch (error) {
      // Turning it on checks the registered phone with the server.
      final offline = _state['enabled'] != true &&
          (error.code == 'FUNCTION_REQUEST_FAILED' ||
              await OfflineAttendanceService.isOffline());
      if (mounted) {
        setState(() => _error = offline
            ? 'Turning on Phone NFC needs internet. Turn it on while you '
                  'have signal; the tap itself then works offline for '
                  '10 minutes.'
            : error.message);
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = 'Could not change phone NFC. Check NFC is enabled, '
              'the phone supports HCE, and the latest Android code is installed.';
        });
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        await _refresh();
      }
    }
  }

  Future<void> _viewPhoneHistory() async {
    if (_busy) return;

    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      final data = await _service.registrationContext();
      // Archived classes aren't offered as subject choices.
      final classes = await ArchivedClassesService.withoutArchived(
        NfcAttendanceService.rows(data['classes']),
        idKey: 'class_id',
      );
      if (!mounted) return;

      if (classes.isEmpty) {
        setState(() {
          _error = 'Join a class to view attendance history.';
        });
        return;
      }

      final selected = await showModalBottomSheet<String>(
        context: context,
        showDragHandle: true,
        builder: (sheetContext) => SafeArea(
          child: SizedBox(
            height: 360,
            child: ListView(
              children: [
                const ListTile(title: Text('Select a class')),
                ...classes.map(
                      (row) => ListTile(
                    title: Text('${row['subject']} • ${row['section']}'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () {
                      Navigator.of(sheetContext).pop(
                        row['class_id'] as String,
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      );

      if (!mounted || selected == null) return;

      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => _NfcStudentHistoryScreen(classId: selected),
        ),
      );
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = error is NfcAttendanceException
              ? error.message
              : 'Could not load classes. Check your connection and try again.';
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_refresh());
    }
    // HCE runs natively. Leaving this page does not disable the tap window.
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final enabled = _state['enabled'] == true;

    // A local NFC response is not evidence that the server saved attendance.
    final tapDetected = _tapDetected(_state);

    final statusTitle = !enabled
        ? 'Phone NFC off'
        : tapDetected
        ? 'Phone tap detected'
        : 'Ready to tap';

    final statusMessage = tapDetected
        ? 'Your phone responded to the scanner. Check Attendance Result '
        'to see whether your attendance was recorded.'
        : 'Keep your phone unlocked and hold it against your professor’s '
        'phone after they start scanning.';

    final expires = _state['expires_at'];

    final remaining = expires is int
        ? ((expires - DateTime.now().millisecondsSinceEpoch) / 1000)
        .ceil()
        .clamp(0, 600)
        : 0;

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 8),
                Icon(
                  Icons.phonelink_ring,
                  size: 56,
                  color: AppColors.accent,
                ),
                const SizedBox(height: 24),
                const Text(
                  'Tap your phone',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 16),
                const Text(
                  'Enable phone NFC for ten minutes. Keep your phone unlocked '
                      'and tap a compatible professor reader. The app can stay '
                      'in the background during this window.\n\n'
                      'No internet? This still works. Keep this screen open '
                      'during the tap so your location is saved too; it is '
                      'sent once you are back online.',
                ),
                const SizedBox(height: 20),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      children: [
                        Text(
                          statusTitle,
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        if (enabled) ...[
                          const SizedBox(height: 12),
                          Text(
                            'Time remaining: ${remaining ~/ 60}:'
                                '${(remaining % 60).toString().padLeft(2, '0')}',
                          ),
                          const SizedBox(height: 12),
                          Text(statusMessage),
                        ],
                        if (_error != null) ...[
                          const SizedBox(height: 12),
                          Text(_error!),
                        ],
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Keep the phones together until the professor’s scanner '
                      'says you can separate them. Use Check Attendance Result '
                      'below to view your saved attendance.',
                ),
                const SizedBox(height: 20),
                ElevatedButton.icon(
                  onPressed: _busy ? null : _toggle,
                  icon: const Icon(Icons.nfc),
                  label: Text(
                    _busy
                        ? 'Checking…'
                        : enabled
                        ? 'Turn Off Phone NFC'
                        : 'Enable Phone NFC',
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: _busy ? null : _viewPhoneHistory,
                  icon: const Icon(Icons.history),
                  label: const Text('Check Attendance Result'),
                ),
                TextButton(
                  onPressed: _busy
                      ? null
                      : () async {
                    await Navigator.of(context).push<void>(
                      MaterialPageRoute<void>(
                        builder: (_) => const NfcPhoneSetupScreen(),
                      ),
                    );
                    if (mounted) await _refresh();
                  },
                  child: const Text('Phone Setup'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _NfcCardAttendancePanel extends StatefulWidget {
  const _NfcCardAttendancePanel({super.key});

  @override
  State<_NfcCardAttendancePanel> createState() =>
      _NfcCardAttendancePanelState();
}

class _NfcCardAttendancePanelState extends State<_NfcCardAttendancePanel>
    with WidgetsBindingObserver {
  final _service = NfcAttendanceService();
  final _phone = NfcPhoneService();
  final _location = AttendanceLocationService();

  List<Map<String, dynamic>> _sessions = [];
  // Every active session from the server; [_sessions] is the chosen class's.
  List<Map<String, dynamic>> _allSessions = [];
  // This screen's own class picker, so it never depends on another tab.
  List<Map<String, String>> _classes = [];
  String? _classId;
  Map<String, dynamic>? _context;
  String? _selected, _readyId, _owner;

  bool _working = false;
  bool _active = false;
  bool _foreground = true;
  bool _recorded = false;

  int _epoch = 0;
  String _message = 'Checking phone and card registration…';

  Timer? _countdown;
  DateTime? _expiresAt;
  int _secondsLeft = 0;
  String? _historyClassId;

  void _startCountdown(DateTime expiresAt) {
    _countdown?.cancel();
    _expiresAt = expiresAt;

    void tick() {
      if (!mounted || !_active) {
        _countdown?.cancel();
        return;
      }

      final milliseconds =
          expiresAt.difference(DateTime.now().toUtc()).inMilliseconds;

      if (milliseconds <= 0) {
        _stop();
        if (mounted) {
          setState(() {
            _message =
            'Readiness expired. Check Attendance History before starting again.';
          });
        }
        return;
      }

      setState(() => _secondsLeft = (milliseconds / 1000).ceil());
    }

    tick();

    if (_active) {
      _countdown = Timer.periodic(
        const Duration(seconds: 1),
            (_) => tick(),
      );
    }
  }

  Future<void> _viewHistory() async {
    final classId = _historyClassId;
    if (classId == null || _active || _working) return;

    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => _NfcStudentHistoryScreen(classId: classId),
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_location.prepare());
    unawaited(_load());
  }

  Future<void> _attachLocation(
      Future<AttendanceLocation?> pending,
      String sessionId,
      ) async {
    final location = await pending;
    if (location == null) return;
    await _location.attachToCheckIn(location, sessionId: sessionId, attempts: 3);
  }

  bool _current(int epoch, String owner) {
    return mounted &&
        _foreground &&
        epoch == _epoch &&
        _service.client.auth.currentUser?.id == owner;
  }

  Future<void> _closeWindow(String? ready, String? owner) async {
    if (ready == null || _service.client.auth.currentUser?.id != owner) {
      return;
    }

    try {
      await _service.call('stop', {'ready_id': ready});
    } catch (_) {
      // Server expiry is the fallback.
    }
  }

  void _stop({bool background = false}) {
    final ready = _readyId;
    final owner = _owner;

    ++_epoch;
    _active = false;
    _readyId = null;

    _countdown?.cancel();
    _expiresAt = null;
    _secondsLeft = 0;

    unawaited(_closeWindow(ready, owner));

    if (mounted) {
      setState(() {
        _working = false;
        _message = background
            ? 'Readiness stopped because this screen left the foreground. '
            'Check History if a submission was already in progress.'
            : 'Readiness stopped. Check History if a submission was already in progress.';
      });
    }
  }

  Future<void> _load() async {
    if (_working || _active) return;

    final epoch = ++_epoch;

    setState(() {
      _working = true;
      _recorded = false;
      _context = null;
      _sessions = [];
      _allSessions = [];
      _selected = null;
      _message = 'Checking phone and card registration…';
    });

    try {
      final owner = _service.accountId;
      final fp = await _service.prepareFingerprint();

      if (!_current(epoch, owner)) return;

      final results = await Future.wait<Object>([
        _service.call('student_context', {'key_fingerprint': fp}),
        EnrolledClassesService.load(),
      ]);
      final data = results[0] as Map<String, dynamic>;
      final joined = results[1] as List<Map<String, String>>;

      if (!_current(epoch, owner)) return;

      setState(() {
        _context = data;
        _allSessions = NfcAttendanceService.rows(data['sessions']);
        _classes = joined;
        // Keep the student's choice; with a single class there's nothing to pick.
        if (!joined.any((c) => c['id'] == _classId)) {
          _classId = joined.length == 1 ? joined.first['id'] : null;
        }
        _applyClass();
      });
    } catch (e) {
      if (mounted && epoch == _epoch) {
        setState(() {
          _message = e is NfcAttendanceException
              ? e.message
              : 'Could not check registration. Check your connection and '
              'rebuild the latest Android code.';
        });
      }
    } finally {
      if (mounted && epoch == _epoch) {
        setState(() => _working = false);
      }
    }
  }

  String _classLabel(Map<String, String> item) {
    final subject = item['subject'] ?? 'Unnamed subject';
    final section = item['section'] ?? '';
    return section.isEmpty ? subject : '$subject — $section';
  }

  /// Shows the chosen class's newest active session. Call inside setState.
  void _applyClass() {
    final chosen = _classes.where((c) => c['id'] == _classId).firstOrNull;
    _historyClassId = chosen?['id'];
    _recorded = false;

    if (chosen == null) {
      _sessions = [];
      _selected = null;
      _message = _classes.isEmpty
          ? 'Join a class to use card attendance.'
          : 'Select the class you are taking attendance for.';
      return;
    }

    final sessions =
        _allSessions.where((s) => s['class_id'] == chosen['id']).toList();

    // If multiple sessions are returned, choose the most recently started.
    sessions.sort((a, b) {
      final left = DateTime.tryParse(a['started_at']?.toString() ?? '');
      final right = DateTime.tryParse(b['started_at']?.toString() ?? '');

      return (right?.millisecondsSinceEpoch ?? 0)
          .compareTo(left?.millisecondsSinceEpoch ?? 0);
    });

    final label = _classLabel(chosen);
    _sessions = sessions;
    _selected =
        sessions.isEmpty ? null : sessions.first['session_id'] as String;
    _message = sessions.isEmpty
        ? 'No active attendance session for $label. '
        'Ask your professor to start attendance, then refresh.'
        : 'Enable readiness, then tap your card on the professor’s '
        'reader for $label.';
  }

  Widget _buildClassPicker() {
    final locked = _active || _working || _context == null;
    return Container(
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: AppDropdown<String>(
        outerPadding: 14,
        value: _classId,
        isExpanded: true,
        dropdownColor: AppColors.card,
        borderRadius: BorderRadius.circular(16),
        iconEnabledColor: AppColors.accent,
        iconDisabledColor: AppColors.secondaryText,
        style: TextStyle(color: AppColors.text, fontSize: 13),
        hint: Text(
          'Select a class',
          style: TextStyle(color: AppColors.secondaryText, fontSize: 13),
        ),
        items: _classes
            .map(
              (item) => DropdownMenuItem<String>(
                value: item['id'],
                child: Text(
                  _classLabel(item),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            )
            .toList(),
        onChanged: locked
            ? null
            : (value) {
                setState(() {
                  _classId = value;
                  _applyClass();
                });
                // The sessions were fetched when the screen opened; ask again
                // so one the professor started since then is found.
                unawaited(_load());
              },
      ),
    );
  }

  Future<void> _start() async {
    if (_working || _active || _context == null || _selected == null) {
      return;
    }

    final epoch = ++_epoch;
    final owner = _service.accountId;

    final session = Map<String, dynamic>.from(
      _sessions.firstWhere((s) => s['session_id'] == _selected),
    );
    final registration = Map<String, dynamic>.from(_context!);

    _historyClassId = session['class_id'] as String;

    setState(() {
      _working = true;
      _recorded = false;
      _message = 'Enabling attendance readiness…';
    });

    try {
      final data = await _service.call(
        'ready',
        {
          'session_id': session['session_id'],
          'card_id': registration['card_id'],
          'credential_id': registration['credential_id'],
        },
      );

      final ready = data['ready_id'];

      if (ready is! String || !NfcAttendanceService.uuid.hasMatch(ready)) {
        throw const NfcAttendanceException('Invalid readiness response.');
      }

      if (!_current(epoch, owner)) {
        unawaited(_closeWindow(ready, owner));
        return;
      }

      final expiry = DateTime.tryParse(
        data['expires_at']?.toString() ?? '',
      );

      if (expiry == null) {
        unawaited(_closeWindow(ready, owner));
        throw const NfcAttendanceException(
          'Invalid readiness expiry. Refresh and try again.',
        );
      }

      _owner = owner;
      _readyId = ready;

      setState(() {
        _active = true;
        _working = false;
        _message = 'Ready to scan. Tap your card on the professor’s reader. '
            'Keep this screen open and connected.';
      });

      _startCountdown(expiry.toUtc());

      if (_active) {
        unawaited(_poll(epoch, owner, ready, session, registration));
      }
    } catch (e) {
      if (mounted && epoch == _epoch) {
        setState(() {
          _recorded = e is NfcAttendanceException &&
              e.code == 'ATTENDANCE_ALREADY_RECORDED';

          _message = _recorded
              ? 'Attendance already recorded. You may now be scanned for '
                  'Hands-on grading.'
              : e is NfcAttendanceException
              ? e.message
              : 'Could not enable readiness. Check your connection.';
        });
      }
    } finally {
      if (mounted && epoch == _epoch) {
        setState(() => _working = false);
      }
    }
  }

  Future<void> _poll(
      int epoch,
      String owner,
      String ready,
      Map<String, dynamic> session,
      Map<String, dynamic> registration,
      ) async {
    try {
      while (_current(epoch, owner) && _active) {
        final data = await _service.call('poll', {'ready_id': ready});

        if (!_current(epoch, owner) || !_active) return;

        if (data['attendance'] is Map) {
          _success();
          return;
        }

        final item = data['challenge'];

        if (item is Map) {
          final challenge = Map<String, dynamic>.from(item);
          final id = challenge['challenge_id'];
          final message = challenge['message'];

          if (id is! String ||
              !NfcAttendanceService.uuid.hasMatch(id) ||
              message is! String) {
            throw const NfcAttendanceException(
              'Invalid attendance challenge.',
            );
          }

          setState(() {
            _message = 'Card detected. Verifying this attendance attempt…';
          });

          // Read GPS while signing so the challenge isn't kept waiting.
          final pendingLocation = _location.current();

          final signature = await _phone.signAttendanceChallenge(
            studentId: owner,
            message: message,
            context: {
              'challenge_id': id,
              'ready_id': ready,
              'session_id': session['session_id'] as String,
              'class_id': session['class_id'] as String,
              'scanner_id': session['scanner_id'] as String,
              'card_id': registration['card_id'] as String,
              'credential_id': registration['credential_id'] as String,
            },
          );

          if (!_current(epoch, owner) || !_active) return;

          final result = await _service.call(
            'complete',
            {'challenge_id': id, 'signature': signature},
          );

          if (!_current(epoch, owner) || !_active) return;

          if (result['attendance'] is! Map) {
            throw const NfcAttendanceException(
              'The server did not confirm attendance.',
            );
          }

          unawaited(_attachLocation(
            pendingLocation,
            session['session_id'] as String,
          ));
          _success();
          return;
        }

        await Future<void>.delayed(const Duration(seconds: 2));
      }
    } catch (e) {
      if (!_current(epoch, owner) || !_active) return;

      // Recover an accepted submission whose response was lost.
      try {
        final recovered = await _service.call(
          'poll',
          {'ready_id': ready},
        );

        if (!_current(epoch, owner) || !_active) return;

        if (recovered['attendance'] is Map) {
          _success();
          return;
        }
      } catch (_) {
        // Keep the original failure.
      }

      if (!_current(epoch, owner) || !_active) return;

      _stop();

      if (mounted) {
        setState(() {
          _message = e is NfcAttendanceException
              ? e.message
              : 'Attendance was not confirmed. Check History before retrying. '
              'If this persists, fully rebuild the Android app.';
        });
      }
    }
  }

  void _success() {
    _active = false;
    _readyId = null;
    _countdown?.cancel();
    _expiresAt = null;
    _secondsLeft = 0;

    NfcAttendanceService.notifyChanged();

    if (mounted) {
      setState(() {
        _recorded = true;
        _message = 'Attendance recorded. You may now be scanned for '
            'Hands-on grading.';
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 'inactive' is a brief pause (notification shade, an NFC tag delivered
    // to the app), not leaving the screen, so readiness keeps running.
    _foreground = state == AppLifecycleState.resumed ||
        state == AppLifecycleState.inactive;

    if (!_foreground && (_active || _working)) {
      _stop(background: true);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    ++_epoch;
    _active = false;
    _countdown?.cancel();
    unawaited(_closeWindow(_readyId, _owner));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 8),
                Icon(
                  Icons.nfc_rounded,
                  size: 56,
                  color: AppColors.accent,
                ),
                const SizedBox(height: 20),
                const Text(
                  'Tap your card',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Keep this tab open and stay connected while your card is scanned.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                if (_classes.isNotEmpty) ...[
                  _buildClassPicker(),
                  const SizedBox(height: 20),
                ],
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      children: [
                        if (_working)
                          const CircularProgressIndicator()
                        else
                          Icon(
                            _recorded
                                ? Icons.check_circle_outline
                                : _active
                                ? Icons.wifi_tethering
                                : Icons.info_outline,
                            size: 32,
                          ),
                        const SizedBox(height: 16),
                        if (_active && _expiresAt != null) ...[
                          Text(
                            'Ready: '
                                '${(_secondsLeft ~/ 60).toString().padLeft(2, "0")}:'
                                '${(_secondsLeft % 60).toString().padLeft(2, "0")}',
                            style: const TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 12),
                        ],
                        Semantics(
                          liveRegion: true,
                          child: Text(
                            _message,
                            textAlign: TextAlign.center,
                            style: const TextStyle(height: 1.5),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                if (_active)
                  ElevatedButton(
                    onPressed: _stop,
                    child: const Text('Stop Readiness'),
                  )
                else if (_context != null &&
                    _selected != null &&
                    !_recorded)
                  ElevatedButton(
                    onPressed: _working ? null : _start,
                    child: const Text('Enable Attendance Readiness'),
                  ),
                if (_historyClassId != null) ...[
                  const SizedBox(height: 10),
                  OutlinedButton.icon(
                    onPressed: _active || _working ? null : _viewHistory,
                    icon: const Icon(Icons.history),
                    label: const Text('Attendance History'),
                  ),
                ],
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  onPressed: _active || _working ? null : _load,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Refresh'),
                ),
                if (!_active)
                  TextButton(
                    onPressed: _working
                        ? null
                        : () async {
                      await Navigator.of(context).push<void>(
                        MaterialPageRoute<void>(
                          builder: (_) => const NfcPhoneSetupScreen(),
                        ),
                      );

                      if (mounted) await _load();
                    },
                    child: const Text('Phone Setup'),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _NfcStudentHistoryScreen extends StatefulWidget {
  const _NfcStudentHistoryScreen({required this.classId});

  final String classId;

  @override
  State<_NfcStudentHistoryScreen> createState() =>
      _NfcStudentHistoryScreenState();
}

class _NfcStudentHistoryScreenState
    extends State<_NfcStudentHistoryScreen> {
  final _service = NfcAttendanceService();
  final _locationService = AttendanceLocationService();

  List<Map<String, dynamic>> _rows = [];
  List<Map<String, dynamic>> _locations = [];
  bool _loading = true;
  String? _error;
  int _version = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
  }

  Future<void> _refresh() async {
    final version = ++_version;

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final locationsFuture = _locationService
          .history(widget.classId)
          .catchError((_) => <Map<String, dynamic>>[]); // History still shows without locations.
      final rows = await _service.history(widget.classId);
      final locations = await locationsFuture;

      if (!mounted || version != _version) return;

      setState(() {
        _rows = rows;
        _locations = locations;
      });
    } catch (_) {
      if (!mounted || version != _version) return;

      setState(() {
        _error = 'Could not load attendance history. Tap Refresh to retry.';
      });
    } finally {
      if (mounted && version == _version) {
        setState(() => _loading = false);
      }
    }
  }

  @override
  void dispose() {
    ++_version;
    super.dispose();
  }

  String _date(dynamic value) {
    final date = DateTime.tryParse(value?.toString() ?? '')?.toLocal();

    if (date == null) return 'Time unavailable';

    String two(int n) => n.toString().padLeft(2, '0');

    return '${date.year}-${two(date.month)}-${two(date.day)} '
        '${two(date.hour)}:${two(date.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Attendance History'),
        actions: [
          IconButton(
            onPressed: _loading ? null : _refresh,
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(24),
          children: [
            if (_loading)
              const Center(child: CircularProgressIndicator())
            else if (_error != null)
              Text(_error!)
            else if (_rows.isEmpty)
                const Text(
                  'No attendance has been recorded for this class yet.',
                )
              else
                ..._rows.map(
                      (row) => Card(
                    child: ListTile(
                      leading: const Icon(Icons.event_available),
                      title: Text(
                        (row['status'] ?? 'Unknown').toString().toUpperCase(),
                      ),
                      subtitle: Text(
                        '${_date(row['check_in_time'] ?? row['session_started_at'])}\n'
                            '${AttendanceLocationService.describe(AttendanceLocationService.find(row, _locations))}',
                      ),
                      isThreeLine: true,
                    ),
                  ),
                ),
          ],
        ),
      ),
    );
  }
}