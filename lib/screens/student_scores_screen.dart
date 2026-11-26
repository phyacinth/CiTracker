import '../widgets/pop_button_effects.dart';

import 'dart:async';

import 'package:flutter/material.dart';

import '../services/archived_classes_service.dart';
import '../services/grade_scale.dart';
import '../services/student_scores_service.dart';
import '../services/student_tab_navigation.dart';
import '../theme/app_theme.dart';
import '../widgets/notification_button.dart';
import '../widgets/app_dropdown.dart';

class StudentScoresScreen extends StatefulWidget {
  const StudentScoresScreen({super.key});

  @override
  State<StudentScoresScreen> createState() => _StudentScoresScreenState();
}

class _StudentScoresScreenState extends State<StudentScoresScreen> {
  static Color get backgroundColor => AppColors.background;
  static Color get cardColor => AppColors.card;
  static Color get accentColor => AppColors.accent;
  static Color get borderColor => AppColors.border;
  static Color get secondaryTextColor => AppColors.secondaryText;

  final List<String> _subjects = [];
  final Map<String, Map<String, dynamic>> _classes = {};
  String? _selectedSubject;
  String? _studentId;
  String? _gradePosted;
  double? _overallGrade;
  String? _remark;
  Map<String, dynamic>? _summary;
  // Starts closed, like the Midterm and Finals cards.
  bool _summaryOpen = false;
  GradeTerm _midterm = const GradeTerm(title: 'Midterm', categories: []);
  GradeTerm _finals = const GradeTerm(title: 'Finals', categories: []);
  bool _loading = true;
  String? _error;
  int _request = 0;

  // Live sync: every few seconds, ask whether anything in the gradebook
  // changed, and reload quietly when it did.
  static const _syncEvery = Duration(seconds: 15);
  Timer? _syncTimer;
  AppLifecycleListener? _lifecycle;
  String? _version;
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    StudentTabNavigation.requested.addListener(_onTabRequested);
    _syncTimer = Timer.periodic(_syncEvery, (_) => _checkForChanges());
    _lifecycle = AppLifecycleListener(onResume: _checkForChanges);
    _load();
  }

  @override
  void dispose() {
    StudentTabNavigation.requested.removeListener(_onTabRequested);
    _syncTimer?.cancel();
    _lifecycle?.dispose();
    super.dispose();
  }

  /// Reloads when the professor saved, changed or deleted a score or grade.
  Future<void> _checkForChanges() async {
    if (!mounted || _loading || _checking) return;
    final state = WidgetsBinding.instance.lifecycleState;
    if (state != null && state != AppLifecycleState.resumed) return;
    _checking = true;
    try {
      final version = await StudentScoresService.version();
      if (!mounted || version == null || _loading) return;
      if (_version != null && version != _version) {
        await _load(quiet: true);
      }
      _version ??= version;
    } finally {
      _checking = false;
    }
  }

  // Opened from a grades notification: reload so the new grades show.
  void _onTabRequested() {
    if (StudentTabNavigation.requested.value == StudentTabNavigation.scores) {
      _load();
    }
  }

  double _number(dynamic value) =>
      value is num ? value.toDouble() : double.parse(value.toString());

  /// [quiet] is a live-sync reload: the screen keeps showing the current
  /// grades (no blank state or progress bar) and keeps them if it fails.
  Future<void> _load({bool quiet = false}) async {
    final request = ++_request;
    final previousSubject = _selectedSubject;
    if (!quiet) {
      setState(() {
        _loading = true;
        _error = null;
        _selectedSubject = null;
        _subjects.clear();
        _classes.clear();
        _studentId = null;
        _gradePosted = null;
        _overallGrade = null;
        _summary = null;
        _remark = null;
        _midterm = const GradeTerm(title: 'Midterm', categories: []);
        _finals = const GradeTerm(title: 'Finals', categories: []);
      });
    }
    try {
      // Taken before loading, so a change made while loading is caught by
      // the next check.
      final version = await StudentScoresService.version();
      final result = await StudentScoresService.load();
      // Archived classes aren't offered as subject choices.
      final classes = await ArchivedClassesService.withoutArchived(
        (result['classes'] as List)
            .map((row) => Map<String, dynamic>.from(row as Map))
            .toList(),
      );
      if (!mounted || request != _request) return;
      setState(() {
        _version = version;
        _error = null;
        _subjects.clear();
        _classes.clear();
        _studentId = result['student_number']?.toString();
        for (final row in classes) {
          final id = row['id'] as String;
          _subjects.add(id);
          _classes[id] = row;
        }
        if (_subjects.contains(previousSubject)) {
          _selectedSubject = previousSubject;
        } else {
          _selectedSubject = _subjects.isEmpty ? null : _subjects.first;
        }
        _selectClass();
      });
    } catch (_) {
      // A failed live-sync reload keeps what's on screen.
      if (!mounted || request != _request || quiet) return;
      setState(() {
        _selectedSubject = null;
        _error = 'Could not load grades. Check your connection and retry.';
      });
    } finally {
      if (mounted && request == _request && !quiet) {
        setState(() => _loading = false);
      }
    }
  }

  void _selectClass() {
    final rows = ((_classes[_selectedSubject]?['assessments'] as List?) ?? [])
        .map((row) => Map<String, dynamic>.from(row as Map))
        .toList();
    _midterm = _term('Midterm', 'midterm', rows);
    _finals = _term('Finals', 'final', rows);
    final dates =
        rows.map((row) => DateTime.parse(row['updated_at'] as String)).toList()
          ..sort();
    // updated_at is the latest score update, not a publication timestamp.
    _gradePosted = dates.isEmpty
        ? null
        : dates.last.toLocal().toString().split('.').first;

    // The latest gradebook summary the professor saved, Draft or published.
    final grade = _classes[_selectedSubject]?['grade'];
    final summary = grade is Map ? Map<String, dynamic>.from(grade) : null;
    _summary = summary;
    final finalGrade = summary?['final_grade'];
    _overallGrade = finalGrade == null ? null : _number(finalGrade);
    final isPublished = summary?['status'] == 'published';
    final savedKey = isPublished ? 'published_at' : 'updated_at';
    final saved = DateTime.tryParse(summary?[savedKey]?.toString() ?? '');
    if (saved != null &&
        (dates.isEmpty || saved.isAfter(dates.last))) {
      _gradePosted = saved.toLocal().toString().split('.').first;
    }
    final remarks = (summary?['remarks'] ?? '').toString().trim();
    _remark = summary != null
        ? (remarks.isNotEmpty
              ? remarks
              : isPublished
              ? 'Published by your professor'
              : 'Not yet published: your professor may still change it')
        : rows.isEmpty
        ? 'No grade yet'
        : 'Scores available; your professor hasn\'t saved an overall grade yet';
  }

  GradeTerm _term(String title, String term, List<Map<String, dynamic>> rows) {
    const names = {
      'exam': 'Term examinations',
      'recitation': 'Participation / recitation',
      'quiz': 'Quizzes',
      'project': 'Projects / activities',
      'attendance': 'Attendance',
    };
    return GradeTerm(
      title: title,
      categories: names.entries.map((entry) {
        final items = rows
            .where((r) => r['term'] == term && r['type'] == entry.key)
            .toList();
        final earned = items.fold<double>(
          0,
          (sum, r) => sum + _number(r['score']),
        );
        final possible = items.fold<double>(
          0,
          (sum, r) => sum + _number(r['max_score']),
        );
        return GradeCategory(
          name: entry.value,
          emptyNote: entry.key == 'exam'
              ? 'No exam scores for this term yet. Your overall exam '
                    'result is in the Gradebook summary above.'
              : null,
          earned: items.isEmpty ? null : earned,
          possible: items.isEmpty ? null : possible,
          percentage: possible > 0 ? earned / possible * 100 : null,
          // Category and term weighting need an agreed grading formula.
          assessments: items
              .map(
                (r) => GradeAssessment(
                  name: r['title'] as String,
                  date: r['date'] as String?,
                  earned: _number(r['score']),
                  possible: _number(r['max_score']),
                ),
              )
              .toList(),
        );
      }).toList(),
    );
  }

  Widget _buildHeader() {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Scores & Grades',
                style: TextStyle(
                  color: AppColors.text,
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 5),
              Text(
                'Your grades and assessment breakdown',
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
        hint: Text(
          'Select a subject',
          style: TextStyle(color: secondaryTextColor, fontSize: 13),
        ),
        style: TextStyle(color: AppColors.text, fontSize: 13),
        items: _subjects.map((subject) {
          return DropdownMenuItem<String>(
            value: subject,
            child: Text(
              '${_classes[subject]?['subject']} / ${_classes[subject]?['section']}',
              overflow: TextOverflow.ellipsis,
            ),
          );
        }).toList(),
        onChanged: (_loading || _subjects.isEmpty)
            ? null
            : (value) {
                setState(() {
                  _selectedSubject = value;
                  _selectClass();
                });
              },
      ),
    );
  }

  Widget _buildInfo(String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            color: secondaryTextColor,
            fontSize: 11,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.5,
          ),
        ),
        const SizedBox(height: 7),
        Text(value, style: TextStyle(color: AppColors.text, fontSize: 14)),
      ],
    );
  }

  Widget _buildGradeSummary() {
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
          Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'OVERALL NUMERICAL GRADE',
                        style: TextStyle(
                          color: secondaryTextColor,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Refresh grades',
                      onPressed: _loading ? null : _load,
                      color: accentColor,
                      disabledColor: secondaryTextColor,
                      icon: const Icon(Icons.refresh),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                // The numerical grade, with its percentage underneath.
                Text(
                  _overallGrade == null ? '—' : numericalGrade(_overallGrade!),
                  style: TextStyle(
                    color: AppColors.text,
                    fontSize: 38,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                if (_overallGrade != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    '${_overallGrade!.toStringAsFixed(2)}%',
                    style: TextStyle(
                      color: secondaryTextColor,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
                const SizedBox(height: 14),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: backgroundColor,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: borderColor),
                  ),
                  child: Text(
                    _remark ?? 'No grade yet',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: accentColor,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                Divider(color: borderColor, height: 1),
                const SizedBox(height: 20),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: _buildInfo('STUDENT ID', _studentId ?? '—'),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: _buildInfo(
                        'LATEST SCORE UPDATE',
                        _gradePosted ?? '—',
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: borderColor)),
            ),
            // Term weights live only in the professor's browser for now, so
            // only the scale is shown here.
            child: Text(
              'Grading scale: 1.00 (highest) to 5.00',
              style: TextStyle(color: secondaryTextColor, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  // Mirrors the professor's Gradebook (Summary): one published percentage per
  // category, across both terms. Exams only exist here, not per term.
  Widget _buildGradebookSummary(Map<String, dynamic> summary) {
    const rows = [
      ('Exams', 'exam_percentage'),
      ('Quizzes', 'quiz_percentage'),
      ('Projects / activities', 'project_percentage'),
      ('Participation / recitation', 'recitation_percentage'),
      ('Attendance', 'attendance_percentage'),
    ];

    // Same collapsible header as the Midterm and Finals cards.
    final radius = BorderRadius.vertical(
      top: const Radius.circular(16),
      bottom: Radius.circular(_summaryOpen ? 0 : 16),
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
          PopButtonEffects(
            borderRadius: radius,
            child: Material(
              color: AppColors.button,
              clipBehavior: Clip.antiAlias,
              borderRadius: radius,
              child: InkWell(
                onTap: () => setState(() => _summaryOpen = !_summaryOpen),
                child: Semantics(
                  expanded: _summaryOpen,
                  child: Padding(
                    padding: const EdgeInsets.all(18),
                    child: Row(
                      children: [
                        const Expanded(
                          child: Text(
                            'Gradebook Summary',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        AnimatedRotation(
                          turns: _summaryOpen ? 0.5 : 0,
                          duration: const Duration(milliseconds: 200),
                          child: const Icon(
                            Icons.keyboard_arrow_down_rounded,
                            color: Colors.white,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (_summaryOpen) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 8),
              child: Text(
                _summary?['status'] == 'published'
                    ? 'Midterm and finals combined, as published by your '
                          'professor.'
                    : 'Midterm and finals combined, as last saved by your '
                          'professor. Not yet published: it may still change.',
                style: TextStyle(color: secondaryTextColor, fontSize: 12),
              ),
            ),
            for (final (name, key) in rows)
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 14,
                ),
                decoration: BoxDecoration(
                  border: Border(top: BorderSide(color: borderColor)),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        name,
                        style: TextStyle(color: AppColors.text, fontSize: 13),
                      ),
                    ),
                    Text(
                      summary[key] == null
                          ? '—'
                          : '${_number(summary[key]).toStringAsFixed(2)}%',
                      style: TextStyle(
                        color: accentColor,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // The shared dashboard owns the bottom navigation.
    return Scaffold(
      backgroundColor: backgroundColor,
      resizeToAvoidBottomInset: false,
      body: SafeArea(
        bottom: false,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final compact = constraints.maxWidth < 600;

            return SingleChildScrollView(
              key: const PageStorageKey('student-scores-scroll'),
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
                      if (_loading) const LinearProgressIndicator(),
                      if (_error != null)
                        Text(
                          _error!,
                          style: TextStyle(color: AppColors.warning),
                        ),
                      const SizedBox(height: 20),
                      _buildSubjectDropdown(),
                      const SizedBox(height: 12),
                      Text(
                        _subjects.isEmpty
                            ? 'Your enrolled subjects will appear here.'
                            : 'Select a subject to view its grades. They '
                                  'update automatically as your professor '
                                  'edits the gradebook.',
                        style: TextStyle(
                          color: secondaryTextColor,
                          fontSize: 12,
                        ),
                      ),
                      const SizedBox(height: 20),
                      _buildGradeSummary(),
                      if (_summary != null) ...[
                        const SizedBox(height: 20),
                        _buildGradebookSummary(_summary!),
                      ],
                      const SizedBox(height: 20),
                      GradeBreakdownCard(
                        key: const ValueKey('midterm-breakdown'),
                        term: _midterm,
                      ),
                      const SizedBox(height: 16),
                      GradeBreakdownCard(
                        key: const ValueKey('finals-breakdown'),
                        term: _finals,
                      ),
                      const SizedBox(height: 20),
                      Text(
                        'Scores update automatically as your professor '
                        'saves them. Until your professor publishes the '
                        'gradebook, they may still change.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: secondaryTextColor,
                          fontSize: 12,
                        ),
                      ),
                    ],
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

// SHARED TERM BREAKDOWN
// Midterm and Finals each receive their own independent widget instance.
class GradeBreakdownCard extends StatefulWidget {
  const GradeBreakdownCard({super.key, required this.term});

  final GradeTerm term;

  @override
  State<GradeBreakdownCard> createState() => _GradeBreakdownCardState();
}

class _GradeBreakdownCardState extends State<GradeBreakdownCard> {
  static Color get backgroundColor => AppColors.background;
  static Color get cardColor => AppColors.card;
  static Color get accentColor => AppColors.accent;
  static Color get buttonColor => AppColors.button;
  static Color get borderColor => AppColors.border;
  static Color get secondaryTextColor => AppColors.secondaryText;

  // Category, Earned / Possible, Percentage share the card's width, so the
  // table fits a phone without sideways scrolling. Weight columns return once
  // the professor dashboard saves weights.
  static const _columnFlex = <int>[5, 3, 3];

  final Set<int> _expandedCategories = {};
  bool _expanded = false;

  void _toggleCategory(int index) {
    setState(() {
      if (!_expandedCategories.add(index)) {
        _expandedCategories.remove(index);
      }
    });
  }

  Widget _textCell(String value, {bool header = false, bool accent = false}) {
    return Text(
      value,
      style: TextStyle(
        color: accent
            ? accentColor
            : header
            ? AppColors.text
            : secondaryTextColor,
        fontSize: header ? 11 : 13,
        fontWeight: header || accent ? FontWeight.w600 : FontWeight.normal,
      ),
    );
  }

  Widget _buildRow({required List<Widget> cells, bool header = false}) {
    return Container(
      decoration: BoxDecoration(
        color: header ? backgroundColor : cardColor,
        border: Border(bottom: BorderSide(color: borderColor)),
      ),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: List.generate(cells.length, (index) {
            return Expanded(
              flex: _columnFlex[index],
              child: Container(
                alignment: Alignment.centerLeft,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 16,
                ),
                child: cells[index],
              ),
            );
          }),
        ),
      ),
    );
  }

  Widget _buildCategoryRow(int index, GradeCategory category) {
    final expanded = _expandedCategories.contains(index);

    return _buildRow(
      cells: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              category.name,
              style: TextStyle(
                color: AppColors.text,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 5),
            TextButton(
              onPressed: () => _toggleCategory(index),
              style: TextButton.styleFrom(
                foregroundColor: accentColor,
                padding: const EdgeInsets.symmetric(horizontal: 4),
                minimumSize: const Size(0, 48),
                alignment: Alignment.centerLeft,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    expanded
                        ? Icons.keyboard_arrow_down_rounded
                        : Icons.keyboard_arrow_right_rounded,
                    size: 18,
                  ),
                  const SizedBox(width: 3),
                  const Flexible(
                    child: Text(
                      'Assessment scores',
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        _textCell(
          category.earned == null || category.possible == null
              ? '— / —'
              : '${_formatNumber(category.earned!)} / '
                    '${_formatNumber(category.possible!)}',
        ),
        _textCell(
          category.percentage == null
              ? '—'
              : '${category.percentage!.toStringAsFixed(2)}%',
        ),
      ],
    );
  }

  Widget _buildAssessmentDetails(GradeCategory category) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 16),
      decoration: BoxDecoration(
        color: backgroundColor,
        border: Border(bottom: BorderSide(color: borderColor)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(
              '${category.name} — Assessment scores',
              style: TextStyle(
                color: accentColor,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(height: 12),
          if (category.assessments.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(
                category.emptyNote ?? 'No assessment scores yet.',
                style: TextStyle(color: secondaryTextColor, fontSize: 12),
              ),
            )
          else
            ...category.assessments.map((assessment) {
              final percentage =
                  assessment.earned == null ||
                      assessment.possible == null ||
                      assessment.possible == 0
                  ? null
                  : assessment.earned! / assessment.possible! * 100;
              // Same columns as the table above, so each score sits under
              // Earned / Possible and its percentage under Percentage.
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      flex: _columnFlex[0],
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              assessment.name,
                              style: TextStyle(
                                color: AppColors.text,
                                fontSize: 13,
                              ),
                            ),
                            if (assessment.date != null) ...[
                              const SizedBox(height: 5),
                              Text(
                                assessment.date!,
                                style: TextStyle(
                                  color: secondaryTextColor,
                                  fontSize: 11,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                    Expanded(
                      flex: _columnFlex[1],
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Text(
                          assessment.earned == null ||
                                  assessment.possible == null
                              ? '— / —'
                              : '${_formatNumber(assessment.earned!)} / '
                                    '${_formatNumber(assessment.possible!)}',
                          style: TextStyle(
                            color: accentColor,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                    Expanded(
                      flex: _columnFlex[2],
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Text(
                          percentage == null
                              ? '—'
                              : '${percentage.toStringAsFixed(2)}%',
                          style: TextStyle(
                            color: secondaryTextColor,
                            fontSize: 13,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              );
            }),
        ],
      ),
    );
  }

  Widget _buildTable() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildRow(
          header: true,
          cells: [
            _textCell('CATEGORY', header: true),
            _textCell('EARNED / POSSIBLE', header: true),
            _textCell('PERCENTAGE', header: true),
          ],
        ),
        for (var index = 0; index < widget.term.categories.length; index++) ...[
          _buildCategoryRow(index, widget.term.categories[index]),
          if (_expandedCategories.contains(index))
            _buildAssessmentDetails(widget.term.categories[index]),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final grade = widget.term.grade;

    return Container(
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PopButtonEffects(
            borderRadius: BorderRadius.vertical(
              top: const Radius.circular(16),
              bottom: Radius.circular(_expanded ? 0 : 16),
            ),
            child: Material(
              color: buttonColor,
              clipBehavior: Clip.antiAlias,
              borderRadius: BorderRadius.vertical(
                top: const Radius.circular(16),
                bottom: Radius.circular(_expanded ? 0 : 16),
              ),
              child: InkWell(
                onTap: () {
                  setState(() {
                    _expanded = !_expanded;
                  });
                },
                child: Semantics(
                  expanded: _expanded,
                  child: Padding(
                    padding: const EdgeInsets.all(18),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            widget.term.title,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        Text(
                          grade == null ? '—' : '${grade.toStringAsFixed(2)}%',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(width: 12),
                        AnimatedRotation(
                          turns: _expanded ? 0.5 : 0,
                          duration: const Duration(milliseconds: 200),
                          child: const Icon(
                            Icons.keyboard_arrow_down_rounded,
                            color: Colors.white,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (_expanded) _buildTable(),
        ],
      ),
    );
  }
}

// GRADE DISPLAY DATA TYPES
// Populated from the authenticated student scores service.

class GradeTerm {
  const GradeTerm({required this.title, required this.categories, this.grade});

  final String title;
  final List<GradeCategory> categories;
  final double? grade;
}

class GradeCategory {
  const GradeCategory({
    required this.name,
    this.earned,
    this.possible,
    this.percentage,
    this.weight,
    this.weightedPoints,
    this.assessments = const [],
    this.emptyNote,
  });

  final String name;
  final double? earned;
  final double? possible;
  final double? percentage;
  final double? weight;
  final double? weightedPoints;
  final List<GradeAssessment> assessments;

  /// Shown instead of "No assessment scores yet." when set.
  final String? emptyNote;
}

class GradeAssessment {
  const GradeAssessment({
    required this.name,
    this.date,
    this.earned,
    this.possible,
  });

  final String name;
  final String? date;
  final double? earned;
  final double? possible;
}

String _formatNumber(double value) {
  return value == value.roundToDouble()
      ? value.toStringAsFixed(0)
      : value.toStringAsFixed(2);
}
