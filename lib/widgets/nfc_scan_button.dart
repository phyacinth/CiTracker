import 'pop_button_effects.dart';

import 'dart:async';

import 'package:flutter/material.dart';

import '../screens/nfc_assign_tag_screen.dart';
import '../screens/nfc_attendance_screen.dart';
import '../services/nfc_credential_service.dart';
import '../services/offline_attendance_service.dart';
import 'nfc_actions_sheet.dart';
import '../theme/app_theme.dart';

class NfcScanButton extends StatefulWidget {
  const NfcScanButton({super.key, this.onPressed});

  final VoidCallback? onPressed;

  @override
  State<NfcScanButton> createState() => _NfcScanButtonState();
}

class _NfcScanButtonState extends State<NfcScanButton> {
  final _credentialService = NfcCredentialService();

  bool _opening = false;
  bool _loading = false;

  void _showError(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
      );
  }

  Future<void> _showNfcActions() async {
    if (_opening) return;

    setState(() {
      _opening = true;
      _loading = true;
    });

    try {
      // Offline, only Tap Phone can work (if it was turned on while online),
      // and the card status can't be checked, so go straight there.
      if (await OfflineAttendanceService.isOffline()) {
        if (!mounted) return;
        setState(() => _loading = false);
        await Navigator.of(context).push<void>(
          MaterialPageRoute<void>(
            builder: (_) => const NfcAttendanceScreen(initialTab: 0),
          ),
        );
        return;
      }

      final status = await _credentialService.getStatus();

      if (!mounted) return;

      setState(() {
        _loading = false;
      });

      final action = await NfcActionsSheet.show(
        context,
        tagAssigned: status.tagAssigned,
      );

      if (!mounted || action == null) return;

      final Widget screen = switch (action) {
        NfcAction.attendance => const NfcAttendanceScreen(),
        NfcAction.phoneTap => const NfcAttendanceScreen(initialTab: 0),
        NfcAction.assignTag => const NfcAssignTagScreen(),
      };

      await Navigator.of(context)
          .push<void>(MaterialPageRoute<void>(builder: (_) => screen));
    } on TimeoutException {
      if (!mounted) return;

      _showError(
        'Checking NFC status took too long. '
            'Check your connection and try again.',
      );
    } catch (_) {
      if (!mounted) return;

      _showError(
        'Unable to verify your NFC assignment status. '
            'Check your connection and try again. '
            'If this continues, sign in again.',
      );
    } finally {
      if (mounted) {
        setState(() {
          _opening = false;
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopButtonEffects(
      child: ElevatedButton.icon(
        onPressed: _opening ? null : widget.onPressed ?? _showNfcActions,
        style: ElevatedButton.styleFrom(
          elevation: 0,
          shadowColor: Colors.transparent,
          surfaceTintColor: Colors.transparent,
          backgroundColor: AppColors.button,
          foregroundColor: Colors.white,
          minimumSize: const Size(0, 56),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
        icon: _loading
            ? SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: AppColors.accent,
          ),
        )
            : const Icon(Icons.nfc_rounded, size: 22),
        label: Text(
          _loading ? 'Checking…' : 'NFC',
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
        ),
      ),
    );
  }
}
