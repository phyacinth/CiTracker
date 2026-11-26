import 'package:flutter/material.dart';

import '../screens/join_class_screen.dart';
import '../screens/qr_scanner_screen.dart';
import '../services/enrolled_classes_service.dart';
import '../theme/app_theme.dart';

enum ClassAction { join, scanAttendance }

class ClassActionsSheet extends StatelessWidget {
  const ClassActionsSheet({super.key});

  static Color get cardColor => AppColors.card;
  static Color get accentColor => AppColors.accent;
  static Color get borderColor => AppColors.border;
  static Color get secondaryTextColor => AppColors.secondaryText;

  static Future<ClassAction?> show(BuildContext context) async {
    final action = await showModalBottomSheet<ClassAction>(
      context: context,
      backgroundColor: cardColor,
      showDragHandle: true,
      isScrollControlled: true,
      constraints: const BoxConstraints(maxWidth: 560),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      clipBehavior: Clip.antiAlias,
      builder: (_) => const ClassActionsSheet(),
    );

    if (!context.mounted) return null;

    if (action == ClassAction.join) {
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(builder: (_) => const JoinClassScreen()),
      );

      EnrolledClassesService.notifyChanged();
      return null;
    }

    if (action == ClassAction.scanAttendance) {
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(builder: (_) => const QrScannerScreen()),
      );

      return null;
    }

    return action;
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
              child: Text(
                'Join Class / Scan QR',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: AppColors.text,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            ListTile(
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 8,
              ),
              leading: Icon(Icons.group_add_outlined, color: accentColor),
              title: Text(
                'Join a class',
                style: TextStyle(
                  color: AppColors.text,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
              subtitle: Text(
                'Join using a class access code',
                style: TextStyle(color: secondaryTextColor, fontSize: 12),
              ),
              onTap: () {
                Navigator.of(context).pop(ClassAction.join);
              },
            ),
            Divider(color: borderColor, height: 1),
            ListTile(
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 8,
              ),
              leading: Icon(
                Icons.qr_code_scanner_rounded,
                color: accentColor,
              ),
              title: Text(
                'Scan attendance QR',
                style: TextStyle(
                  color: AppColors.text,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
              subtitle: Text(
                "Scan your professor's session QR",
                style: TextStyle(color: secondaryTextColor, fontSize: 12),
              ),
              onTap: () {
                Navigator.of(context).pop(ClassAction.scanAttendance);
              },
            ),
          ],
        ),
      ),
    );
  }
}
