import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/nfc_phone_registration_service.dart';
import '../services/nfc_phone_service.dart';
import '../services/nfc_attendance_service.dart';
import '../services/nfc_service.dart';
import '../theme/app_theme.dart';

class NfcPhoneSetupScreen extends StatefulWidget {
  const NfcPhoneSetupScreen({super.key});

  @override
  State<NfcPhoneSetupScreen> createState() => _NfcPhoneSetupScreenState();
}

class _NfcPhoneSetupScreenState extends State<NfcPhoneSetupScreen>
    with WidgetsBindingObserver {
  static Color get backgroundColor => AppColors.background;
  static Color get cardColor => AppColors.card;
  static Color get accentColor => AppColors.accent;
  static Color get borderColor => AppColors.border;
  static Color get secondaryTextColor => AppColors.secondaryText;

  final _nfcService = NfcService();
  final _phoneService = NfcPhoneService();
  final _registrationService = NfcPhoneRegistrationService();

  bool _working = false;
  bool _keyPrepared = false;
  bool _registered = false;
  // True only before this account's first phone registration: shows the
  // visible Register This Phone button. The hidden logo tap always remains.
  bool _firstTime = false;
  String? _preparedStudentId;
  int _logoTapCount = 0;
  DateTime? _lastLogoTap;

  void _onLogoTap() {
    if (_working || !_keyPrepared || _registered) return;
    final now = DateTime.now();
    if (_lastLogoTap == null ||
        now.difference(_lastLogoTap!) > const Duration(seconds: 2)) {
      _logoTapCount = 0;
    }
    _lastLogoTap = now;
    _logoTapCount++;
    if (_logoTapCount == 3) {
      _logoTapCount = 0;
      _lastLogoTap = null;
      _registerPhone();
    }
  }

  String _title = 'Checking your phone…';
  String _message = 'Please wait.';
  String? _keyDetails;
  String? _phoneCode;

  static const _lostPhoneMessage =
      'This account already has a registered phone. If it was lost or '
      'replaced, tap the NFC logo above three times to register this phone '
      'instead. Your old phone will stop working for attendance.';

  // Shown only when the server requires an approved replacement.
  static const _approvalMessage =
      'This account already has a registered phone. If it was lost or '
      'replaced, send the phone code under Registration details to your '
      'professor or admin. After they approve it, tap the NFC logo above '
      'three times to register this phone.';

  void _setPhoneCode(String email, String fingerprint) {
    _phoneCode = fingerprint;
    _keyDetails = 'Account: $email\n\nPhone code:\n$fingerprint';
  }

  Future<void> _copyPhoneCode() async {
    final code = _phoneCode;
    if (code == null) return;
    await Clipboard.setData(ClipboardData(text: code));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Phone code copied.')),
    );
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _preparePhone();
  }

  void _showStatus(String title, String message) {
    if (!mounted) return;

    setState(() {
      _title = title;
      _message = message;
    });
  }

  Future<void> _preparePhone() async {
    if (_working) return;
    _logoTapCount = 0;
    _lastLogoTap = null;

    setState(() {
      _working = true;
      _keyPrepared = false;
      _registered = false;
      _firstTime = false;
      _preparedStudentId = null;
      _keyDetails = null;
      _phoneCode = null;
      _title = 'Checking your phone…';
      _message = 'Checking NFC and card-emulation support.';
    });

    try {
      final client = Supabase.instance.client;
      final studentId = client.auth.currentUser?.id;

      if (studentId == null) {
        _showStatus(
          'Sign-in required',
          'Sign in to your student account and try again.',
        );
        return;
      }

      final results = await Future.wait<bool>([
        _nfcService.isEnabled(),
        _phoneService.supportsCardEmulation(),
      ]);

      if (!mounted) return;

      if (!results[0]) {
        _showStatus(
          'NFC is off or unavailable',
          'Enable NFC in your phone settings, then try again.',
        );
        return;
      }

      if (!results[1]) {
        _showStatus(
          'Card emulation is unsupported',
          'This device cannot present our planned phone '
              'attendance credential.',
        );
        return;
      }

      _showStatus(
        'Preparing your phone key…',
        'Keep the app open while the local signing test runs.',
      );

      final hasKey = await _phoneService.hasPhoneKey(studentId);
      if (!mounted || client.auth.currentUser?.id != studentId) return;
      if (!hasKey) {
        // The visible button is for the account's first phone only. If the
        // server can't be asked, offer it; the server still decides.
        final alreadyRegistered =
            await _registrationService.accountHasRegisteredPhone() ?? false;
        if (!mounted || client.auth.currentUser?.id != studentId) return;
        setState(() {
          _keyPrepared = true; // Enables the explicit registration action only.
          _firstTime = !alreadyRegistered;
          _preparedStudentId = studentId;
          if (alreadyRegistered) {
            _title = 'This is not your registered phone';
            _message = _lostPhoneMessage;
          } else {
            _title = 'This phone is not registered yet';
            _message =
                'Tap Register This Phone below to use this phone for attendance.';
          }
        });
        return;
      }
      await _phoneService.preparePhoneKey(studentId);

      if (!mounted) return;

      if (client.auth.currentUser?.id != studentId) {
        _showStatus(
          'Account changed',
          'Return to the dashboard and open NFC again.',
        );
        return;
      }

      final attendance = NfcAttendanceService();
      final fingerprint = await attendance.prepareFingerprint();
      if (!mounted || client.auth.currentUser?.id != studentId) return;
      String title = 'Local phone key prepared';
      String status =
          'Server registration could not be checked. No registration was changed.';
      bool registered = false;
      try {
        await attendance.call('phone_context', {
          'key_fingerprint': fingerprint,
        });
        registered = true;
        title = 'Registered phone confirmed';
        status = 'This phone matches your active registration. Return to NFC Attendance.';
      } on NfcAttendanceException catch (error) {
        if (error.code == 'REGISTERED_PHONE_REQUIRED') {
          title = 'This is not your registered phone';
          status = _lostPhoneMessage;
        } else {
          status = error.message;
        }
      } catch (_) {
        status =
        'Could not reach the attendance server. Check your connection and try again. '
            'No registration was changed.';
      }
      if (!mounted || client.auth.currentUser?.id != studentId) return;
      setState(() {
        _keyPrepared = true;
        _preparedStudentId = studentId;
        _registered = registered;
        _title = title;
        _message = status;
        _setPhoneCode(client.auth.currentUser?.email ?? studentId, fingerprint);
      });
    } catch (_) {
      _showStatus(
        'Phone setup could not be completed',
        'Try checking your phone again.',
      );
    } finally {
      if (mounted) {
        setState(() => _working = false);
      }
    }
  }

  Future<void> _registerPhone() async {
    if (_working || !_keyPrepared || _registered) return;

    if (_preparedStudentId != Supabase.instance.client.auth.currentUser?.id) {
      setState(() {
        _keyPrepared = false;
        _preparedStudentId = null;
      });

      _showStatus(
        'Account changed',
        'Tap Check Phone Again before registering.',
      );
      return;
    }

    setState(() {
      _working = true;
      _title = 'Registering your phone…';
      _message = 'Keep the app open until registration is confirmed.';
    });

    try {
      await _registrationService.registerPhone(
        onProgress: (message) {
          _showStatus('Registering your phone…', message);
        },
      );

      if (!mounted) return;

      if (_preparedStudentId != Supabase.instance.client.auth.currentUser?.id) {
        _showStatus(
          'Account changed',
          'Return to the dashboard and open NFC again.',
        );
        return;
      }

      setState(() {
        _registered = true;
        _firstTime = false;
        _title = 'Phone registered';
        _message = 'Your phone is registered. Return to NFC Attendance.';
      });
    } on NfcRegistrationException catch (error) {
      if (error.code == 'AUTHORIZED_PHONE_REPLACEMENT_REQUIRED') {
        // The account already has a phone: hide the one-time button and show
        // this phone's code so a professor or admin can approve a replacement.
        // The key was created during this attempt, so its code is available.
        String? fingerprint;
        try {
          fingerprint = await NfcAttendanceService().prepareFingerprint();
        } catch (_) {
          // The message still explains what to do; Check Phone Again shows the code.
        }
        if (!mounted) return;
        final email = Supabase.instance.client.auth.currentUser?.email ?? '';
        setState(() {
          _firstTime = false;
          if (fingerprint != null) _setPhoneCode(email, fingerprint);
          _title = 'Replacement approval needed';
          _message = _approvalMessage;
        });
        return;
      }
      _showStatus('Registration not confirmed', error.message);
    } catch (_) {
      _showStatus(
        'Registration not confirmed',
        'Check your connection and try again.',
      );
    } finally {
      if (mounted) {
        setState(() => _working = false);
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed || _working) return;

    final currentId = Supabase.instance.client.auth.currentUser?.id;

    if (!_registered || currentId != _preparedStudentId) {
      _preparePhone();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: backgroundColor,
      appBar: AppBar(
        title: const Text('Phone Setup'),
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
                  const SizedBox(height: 8),
                  Center(
                    child: IconButton(
                      onPressed: _keyPrepared && !_registered && !_working
                          ? _onLogoTap
                          : null,
                      tooltip: _registered
                          ? 'Phone already registered'
                          : 'Tap three times to register this phone',
                      iconSize: 56,
                      color: accentColor,
                      disabledColor: accentColor,
                      icon: const Icon(Icons.nfc_rounded),
                    ),
                  ),
                  const SizedBox(height: 24),
                  Text(
                    'Register your phone',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: AppColors.text,
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Use your registered phone as your '
                        'attendance credential.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: secondaryTextColor, height: 1.5),
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
                          if (_working)
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
                              _registered
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
                  if (_keyDetails != null)
                    ExpansionTile(
                      title: const Text('Registration details'),
                      initiallyExpanded: !_registered,
                      childrenPadding: const EdgeInsets.all(16),
                      expandedCrossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SelectableText(_keyDetails!),
                        if (_phoneCode != null && !_registered)
                          Align(
                            alignment: Alignment.centerRight,
                            child: TextButton.icon(
                              onPressed: _copyPhoneCode,
                              icon: const Icon(Icons.copy_rounded, size: 18),
                              label: const Text('Copy phone code'),
                            ),
                          ),
                      ],
                    ),
                  const SizedBox(height: 24),
                  if (_registered)
                    ElevatedButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Done'),
                    ),
                  if (_firstTime && !_registered)
                    ElevatedButton.icon(
                      onPressed: _working ? null : _registerPhone,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.button,
                        foregroundColor: Colors.white,
                        minimumSize: const Size(0, 52),
                      ),
                      icon: const Icon(Icons.phonelink_lock_rounded),
                      label: const Text('Register This Phone'),
                    ),
                  if (!_registered) ...[
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: _working ? null : _preparePhone,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: accentColor,
                        minimumSize: const Size(0, 52),
                      ),
                      icon: const Icon(Icons.refresh_rounded),
                      label: const Text('Check Phone Again'),
                    ),
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
