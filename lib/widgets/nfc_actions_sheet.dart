import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

enum NfcAction {
  attendance,
  phoneTap, // Compatibility only; the menu now has one attendance entry.
  assignTag,
}

class NfcActionsSheet extends StatelessWidget {
  const NfcActionsSheet({
    super.key,
    this.tagAssigned = false,
  });

  final bool tagAssigned;

  static Color get cardColor => AppColors.card;
  static Color get accentColor => AppColors.accent;
  static Color get borderColor => AppColors.border;
  static Color get secondaryTextColor => AppColors.secondaryText;

  static Future<NfcAction?> show(
      BuildContext context, {
        bool tagAssigned = false,
      }) {
    return showModalBottomSheet<NfcAction>(
      context: context,
      backgroundColor: cardColor,
      showDragHandle: true,
      isScrollControlled: true,
      constraints: const BoxConstraints(maxWidth: 560),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(20),
        ),
      ),
      clipBehavior: Clip.antiAlias,
      builder: (_) => NfcActionsSheet(
        tagAssigned: tagAssigned,
      ),
    );
  }

  Widget _buildAction({
    required BuildContext context,
    required IconData icon,
    required String title,
    required String subtitle,
    required NfcAction action,
    bool enabled = true,
  }) {
    return ListTile(
      enabled: enabled,
      contentPadding: const EdgeInsets.symmetric(
        horizontal: 12,
        vertical: 8,
      ),
      leading: Icon(
        icon,
        color: enabled ? accentColor : secondaryTextColor,
      ),
      title: Text(
        title,
        style: TextStyle(
          color: enabled ? AppColors.text : secondaryTextColor,
          fontSize: 15,
          fontWeight: FontWeight.w600,
        ),
      ),
      subtitle: Text(
        subtitle,
        style: TextStyle(
          color: secondaryTextColor,
          fontSize: 12,
        ),
      ),
      onTap: enabled
          ? () => Navigator.of(context).pop(action)
          : null,
    );
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
                'NFC Actions',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: AppColors.text,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            _buildAction(
              context: context,
              icon: Icons.nfc_rounded,
              title: 'NFC Attendance',
              subtitle: 'Choose Tap Phone or Use Card',
              action: NfcAction.attendance,
            ),
            Divider(color: borderColor, height: 1),
            _buildAction(
              context: context,
              icon: Icons.add_card_rounded,
              title: 'Assign NFC Card',
              subtitle: tagAssigned
                  ? 'Card already assigned'
                  : 'Link your attendance card to your account',
              action: NfcAction.assignTag,
              enabled: !tagAssigned,
            ),
          ],
        ),
      ),
    );
  }
}