import '../widgets/pop_button_effects.dart';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/enrolled_classes_service.dart';
import '../services/student_requests_service.dart';
import '../theme/app_theme.dart';
import '../widgets/app_dropdown.dart';

class StudentRequestsScreen extends StatefulWidget {
  const StudentRequestsScreen({super.key, this.initialClassId});
  final String? initialClassId;

  @override
  State<StudentRequestsScreen> createState() => _StudentRequestsScreenState();
}

class _StudentRequestsScreenState extends State<StudentRequestsScreen> {
  static Color get _background => AppColors.background;
  static Color get _card => AppColors.card;
  static Color get _accent => AppColors.accent;
  static Color get _button => AppColors.button;
  static Color get _border => AppColors.border;
  static Color get _secondary => AppColors.secondaryText;
  final _service = StudentRequestsService();
  final _form = GlobalKey<FormState>();
  final _message = TextEditingController();
  List<Map<String, String>> _classes = [];
  List<Map<String, dynamic>> _requests = [];
  String? _classId;
  String? _error;
  String _kind = 'excuse';
  String _filter = 'All';
  DateTime? _date;
  bool _loading = true;
  bool _saving = false;
  bool _confirming = false;
  bool _compose = false;
  int _version = 0;
  late final String? _accountId;

  @override
  void initState() {
    super.initState();
    _accountId = Supabase.instance.client.auth.currentUser?.id;
    _classId = widget.initialClassId;
    _load();
  }

  @override
  void dispose() {
    _version++;
    _message.dispose();
    super.dispose();
  }

  bool get _sameAccount =>
      _accountId != null &&
          Supabase.instance.client.auth.currentUser?.id == _accountId;

  Future<void> _load() async {
    final version = ++_version;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      if (!_sameAccount) {
        throw StateError('Please reopen this screen after signing in.');
      }
      final results = await Future.wait<dynamic>([
        EnrolledClassesService.load(),
        _service.load(),
      ]);
      if (!mounted || version != _version) return;
      if (!_sameAccount) {
        setState(() {
          _classes = [];
          _requests = [];
          _error = 'Account changed. Reopen this screen.';
        });
        return;
      }
      setState(() {
        _classes = results[0] as List<Map<String, String>>;
        _requests = results[1] as List<Map<String, dynamic>>;
        if (!_classes.any((row) => row['id'] == _classId)) _classId = null;
      });
    } catch (_) {
      if (mounted && version == _version) {
        setState(
              () => _error =
          'Could not load requests. Check your connection and try again. '
              'If this is the first setup, make sure the request SQL has been applied.',
        );
      }
    } finally {
      if (mounted && version == _version) setState(() => _loading = false);
    }
  }

  String _dateText(DateTime date) =>
      '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

  String _timestamp(dynamic value) {
    final date = DateTime.tryParse(value?.toString() ?? '')?.toLocal();
    if (date == null) return '—';
    return '${_dateText(date)} • ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
  }

  String _status(dynamic value) {
    switch (value) {
      case 'Open':
        return 'Pending';
      case 'Accepted':
        return 'Approved';
      case 'Denied':
        return 'Declined';
      default:
        return value?.toString() ?? 'Unknown';
    }
  }

  Color _statusColor(String status) {
    if (status == 'Approved') return AppColors.success;
    if (status == 'Declined') return AppColors.error;
    return AppColors.warning;
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _date ?? now,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100, 12, 31),
      builder: (context, child) => Theme(
        data: ThemeData.dark().copyWith(
          colorScheme: ColorScheme.dark(
            primary: _accent,
            onPrimary: _card,
            surface: _card,
          ),
        ),
        child: child!,
      ),
    );
    if (picked != null && mounted) setState(() => _date = picked);
  }

  void _notice(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
      );
  }

  Future<void> _submit() async {
    if (_saving || _confirming || !_form.currentState!.validate()) return;
    if (!_sameAccount) {
      _notice('Account changed. Reopen this screen.');
      return;
    }
    if (_kind == 'excuse' && _date == null) {
      _notice('Choose the absence date.');
      return;
    }
    FocusScope.of(context).unfocus();
    _confirming = true;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: _card,
        title: const Text('Submit to your professor?'),
        content: const Text(
          'Your request will be sent for review. You cannot edit it after submission.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Back'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Submit'),
          ),
        ],
      ),
    );
    _confirming = false;
    if (confirmed != true || !mounted) return;
    if (!_sameAccount) {
      _notice('Account changed. Reopen this screen.');
      return;
    }
    setState(() => _saving = true);
    try {
      await _service.submit(
        classId: _classId!,
        kind: _kind,
        date: _date,
        message: _message.text,
      );
      if (!mounted || !_sameAccount) return;
      _message.clear();
      setState(() {
        _date = null;
        _compose = false;
        _filter = 'All';
      });
      _notice('Request submitted. Your professor can now review it.');
      await _load();
    } on ArgumentError catch (error) {
      if (mounted) _notice(error.message.toString());
    } on PostgrestException catch (error) {
      if (mounted) _notice(error.message);
    } catch (_) {
      if (mounted) {
        _notice(
          'Submission could not be confirmed. Refresh My submissions before trying again.',
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  InputDecoration _field(String label, {String? hint}) => InputDecoration(
    labelText: label,
    hintText: hint,
    filled: true,
    fillColor: _background,
    labelStyle: TextStyle(color: _secondary),
    hintStyle: TextStyle(color: _secondary),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: BorderSide(color: _border),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: BorderSide(color: _border),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: BorderSide(color: _accent),
    ),
  );

  Widget _panel(Widget child) => Container(
    padding: const EdgeInsets.all(18),
    decoration: BoxDecoration(
      color: _card,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: _border),
    ),
    child: child,
  );

  Widget _badge(String status) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
    decoration: BoxDecoration(
      color: _statusColor(status).withValues(alpha: .12),
      borderRadius: BorderRadius.circular(20),
    ),
    child: Text(
      status,
      style: TextStyle(
        color: _statusColor(status),
        fontSize: 12,
        fontWeight: FontWeight.w600,
      ),
    ),
  );

  Widget _composer() {
    if (_classes.isEmpty) {
      return _panel(const Text('Join a class before submitting a request.'));
    }
    Map<String, String>? selected;
    for (final row in _classes) {
      if (row['id'] == _classId) selected = row;
    }
    return _panel(
      Form(
        key: _form,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'New submission',
              style: TextStyle(
                color: AppColors.text,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Send an excuse letter, concern, or special assessment request to your professor.',
              style: TextStyle(color: _secondary),
            ),
            const SizedBox(height: 22),
            AppDropdown<String>(
              initialValue: _classId,
              isExpanded: true,
              dropdownColor: _card,
              // The list that opens has rounded corners like the cards.
              borderRadius: BorderRadius.circular(16),
              style: TextStyle(color: AppColors.text, fontSize: 15),
              decoration: _field('Class'),
              items: _classes
                  .map(
                    (row) => DropdownMenuItem(
                  value: row['id'],
                  child: Text(
                    '${row['subject']} • ${row['section']}',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              )
                  .toList(),
              onChanged: _saving
                  ? null
                  : (value) => setState(() => _classId = value),
              validator: (value) => value == null ? 'Select a class.' : null,
            ),
            if (selected != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'To: ${selected['professor']}',
                  style: TextStyle(color: _secondary, fontSize: 12),
                ),
              ),
            const SizedBox(height: 18),
            AppDropdown<String>(
              initialValue: _kind,
              isExpanded: true,
              dropdownColor: _card,
              // The list that opens has rounded corners like the cards.
              borderRadius: BorderRadius.circular(16),
              style: TextStyle(color: AppColors.text, fontSize: 15),
              decoration: _field('Submission type'),
              items: const [
                DropdownMenuItem(value: 'excuse', child: Text('Excuse Letter')),
                DropdownMenuItem(value: 'concern', child: Text('Concern')),
                DropdownMenuItem(
                  value: 'special',
                  child: Text(
                    'Request for Special Exam/Quiz/Activity',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
              onChanged: _saving
                  ? null
                  : (value) => setState(() {
                _kind = value!;
                if (_kind == 'special') _date = null;
              }),
            ),
            if (_kind != 'special') ...[
              const SizedBox(height: 18),
              OutlinedButton.icon(
                onPressed: _saving ? null : _pickDate,
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.all(16),
                  foregroundColor: _accent,
                  side: BorderSide(color: _border),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                icon: const Icon(Icons.calendar_today_outlined, size: 20),
                label: Text(
                  _date == null
                      ? (_kind == 'excuse'
                      ? 'Select absence date *'
                      : 'Select relevant date (optional)')
                      : _dateText(_date!),
                ),
              ),
              if (_date != null && _kind == 'concern')
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: _saving
                        ? null
                        : () => setState(() => _date = null),
                    child: const Text('Clear date'),
                  ),
                ),
            ],
            const SizedBox(height: 18),
            TextFormField(
              controller: _message,
              enabled: !_saving,
              minLines: 6,
              maxLines: 12,
              maxLength: _kind == 'special'
                  ? 3000 - StudentRequestsService.specialRequestHeading.length
                  : 3000,
              textCapitalization: TextCapitalization.sentences,
              decoration: _field(
                'Your message',
                hint: 'Explain what happened and what you would like your professor to review.',
              ),
              validator: (value) => (value?.trim().length ?? 0) < 10
                  ? 'Enter at least 10 characters.'
                  : null,
            ),
            const SizedBox(height: 12),
            Text(
              'Approval records your professor’s decision. Attendance changes, if needed, are handled separately.',
              style: TextStyle(color: _secondary, fontSize: 12, height: 1.5),
            ),
            const SizedBox(height: 20),
            PopButtonEffects(
              child: FilledButton.icon(
                onPressed: _saving ? null : _submit,
                style: FilledButton.styleFrom(
                  elevation: 0,
                  shadowColor: Colors.transparent,
                  surfaceTintColor: Colors.transparent,
                  backgroundColor: _button,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.all(16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                icon: _saving
                    ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
                    : const Icon(Icons.send_outlined),
                label: Text(_saving ? 'Submitting…' : 'Submit for Review'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _details(Map<String, dynamic> row) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: _card,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: FractionallySizedBox(
          heightFactor: .85,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _badge(_status(row['status'])),
                const SizedBox(height: 16),
                Text(
                  row['subject']?.toString() ?? 'Class',
                  style: TextStyle(
                    color: AppColors.text,
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Submitted ${_timestamp(row['created_at'])}',
                  style: TextStyle(color: _secondary, fontSize: 12),
                ),
                const SizedBox(height: 24),
                Text(
                  'Your submission',
                  style: TextStyle(color: _accent, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 10),
                SelectableText(row['message']?.toString() ?? ''),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 20),
                  child: Divider(color: _border),
                ),
                Text(
                  'Professor’s response',
                  style: TextStyle(color: _accent, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 10),
                SelectableText(
                  (row['faculty_reply']?.toString() ?? '').trim().isEmpty
                      ? 'No response yet. Pull down on My submissions to check for updates.'
                      : row['faculty_reply'].toString(),
                ),
                if (row['reviewed_at'] != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Text(
                      'Reviewed ${_timestamp(row['reviewed_at'])}',
                      style: TextStyle(color: _secondary, fontSize: 12),
                    ),
                  ),
                const SizedBox(height: 24),
                Text(
                  'An approved request does not automatically change your attendance record.',
                  style: TextStyle(color: _secondary, fontSize: 12),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _history() {
    final rows = _requests
        .where((row) => _filter == 'All' || _status(row['status']) == _filter)
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: ['All', 'Pending', 'Approved', 'Declined']
              .map(
                (label) => ChoiceChip(
              label: Text(label),
              selected: _filter == label,
              selectedColor: _button,
              backgroundColor: _card,
              side: BorderSide(
                color: _filter == label ? _button : _border,
              ),
              checkmarkColor: Colors.white,
              labelStyle: TextStyle(
                color: _filter == label ? Colors.white : AppColors.text,
                fontWeight: FontWeight.w600,
              ),
              onSelected: (_) => setState(() => _filter = label),
            ),
          )
              .toList(),
        ),
        const SizedBox(height: 16),
        if (rows.isEmpty)
          _panel(
            Column(
              children: [
                Icon(
                  Icons.mark_email_read_outlined,
                  color: _secondary,
                  size: 36,
                ),
                const SizedBox(height: 12),
                Text(
                  _requests.isEmpty
                      ? 'No submissions yet'
                      : 'No ${_filter.toLowerCase()} requests',
                  style: TextStyle(
                    color: AppColors.text,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Your submitted letters, decisions, and professor responses appear here.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: _secondary),
                ),
              ],
            ),
          ),
        ...rows.map(
              (row) => Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Material(
              color: _card,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: BorderSide(color: _border),
              ),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: () => _details(row),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.description_outlined,
                            color: _accent,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              row['subject']?.toString() ?? 'Class',
                              style: TextStyle(
                                color: AppColors.text,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          _badge(_status(row['status'])),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Text(
                        row['message']?.toString() ?? '',
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: _secondary, height: 1.5),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              _timestamp(row['created_at']),
                              style: TextStyle(
                                color: _secondary,
                                fontSize: 12,
                              ),
                            ),
                          ),
                          Icon(Icons.chevron_right, color: _accent),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_saving,
    child: Theme(
      data: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: _background,
        colorScheme: ColorScheme.dark(primary: _accent, surface: _card),
      ),
      child: Scaffold(
        backgroundColor: _background,
        appBar: AppBar(
          backgroundColor: _background,
          foregroundColor: AppColors.text,
          title: const Text(
            'Excuse Letters & Concerns',
            style: TextStyle(fontSize: 18),
          ),
          actions: [
            IconButton(
              onPressed: _loading || _saving ? null : _load,
              icon: const Icon(Icons.refresh),
              tooltip: 'Refresh requests',
            ),
          ],
        ),
        body: SafeArea(
          child: RefreshIndicator(
            onRefresh: _saving ? () async {} : _load,
            color: _accent,
            backgroundColor: _card,
            child: SingleChildScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.all(16),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 760),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        'Stay in touch with your professor',
                        style: TextStyle(color: _secondary),
                      ),
                      const SizedBox(height: 20),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              onPressed: _saving
                                  ? null
                                  : () => setState(() => _compose = false),
                              style: OutlinedButton.styleFrom(
                                foregroundColor:
                                    !_compose ? Colors.white : _accent,
                                backgroundColor: !_compose ? _button : null,
                              ),
                              child: const Text('My submissions'),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: OutlinedButton(
                              onPressed: _saving
                                  ? null
                                  : () => setState(() => _compose = true),
                              style: OutlinedButton.styleFrom(
                                foregroundColor:
                                    _compose ? Colors.white : _accent,
                                backgroundColor: _compose ? _button : null,
                              ),
                              child: const Text('New submission'),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 20),
                      if (_loading)
                        const Padding(
                          padding: EdgeInsets.all(40),
                          child: Center(child: CircularProgressIndicator()),
                        )
                      else if (_error != null)
                        _panel(
                          Column(
                            children: [
                              Text(_error!),
                              const SizedBox(height: 12),
                              TextButton.icon(
                                onPressed: _load,
                                icon: const Icon(Icons.refresh),
                                label: const Text('Try again'),
                              ),
                            ],
                          ),
                        )
                      else if (_compose)
                          _composer()
                        else
                          _history(),
                      const SizedBox(height: 24),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
