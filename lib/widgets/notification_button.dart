import 'package:flutter/material.dart';

import '../screens/student_requests_screen.dart';
import '../services/nfc_attendance_service.dart';
import '../services/student_home_service.dart';
import '../services/student_notification_service.dart';
import '../services/student_tab_navigation.dart';
import '../theme/app_theme.dart';

class NotificationButton extends StatefulWidget {
  const NotificationButton({super.key});

  @override
  State<NotificationButton> createState() => _NotificationButtonState();
}

class _NotificationButtonState extends State<NotificationButton> {
  static Color get cardColor => AppColors.card;
  static Color get accentColor => AppColors.accent;
  static Color get borderColor => AppColors.border;
  static Color get secondaryTextColor => AppColors.secondaryText;

  final _service = StudentNotificationService.instance;

  @override
  void initState() {
    super.initState();
    _service.start();
  }

  static IconData _icon(String? kind) => switch (kind) {
    'score' => Icons.grading_rounded,
    'letter' => Icons.mark_email_read_outlined,
    'attendance' => Icons.event_available_outlined,
    'schedule' => Icons.event_repeat_outlined,
    'class' => Icons.inventory_2_outlined,
    'activity' => Icons.event_note_rounded,
    _ => Icons.campaign_outlined,
  };

  // Every item is the same height so exactly four fit before the list scrolls.
  static const _visibleItems = 4;

  /// Kinds with a screen to open; make-up classes and professor messages
  /// have none, so those items aren't tappable.
  static bool _opens(String? kind) =>
      kind == 'letter' ||
      kind == 'score' ||
      kind == 'attendance' ||
      kind == 'class' ||
      kind == 'activity';

  void _open(Map<String, dynamic> item, BuildContext dialogContext) {
    Navigator.pop(dialogContext);
    switch (item['kind']) {
      case 'score':
        StudentTabNavigation.open(StudentTabNavigation.scores);
      // An archived class is listed under Archived Classes on that tab.
      case 'attendance' || 'class':
        // Reloads the Attendance tab so the professor's change shows.
        NfcAttendanceService.notifyChanged();
        StudentTabNavigation.open(StudentTabNavigation.attendance);
      // A new activity is listed under Upcoming Activities on Home.
      case 'activity':
        StudentHomeService.showActivities(item['class_id'] as String?);
        StudentTabNavigation.open(StudentTabNavigation.home);
      case 'letter':
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => StudentRequestsScreen(
              initialClassId: item['class_id'] as String?,
            ),
          ),
        );
    }
  }

  static String _time(dynamic value) {
    final date = DateTime.tryParse(value?.toString() ?? '')?.toLocal();
    if (date == null) return '';
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    final hour = date.hour % 12 == 0 ? 12 : date.hour % 12;
    final minute = date.minute.toString().padLeft(2, '0');
    return '${months[date.month - 1]} ${date.day}, $hour:$minute '
        '${date.hour < 12 ? 'AM' : 'PM'}';
  }

  void _showNotifications(BuildContext context) {
    // Remember what was unread so it stays highlighted while the list is open.
    final unread = {
      for (final n in _service.items.value)
        if (n['read_at'] == null) n['id'],
    };
    _service.markAllRead();

    showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return Dialog(
          backgroundColor: cardColor,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(color: borderColor),
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 380, maxHeight: 520),
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Notifications',
                          style: TextStyle(
                            color: AppColors.text,
                            fontSize: 17,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      IconButton(
                        onPressed: () {
                          Navigator.pop(dialogContext);
                        },
                        icon: Icon(Icons.close, color: secondaryTextColor),
                      ),
                    ],
                  ),

                  Divider(color: borderColor),

                  Flexible(
                    child: ValueListenableBuilder<List<Map<String, dynamic>>>(
                      valueListenable: _service.items,
                      builder: (context, items, _) {
                        if (items.isEmpty) return _buildEmpty();
                        final itemHeight = _scaledItemHeight(context);
                        return ConstrainedBox(
                          constraints: BoxConstraints(
                            maxHeight:
                                itemHeight * _visibleItems +
                                (_visibleItems - 1),
                          ),
                          child: ListView.separated(
                            shrinkWrap: true,
                            itemCount: items.length,
                            separatorBuilder: (_, _) =>
                                Divider(color: borderColor, height: 1),
                            itemBuilder: (context, index) => _buildItem(
                              items[index],
                              unread,
                              itemHeight,
                              dialogContext,
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildEmpty() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 20),

        Icon(Icons.notifications_off_outlined, color: accentColor, size: 40),

        const SizedBox(height: 12),

        Text(
          'No notifications yet',
          style: TextStyle(color: AppColors.text, fontWeight: FontWeight.w600),
        ),

        const SizedBox(height: 8),

        Text(
          'Messages from your professors, make-up classes, attendance, '
          'scores and letter replies will appear here.',
          textAlign: TextAlign.center,
          style: TextStyle(color: secondaryTextColor, fontSize: 12),
        ),

        const SizedBox(height: 20),
      ],
    );
  }

  /// Title, two body lines and the time, grown with the phone's text size.
  static double _scaledItemHeight(BuildContext context) =>
      20 + MediaQuery.textScalerOf(context).scale(76);

  Widget _buildItem(
    Map<String, dynamic> item,
    Set<dynamic> unread,
    double height,
    BuildContext dialogContext,
  ) {
    final isNew = unread.contains(item['id']);
    final body = (item['body'] ?? '').toString();
    final opens = _opens(item['kind'] as String?);

    // Tappable items are cut to a fixed height; the full text is on the screen
    // they open. Items with nowhere to go show everything here instead, and
    // the list scrolls if they take more than four items' worth of space.
    return InkWell(
      onTap: opens ? () => _open(item, dialogContext) : null,
      borderRadius: BorderRadius.circular(8),
      child: ConstrainedBox(
        constraints: opens
            ? BoxConstraints.tightFor(height: height)
            : BoxConstraints(minHeight: height),
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: opens ? 0 : 12),
          child: Row(
            children: [
              Icon(
                _icon(item['kind'] as String?),
                color: accentColor,
                size: 22,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      (item['title'] ?? '').toString(),
                      maxLines: opens ? 1 : null,
                      overflow: opens ? TextOverflow.ellipsis : null,
                      style: TextStyle(
                        color: AppColors.text,
                        fontWeight: isNew ? FontWeight.bold : FontWeight.w500,
                      ),
                    ),
                    if (body.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        body,
                        maxLines: opens ? 2 : null,
                        overflow: opens ? TextOverflow.ellipsis : null,
                        style: TextStyle(
                          color: secondaryTextColor,
                          fontSize: 12,
                        ),
                      ),
                    ],
                    const SizedBox(height: 4),
                    Text(
                      _time(item['created_at']),
                      style: TextStyle(color: secondaryTextColor, fontSize: 11),
                    ),
                  ],
                ),
              ),
              if (isNew)
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: CircleAvatar(radius: 4, backgroundColor: accentColor),
                ),
              if (opens)
                Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: Icon(
                    Icons.chevron_right_rounded,
                    color: secondaryTextColor,
                    size: 20,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<Map<String, dynamic>>>(
      valueListenable: _service.items,
      builder: (context, _, _) {
        final count = _service.unreadCount;
        return Container(
          decoration: BoxDecoration(
            color: cardColor,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: borderColor),
          ),
          child: IconButton(
            tooltip: count == 0
                ? 'Notifications'
                : 'Notifications, $count unread',
            onPressed: () => _showNotifications(context),
            icon: Badge(
              isLabelVisible: count > 0,
              label: Text(count > 9 ? '9+' : '$count'),
              child: Icon(
                count == 0
                    ? Icons.notifications_none_rounded
                    : Icons.notifications_active_outlined,
                color: accentColor,
              ),
            ),
          ),
        );
      },
    );
  }
}
