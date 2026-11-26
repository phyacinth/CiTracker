import 'dart:async';

import 'package:flutter/material.dart';

import '../services/nfc_service.dart';
import '../theme/app_theme.dart';

enum NfcReadState {
  waiting,
  success,
  failed,
}

class NfcScannerScreen extends StatefulWidget {
  const NfcScannerScreen({super.key});

  @override
  State<NfcScannerScreen> createState() => _NfcScannerScreenState();
}

class _NfcScannerScreenState extends State<NfcScannerScreen>
    with WidgetsBindingObserver {
  static Color get backgroundColor => AppColors.background;
  static Color get cardColor => AppColors.card;
  static Color get accentColor => AppColors.accent;
  static Color get buttonColor => AppColors.button;
  static Color get borderColor => AppColors.border;
  static Color get secondaryTextColor => AppColors.secondaryText;

  final NfcService _nfcService = NfcService();

  NfcReadState _state = NfcReadState.waiting;
  NfcReadResult? _result;
  String _errorMessage = '';
  Timer? _timeout;

  int _attempt = 0;
  bool _starting = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _startReading();
      }
    });
  }

  Future<void> _stopReading() async {
    try {
      await _nfcService.stopReading();
    } catch (_) {
      // There may be no active session to stop.
    }
  }

  Future<void> _startReading() async {
    if (_starting) return;
    _starting = true;

    final attempt = ++_attempt;
    _timeout?.cancel();

    setState(() {
      _state = NfcReadState.waiting;
      _result = null;
      _errorMessage = '';
    });

    try {
      await _stopReading();

      if (!mounted || attempt != _attempt) return;

      final enabled = await _nfcService.isEnabled();

      if (!mounted || attempt != _attempt) return;

      if (!enabled) {
        _showFailure(
          'NFC is unavailable or switched off. '
              'Enable NFC in your phone settings, then try again.',
        );
        return;
      }

      await _nfcService.startReading(
        onRead: (result) {
          if (!mounted ||
              attempt != _attempt ||
              _state != NfcReadState.waiting) {
            return;
          }

          _timeout?.cancel();

          setState(() {
            _result = result;
            _state = NfcReadState.success;
          });
        },
        onError: (message) {
          if (!mounted ||
              attempt != _attempt ||
              _state != NfcReadState.waiting) {
            return;
          }

          _showFailure(message);
        },
      );

      if (!mounted || attempt != _attempt) {
        await _stopReading();
        return;
      }

      if (_state == NfcReadState.waiting) {
        _timeout = Timer(const Duration(seconds: 30), () {
          if (!mounted ||
              attempt != _attempt ||
              _state != NfcReadState.waiting) {
            return;
          }

          _showFailure(
            'No tag was read. Place the tag near your phone’s '
                'NFC antenna and hold it steady.',
          );

          unawaited(_stopReading());
        });
      }
    } catch (_) {
      if (mounted && attempt == _attempt) {
        _showFailure(
          'Could not start NFC scanning. '
              'Check your device and try again.',
        );
      }

      await _stopReading();
    } finally {
      _starting = false;
    }
  }

  void _showFailure(String message) {
    _timeout?.cancel();

    setState(() {
      _errorMessage = message;
      _state = NfcReadState.failed;
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed ||
        _state != NfcReadState.waiting) {
      return;
    }

    ++_attempt;
    _timeout?.cancel();
    unawaited(_stopReading());

    if (mounted) {
      _showFailure(
        'Scanning was interrupted. Tap Try Again when you are ready.',
      );
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    ++_attempt;
    _timeout?.cancel();
    unawaited(_stopReading());
    super.dispose();
  }

  Widget _buildInformation(String text) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: borderColor),
      ),
      child: SelectableText(
        text,
        style: TextStyle(
          color: AppColors.text,
          fontSize: 14,
          height: 1.6,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final waiting = _state == NfcReadState.waiting;
    final success = _state == NfcReadState.success;

    final IconData icon;
    final Color iconColor;
    final String title;

    switch (_state) {
      case NfcReadState.waiting:
        icon = Icons.nfc_rounded;
        iconColor = accentColor;
        title = 'Tap and hold the NFC tag behind your phone';
        break;
      case NfcReadState.success:
        icon = Icons.check_circle_outline_rounded;
        iconColor = AppColors.success;
        title = _result!.supportsNdef
            ? 'NFC read success!'
            : 'NFC tag detected';
        break;
      case NfcReadState.failed:
        icon = Icons.highlight_off_rounded;
        iconColor = AppColors.error;
        title = 'NFC read failed';
        break;
    }

    return Scaffold(
      backgroundColor: backgroundColor,
      appBar: AppBar(
        title: const Text('Read NFC Tag'),
        backgroundColor: backgroundColor,
        foregroundColor: AppColors.text,
        surfaceTintColor: Colors.transparent,
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            return SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight: (constraints.maxHeight - 48)
                      .clamp(0.0, double.infinity)
                      .toDouble(),
                ),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 560),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          icon,
                          size: 120,
                          color: iconColor,
                        ),
                        const SizedBox(height: 28),
                        Text(
                          title,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: AppColors.text,
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 20),
                        if (waiting) ...[
                          Text(
                            'Keep the tag steady until a result appears.',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: secondaryTextColor,
                              fontSize: 14,
                            ),
                          ),
                          const SizedBox(height: 24),
                          CircularProgressIndicator(
                            color: accentColor,
                          ),
                        ] else if (success) ...[
                          _buildInformation(
                            'Tag ID\n${_result!.tagId}\n\n'
                                'Tag contents\n${_result!.contents}',
                          ),
                          const SizedBox(height: 20),
                          Text(
                            'Reading this tag does not record attendance.',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: secondaryTextColor,
                              fontSize: 12,
                            ),
                          ),
                        ] else
                          _buildInformation(_errorMessage),
                        if (!waiting) ...[
                          const SizedBox(height: 24),
                          SizedBox(
                            width: double.infinity,
                            child: ElevatedButton.icon(
                              onPressed: _startReading,
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
                              icon: const Icon(Icons.refresh_rounded),
                              label: Text(
                                success ? 'Read Another Tag' : 'Try Again',
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}