import '../widgets/pop_button_effects.dart';

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:image_picker/image_picker.dart';
import 'package:flutter/material.dart';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/student_profile_service.dart';
import '../services/student_photo_service.dart';
import 'login_screen.dart';
import '../theme/app_theme.dart';
import '../widgets/notification_button.dart';
import '../widgets/app_dropdown.dart';

class StudentProfileScreen extends StatefulWidget {
  const StudentProfileScreen({
    super.key,
    this.initialEmail = '',
    this.initialName = '',
    this.studentId = '',
    this.initialSection = '',
    this.status = '',
  });

  final String initialEmail;
  final String initialName;
  final String studentId;
  final String initialSection;
  final String status;

  @override
  State<StudentProfileScreen> createState() => _StudentProfileScreenState();
}

class _StudentProfileScreenState extends State<StudentProfileScreen> {
  // Colors follow the selected Light/Dark mode.
  static Color get backgroundColor => AppColors.background;
  static Color get cardColor => AppColors.card;
  static Color get accentColor => AppColors.accent;
  static Color get buttonColor => AppColors.button;
  static Color get borderColor => AppColors.border;
  static Color get secondaryTextColor => AppColors.secondaryText;

  final _formKey = GlobalKey<FormState>();

  late final TextEditingController _emailController;
  late final TextEditingController _nameController;
  late final TextEditingController _studentIdController;
  late final TextEditingController _sectionController;
  String? _studentType;
  bool _isSaving = false;

  late String _displayName;
  bool _isLoading = true;
  bool _isLoggingOut = false;
  String? _loadError;
  bool _profileMissing = false;
  Uint8List? _photo;
  bool _uploadingPhoto = false;
  int _photoRequest = 0;

  Future<void> _loadPhoto() async {
    final request = ++_photoRequest;
    try {
      final photo = await StudentPhotoService.load();
      if (mounted && request == _photoRequest) setState(() => _photo = photo);
    } catch (_) {
      // Keep the profile usable when photo storage is temporarily unavailable.
    }
  }

  Future<void> _choosePhoto() async {
    if (_uploadingPhoto || _isLoading || _isLoggingOut) return;
    final uid = Supabase.instance.client.auth.currentUser?.id;
    if (uid == null) return;
    ++_photoRequest;
    setState(() => _uploadingPhoto = true);
    try {
      final image = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 1200,
        maxHeight: 1200,
        imageQuality: 85,
      );
      if (image == null || !mounted) return;
      if (await image.length() > 5 * 1024 * 1024) {
        throw const FormatException('Choose a photo smaller than 5 MB.');
      }
      final bytes = await image.readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      try {
        final frame = await codec.getNextFrame();
        frame.image.dispose();
      } finally {
        codec.dispose();
      }
      if (!mounted) return;
      await StudentPhotoService.upload(bytes, uid);
      if (!mounted || Supabase.instance.client.auth.currentUser?.id != uid) {
        return;
      }
      setState(() => _photo = bytes);
      _showMessage('Profile photo updated.');
    } on FormatException catch (error) {
      if (mounted) _showMessage(error.message);
    } catch (_) {
      if (mounted) {
        _showMessage(
          'Could not upload your photo. Check your connection and photo permissions, then try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _uploadingPhoto = false);
    }
  }

  Future<void> _loadProfile() async {
    setState(() {
      _isLoading = true;
      _loadError = null;
    });
    try {
      final profile = await StudentProfileService.load();
      if (!mounted) return;
      setState(() {
        _emailController.text = profile['email']!;
        _nameController.text = profile['name']!;
        _studentIdController.text = profile['student_number']!;
        _sectionController.text = profile['section']!;
        final status = profile['status'];
        _studentType =
        const ['Regular Student', 'Irregular Student'].contains(status)
            ? status
            : null;
        _displayName = profile['name']!;
        _profileMissing = profile['profile_missing'] == 'true';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loadError =
        'Could not load your profile. Check your connection and '
            'try again. If this continues, contact your administrator.';
      });
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  void initState() {
    super.initState();

    _emailController = TextEditingController(text: widget.initialEmail);
    _nameController = TextEditingController(text: widget.initialName);
    _studentIdController = TextEditingController(text: widget.studentId);
    _sectionController = TextEditingController(text: widget.initialSection);

    _displayName = widget.initialName.trim();
    _loadProfile();
    _loadPhoto();
  }

  @override
  void dispose() {
    _emailController.dispose();
    _nameController.dispose();
    _studentIdController.dispose();
    _sectionController.dispose();
    super.dispose();
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
      );
  }

  Future<void> _saveStudentType() async {
    if (_isSaving || _isLoading || _isLoggingOut) return;
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() => _isSaving = true);
    try {
      await StudentProfileService.saveStudentType(_studentType!);
      if (mounted) _showMessage('Student status saved.');
    } catch (_) {
      if (mounted) {
        _showMessage(
          'Could not confirm the save. Check your connection and '
              'retry. Your student profile must exist before saving.',
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _confirmLogout() async {
    if (_isLoggingOut || _isLoading || _isSaving || _uploadingPhoto) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          backgroundColor: cardColor,
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(color: borderColor),
          ),
          title: Text('Log out?', style: TextStyle(color: AppColors.text)),
          content: Text(
            'Sign out of your student account?',
            style: TextStyle(color: secondaryTextColor),
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(dialogContext).pop(false);
              },
              child: Text(
                'Cancel',
                style: TextStyle(color: secondaryTextColor),
              ),
            ),
            TextButton(
              onPressed: () {
                Navigator.of(dialogContext).pop(true);
              },
              child: Text(
                'Log out',
                style: TextStyle(color: accentColor),
              ),
            ),
          ],
        );
      },
    );

    if (!mounted || confirmed != true) return;

    setState(() => _isLoggingOut = true);
    try {
      await Supabase.instance.client.auth.signOut();
    } catch (_) {
      if (mounted) {
        setState(() => _isLoggingOut = false);
        _showMessage('Could not sign out. Please try again.');
      }
      return;
    }
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute<void>(builder: (_) => const LoginScreen()),
          (_) => false,
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
                'My Profile',
                style: TextStyle(
                  color: AppColors.text,
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 5),
              Text(
                'Your registered student information',
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

  Widget _buildProfileCard(bool compact) {
    return Semantics(
      button: true,
      label: _uploadingPhoto
          ? 'Uploading profile photo'
          : 'Change profile photo',
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: _uploadingPhoto || _isLoggingOut ? null : _choosePhoto,
          child: Ink(
            padding: EdgeInsets.all(compact ? 24 : 32),
            decoration: BoxDecoration(
              color: cardColor,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: borderColor),
            ),
            child: Column(
              children: [
                Container(
                  width: compact ? 96 : 120,
                  height: compact ? 96 : 120,
                  decoration: BoxDecoration(
                    color: backgroundColor,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: borderColor),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: _uploadingPhoto
                      ? Center(
                    child: CircularProgressIndicator(color: accentColor),
                  )
                      : _photo != null
                      ? Image.memory(
                    _photo!,
                    fit: BoxFit.cover,
                    width: double.infinity,
                    height: double.infinity,
                    errorBuilder: (_, _, _) => Icon(
                      Icons.person_outline_rounded,
                      color: accentColor,
                      size: compact ? 54 : 68,
                    ),
                  )
                      : Icon(
                    Icons.person_outline_rounded,
                    color: accentColor,
                    size: compact ? 54 : 68,
                  ),
                ),
                const SizedBox(height: 18),
                Text(
                  _displayName.isEmpty ? 'Student' : _displayName,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: AppColors.text,
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  _studentIdController.text.trim().isEmpty
                      ? 'Student information will appear here'
                      : 'Student ID: ${_studentIdController.text}',
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
      ),
    );
  }

  Widget _buildField({
    required TextEditingController controller,
    required String label,
    required IconData icon,
    bool readOnly = true,
    TextInputType keyboardType = TextInputType.text,
    TextCapitalization capitalization = TextCapitalization.none,
    String? Function(String?)? validator,
    bool lastField = false,
  }) {
    OutlineInputBorder border(Color color) {
      return OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: color),
      );
    }

    return TextFormField(
      controller: controller,
      readOnly: readOnly,
      keyboardType: keyboardType,
      textCapitalization: capitalization,
      textInputAction: lastField ? TextInputAction.done : TextInputAction.next,
      validator: validator,
      cursorColor: accentColor,
      style: TextStyle(
        color: readOnly ? secondaryTextColor : AppColors.text,
        fontSize: 14,
      ),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: TextStyle(color: secondaryTextColor),
        floatingLabelBehavior: FloatingLabelBehavior.always,
        floatingLabelStyle: TextStyle(color: accentColor),
        hintText: readOnly
            ? 'Not available yet'
            : 'Enter your ${label.toLowerCase()}',
        hintStyle: TextStyle(color: secondaryTextColor, fontSize: 12),
        prefixIcon: Icon(icon, color: accentColor, size: 21),
        suffixIcon: readOnly
            ? Icon(
          Icons.lock_outline_rounded,
          color: secondaryTextColor,
          size: 18,
        )
            : null,
        filled: true,
        fillColor: backgroundColor,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 16,
        ),
        enabledBorder: border(borderColor),
        focusedBorder: border(accentColor),
        errorBorder: border(Colors.redAccent),
        focusedErrorBorder: border(Colors.redAccent),
        errorMaxLines: 3,
      ),
    );
  }

  // Saved on the device; Light is the default on first install.
  Widget _buildAppearanceToggle() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.palette_outlined, color: accentColor, size: 20),
            const SizedBox(width: 8),
            Text(
              'Appearance',
              style: TextStyle(
                color: AppColors.text,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        SegmentedButton<ThemeMode>(
          segments: const [
            ButtonSegment(
              value: ThemeMode.light,
              icon: Icon(Icons.light_mode_outlined),
              label: Text('Light'),
            ),
            ButtonSegment(
              value: ThemeMode.dark,
              icon: Icon(Icons.dark_mode_outlined),
              label: Text('Dark'),
            ),
          ],
          selected: {AppTheme.mode.value},
          onSelectionChanged: (selection) => AppTheme.setMode(selection.single),
          style: SegmentedButton.styleFrom(
            minimumSize: const Size.fromHeight(48),
            backgroundColor: backgroundColor,
            foregroundColor: AppColors.text,
            selectedBackgroundColor: buttonColor,
            selectedForegroundColor: Colors.white,
            side: BorderSide(color: borderColor),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildForm(bool compact) {
    return Container(
      padding: EdgeInsets.all(compact ? 20 : 28),
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: borderColor),
      ),
      child: Form(
        key: _formKey,
        autovalidateMode: AutovalidateMode.onUserInteraction,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.badge_outlined, color: accentColor, size: 22),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Student Information',
                    style: TextStyle(
                      color: AppColors.text,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            _buildField(
              controller: _emailController,
              label: 'Email',
              icon: Icons.email_outlined,
              keyboardType: TextInputType.emailAddress,
            ),
            const SizedBox(height: 20),
            _buildField(
              controller: _nameController,
              label: 'Name',
              icon: Icons.person_outline_rounded,
              capitalization: TextCapitalization.words,
            ),
            const SizedBox(height: 20),
            _buildField(
              controller: _studentIdController,
              label: 'Student ID',
              icon: Icons.badge_outlined,
              readOnly: true,
            ),
            const SizedBox(height: 20),
            _buildField(
              controller: _sectionController,
              label: 'Section',
              icon: Icons.groups_outlined,
              capitalization: TextCapitalization.characters,
              lastField: true,
            ),
            const SizedBox(height: 20),
            AppDropdown<String>(
              key: ValueKey(_studentType),
              initialValue: _studentType,
              dropdownColor: cardColor,
              // The list that opens has rounded corners like the cards.
              borderRadius: BorderRadius.circular(16),
              style: TextStyle(color: AppColors.text, fontSize: 14),
              decoration: InputDecoration(
                labelText: 'Status',
                floatingLabelBehavior: FloatingLabelBehavior.always,
                prefixIcon: Icon(
                  Icons.assignment_ind_outlined,
                  color: accentColor,
                ),
                filled: true,
                fillColor: backgroundColor,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              hint: const Text('Select your status'),
              items: const [
                DropdownMenuItem(
                  value: 'Regular Student',
                  child: Text('Regular Student'),
                ),
                DropdownMenuItem(
                  value: 'Irregular Student',
                  child: Text('Irregular Student'),
                ),
              ],
              onChanged: _isSaving || _isLoggingOut || _profileMissing
                  ? null
                  : (value) => setState(() => _studentType = value),
              validator: (value) =>
              value == null ? 'Please select your status.' : null,
            ),
            const SizedBox(height: 20),
            _buildAppearanceToggle(),
            const SizedBox(height: 24),
            Text(
              'Student ID is managed by the school. Choose your student status, then tap Save. '
              'Appearance changes apply right away.',
              style: TextStyle(color: secondaryTextColor, fontSize: 12),
            ),
            const SizedBox(height: 20),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 12,
              runSpacing: 12,
              children: [
                OutlinedButton.icon(
                  onPressed: _isLoggingOut || _isSaving || _uploadingPhoto
                      ? null
                      : _confirmLogout,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: accentColor,
                    side: BorderSide(color: borderColor),
                    minimumSize: const Size(120, 50),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  icon: const Icon(Icons.logout_rounded),
                  label: Text(_isLoggingOut ? 'Signing out...' : 'Log out'),
                ),
                PopButtonEffects(
                  child: ElevatedButton.icon(
                    onPressed: _isLoggingOut || _isSaving || _profileMissing
                        ? null
                        : _saveStudentType,
                    style: ElevatedButton.styleFrom(
                      elevation: 0,
                      shadowColor: Colors.transparent,
                      surfaceTintColor: Colors.transparent,
                      backgroundColor: buttonColor,
                      foregroundColor: Colors.white,
                      minimumSize: const Size(120, 50),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    icon: const Icon(Icons.save_outlined),
                    label: Text(
                      _isSaving ? 'Saving...' : 'Save',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: backgroundColor,

      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final compact = constraints.maxWidth < 600;

            return SingleChildScrollView(
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
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
                      if (_isLoading)
                        const Padding(
                          padding: EdgeInsets.all(32),
                          child: Center(child: CircularProgressIndicator()),
                        )
                      else if (_loadError != null)
                        Column(
                          children: [
                            Text(_loadError!, textAlign: TextAlign.center),
                            const SizedBox(height: 12),
                            OutlinedButton(
                              onPressed: _loadProfile,
                              child: const Text('Try again'),
                            ),
                          ],
                        )
                      else ...[
                          _buildProfileCard(compact),
                          const SizedBox(height: 20),
                          if (_profileMissing) ...[
                            Text(
                              'Your additional student profile is missing or '
                                  'unavailable. Contact your administrator to check '
                                  'your student profile.',
                              style: TextStyle(color: AppColors.warning),
                            ),
                            const SizedBox(height: 16),
                          ],
                          _buildForm(compact),
                        ],
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
