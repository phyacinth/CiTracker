import 'package:flutter/material.dart';
import 'nfc_attendance_screen.dart';

/// Compatibility route for older callers. All NFC attendance now uses one screen.
class PhoneNfcTapScreen extends StatelessWidget {
  const PhoneNfcTapScreen({super.key});

  @override
  Widget build(BuildContext context) => const NfcAttendanceScreen(initialTab: 0);
}
