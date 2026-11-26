import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:nfc_manager/ndef_record.dart';
import 'package:nfc_manager/nfc_manager.dart';
import 'package:nfc_manager/nfc_manager_android.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/nfc_card_assignment_service.dart';
import '../theme/app_theme.dart';

class _PendingCardAssignment {
  const _PendingCardAssignment({
    required this.challenge,
    required this.previousPayload,
  });

  final NfcCardAssignmentChallenge challenge;

  // Contents observed before this attempt wrote its new token.
  // Null means the card was empty.
  final String? previousPayload;
}

class NfcAssignTagScreen extends StatefulWidget {
  const NfcAssignTagScreen({super.key});

  @override
  State<NfcAssignTagScreen> createState() =>
      _NfcAssignTagScreenState();
}

class _NfcAssignTagScreenState extends State<NfcAssignTagScreen>
    with WidgetsBindingObserver {
  static Color get backgroundColor => AppColors.background;
  static Color get cardColor => AppColors.card;
  static Color get accentColor => AppColors.accent;
  static Color get buttonColor => AppColors.button;
  static Color get borderColor => AppColors.border;
  static Color get secondaryTextColor => AppColors.secondaryText;

  static final _payloadPattern = RegExp(
    r'^COMPTECH:NFC:CARD:V1:[0-9a-f]{64}$',
  );

  final _service = NfcCardAssignmentService();
  final _preferences = SharedPreferencesAsync();

  bool _busy = false;
  bool _waitingForTag = false;
  bool _ready = false;
  bool _done = false;
  bool _hasPending = false;
  bool _interrupted = false;

  int _operation = 0;
  VoidCallback? _cancelWaiting;

  String _title = 'Checking your card status…';
  String _message = 'Please wait.';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_loadStatus());
  }

  String _storageKey(String studentId) {
    return 'comptech_nfc_card_assignment_v1_$studentId';
  }

  void _assertActive(int operation, String studentId) {
    if (!mounted ||
        operation != _operation ||
        _interrupted) {
      throw const NfcCardAssignmentException(
        'Setup was interrupted. Return to this screen '
            'and check the saved status before continuing.',
      );
    }

    _service.requireSameAccount(studentId);
  }

  void _showStatus(String title, String message) {
    if (!mounted) return;

    setState(() {
      _title = title;
      _message = message;
    });
  }

  Future<void> _stopNfc() async {
    try {
      await NfcManager.instance.stopSession();
    } catch (_) {
      // No active session may exist.
    }
  }

  Future<_PendingCardAssignment?> _loadPending(
      String studentId,
      ) async {
    final saved = await _preferences.getString(
      _storageKey(studentId),
    );

    if (saved == null) return null;

    try {
      if (saved.length > 16000) {
        throw const FormatException();
      }

      final decoded = jsonDecode(saved);

      if (decoded is! Map ||
          decoded['version'] != 1 ||
          decoded['challenge'] is! Map) {
        throw const FormatException();
      }

      final challenge = NfcCardAssignmentChallenge.fromJson(
        Map<String, dynamic>.from(decoded['challenge'] as Map),
      );

      final previous = decoded['previous_payload'];

      if (challenge.studentId != studentId ||
          (previous != null &&
              (previous is! String ||
                  !_payloadPattern.hasMatch(previous)))) {
        throw const FormatException();
      }

      return _PendingCardAssignment(
        challenge: challenge,
        previousPayload: previous as String?,
      );
    } catch (_) {
      throw const NfcCardAssignmentException(
        'The saved setup details could not be read. '
            'Keep your card unchanged so the setup can be checked.',
      );
    }
  }

  Future<void> _savePending(
      _PendingCardAssignment pending,
      ) async {
    final key = _storageKey(pending.challenge.studentId);
    final encoded = jsonEncode({
      'version': 1,
      'challenge': pending.challenge.toJson(),
      'previous_payload': pending.previousPayload,
    });

    await _preferences.setString(key, encoded);

    final saved = await _preferences.getString(key);

    if (saved != encoded) {
      throw const NfcCardAssignmentException(
        'Pending setup could not be saved. '
            'The card write was not started.',
      );
    }
  }

  Future<void> _clearPending(String studentId) async {
    try {
      await _preferences.remove(_storageKey(studentId));
    } catch (_) {
      // Server status remains authoritative.
    }
  }

  void _showExistingCard(NfcCardAssignmentStatus status) {
    if (!mounted) return;

    setState(() {
      _ready = false;
      _done = true;
      _hasPending = false;

      if (status.cardStatus == 'active') {
        _title = 'Your account has an active card';
        _message =
        'A card is already registered to your account.\n\n'
            'Open Use NFC for Attendance to select an active NFC test session.';
      } else {
        _title = 'A card record already exists';
        _message =
        'Your card status is ${status.cardStatus}.\n\n'
            'An authorized card replacement is required.';
      }
    });
  }

  Future<void> _loadStatus() async {
    if (_busy) return;

    final operation = ++_operation;
    _interrupted = false;

    setState(() {
      _busy = true;
      _ready = false;
      _done = false;
      _title = 'Checking your card status…';
      _message = 'Please wait.';
    });

    try {
      final studentId = _service.currentStudentId;

      final status = await _service.getStatus(
        studentId: studentId,
      );

      _assertActive(operation, studentId);

      if (status.tagAssigned) {
        _showExistingCard(status);
        return;
      }

      final pending = await _loadPending(studentId);

      _assertActive(operation, studentId);

      setState(() {
        _ready = true;
        _hasPending = pending != null;
        _title = pending == null
            ? 'Assign your attendance card'
            : 'Continue your card setup';
        _message = pending == null
            ? 'Tap Assign This Card, then hold your empty card '
            'against your phone.\n\n'
            'Keep it steady until you are told to remove it.'
            : 'A previous setup was not confirmed.\n\n'
            'Tap Continue Setup and use the same card. '
            'Its saved setup data will be checked before '
            'any further write.';
      });
    } on NfcCardAssignmentException catch (error) {
      _showStatus('Could not check card setup', error.message);
    } catch (_) {
      _showStatus(
        'Could not check card setup',
        'Check your connection and try checking the saved status again.',
      );
    } finally {
      if (mounted && operation == _operation) {
        setState(() => _busy = false);
      }
    }
  }

  String _cardUid(NfcTag tag) {
    final androidTag = NfcTagAndroid.from(tag);

    if (androidTag == null || androidTag.id.isEmpty) {
      throw const NfcCardAssignmentException(
        'The card UID could not be read.',
      );
    }

    return androidTag.id
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  String? _readPayload(NdefMessage? message) {
    if (message == null || message.records.isEmpty) {
      return null;
    }

    if (message.records.length != 1) {
      throw const NfcCardAssignmentException(
        'This card contains other data. It will not be overwritten.',
      );
    }

    final record = message.records.single;

    if (record.typeNameFormat == TypeNameFormat.empty &&
        record.type.isEmpty &&
        record.identifier.isEmpty &&
        record.payload.isEmpty) {
      return null;
    }

    final bytes = record.payload;

    if (record.typeNameFormat != TypeNameFormat.wellKnown ||
        record.type.length != 1 ||
        record.type.first != 0x54 ||
        bytes.isEmpty) {
      throw const NfcCardAssignmentException(
        'This card contains other data. It will not be overwritten.',
      );
    }

    final status = bytes.first;
    final languageLength = status & 0x3f;
    final textStart = 1 + languageLength;

    // Accept UTF-8 text only; reject reserved encoding bits.
    if ((status & 0xc0) != 0 || textStart > bytes.length) {
      throw const NfcCardAssignmentException(
        'The card text format is unsupported. '
            'Its data was not changed.',
      );
    }

    final text = utf8.decode(
      bytes.sublist(textStart),
      allowMalformed: false,
    );

    if (!_payloadPattern.hasMatch(text)) {
      throw const NfcCardAssignmentException(
        'This card contains other data. It will not be overwritten.',
      );
    }

    return text;
  }

  NdefMessage _buildMessage(String text) {
    return NdefMessage(
      records: [
        NdefRecord(
          typeNameFormat: TypeNameFormat.wellKnown,
          type: Uint8List.fromList([0x54]),
          identifier: Uint8List(0),
          payload: Uint8List.fromList([
            0x02, // UTF-8, two-byte language code.
            0x65, // e
            0x6e, // n
            ...utf8.encode(text),
          ]),
        ),
      ],
    );
  }

  Future<void> _scanAndProcess({
    required int operation,
    required String studentId,
    required Future<void> Function(NfcTag tag) action,
  }) async {
    final availability =
    await NfcManager.instance.checkAvailability();

    _assertActive(operation, studentId);

    if (availability != NfcAvailability.enabled) {
      throw const NfcCardAssignmentException(
        'Enable NFC in your phone settings and try again.',
      );
    }

    final completion = Completer<void>();
    var processing = false;
    var active = true;
    Timer? timer;

    void cancelWaiting() {
      if (active && !processing && !completion.isCompleted) {
        completion.completeError(
          const NfcCardAssignmentException(
            'The scan was cancelled. '
                'Any saved pending setup has been retained.',
          ),
        );
      }
    }

    _cancelWaiting = cancelWaiting;

    setState(() {
      _waitingForTag = true;
      _title = 'Hold your card near your phone';
      _message =
      'Keep the card steady against the NFC antenna '
          'until this screen tells you to remove it.';
    });

    timer = Timer(const Duration(seconds: 30), () {
      if (active && !processing && !completion.isCompleted) {
        completion.completeError(
          const NfcCardAssignmentException(
            'No card was detected. Try another position '
                'behind your phone.',
          ),
        );
      }
    });

    try {
      await Future.wait<void>(
        [
          NfcManager.instance.startSession(
            pollingOptions: {
              NfcPollingOption.iso14443,
            },
            onDiscovered: (tag) async {
              if (!active || processing || completion.isCompleted) {
                return;
              }

              processing = true;
              timer?.cancel();

              if (mounted && operation == _operation) {
                setState(() => _waitingForTag = false);
              }

              try {
                _assertActive(operation, studentId);
                await action(tag);

                if (!completion.isCompleted) {
                  completion.complete();
                }
              } catch (error, stack) {
                if (!completion.isCompleted) {
                  completion.completeError(error, stack);
                }
              }
            },
          ),
          completion.future,
        ],
        eagerError: true,
      );
    } finally {
      active = false;
      timer.cancel();
      _cancelWaiting = null;

      if (mounted && operation == _operation) {
        setState(() => _waitingForTag = false);
      }

      await _stopNfc();
    }
  }

  Future<bool> _checkForCompletedAssignment(
      int operation,
      String studentId,
      ) async {
    if (!mounted ||
        operation != _operation ||
        _interrupted) {
      return false;
    }

    try {
      final status = await _service.getStatus(
        studentId: studentId,
      );

      _assertActive(operation, studentId);

      if (!status.tagAssigned) return false;

      _showExistingCard(status);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _assignCard() async {
    if (_busy || !_ready || _done) return;

    final operation = ++_operation;
    _interrupted = false;

    String? studentId;

    setState(() {
      _busy = true;
      _title = 'Checking your saved status…';
      _message = 'Keep this screen open during setup.';
    });

    try {
      final id = _service.currentStudentId;
      studentId = id;

      final status = await _service.getStatus(studentId: id);

      _assertActive(operation, id);

      if (status.tagAssigned) {
        _showExistingCard(status);
        return;
      }

      final previousAttempt = await _loadPending(id);

      _assertActive(operation, id);

      await _scanAndProcess(
        operation: operation,
        studentId: id,
        action: (tag) async {
          final uid = _cardUid(tag);
          final ndef = NdefAndroid.from(tag);

          if (ndef == null) {
            throw const NfcCardAssignmentException(
              'This card does not expose NDEF storage. '
                  'No write was started.',
            );
          }

          final originalPayload = _readPayload(
            await ndef.getNdefMessage(),
          );

          _assertActive(operation, id);

          if (previousAttempt == null) {
            if (originalPayload != null) {
              throw const NfcCardAssignmentException(
                'This card already contains a token, but this '
                    'phone has no matching pending setup. '
                    'It will not be overwritten.',
              );
            }
          } else {
            if (uid != previousAttempt.challenge.cardUid) {
              throw const NfcCardAssignmentException(
                'Use the same card from your pending setup.',
              );
            }

            if (originalPayload != null &&
                originalPayload !=
                    previousAttempt.challenge.ndefPayload &&
                originalPayload != previousAttempt.previousPayload) {
              throw const NfcCardAssignmentException(
                'This card’s contents do not match your '
                    'pending setup. It will not be overwritten.',
              );
            }
          }

          if (!ndef.isWritable) {
            throw const NfcCardAssignmentException(
              'The card is read-only. '
                  'A writable card is required for this setup.',
            );
          }

          _showStatus(
            'Preparing card assignment…',
            'Keep the card steady while the server '
                'prepares a fresh challenge.',
          );

          // Always request a fresh challenge on a retry.
          // This also handles expired or superseded attempts.
          final challenge = await _service.beginAssignment(
            studentId: id,
            cardUid: uid,
          );

          _assertActive(operation, id);

          await _service.verifyPhoneForAssignment(challenge);

          _assertActive(operation, id);

          final message = _buildMessage(challenge.ndefPayload);

          if (message.byteLength > ndef.maxSize) {
            throw const NfcCardAssignmentException(
              'This card does not have enough space '
                  'for the attendance token.',
            );
          }

          final pending = _PendingCardAssignment(
            challenge: challenge,
            previousPayload: originalPayload,
          );

          // Save retry information before starting a write.
          await _savePending(pending);

          _assertActive(operation, id);

          setState(() => _hasPending = true);

          // Check again after the network and signing operations.
          final beforeWrite = _readPayload(
            await ndef.getNdefMessage(),
          );

          _assertActive(operation, id);

          if (beforeWrite != originalPayload) {
            throw const NfcCardAssignmentException(
              'The card contents changed during preparation. '
                  'The write was not started.',
            );
          }

          if (challenge.isExpired) {
            throw const NfcCardAssignmentException(
              'The challenge expired before writing. '
                  'Continue setup to request a fresh attempt.',
            );
          }

          _showStatus(
            'Writing your card…',
            'Keep the card steady. Do not remove it yet.',
          );

          await ndef.writeNdefMessage(message);

          _assertActive(operation, id);

          final readBack = _readPayload(
            await ndef.getNdefMessage(),
          );

          _assertActive(operation, id);

          if (readBack != challenge.ndefPayload) {
            throw const NfcCardAssignmentException(
              'The written token could not be verified. '
                  'Keep this card and continue setup to retry.',
            );
          }

          _showStatus(
            'Confirming your assignment…',
            'You can remove the card now.\n\n'
                'Keep the app open while the server verifies '
                'your phone’s signature.',
          );

          await _service.completeAssignment(
            challenge: challenge,
            readBackPayload: readBack!,
          );

          _assertActive(operation, id);

          // Failure to remove a local hint must not turn
          // confirmed server success into a registration failure.
          await _clearPending(id);

          _assertActive(operation, id);

          setState(() {
            _done = true;
            _ready = false;
            _hasPending = false;
            _title = 'Card assigned';
            _message =
            'The token was written and read back successfully. '
                'The server verified your registered phone '
                'and activated the card for your account.\n\n'
                'Open Use NFC for Attendance to enable readiness for an active NFC test session.';
          });
        },
      );
    } catch (error) {
      final id = studentId;

      // A response may have been lost after the server committed.
      final completed = id != null &&
          await _checkForCompletedAssignment(operation, id);

      if (!completed &&
          mounted &&
          operation == _operation) {
        final explanation = error is NfcCardAssignmentException
            ? error.message
            : 'Setup could not be confirmed. '
            'Check your connection and keep the card steady '
            'during the next attempt.';

        _showStatus(
          'Assignment not confirmed',
          _hasPending
              ? '$explanation\n\n'
              'Keep the same card. Pending setup details '
              'are saved for another attempt.'
              : explanation,
        );
      }
    } finally {
      if (mounted && operation == _operation) {
        setState(() {
          _busy = false;
          _waitingForTag = false;
        });
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (!_busy) {
        unawaited(_loadStatus());
      }
      return;
    }

    if (_busy) {
      _interrupted = true;

      // Cancel only while waiting for a card. Once processing
      // starts, let it settle and check the interruption guards.
      _cancelWaiting?.call();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _interrupted = true;
    ++_operation;
    _cancelWaiting?.call();
    unawaited(_stopNfc());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        backgroundColor: backgroundColor,
        appBar: AppBar(
          title: const Text('Assign NFC Tag'),
          backgroundColor: backgroundColor,
          foregroundColor: AppColors.text,
          surfaceTintColor: Colors.transparent,
        ),
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SizedBox(height: 32),
                    Icon(
                      Icons.add_card_rounded,
                      size: 100,
                      color: accentColor,
                    ),
                    const SizedBox(height: 24),
                    Text(
                      'Assign Tag (1 time)',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: AppColors.text,
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Link your attendance card to your account.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: secondaryTextColor,
                        height: 1.5,
                      ),
                    ),
                    const SizedBox(height: 28),
                    Container(
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        color: cardColor,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: borderColor),
                      ),
                      child: Semantics(
                        liveRegion: true,
                        child: Column(
                          children: [
                            if (_busy)
                              SizedBox(
                                width: 28,
                                height: 28,
                                child: CircularProgressIndicator(
                                  color: accentColor,
                                  strokeWidth: 3,
                                ),
                              )
                            else
                              Icon(
                                _done
                                    ? Icons.check_circle_outline_rounded
                                    : Icons.info_outline_rounded,
                                color: accentColor,
                                size: 32,
                              ),
                            const SizedBox(height: 16),
                            Text(
                              _title,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: AppColors.text,
                                fontSize: 17,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 10),
                            Text(
                              _message,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: secondaryTextColor,
                                height: 1.5,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),
                    if (_ready && !_done)
                      ElevatedButton.icon(
                        onPressed: _busy ? null : _assignCard,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: buttonColor,
                          foregroundColor: Colors.white,
                          minimumSize: const Size(0, 56),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        icon: const Icon(Icons.nfc_rounded),
                        label: Text(
                          _hasPending
                              ? 'Continue Setup'
                              : 'Assign This Card',
                        ),
                      ),
                    const SizedBox(height: 12),
                    if (_waitingForTag)
                      OutlinedButton(
                        onPressed: _cancelWaiting,
                        style: OutlinedButton.styleFrom(
                          foregroundColor: accentColor,
                          minimumSize: const Size(0, 52),
                        ),
                        child: const Text('Cancel Scan'),
                      )
                    else
                      OutlinedButton.icon(
                        onPressed: _busy ? null : _loadStatus,
                        style: OutlinedButton.styleFrom(
                          foregroundColor: accentColor,
                          minimumSize: const Size(0, 52),
                        ),
                        icon: const Icon(Icons.refresh_rounded),
                        label: const Text('Check Saved Status'),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}