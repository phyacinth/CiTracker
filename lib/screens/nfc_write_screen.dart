import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:nfc_manager/ndef_record.dart';
import 'package:nfc_manager/nfc_manager.dart';
import 'package:nfc_manager/nfc_manager_android.dart';
import '../theme/app_theme.dart';

class NfcWriteScreen extends StatefulWidget {
  const NfcWriteScreen({super.key});

  @override
  State<NfcWriteScreen> createState() => _NfcWriteScreenState();
}

class _NfcWriteScreenState extends State<NfcWriteScreen>
    with WidgetsBindingObserver {
  static Color get backgroundColor => AppColors.background;
  static Color get cardColor => AppColors.card;
  static Color get accentColor => AppColors.accent;
  static Color get buttonColor => AppColors.button;
  static Color get secondaryTextColor => AppColors.secondaryText;

  final _controller = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  Timer? _timeout;
  bool _busy = false;
  bool _handlingTag = false;
  bool _success = false;
  int _attempt = 0;

  String _message = 'Enter the text you want to save to a tag.';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  NdefMessage _buildMessage(String text) {
    final language = utf8.encode('en');

    return NdefMessage(
      records: [
        NdefRecord(
          typeNameFormat: TypeNameFormat.wellKnown,
          type: Uint8List.fromList([0x54]),
          identifier: Uint8List(0),
          payload: Uint8List.fromList([
            language.length,
            ...language,
            ...utf8.encode(text),
          ]),
        ),
      ],
    );
  }

  Future<void> _stopSession() async {
    try {
      await NfcManager.instance.stopSession();
    } catch (_) {
      // There may be no active session.
    }
  }

  Future<void> _finish(
      int attempt,
      String message, {
        bool success = false,
      }) async {
    if (attempt != _attempt) return;

    // Invalidate callbacks from this attempt before stopping it.
    ++_attempt;
    _timeout?.cancel();

    await _stopSession();

    if (!mounted) return;

    setState(() {
      _busy = false;
      _handlingTag = false;
      _success = success;
      _message = message;
    });
  }

  Future<void> _startWriting() async {
    if (_busy || !_formKey.currentState!.validate()) return;

    FocusScope.of(context).unfocus();

    final text = _controller.text;
    final ndefMessage = _buildMessage(text);
    final attempt = ++_attempt;

    setState(() {
      _busy = true;
      _handlingTag = false;
      _success = false;
      _message = 'Hold your writable NFC tag behind your phone.';
    });

    try {
      final availability =
      await NfcManager.instance.checkAvailability();

      if (!mounted || attempt != _attempt) return;

      if (availability != NfcAvailability.enabled) {
        await _finish(
          attempt,
          'NFC is unavailable or switched off. '
              'Enable NFC in your phone settings and try again.',
        );
        return;
      }

      await NfcManager.instance.startSession(
        pollingOptions: {
          NfcPollingOption.iso14443,
          NfcPollingOption.iso15693,
          NfcPollingOption.iso18092,
        },
        onDiscovered: (tag) async {
          if (!mounted ||
              attempt != _attempt ||
              _handlingTag) {
            return;
          }

          _timeout?.cancel();

          setState(() {
            _handlingTag = true;
            _message = 'Writing tag. Keep it steady.';
          });

          await _writeTag(tag, ndefMessage, attempt);
        },
      );

      if (!mounted || attempt != _attempt) return;

      if (!_handlingTag) {
        _timeout = Timer(const Duration(seconds: 30), () {
          unawaited(
            _finish(
              attempt,
              'No tag was detected. Tap Write Tag to try again.',
            ),
          );
        });
      }
    } catch (_) {
      await _finish(
        attempt,
        'Could not start NFC writing. Check NFC and try again.',
      );
    }
  }

  Future<void> _writeTag(
      NfcTag tag,
      NdefMessage message,
      int attempt,
      ) async {
    try {
      final ndef = NdefAndroid.from(tag);

      if (ndef == null) {
        await _finish(
          attempt,
          'This tag is not ready for standard NDEF writing. '
              'Use a writable NDEF-formatted test tag.',
        );
        return;
      }

      if (!ndef.isWritable) {
        await _finish(
          attempt,
          'This tag is read-only and cannot be written.',
        );
        return;
      }

      if (message.byteLength > ndef.maxSize) {
        await _finish(
          attempt,
          'The message needs ${message.byteLength} bytes, '
              'but this tag holds ${ndef.maxSize} bytes. '
              'Shorten the text and try again.',
        );
        return;
      }

      await ndef.writeNdefMessage(message);

      await _finish(
        attempt,
        'Write completed. Remove the tag, then use Read Tag '
            'to check its saved contents. Separate verification '
            'has not been performed yet.',
        success: true,
      );
    } catch (_) {
      await _finish(
        attempt,
        'The write could not be confirmed. The tag may have '
            'moved or the operation was interrupted. Read it '
            'before deciding whether to retry.',
      );
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed || !_busy) return;

    unawaited(
      _finish(
        _attempt,
        'Writing was interrupted. If a tag was being written, '
            'read it to check its contents before retrying.',
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    ++_attempt;
    _timeout?.cancel();
    unawaited(_stopSession());
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: backgroundColor,
      appBar: AppBar(
        title: const Text('Write NFC Tag'),
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
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SizedBox(height: 24),
                    Icon(
                      _success
                          ? Icons.check_circle_outline_rounded
                          : Icons.nfc_rounded,
                      size: 100,
                      color: _success
                          ? AppColors.success
                          : accentColor,
                    ),
                    const SizedBox(height: 24),
                    Text(
                      'Write text to an NFC tag',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: AppColors.text,
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Writing replaces the tag’s existing NDEF '
                          'message. Use a blank test tag.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: secondaryTextColor,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 28),
                    TextFormField(
                      controller: _controller,
                      enabled: !_busy,
                      minLines: 3,
                      maxLines: 6,
                      style: TextStyle(color: AppColors.text),
                      decoration: InputDecoration(
                        labelText: 'Text to write',
                        hintText: 'Example: COMPTECH NFC TEST',
                        filled: true,
                        fillColor: cardColor,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      validator: (value) {
                        if (value == null || value.trim().isEmpty) {
                          return 'Enter text before writing.';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 20),
                    Semantics(
                      liveRegion: true,
                      child: Text(
                        _message,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: secondaryTextColor,
                          height: 1.5,
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),
                    if (_busy) ...[
                      Center(
                        child: CircularProgressIndicator(
                          color: accentColor,
                        ),
                      ),
                      const SizedBox(height: 20),
                      if (!_handlingTag)
                        TextButton(
                          onPressed: () {
                            unawaited(
                              _finish(
                                _attempt,
                                'Scanning cancelled. No write was started.',
                              ),
                            );
                          },
                          child: const Text('Cancel Scanning'),
                        ),
                    ] else
                      ElevatedButton.icon(
                        onPressed: _startWriting,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: buttonColor,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(
                            vertical: 16,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        icon: const Icon(Icons.edit_outlined),
                        label: const Text('Write Tag'),
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