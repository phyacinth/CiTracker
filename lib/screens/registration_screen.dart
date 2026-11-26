import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/student_service.dart';
import '../services/student_profile_service.dart';
import 'login_screen.dart';
import '../theme/app_theme.dart';
import '../widgets/theme_toggle_logo.dart';
import '../widgets/app_dropdown.dart';

class RegistrationScreen extends StatefulWidget {
  const RegistrationScreen({super.key});

  @override
  State<RegistrationScreen> createState() => _RegistrationScreenState();
}

class _RegistrationScreenState extends State<RegistrationScreen> {
  static Color get backgroundColor => AppColors.background;
  static Color get cardColor => AppColors.card;
  static Color get accentColor => AppColors.accent;
  static Color get buttonColor => AppColors.button;
  static Color get borderColor => AppColors.border;
  static Color get secondaryTextColor => AppColors.secondaryText;

  final _formKey = GlobalKey<FormState>();

  final _emailController = TextEditingController();
  final _nameController = TextEditingController();
  final _studentIdController = TextEditingController();
  final _sectionController = TextEditingController();

  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();

  bool _isSubmitting = false;
  String? _studentType;

  bool _hidePassword = true;
  bool _hideConfirmPassword = true;

  @override
  void dispose() {
    _emailController.dispose();
    _nameController.dispose();
    _studentIdController.dispose();
    _sectionController.dispose();

    _passwordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  String? _requiredField(String? value, String label) {
    if (value == null || value.trim().isEmpty) {
      return 'Please enter your $label.';
    }

    return null;
  }

  String? _validateEmail(String? value) {
    final requiredError = _requiredField(value, 'email');

    if (requiredError != null) return requiredError;

    final email = value!.trim();
    final pattern = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$');

    if (!pattern.hasMatch(email)) {
      return 'Please enter a valid email address.';
    }

    // New student accounts must use a BulSU student email; the database
    // enforces the same rule (20261104000000_bulsu_student_email.sql).
    if (!email.toLowerCase().endsWith(bulsuEmailDomain)) {
      return 'Use your BulSU student email (ending in $bulsuEmailDomain).';
    }

    return null;
  }

  String? _validatePassword(String? value) {
    if (value == null || value.isEmpty) {
      return 'Please enter a password.';
    }

    // Frontend rule; align with the chosen auth provider later.
    if (value.length < 8) {
      return 'Use at least 8 characters.';
    }

    return null;
  }

  String? _validateConfirmPassword(String? value) {
    if (value == null || value.isEmpty) {
      return 'Please confirm your password.';
    }

    if (value != _passwordController.text) {
      return 'Passwords do not match.';
    }

    return null;
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _register() async {
    if (_isSubmitting) return;
    FocusScope.of(context).unfocus();
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final email = _emailController.text.trim();
    final password = _passwordController.text;
    final name = _nameController.text.trim();
    final number = _studentIdController.text.trim();
    final section = _sectionController.text.trim();
    setState(() => _isSubmitting = true);
    var profileSaved = false;
    try {
      final client = Supabase.instance.client;

      final result = await client.auth.signUp(
        email: email,
        password: password,
        data: {
          'full_name': name,
          'student_number': number,
          'section': section,
          'student_type': _studentType!,
        },
      );
      if (result.session == null) {
        if (!mounted) return;
        _passwordController.clear();
        _confirmPasswordController.clear();
        await showDialog<void>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('Check your email'),
            content: const Text(
              'If this email is eligible for signup, a confirmation message '
              'will be sent. Confirm your email, then log in to finish saving '
              'your student profile. If you already have an account, log in.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('OK'),
              ),
            ],
          ),
        );
        return;
      }
      await StudentService.completeProfile(
        fullName: name,
        studentNumber: number,
        section: section,
      );
      await StudentProfileService.saveStudentType(_studentType!);
      profileSaved = true;
      await client.auth.signOut();
      if (!mounted) return;
      _passwordController.clear();
      _confirmPasswordController.clear();
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Registration complete'),
          content: const Text(
            'Your student profile is saved. You can now log in. '
            'Your student status has been saved.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Go to login'),
            ),
          ],
        ),
      );
      if (mounted) _goToLogin();
    } on AuthException catch (error) {
      if (mounted) {
        _showMessage(
          profileSaved
              ? 'Profile saved, but sign-out failed. Please retry signing out.'
              // The database refused it: a sign-up rule, i.e. the email domain.
              : error.message.contains('Database error')
              ? 'Student accounts must use a BulSU student email '
                    '(ending in $bulsuEmailDomain).'
              : error.message,
        );
      }
    } on PostgrestException catch (error) {
      if (!mounted) return;
      _showMessage(
        error.message.contains('BULSU_EMAIL_REQUIRED')
            ? 'Student accounts must use a BulSU student email '
                  '(ending in $bulsuEmailDomain).'
            : error.code == '23505'
            ? 'This email or student number is already in use. Check your details '
                  'or contact the school. Your profile setup is not complete.'
            : 'Profile setup could not finish: ${error.message}. '
                  'Log in to retry saving your profile after fixing the issue.',
      );
    } catch (_) {
      if (mounted) {
        _showMessage(
          profileSaved
              ? 'Your profile was saved. Please return to login.'
              : 'Could not finish setup. Check your connection. If signup already '
                    'succeeded, confirm your email and log in to continue.',
        );
      }
    } finally {
      // Do not leave a partly registered or wrong-role account signed in here.
      try {
        await Supabase.instance.client.auth.signOut();
      } catch (_) {}
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  void _goToLogin() {
    final navigator = Navigator.of(context);

    // Registration is normally pushed from Login.
    if (navigator.canPop()) {
      navigator.pop();
      return;
    }

    // Also supports launching Registration directly for preview.
    navigator.pushReplacement(
      MaterialPageRoute<void>(builder: (_) => const LoginScreen()),
    );
  }

  InputDecoration _decoration({
    required String label,
    required IconData icon,
    String? helperText,
    Widget? suffixIcon,
  }) {
    OutlineInputBorder border(Color color) {
      return OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: color),
      );
    }

    return InputDecoration(
      labelText: label,
      labelStyle: TextStyle(color: secondaryTextColor, fontSize: 14),
      floatingLabelStyle: TextStyle(color: accentColor),
      prefixIcon: Icon(icon, color: accentColor, size: 21),
      suffixIcon: suffixIcon,
      helperText: helperText,
      helperMaxLines: 2,
      helperStyle: TextStyle(color: secondaryTextColor, fontSize: 12),
      errorMaxLines: 3,
      filled: true,
      fillColor: backgroundColor,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      enabledBorder: border(borderColor),
      focusedBorder: border(accentColor),
      errorBorder: border(Colors.redAccent),
      focusedErrorBorder: border(Colors.redAccent),
    );
  }

  Widget _buildField({
    required TextEditingController controller,
    required String label,
    required IconData icon,
    required String? Function(String?) validator,
    TextInputType keyboardType = TextInputType.text,
    TextCapitalization capitalization = TextCapitalization.none,
    Iterable<String>? autofillHints,
    String? helperText,
  }) {
    return TextFormField(
      controller: controller,
      keyboardType: keyboardType,
      textCapitalization: capitalization,
      textInputAction: TextInputAction.next,
      autofillHints: autofillHints,
      style: TextStyle(color: AppColors.text, fontSize: 14),
      cursorColor: accentColor,
      decoration: _decoration(label: label, icon: icon, helperText: helperText),
      validator: validator,
    );
  }

  Widget _buildPasswordField({required bool confirmation}) {
    final hidden = confirmation ? _hideConfirmPassword : _hidePassword;

    return TextFormField(
      controller: confirmation
          ? _confirmPasswordController
          : _passwordController,
      obscureText: hidden,
      autocorrect: false,
      enableSuggestions: false,
      keyboardType: TextInputType.visiblePassword,
      textInputAction: confirmation
          ? TextInputAction.done
          : TextInputAction.next,
      autofillHints: const [AutofillHints.newPassword],
      style: TextStyle(color: AppColors.text, fontSize: 14),
      cursorColor: accentColor,
      decoration: _decoration(
        label: confirmation ? 'Confirm Password' : 'Password',
        icon: Icons.lock_outline_rounded,
        helperText: confirmation ? null : 'Use at least 8 characters.',
        suffixIcon: IconButton(
          tooltip: hidden ? 'Show password' : 'Hide password',
          onPressed: () {
            setState(() {
              if (confirmation) {
                _hideConfirmPassword = !_hideConfirmPassword;
              } else {
                _hidePassword = !_hidePassword;
              }
            });
          },
          icon: Icon(
            hidden ? Icons.visibility_off_outlined : Icons.visibility_outlined,
            color: secondaryTextColor,
          ),
        ),
      ),
      validator: confirmation ? _validateConfirmPassword : _validatePassword,
      onFieldSubmitted: confirmation ? (_) => _register() : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: backgroundColor,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: cardColor,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: borderColor),
                ),
                child: AutofillGroup(
                  child: Form(
                    key: _formKey,
                    autovalidateMode: AutovalidateMode.onUserInteraction,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // Tap to switch light/dark mode.
                        Center(
                          child: ThemeToggleLogo(
                            child: Container(
                              width: 76,
                              height: 76,
                              decoration: BoxDecoration(
                                color: backgroundColor,
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(color: borderColor),
                              ),
                              child: Icon(
                                Icons.school_outlined,
                                color: accentColor,
                                size: 40,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 20),
                        Text(
                          'Create Account',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: AppColors.text,
                            fontSize: 26,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Register for CiTracker',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: secondaryTextColor,
                            fontSize: 13,
                          ),
                        ),
                        const SizedBox(height: 28),

                        _buildField(
                          controller: _emailController,
                          label: 'BulSU Email',
                          icon: Icons.email_outlined,
                          keyboardType: TextInputType.emailAddress,
                          autofillHints: const [AutofillHints.email],
                          validator: _validateEmail,
                          helperText: 'Use your student email ending in '
                              '$bulsuEmailDomain',
                        ),
                        const SizedBox(height: 16),

                        _buildField(
                          controller: _nameController,
                          label: 'Full Name',
                          icon: Icons.person_outline_rounded,
                          capitalization: TextCapitalization.words,
                          autofillHints: const [AutofillHints.name],
                          validator: (value) =>
                              _requiredField(value, 'full name'),
                        ),
                        const SizedBox(height: 16),

                        _buildField(
                          controller: _studentIdController,
                          label: 'Student ID',
                          icon: Icons.badge_outlined,
                          validator: (value) =>
                              _requiredField(value, 'student ID'),
                        ),
                        const SizedBox(height: 16),

                        _buildField(
                          controller: _sectionController,
                          label: 'Section',
                          icon: Icons.groups_outlined,
                          capitalization: TextCapitalization.characters,
                          validator: (value) =>
                              _requiredField(value, 'section'),
                        ),
                        const SizedBox(height: 16),

                        AppDropdown<String>(
                          initialValue: _studentType,
                          dropdownColor: cardColor,
                          // The list that opens has rounded corners like the cards.
                          borderRadius: BorderRadius.circular(16),
                          decoration: _decoration(
                            label: 'Status',
                            icon: Icons.assignment_ind_outlined,
                          ),
                          style: TextStyle(color: AppColors.text),
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
                          onChanged: _isSubmitting
                              ? null
                              : (value) => setState(() => _studentType = value),
                          validator: (value) => value == null
                              ? 'Please select your status.'
                              : null,
                        ),
                        const SizedBox(height: 16),
                        _buildPasswordField(confirmation: false),
                        const SizedBox(height: 16),

                        _buildPasswordField(confirmation: true),
                        const SizedBox(height: 24),

                        ElevatedButton(
                          onPressed: _isSubmitting ? null : _register,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: buttonColor,
                            foregroundColor: Colors.white,
                            minimumSize: const Size.fromHeight(52),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 16,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          child: Text(
                            _isSubmitting ? 'Please wait...' : 'Register',
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),

                        Wrap(
                          alignment: WrapAlignment.center,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Text(
                              'Already have an account?',
                              style: TextStyle(
                                color: secondaryTextColor,
                                fontSize: 13,
                              ),
                            ),
                            TextButton(
                              onPressed: _isSubmitting ? null : _goToLogin,
                              style: TextButton.styleFrom(
                                foregroundColor: accentColor,
                              ),
                              child: const Text(
                                'Log in',
                                style: TextStyle(fontWeight: FontWeight.w600),
                              ),
                            ),
                          ],
                        ),
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
}
