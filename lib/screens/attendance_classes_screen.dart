import 'dart:async';

import '../widgets/pop_button_effects.dart';

import 'package:flutter/material.dart';

import 'student_requests_screen.dart';
import '../services/attendance_location_service.dart';
import '../services/nfc_attendance_service.dart';
import '../services/offline_attendance_service.dart';
import '../services/enrolled_classes_service.dart';
import '../widgets/class_actions_sheet.dart';
import '../widgets/nfc_scan_button.dart';
import '../theme/app_theme.dart';
import '../widgets/notification_button.dart';
import '../widgets/app_dropdown.dart';

class AttendanceClassesScreen extends StatefulWidget {
  const AttendanceClassesScreen({super.key});

  @override
  State<AttendanceClassesScreen> createState() =>
      _AttendanceClassesScreenState();
}

class _AttendanceClassesScreenState extends State<AttendanceClassesScreen> {
  // Colors follow the selected Light/Dark mode.
  static Color get backgroundColor => AppColors.background;
  static Color get cardColor => AppColors.card;
  static Color get accentColor => AppColors.accent;
  static Color get buttonColor => AppColors.button;
  static Color get borderColor => AppColors.border;
  static Color get secondaryTextColor => AppColors.secondaryText;

  List<Map<String, String>> _classes = [];
  List<Map<String, String>> _archivedClasses = [];
  bool _isLoadingClasses = true;
  // Classes Joined starts open; Archived Classes starts closed.
  bool _joinedOpen = true;
  bool _archivedOpen = false;
  final _joinedScroll = ScrollController();
  final _archivedScroll = ScrollController();
  String? _classesError;
  int _loadVersion = 0;

  @override
  void initState() {
    super.initState();
    EnrolledClassesService.changes.addListener(_onClassesChanged);
    NfcAttendanceService.changes.addListener(_onAttendanceChanged);
    _loadClasses();
  }

  @override
  void dispose() {
    EnrolledClassesService.changes.removeListener(_onClassesChanged);
    NfcAttendanceService.changes.removeListener(_onAttendanceChanged);
    ++_attendanceVersion;
    _joinedScroll.dispose();
    _archivedScroll.dispose();
    super.dispose();
  }

  void _onClassesChanged() {
    _loadClasses();
  }

  Future<void> _loadClasses() async {
    final version = ++_loadVersion;
    // Pull to refresh also retries sending anything saved offline.
    unawaited(OfflineAttendanceService.instance.sync());
    setState(() {
      _isLoadingClasses = true;
      _classesError = null;
    });

    try {
      final all = await EnrolledClassesService.loadAll();
      final classes = all
          .where((c) => c['status'] != EnrolledClassesService.archivedStatus)
          .toList();
      if (!mounted || version != _loadVersion) return;
      setState(() {
        _classes = classes;
        _archivedClasses = all
            .where((c) => c['status'] == EnrolledClassesService.archivedStatus)
            .toList();
        if (!classes.any((item) => item['id'] == _selectedClassId)) {
          _selectedClassId = null;
        }
      });
      await _loadAttendance();
    } catch (_) {
      if (!mounted || version != _loadVersion) return;
      setState(() {
        _classesError =
        'Could not load your classes. Check your connection '
            'and try again. If this continues, contact your administrator.';
      });
    } finally {
      if (mounted && version == _loadVersion) {
        setState(() => _isLoadingClasses = false);
      }
    }
  }

  final _attendanceService = NfcAttendanceService();
  final _locationService = AttendanceLocationService();
  List<Map<String, String>> _attendanceRecords = [];
  bool _loadingAttendance = false;
  String? _attendanceError;
  int _attendanceVersion = 0;

  void _onAttendanceChanged() {
    _loadAttendance();
  }

  Future<void> _loadAttendance() async {
    final classId = _selectedClassId;
    final version = ++_attendanceVersion;
    if (classId == null) {
      if (mounted) {
        setState(() {
          _attendanceRecords = [];
          _attendanceError = null;
          _loadingAttendance = false;
        });
      }
      return;
    }
    setState(() {
      _loadingAttendance = true;
      _attendanceError = null;
      _attendanceRecords = [];
    });
    try {
      final locationsFuture = _locationService
          .history(classId)
          .catchError((_) => <Map<String, dynamic>>[]); // History still shows without locations.
      final rows = await _attendanceService.history(classId);
      final locations = await locationsFuture;
      if (!mounted ||
          version != _attendanceVersion ||
          classId != _selectedClassId) {
        return;
      }
      setState(
            () => _attendanceRecords = rows.map((row) {
          final date = DateTime.tryParse(
            (row['check_in_time'] ?? row['session_started_at'] ?? '')
                .toString(),
          )?.toLocal();
          String two(int value) => value.toString().padLeft(2, '0');
          final raw = (row['status'] ?? 'Unknown').toString();
          final location = AttendanceLocationService.find(row, locations);
          return <String, String>{
            'classId': classId,
            'date': date == null
                ? '—'
                : '${date.year}-${two(date.month)}-${two(date.day)} ${two(date.hour)}:${two(date.minute)}',
            'status': raw.isEmpty
                ? 'Unknown'
                : '${raw[0].toUpperCase()}${raw.substring(1)}',
            'location': AttendanceLocationService.describe(location),
          };
        }).toList(),
      );
    } catch (_) {
      if (mounted && version == _attendanceVersion) {
        setState(
              () => _attendanceError =
          'Could not load attendance history. Pull down to retry.',
        );
      }
    } finally {
      if (mounted && version == _attendanceVersion) {
        setState(() => _loadingAttendance = false);
      }
    }
  }

  String? _selectedClassId;

  List<Map<String, String>> get _filteredRecords {
    if (_selectedClassId == null) return [];

    return _attendanceRecords
        .where((record) => record['classId'] == _selectedClassId)
        .toList();
  }

  Future<void> _showClassActions() async {
    await ClassActionsSheet.show(context);
  }

  Widget _buildHeader() {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Attendance & Classes',
                style: TextStyle(
                  color: AppColors.text,
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 5),
              Text(
                'Your classes and attendance records',
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

  /// A card with a title. With [onToggle], tapping the title opens or
  /// closes it, and [child] shows only while [open].
  Widget _buildSection({
    required String title,
    required IconData icon,
    required Widget child,
    bool open = true,
    VoidCallback? onToggle,
  }) {
    final header = Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          Icon(icon, color: accentColor, size: 22),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              title,
              style: TextStyle(
                color: AppColors.text,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          if (onToggle != null)
            AnimatedRotation(
              turns: open ? 0.5 : 0,
              duration: const Duration(milliseconds: 200),
              child: Icon(
                Icons.keyboard_arrow_down_rounded,
                color: accentColor,
              ),
            ),
        ],
      ),
    );

    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (onToggle == null)
            header
          else
            Semantics(
              button: true,
              expanded: open,
              child: InkWell(onTap: onToggle, child: header),
            ),
          AnimatedSize(
            duration: const Duration(milliseconds: 200),
            alignment: Alignment.topCenter,
            child: open ? child : const SizedBox(width: double.infinity),
          ),
        ],
      ),
    );
  }

  Widget _buildTableRow(List<String> values, {bool header = false}) {
    return Container(
      decoration: BoxDecoration(
        color: header ? buttonColor : Colors.transparent,
        border: header
            ? null
            : Border(top: BorderSide(color: borderColor)),
      ),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: List.generate(values.length, (index) {
            return Expanded(
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 14,
                ),
                decoration: BoxDecoration(
                  border: index < values.length - 1
                      ? Border(right: BorderSide(color: borderColor))
                      : null,
                ),
                child: Text(
                  values[index],
                  style: TextStyle(
                    color: header ? Colors.white : secondaryTextColor,
                    fontSize: 12,
                    fontWeight: header ? FontWeight.w600 : FontWeight.normal,
                  ),
                ),
              ),
            );
          }),
        ),
      ),
    );
  }

  static const _visibleClassRows = 5;

  /// Class table rows: up to five show at once; more scroll inside the
  /// card, under the table header.
  Widget _buildClassRows(
    List<Map<String, String>> classes,
    ScrollController controller,
  ) {
    final rows = [
      for (final item in classes)
        _buildTableRow([
          item['subject'] ?? '—',
          item['professor'] ?? '—',
          item['status'] ?? '—',
        ]),
    ];
    if (classes.length <= _visibleClassRows) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: rows,
      );
    }
    // One single-line row: 14 px padding top and bottom, the text, and the
    // 1 px divider, grown with the phone's text size.
    final rowHeight = 29 + MediaQuery.textScalerOf(context).scale(12) * 1.45;
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: rowHeight * _visibleClassRows),
      child: Scrollbar(
        controller: controller,
        thumbVisibility: true,
        child: SingleChildScrollView(
          controller: controller,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: rows,
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyState({
    required IconData icon,
    required String title,
    required String description,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 28),
      child: Column(
        children: [
          Icon(icon, color: secondaryTextColor, size: 32),
          const SizedBox(height: 12),
          Text(
            title,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppColors.text,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            description,
            textAlign: TextAlign.center,
            style: TextStyle(color: secondaryTextColor, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _buildClassesSection() {
    return _buildSection(
      title: 'Classes Joined',
      icon: Icons.menu_book_outlined,
      open: _joinedOpen,
      onToggle: () => setState(() => _joinedOpen = !_joinedOpen),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildTableRow(['Subject', 'Professor', 'Status'], header: true),
          if (_isLoadingClasses)
            Padding(
              padding: const EdgeInsets.all(28),
              child: Center(
                child: CircularProgressIndicator(color: accentColor),
              ),
            )
          else if (_classesError != null)
            Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                children: [
                  Text(
                    _classesError!,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: secondaryTextColor),
                  ),
                  const SizedBox(height: 12),
                  TextButton.icon(
                    onPressed: _loadClasses,
                    icon: const Icon(Icons.refresh_rounded),
                    label: const Text('Try Again'),
                  ),
                ],
              ),
            )
          else if (_classes.isEmpty)
              _buildEmptyState(
                icon: Icons.school_outlined,
                title: 'No classes joined yet',
                description: 'Your enrolled classes will appear here.',
              )
            else
              _buildClassRows(_classes, _joinedScroll),
        ],
      ),
    );
  }

  /// Classes the professor archived. Kept for reference; they aren't offered
  /// as subject choices.
  Widget _buildArchivedSection() {
    final count = _archivedClasses.length;
    return _buildSection(
      title: count == 0 ? 'Archived Classes' : 'Archived Classes ($count)',
      icon: Icons.inventory_2_outlined,
      open: _archivedOpen,
      onToggle: () => setState(() => _archivedOpen = !_archivedOpen),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildTableRow(['Subject', 'Professor', 'Status'], header: true),
          if (_isLoadingClasses)
            Padding(
              padding: const EdgeInsets.all(28),
              child: Center(
                child: CircularProgressIndicator(color: accentColor),
              ),
            )
          else if (_archivedClasses.isEmpty)
            _buildEmptyState(
              icon: Icons.inventory_2_outlined,
              title: 'No archived classes',
              description:
                  'Classes your professor archives will appear here.',
            )
          else
            _buildClassRows(_archivedClasses, _archivedScroll),
        ],
      ),
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
          value: _selectedClassId,
          isExpanded: true,
          dropdownColor: cardColor,
          // The list that opens has rounded corners like the cards.
          borderRadius: BorderRadius.circular(16),
          iconEnabledColor: accentColor,
          iconDisabledColor: secondaryTextColor,
          style: TextStyle(color: AppColors.text, fontSize: 13),
          hint: Text(
            'Select a subject',
            style: TextStyle(color: secondaryTextColor, fontSize: 13),
          ),
          items: _classes.map((item) {
            return DropdownMenuItem<String>(
              value: item['id'],
              child: Text(
                "${item['subject'] ?? 'Unnamed subject'}${(item['section'] ?? '').isEmpty ? '' : ' • ${item['section']}'}",
                overflow: TextOverflow.ellipsis,
              ),
            );
          }).toList(),
          onChanged:
          _classes.isEmpty || _isLoadingClasses || _classesError != null
              ? null
              : (value) {
            setState(() {
              _selectedClassId = value;
            });
            _loadAttendance();
          },
      ),
    );
  }

  /// QR scans saved offline for this class: still waiting, or refused today.
  List<List<String>> _offlineRows(List<Map<String, dynamic>> pending) {
    String when(dynamic value) {
      final date = DateTime.tryParse(value?.toString() ?? '');
      if (date == null) return '—';
      String two(int n) => n.toString().padLeft(2, '0');
      return '${date.year}-${two(date.month)}-${two(date.day)} '
          '${two(date.hour)}:${two(date.minute)}';
    }

    final offline = OfflineAttendanceService.instance;
    final problem = offline.lastError.value;
    return [
      for (final item in pending)
        if (item['kind'] == 'qr' && item['class_id'] == _selectedClassId)
          [
            when(item['created_at']),
            'Waiting to send',
            problem == null
                ? 'Saved offline; sends automatically when you are back online'
                : 'Not sent yet: $problem',
          ],
      for (final item in offline.refused.value)
        if (item['kind'] == 'qr' && item['class_id'] == _selectedClassId)
          [
            when(item['saved_at']),
            'Not accepted',
            'Offline scan refused: '
                '${OfflineAttendanceService.explain(item['code'] as String?)}',
          ],
    ];
  }

  Widget _buildAttendanceHistory() {
    final offline = OfflineAttendanceService.instance;
    return ListenableBuilder(
      listenable: Listenable.merge([offline.pending, offline.lastError]),
      builder: (context, _) => _buildAttendanceTable(
        _offlineRows(offline.pending.value),
      ),
    );
  }

  Widget _buildAttendanceTable(List<List<String>> offlineRows) {
    final records = _filteredRecords;

    return _buildSection(
      title: 'Attendance History',
      icon: Icons.history_rounded,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildTableRow(['Date', 'Status', 'Location'], header: true),
          ...offlineRows.map(_buildTableRow),
          if (_loadingAttendance)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_attendanceError != null)
            Padding(
              padding: const EdgeInsets.all(20),
              child: Text(_attendanceError!),
            )
          else if (records.isEmpty && offlineRows.isEmpty)
              _buildEmptyState(
                icon: Icons.event_busy_outlined,
                title: _selectedClassId == null
                    ? 'Select a subject'
                    : 'No attendance recorded yet',
                description: _selectedClassId == null
                    ? 'Choose a subject to view its attendance history.'
                    : 'Confirmed attendance for this subject will appear here.',
              )
            else
              ...records.map(
                    (record) => _buildTableRow([
                  record['date'] ?? '—',
                  record['status'] ?? '—',
                  record['location'] ?? 'Not recorded',
                ]),
              ),
        ],
      ),
    );
  }

  Widget _buildActions() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                flex: 1,
                child: PopButtonEffects(
                  child: ElevatedButton.icon(
                    onPressed: _showClassActions,
                    style: ElevatedButton.styleFrom(
                      elevation: 0,
                      shadowColor: Colors.transparent,
                      surfaceTintColor: Colors.transparent,
                      backgroundColor: buttonColor,
                      foregroundColor: Colors.white,
                      minimumSize: const Size(0, 56),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 16,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    icon: const Icon(Icons.qr_code_scanner_rounded, size: 22),
                    label: const Text(
                      'Join Class / Scan QR',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              const Expanded(child: NfcScanButton()),
            ],
          ),
        ),

        const SizedBox(height: 12),
        PopButtonEffects(
          child: ElevatedButton.icon(
            onPressed: () => Navigator.of(context).push<void>(
              MaterialPageRoute(
                builder: (_) =>
                    StudentRequestsScreen(initialClassId: _selectedClassId),
              ),
            ),
            style: ElevatedButton.styleFrom(
              elevation: 0,
              shadowColor: Colors.transparent,
              surfaceTintColor: Colors.transparent,
              backgroundColor: buttonColor,
              foregroundColor: Colors.white,
              minimumSize: const Size(0, 56),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            icon: const Icon(Icons.description_outlined),
            label: const Text('Submit a letter', textAlign: TextAlign.center),
          ),
        ),
      ],
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
              onRefresh: _loadClasses,
              color: accentColor,
              backgroundColor: cardColor,
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
                        _buildHeader(),
                        const SizedBox(height: 20),
                        _buildClassesSection(),
                        const SizedBox(height: 16),
                        _buildArchivedSection(),
                        const SizedBox(height: 20),
                        _buildSubjectDropdown(),
                        const SizedBox(height: 16),
                        _buildAttendanceHistory(),
                        const SizedBox(height: 20),
                        _buildActions(),
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
