import '../widgets/pop_button_effects.dart';

import 'package:flutter/material.dart';


import '../widgets/class_actions_sheet.dart';
import '../widgets/nfc_scan_button.dart';
import '../services/student_home_service.dart';
import '../services/archived_classes_service.dart';
import '../services/enrolled_classes_service.dart';
import '../services/offline_attendance_service.dart';
import '../theme/app_theme.dart';
import '../widgets/notification_button.dart';
import '../widgets/app_dropdown.dart';

class StudentHomeScreen extends StatefulWidget {
  const StudentHomeScreen({super.key});

  @override
  State<StudentHomeScreen> createState() => _StudentHomeScreenState();
}

class _StudentHomeScreenState extends State<StudentHomeScreen> {
  // Colors follow the selected Light/Dark mode.
  static Color get backgroundColor => AppColors.background;
  static Color get cardColor => AppColors.card;
  static Color get accentColor => AppColors.accent;
  static Color get buttonColor => AppColors.button;
  static Color get borderColor => AppColors.border;
  static Color get secondaryTextColor => AppColors.secondaryText;

  List<Map<String, dynamic>> _activities = [];
  bool _activitiesLoading = true;
  String? _activitiesError;
  int _activitiesVersion = 0;
  final _activitiesScroll = ScrollController();

  Future<void> _loadActivities() async {
    final version = ++_activitiesVersion;
    setState(() {
      _activitiesLoading = true;
      _activitiesError = null;
      _activities = [];
    });
    try {
      final rows = await StudentHomeService.loadActivities();
      if (!mounted || version != _activitiesVersion) return;
      setState(() => _activities = rows);
    } catch (_) {
      if (mounted && version == _activitiesVersion) {
        setState(
              () => _activitiesError =
          'Could not load activities. Check your connection and try again.',
        );
      }
    } finally {
      if (mounted && version == _activitiesVersion) {
        setState(() => _activitiesLoading = false);
      }
    }
  }

  Future<void> _refreshHome() async {
    await Future.wait([_loadHome(), _loadActivities()]);
  }

  String? _studentName;
  String? _selectedSubject;
  List<Map<String, dynamic>> _classes = [];
  bool _isLoading = true;
  String? _error;
  int _loadVersion = 0;

  @override
  void initState() {
    super.initState();
    EnrolledClassesService.changes.addListener(_onClassesChanged);
    StudentHomeService.activitiesRequested.addListener(_onActivitiesRequested);
    _refreshHome();
  }

  @override
  void dispose() {
    EnrolledClassesService.changes.removeListener(_onClassesChanged);
    StudentHomeService.activitiesRequested
        .removeListener(_onActivitiesRequested);
    _activitiesScroll.dispose();
    ++_activitiesVersion;
    ++_loadVersion;
    super.dispose();
  }

  void _onClassesChanged() {
    _refreshHome();
  }

  /// A "new activity" notification was tapped: show that class's activities,
  /// including the new one.
  void _onActivitiesRequested() {
    final classId = StudentHomeService.activitiesRequested.value;
    if (classId == null) return;
    if (_classes.any((item) => item['id'] == classId)) {
      setState(() => _selectedSubject = classId);
    }
    _loadActivities();
  }

  Future<void> _loadHome() async {
    final version = ++_loadVersion;
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final data = await StudentHomeService.load();
      // Archived classes aren't offered as subject choices.
      final classes = await ArchivedClassesService.withoutArchived(
        (data['classes'] as List)
            .map((item) => Map<String, dynamic>.from(item as Map))
            .toList(),
      );
      if (!mounted || version != _loadVersion) return;
      setState(() {
        _studentName = data['student_name'] as String?;
        _classes = classes;
        if (!classes.any((item) => item['id'] == _selectedSubject)) {
          _selectedSubject = classes.isEmpty
              ? null
              : classes.first['id'] as String;
        }
      });
    } catch (_) {
      final offline = await OfflineAttendanceService.isOffline();
      if (!mounted || version != _loadVersion) return;
      setState(() {
        _error = offline
            ? "You're offline. Your dashboard will load when you reconnect. "
                  'You can still scan the QR code below; your check-in is '
                  'saved and sent later.'
            : 'Could not load your dashboard. Check your connection '
                  'and try again.';
      });
    } finally {
      if (mounted && version == _loadVersion) {
        setState(() => _isLoading = false);
      }
    }
  }

  Map<String, dynamic>? get _selectedClass {
    for (final item in _classes) {
      if (item['id'] == _selectedSubject) return item;
    }
    return null;
  }

  Future<void> _showClassActions() async {
    await ClassActionsSheet.show(context);
  }

  Widget _buildHeader() {
    final name = _studentName?.trim();

    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                name == null || name.isEmpty
                    ? 'Welcome, Student!'
                    : 'Hi! $name',
                style: TextStyle(
                  color: AppColors.text,
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 5),
              Text(
                "Here's your academic overview",
                style: TextStyle(color: secondaryTextColor, fontSize: 12),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        const NotificationButton(),
      ],
    );
  }

  Widget _buildSubjectDropdown() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: borderColor),
      ),
      child: AppDropdown<String>(
        outerPadding: 14,
          value: _selectedSubject,
          isExpanded: true,
          dropdownColor: cardColor,
          // The list that opens has rounded corners like the cards.
          borderRadius: BorderRadius.circular(16),
          iconEnabledColor: accentColor,
          iconDisabledColor: secondaryTextColor,
          style: TextStyle(color: AppColors.text, fontSize: 13),
          hint: Text(
            'Select an enrolled subject',
            style: TextStyle(color: secondaryTextColor, fontSize: 13),
          ),
          items: _classes.map((subject) {
            return DropdownMenuItem<String>(
              value: subject['id'] as String,
              child: Text(
                '${subject['subject']} — ${subject['section']}',
                overflow: TextOverflow.ellipsis,
              ),
            );
          }).toList(),
          onChanged: _classes.isEmpty
              ? null
              : (value) {
            setState(() {
              _selectedSubject = value;
            });
          },
      ),
    );
  }

  Widget _buildSummaryCard({
    required String title,
    required String value,
    required String emptyMessage,
    required IconData icon,
    required bool compact,
  }) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.all(compact ? 12 : 20),
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: accentColor, size: compact ? 22 : 27),
          const SizedBox(height: 12),
          Text(
            title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: secondaryTextColor,
              fontSize: compact ? 11 : 14,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            value,
            style: TextStyle(
              color: AppColors.text,
              fontSize: compact ? 28 : 34,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            emptyMessage,
            style: TextStyle(
              color: secondaryTextColor,
              fontSize: compact ? 10 : 12,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSummarySection(bool compact) {
    final selected = _selectedClass;
    final count = (selected?['attendance_count'] as num?)?.toInt() ?? 0;
    final statuses = (selected?['attendance_statuses'] as List?) ?? [];
    final breakdown = statuses
        .map((item) {
      final row = Map<String, dynamic>.from(item as Map);
      return '${row['status']}: ${row['count']}';
    })
        .join(' • ');

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: _buildSummaryCard(
              title: 'Current Grade',
              value: '—',
              emptyMessage: 'Grade records are not connected yet.',
              icon: Icons.school_outlined,
              compact: compact,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _buildSummaryCard(
              title: 'Attendance Summary',
              value: selected == null ? '—' : '$count',
              emptyMessage: selected == null
                  ? 'Join a class to view attendance.'
                  : count == 0
                  ? 'No recorded attendance for this class.'
                  : 'Recorded entries\n$breakdown',
              icon: Icons.fact_check_outlined,
              compact: compact,
            ),
          ),
        ],
      ),
    );
  }

  String _activityTime(dynamic raw) {
    final parts = (raw?.toString() ?? '').split(':');
    if (parts.length < 2) return 'Time not specified';
    final hour = int.tryParse(parts[0]);
    if (hour == null) return 'Time not specified';
    return '${hour % 12 == 0 ? 12 : hour % 12}:${parts[1]} ${hour < 12 ? 'AM' : 'PM'}';
  }

  void _showActivity(Map<String, dynamic> row) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: cardColor,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                row['title']?.toString() ?? 'Activity',
                style: TextStyle(
                  color: AppColors.text,
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                '${row['subject']} • ${row['section']}',
                style: TextStyle(color: accentColor),
              ),
              const SizedBox(height: 16),
              Text(
                'Date: ${row['date']}',
                style: TextStyle(color: AppColors.text),
              ),
              const SizedBox(height: 8),
              Text(
                '${_activityTime(row['start_time'])} – ${_activityTime(row['end_time'])}',
                style: TextStyle(color: AppColors.text),
              ),
              const SizedBox(height: 8),
              Text(
                'Type: ${row['activity_type'] ?? 'Activity'}',
                style: TextStyle(color: secondaryTextColor),
              ),
              const SizedBox(height: 8),
              Text(
                'Participation: ${row['participation'] ?? 'Not specified'}',
                style: TextStyle(color: secondaryTextColor),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildActivitiesSection() {
    final rows = _activities
        .where((row) => row['class_id']?.toString() == _selectedSubject)
        .toList();
    final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
    final rowHeight = 112.0 * (textScale < 1 ? 1 : textScale);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                Icons.event_note_rounded,
                color: accentColor,
                size: 22,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Upcoming Activities',
                  style: TextStyle(
                    color: AppColors.text,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              IconButton(
                onPressed: _activitiesLoading ? null : _loadActivities,
                icon: Icon(Icons.refresh_rounded, color: accentColor),
                tooltip: 'Refresh activities',
              ),
            ],
          ),
          Text(
            'Today and upcoming • ${rows.length} ${rows.length == 1 ? 'activity' : 'activities'} • selected subject',
            style: TextStyle(color: secondaryTextColor, fontSize: 12),
          ),
          const SizedBox(height: 16),
          if (_activitiesLoading)
            Padding(
              padding: const EdgeInsets.all(20),
              child: Center(
                child: CircularProgressIndicator(color: accentColor),
              ),
            )
          else if (_activitiesError != null) ...[
            Text(
              _activitiesError!,
              style: TextStyle(color: secondaryTextColor),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: _loadActivities,
                child: const Text('Try again'),
              ),
            ),
          ] else if (_selectedSubject == null)
            Text(
              'Join a class to see its activities.',
              style: TextStyle(color: secondaryTextColor),
            )
          else if (rows.isEmpty)
              Text(
                'No upcoming activities for this subject.',
                style: TextStyle(color: secondaryTextColor),
              )
            else
              SizedBox(
                height: rowHeight * (rows.length < 3 ? rows.length : 3),
                child: Scrollbar(
                  controller: _activitiesScroll,
                  thumbVisibility: rows.length > 3,
                  child: ListView.builder(
                    controller: _activitiesScroll,
                    primary: false,
                    itemExtent: rowHeight,
                    padding: const EdgeInsets.only(right: 12),
                    itemCount: rows.length,
                    itemBuilder: (context, index) {
                      final row = rows[index];
                      return Container(
                        decoration: BoxDecoration(
                          border: Border(top: BorderSide(color: borderColor)),
                        ),
                        child: InkWell(
                          onTap: () => _showActivity(row),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        row['title']?.toString() ?? 'Activity',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          color: AppColors.text,
                                          fontSize: 14,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                      const SizedBox(height: 6),
                                      Text(
                                        '${row['date']} • ${_activityTime(row['start_time'])}\n${row['activity_type'] ?? 'Activity'} • ${row['participation'] ?? ''}',
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          color: secondaryTextColor,
                                          fontSize: 12,
                                          height: 1.5,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Icon(
                                  Icons.chevron_right,
                                  color: accentColor,
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
        ],
      ),
    );
  }

  Widget _buildJoinClassButton() {
    return SizedBox(
      width: double.infinity,
      child: PopButtonEffects(
        child: ElevatedButton.icon(
          onPressed: _showClassActions,
          style: ElevatedButton.styleFrom(
            elevation: 0,
            shadowColor: Colors.transparent,
            surfaceTintColor: Colors.transparent,
            backgroundColor: buttonColor,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
            minimumSize: const Size(0, 56),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          icon: const Icon(Icons.qr_code_scanner_rounded),
          label: const Text(
            'Join Class / Scan QR',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: backgroundColor,
      resizeToAvoidBottomInset: false,
      body: SafeArea(
        bottom: false,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final compact = constraints.maxWidth < 600;

            return RefreshIndicator(
              onRefresh: _refreshHome,
              child: SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: EdgeInsets.symmetric(
                  horizontal: compact ? 16 : 24,
                  vertical: 20,
                ),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1000),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (_isLoading)
                          const Center(child: CircularProgressIndicator())
                        else if (_error != null)
                          Column(
                            children: [
                              Text(_error!, textAlign: TextAlign.center),
                              TextButton(
                                onPressed: _refreshHome,
                                child: const Text('Try again'),
                              ),
                            ],
                          )
                        else ...[
                            _buildHeader(),
                            const SizedBox(height: 20),
                            if (_classes.isEmpty)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 16),
                                child: Text(
                                  'No classes joined yet. Use Join Class '
                                      'to enter your professor’s access code.',
                                  style: TextStyle(color: secondaryTextColor),
                                ),
                              ),
                            _buildSubjectDropdown(),
                            const SizedBox(height: 20),
                            _buildSummarySection(compact),
                            const SizedBox(height: 20),
                            _buildActivitiesSection(),
                            const SizedBox(height: 20),
                          ],
                        IntrinsicHeight(
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Expanded(child: _buildJoinClassButton()),
                              const SizedBox(width: 10),
                              const Expanded(child: NfcScanButton()),
                            ],
                          ),
                        ),
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
