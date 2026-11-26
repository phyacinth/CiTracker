import 'login_screen.dart';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class StudentPasswordRecoveryScreen extends StatefulWidget {
  const StudentPasswordRecoveryScreen({
    super.key,
    required this.initialEmail,
    this.recoveryVerified = false,
  });
  final String initialEmail;
  final bool recoveryVerified;

  @override
  State<StudentPasswordRecoveryScreen> createState() =>
      _StudentPasswordRecoveryScreenState();
}

class _StudentPasswordRecoveryScreenState
    extends State<StudentPasswordRecoveryScreen> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _email;
  final _password = TextEditingController();
  final _confirmation = TextEditingController();
  bool _sent = false;
  bool _verified = false;
  bool _busy = false;
  bool _hidden = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _email = TextEditingController(text: widget.initialEmail);
    _verified = widget.recoveryVerified;
    _sent = _verified;
  }

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _confirmation.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy || !(_form.currentState?.validate() ?? false)) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });
    final auth = Supabase.instance.client.auth;
    try {
      if (!_sent) {
        await auth.resetPasswordForEmail(
          _email.text.trim(),
          redirectTo: 'comptechportal://reset-password',
        );
        if (mounted) setState(() => _sent = true);
      } else {
        await auth.updateUser(UserAttributes(password: _password.text));
        // Password changes succeed independently of local session cleanup.
        try {
          await auth.signOut(scope: SignOutScope.local);
        } catch (_) {}
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Password changed. Log in with your new password.'),
          ),
        );
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute<void>(builder: (_) => const LoginScreen()),
              (_) => false,
        );
      }
    } on AuthException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) {
        setState(
              () =>
          _error = 'Could not finish. Check your connection and try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        appBar: AppBar(title: const Text('Reset student password')),
        body: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Form(
                key: _form,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      _verified
                          ? 'Choose your new password.'
                          : _sent
                          ? 'Check your email and tap Reset password. Open the link on this Android device with this app installed.'
                          : 'Enter your student account email to receive a password reset link.',
                    ),
                    const SizedBox(height: 24),
                    TextFormField(
                      controller: _email,
                      enabled: !_sent && !_busy,
                      keyboardType: TextInputType.emailAddress,
                      autocorrect: false,
                      decoration: const InputDecoration(
                        labelText: 'Email address',
                      ),
                      validator: (value) =>
                      RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$')
                          .hasMatch(value?.trim() ?? '')
                          ? null
                          : 'Enter a valid email address.',
                    ),
                    if (_sent && !_verified) ...[
                      const SizedBox(height: 16),
                      TextButton(
                        onPressed: _busy
                            ? null
                            : () {
                          setState(() {
                            _sent = false;
                            _error = null;
                          });
                        },
                        child: const Text(
                          'Change email or request another link',
                        ),
                      ),
                    ],
                    if (_verified) ...[
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _password,
                        enabled: !_busy,
                        obscureText: _hidden,
                        autocorrect: false,
                        enableSuggestions: false,
                        autofillHints: const [AutofillHints.newPassword],
                        decoration: InputDecoration(
                          labelText: 'New password',
                          helperText: 'Use at least 8 characters, including uppercase, lowercase and a number.',
                          helperMaxLines: 3,
                          suffixIcon: IconButton(
                            tooltip: _hidden
                                ? 'Show password'
                                : 'Hide password',
                            onPressed: () => setState(() => _hidden = !_hidden),
                            icon: Icon(
                              _hidden ? Icons.visibility_off : Icons.visibility,
                            ),
                          ),
                        ),
                        validator: (value) {
                          final password = value ?? '';
                          if (password.length < 8 ||
                              !RegExp('[A-Z]').hasMatch(password) ||
                              !RegExp('[a-z]').hasMatch(password) ||
                              !RegExp('[0-9]').hasMatch(password)) {
                            return 'Use 8+ characters with uppercase, lowercase and a number.';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _confirmation,
                        enabled: !_busy,
                        obscureText: _hidden,
                        autocorrect: false,
                        enableSuggestions: false,
                        decoration: const InputDecoration(
                          labelText: 'Confirm new password',
                        ),
                        validator: (value) => value != _password.text
                            ? 'Passwords do not match.'
                            : null,
                      ),
                    ],
                    if (_error != null) ...[
                      const SizedBox(height: 16),
                      Text(
                        _error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ],
                    const SizedBox(height: 24),
                    FilledButton(
                      onPressed: _busy || (_sent && !_verified)
                          ? null
                          : _submit,
                      child: Text(
                        _busy
                            ? 'Please wait...'
                            : _verified
                            ? 'Change password'
                            : _sent
                            ? 'Email sent'
                            : 'Send reset link',
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
