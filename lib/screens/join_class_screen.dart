import '../widgets/pop_button_effects.dart';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme/app_theme.dart';

class JoinClassScreen extends StatefulWidget {
  const JoinClassScreen({super.key});

  @override
  State<JoinClassScreen> createState() => _JoinClassScreenState();
}

class _JoinClassScreenState extends State<JoinClassScreen> {
  static Color get backgroundColor => AppColors.background;
  static Color get cardColor => AppColors.card;
  static Color get accentColor => AppColors.accent;
  static Color get buttonColor => AppColors.button;
  static Color get borderColor => AppColors.border;
  static Color get secondaryTextColor => AppColors.secondaryText;

  final _formKey = GlobalKey<FormState>();
  final _codeController = TextEditingController();
  bool _isSubmitting = false;
  String? _status;
  String? _resultMessage;
  String? _errorMessage;

  @override
  void dispose() {
    _codeController.dispose();
    super.dispose();
  }

  void _clearResult() {
    if (_status == null && _resultMessage == null && _errorMessage == null) {
      return;
    }
    setState(() {
      _status = null;
      _resultMessage = null;
      _errorMessage = null;
    });
  }

  Future<void> _submitRequest() async {
    if (_isSubmitting) return;
    if (!(_formKey.currentState?.validate() ?? false)) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _isSubmitting = true;
      _status = null;
      _resultMessage = null;
      _errorMessage = null;
    });
    try {
      final client = Supabase.instance.client;
      if (client.auth.currentUser == null) {
        setState(() {
          _errorMessage = 'Please sign in before joining a class.';
        });
        return;
      }
      final response = await client.rpc(
        'comptech_request_class_join',
        params: {'p_access_code': _codeController.text.trim()},
      );
      if (!mounted) return;
      if (response is! Map) {
        throw const FormatException('Unexpected join response.');
      }
      final status = response['status'];
      final message = response['message'];
      const validStatuses = {'enrolled', 'already_enrolled'};
      if (status is! String ||
          !validStatuses.contains(status) ||
          message is! String ||
          message.trim().isEmpty) {
        throw const FormatException('Unexpected join response.');
      }
      setState(() {
        _status = status;
        _resultMessage = message;
      });
    } on PostgrestException catch (error) {
      if (!mounted) return;
      setState(() {
        _errorMessage = error.code == 'P0001' ? error.message : 'Could not join the class. Please try again or contact your administrator.';
      });
    } on AuthException catch (_) {
      if (!mounted) return;
      setState(() {
        _errorMessage =
        'Your session could not be verified. Please sign in again.';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _errorMessage =
        'Could not confirm enrollment. Check your connection and try again. '
            'Retrying will not duplicate an enrollment already saved.';
      });
    } finally {
      if (mounted) {
        setState(() => _isSubmitting = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasResult = _status != null;
    final displayColor = _errorMessage != null
        ? AppColors.error
        : hasResult
        ? AppColors.success
        : accentColor;
    final icon = _errorMessage != null
        ? Icons.error_outline_rounded
        : hasResult
        ? Icons.check_circle_outline_rounded
        : Icons.group_add_outlined;
    final title = _errorMessage != null
        ? 'Enrollment Not Confirmed'
        : _status == 'enrolled'
        ? 'Joined Successfully'
        : _status == 'already_enrolled'
        ? 'Already Enrolled'
        : 'Join a Class';
    final message = _isSubmitting
        ? 'Joining your class…'
        : _errorMessage ?? _resultMessage;

    return PopScope(
      canPop: !_isSubmitting,
      child: Scaffold(
        backgroundColor: backgroundColor,
        appBar: AppBar(
          title: const Text('Join a Class'),
          backgroundColor: backgroundColor,
          foregroundColor: AppColors.text,
          surfaceTintColor: Colors.transparent,
          automaticallyImplyLeading: !_isSubmitting,
        ),
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const SizedBox(height: 24),
                      Icon(icon, size: 100, color: displayColor),
                      const SizedBox(height: 24),
                      Text(
                        title,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: AppColors.text,
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'Enter the class access code provided by your professor to join the class.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: secondaryTextColor,
                          fontSize: 13,
                          height: 1.5,
                        ),
                      ),
                      const SizedBox(height: 28),
                      TextFormField(
                        controller: _codeController,
                        enabled: !_isSubmitting,
                        autocorrect: false,
                        enableSuggestions: false,
                        textCapitalization: TextCapitalization.characters,
                        textInputAction: TextInputAction.done,
                        maxLength: 128,
                        style: TextStyle(
                          color: AppColors.text,
                          fontSize: 16,
                        ),
                        decoration: InputDecoration(
                          labelText: 'Class access code',
                          labelStyle: TextStyle(
                            color: secondaryTextColor,
                          ),
                          prefixIcon: Icon(
                            Icons.vpn_key_outlined,
                            color: accentColor,
                          ),
                          filled: true,
                          fillColor: cardColor,
                          counterText: '',
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide(color: borderColor),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide(color: accentColor),
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        validator: (value) =>
                        value == null || value.trim().isEmpty
                            ? 'Enter a class access code.'
                            : null,
                        onChanged: (_) => _clearResult(),
                        onFieldSubmitted: (_) => _submitRequest(),
                      ),
                      if (message != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 20),
                          child: Semantics(
                            liveRegion: true,
                            child: Text(
                              message,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: _isSubmitting
                                    ? secondaryTextColor
                                    : displayColor,
                                fontSize: 14,
                                height: 1.5,
                              ),
                            ),
                          ),
                        ),
                      const SizedBox(height: 24),
                      PopButtonEffects(
                        child: ElevatedButton(
                          onPressed: _isSubmitting ? null : _submitRequest,
                          style: ElevatedButton.styleFrom(
                            elevation: 0,
                            shadowColor: Colors.transparent,
                            surfaceTintColor: Colors.transparent,
                            backgroundColor: buttonColor,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          child: _isSubmitting
                              ? SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: accentColor,
                            ),
                          )
                              : const Text(
                            'Join Class',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                    ],
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
