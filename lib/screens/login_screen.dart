import 'package:flutter/material.dart';
import 'nfc_professor_test_screen.dart';

import 'registration_screen.dart';
import 'student_password_recovery_screen.dart';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/offline_attendance_service.dart';
import '../services/student_service.dart';
import 'student_dashboard_screen.dart';
import '../theme/app_theme.dart';
import '../widgets/theme_toggle_logo.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  // FORM CONTROLLERS
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();

  // KEYBOARD FOCUS
  final _passwordFocusNode = FocusNode();

  // UI STATES
  bool _obscurePassword = true;
  bool _isLoading = false;

  // OFFLINE: a sign-in still saved on this phone (until Log out) can open
  // the app without internet, so attendance can be saved offline.
  String? _savedRole;
  String? _savedEmail;
  bool _showContinueOffline = false;

  static String _roleKey(String userId) => 'comptech_role_v1_$userId';

  @override
  void initState() {
    super.initState();
    _checkSavedSignIn();
  }

  Future<void> _checkSavedSignIn() async {
    final user = Supabase.instance.client.auth.currentSession?.user;
    if (user == null) return;
    final prefs = await SharedPreferences.getInstance();
    final role = prefs.getString(_roleKey(user.id));
    if (role == null || !mounted) return;
    setState(() {
      _savedRole = role;
      _savedEmail = user.email;
    });
    // No internet at all: skip straight in. Online, login works as before.
    if (await OfflineAttendanceService.isOffline() && mounted) {
      _openHome(role);
    }
  }

  void _openHome(String? role) {
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute<void>(builder: (_) =>
      role == 'faculty' || role == 'professor'
          ? const NfcProfessorTestScreen()
          : const StudentDashboardScreen()),
          (route) => false,
    );
  }

  // Colors follow the selected Light/Dark mode.
  static Color get backgroundColor => AppColors.background;
  static Color get containerColor => AppColors.card;
  static Color get accentColor => AppColors.accent;
  static Color get buttonColor => AppColors.button;
  static Color get borderColor => AppColors.border;
  static Color get secondaryTextColor => AppColors.secondaryText;

  // EMAIL VALIDATION
  String? _validateEmail(String? value) {
    final email = value?.trim() ?? '';

    if (email.isEmpty) {
      return 'Please enter your email';
    }

    final emailRegex = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$');

    if (!emailRegex.hasMatch(email)) {
      return 'Enter a valid email address';
    }

    return null;
  }

  // PASSWORD VALIDATION
  String? _validatePassword(String? value) {
    if (value == null || value.isEmpty) {
      return 'Please enter your password';
    }

    return null;
  }

  // LOGIN - VALIDATION ONLY
  Future<void> _handleLogin() async {
    if (_isLoading) return;

    FocusScope.of(context).unfocus();

    if (!(_formKey.currentState?.validate() ?? false)) {
      return;
    }

    setState(() => _isLoading = true);

    try {
      final profile = await StudentService.signIn(
        email: _emailController.text,
        password: _passwordController.text,
        allowFaculty: true,
      );

      final role = profile['role']?.toString() ?? 'student';
      final userId = Supabase.instance.client.auth.currentUser?.id;
      if (userId != null) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_roleKey(userId), role);
      }

      if (!mounted) return;

      _openHome(role);
    } on AuthRetryableFetchException catch (_) {
      // No answer from the server: offer the saved sign-in, if there is one.
      if (!mounted) return;
      if (_savedRole != null) {
        setState(() => _showContinueOffline = true);
      } else {
        _showLoginError(
          'No internet connection. Log in once while online; after that '
          'you can open the app offline until you log out.',
        );
      }
    } on AuthException catch (error) {
      if (!mounted) return;
      _showLoginError(error.message);
    } on PostgrestException catch (_) {
      if (!mounted) return;
      _showLoginError(
        'Could not load your account profile. '
            'Please contact your administrator.',
      );
    } catch (error) {
      if (!mounted) return;

      final message = error.toString().replaceFirst('Exception: ', '');
      _showLoginError(message);
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  void _showLoginError(String message) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Unable to finish login'),
        content: SingleChildScrollView(child: SelectableText(message)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  // OPEN TEMPORARY REGISTRATION PAGE
  void _openRegistration() {
    FocusScope.of(context).unfocus();

    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const RegistrationScreen()),
    );
  }

  // Student password recovery requires verification through the account email.
  void _forgotPassword() {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => StudentPasswordRecoveryScreen(
          initialEmail: _emailController.text.trim(),
        ),
      ),
    );
  }

  // INPUT FIELD DESIGN
  InputDecoration _inputDecoration({
    required String hint,
    required IconData icon,
    Widget? suffixIcon,
  }) {
    return InputDecoration(
      hintText: hint,
      hintStyle: TextStyle(color: secondaryTextColor),
      prefixIcon: Icon(icon, color: accentColor),
      suffixIcon: suffixIcon,

      filled: true,
      fillColor: backgroundColor,

      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),

      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: borderColor),
      ),

      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: accentColor, width: 2),
      ),

      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Colors.redAccent),
      ),

      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Colors.redAccent, width: 2),
      ),

      errorStyle: const TextStyle(color: Colors.redAccent, fontSize: 12),
    );
  }

  // RELEASE RESOURCES
  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _passwordFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: backgroundColor,
      resizeToAvoidBottomInset: true,

      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            return SingleChildScrollView(
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,

              padding: const EdgeInsets.all(20),

              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight: (constraints.maxHeight - 40).clamp(
                    0.0,
                    double.infinity,
                  ),
                ),

                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 400),

                    child: Container(
                      width: double.infinity,

                      padding: const EdgeInsets.all(24),

                      decoration: BoxDecoration(
                        color: containerColor,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: borderColor),
                      ),

                      child: Form(
                        key: _formKey,

                        autovalidateMode: AutovalidateMode.onUserInteraction,

                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,

                          children: [
                            // APP ICON (tap to switch light/dark mode)
                            Center(
                              child: ThemeToggleLogo(
                                child: Container(
                                  width: 60,
                                  height: 60,

                                  decoration: BoxDecoration(
                                    color: buttonColor,
                                    borderRadius: BorderRadius.circular(16),
                                  ),

                                  child: Icon(
                                    Icons.school,
                                    size: 34,
                                    color: AppColors.selectedOnButton,
                                  ),
                                ),
                              ),
                            ),

                            const SizedBox(height: 20),

                            // WELCOME TITLE
                            Text(
                              'Welcome Back',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: AppColors.text,
                                fontSize: 26,
                                fontWeight: FontWeight.bold,
                              ),
                            ),

                            const SizedBox(height: 8),

                            // SUBTITLE
                            Text(
                              'Sign in to your CompTech account',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: secondaryTextColor,
                                fontSize: 14,
                              ),
                            ),

                            const SizedBox(height: 32),

                            // EMAIL LABEL
                            Text(
                              'Email Address',
                              style: TextStyle(
                                color: AppColors.text,
                                fontSize: 14,
                                fontWeight: FontWeight.w500,
                              ),
                            ),

                            const SizedBox(height: 8),

                            // EMAIL INPUT
                            TextFormField(
                              controller: _emailController,

                              keyboardType: TextInputType.emailAddress,
                              textInputAction: TextInputAction.next,

                              autocorrect: false,
                              validator: _validateEmail,

                              onFieldSubmitted: (_) {
                                _passwordFocusNode.requestFocus();
                              },

                              style: TextStyle(color: AppColors.text),

                              decoration: _inputDecoration(
                                // Hint only: older accounts with other
                                // emails can still log in.
                                hint: bulsuEmailDomain,
                                icon: Icons.email_outlined,
                              ),
                            ),

                            const SizedBox(height: 20),

                            // PASSWORD LABEL
                            Text(
                              'Password',
                              style: TextStyle(
                                color: AppColors.text,
                                fontSize: 14,
                                fontWeight: FontWeight.w500,
                              ),
                            ),

                            const SizedBox(height: 8),

                            // PASSWORD INPUT
                            TextFormField(
                              controller: _passwordController,
                              focusNode: _passwordFocusNode,

                              obscureText: _obscurePassword,
                              autocorrect: false,
                              enableSuggestions: false,

                              textInputAction: TextInputAction.done,
                              validator: _validatePassword,

                              onFieldSubmitted: (_) {
                                if (!_isLoading) {
                                  _handleLogin();
                                }
                              },

                              style: TextStyle(color: AppColors.text),

                              decoration: _inputDecoration(
                                hint: 'Enter your password',
                                icon: Icons.lock_outline,

                                suffixIcon: IconButton(
                                  tooltip: _obscurePassword
                                      ? 'Show password'
                                      : 'Hide password',

                                  color: secondaryTextColor,

                                  icon: Icon(
                                    _obscurePassword
                                        ? Icons.visibility_off
                                        : Icons.visibility,
                                  ),

                                  onPressed: () {
                                    setState(() {
                                      _obscurePassword = !_obscurePassword;
                                    });
                                  },
                                ),
                              ),
                            ),

                            const SizedBox(height: 8),

                            // FORGOT PASSWORD
                            Align(
                              alignment: Alignment.centerRight,

                              child: TextButton(
                                onPressed: _isLoading ? null : _forgotPassword,

                                child: Text(
                                  'Forgot Password?',
                                  style: TextStyle(
                                    color: accentColor,
                                    fontSize: 13,
                                  ),
                                ),
                              ),
                            ),

                            const SizedBox(height: 18),

                            // LOGIN BUTTON
                            SizedBox(
                              height: 52,

                              child: ElevatedButton.icon(
                                onPressed: _isLoading ? null : _handleLogin,

                                style: ElevatedButton.styleFrom(
                                  backgroundColor: buttonColor,
                                  foregroundColor: Colors.white,

                                  disabledBackgroundColor: buttonColor
                                      .withValues(alpha: 0.5),

                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                ),

                                icon: _isLoading
                                    ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    color: Colors.white,
                                    strokeWidth: 2,
                                  ),
                                )
                                    : const Icon(Icons.arrow_forward, size: 20),

                                label: Text(
                                  _isLoading ? 'Logging In...' : 'Log In',

                                  style: const TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ),

                            if (_showContinueOffline) ...[
                              const SizedBox(height: 12),
                              Text(
                                'No internet. You are still signed in on this '
                                'phone, so you can continue offline and save '
                                'attendance to send later.',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: secondaryTextColor,
                                  fontSize: 12,
                                ),
                              ),
                              const SizedBox(height: 8),
                              OutlinedButton.icon(
                                onPressed: () => _openHome(_savedRole),
                                icon: const Icon(Icons.cloud_off_outlined),
                                label: Text(
                                  _savedEmail == null
                                      ? 'Continue offline'
                                      : 'Continue offline as $_savedEmail',
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],

                            const SizedBox(height: 24),

                            // REGISTRATION LINK
                            Wrap(
                              alignment: WrapAlignment.center,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              spacing: 4,

                              children: [
                                Text(
                                  "Don't have an account?",
                                  style: TextStyle(
                                    color: secondaryTextColor,
                                    fontSize: 13,
                                  ),
                                ),

                                TextButton(
                                  onPressed: _openRegistration,

                                  child: Text(
                                    'Register',
                                    style: TextStyle(
                                      color: accentColor,
                                      fontSize: 13,
                                      fontWeight: FontWeight.bold,
                                    ),
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
            );
          },
        ),
      ),
    );
  }
}
