import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AppPalette {
  const AppPalette({
    required this.background,
    required this.card,
    required this.accent,
    required this.button,
    required this.border,
    required this.secondaryText,
    required this.text,
    required this.selectedOnButton,
    required this.success,
    required this.warning,
    required this.error,
  });

  final Color background;
  final Color card;
  final Color accent;
  final Color button;
  final Color border;
  final Color secondaryText;
  final Color text;
  // Foreground for selected items drawn on a button-colored background.
  final Color selectedOnButton;
  final Color success;
  final Color warning;
  final Color error;

  static const dark = AppPalette(
    background: Color(0xFF171717),
    card: Color(0xFF132135),
    accent: Color(0xFFADF1FF),
    button: Color(0xFF346485),
    border: Color(0xFF343D3F),
    secondaryText: Color(0xFFA7B0BC),
    text: Colors.white,
    selectedOnButton: Color(0xFFADF1FF),
    success: Color(0xFF81C784),
    warning: Color(0xFFFFD27A),
    error: Color(0xFFFFB4AB),
  );

  // Matches the professor portal: navy, indigo, and white cards on a pale page.
  static const light = AppPalette(
    background: Color(0xFFF5F6FB),
    card: Colors.white,
    accent: Color(0xFF4F5BD5),
    button: Color(0xFF26346E),
    border: Color(0xFFE2E5EE),
    // Dark slate, not grey, so smaller text stays readable on white cards.
    secondaryText: Color(0xFF454B66),
    text: Color(0xFF1B2140),
    selectedOnButton: Colors.white,
    success: Color(0xFF2E8B57),
    warning: Color(0xFFB7791F),
    error: Color(0xFFC62828),
  );
}

/// The current palette. Screens read these getters while building, so a mode
/// change takes effect on the next rebuild (see [AppTheme.setMode]).
class AppColors {
  AppColors._();

  static AppPalette get _p => AppTheme.palette;
  static Color get background => _p.background;
  static Color get card => _p.card;
  static Color get accent => _p.accent;
  static Color get button => _p.button;
  static Color get border => _p.border;
  static Color get secondaryText => _p.secondaryText;
  static Color get text => _p.text;
  static Color get selectedOnButton => _p.selectedOnButton;
  static Color get success => _p.success;
  static Color get warning => _p.warning;
  static Color get error => _p.error;
}

class AppTheme {
  AppTheme._();

  static const _key = 'theme_mode';

  /// Light is the default until the student picks a mode in Profile.
  static final mode = ValueNotifier<ThemeMode>(ThemeMode.light);

  static bool get isDark => mode.value == ThemeMode.dark;
  static AppPalette get palette => isDark ? AppPalette.dark : AppPalette.light;

  static Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      mode.value =
          prefs.getString(_key) == 'dark' ? ThemeMode.dark : ThemeMode.light;
    } catch (_) {
      // Keep the default if preferences are unavailable.
    }
  }

  static Future<void> setMode(ThemeMode value) async {
    mode.value = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, value == ThemeMode.dark ? 'dark' : 'light');
    } catch (_) {
      // The choice still applies for this run.
    }
  }

  static SystemUiOverlayStyle get overlayStyle =>
      isDark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark;

  static ThemeData data(AppPalette p, Brightness brightness) {
    final scheme = brightness == Brightness.dark
        ? ColorScheme.dark(
            primary: p.accent,
            onPrimary: p.background,
            secondary: p.button,
            onSecondary: Colors.white,
            surface: p.card,
            onSurface: p.text,
            error: p.error,
          )
        : ColorScheme.light(
            primary: p.accent,
            onPrimary: Colors.white,
            secondary: p.button,
            onSecondary: Colors.white,
            surface: p.card,
            onSurface: p.text,
            error: p.error,
          );
    return ThemeData(
      brightness: brightness,
      scaffoldBackgroundColor: p.background,
      canvasColor: p.background,
      colorScheme: scheme,
      dividerColor: p.border,
      appBarTheme: AppBarTheme(
        backgroundColor: p.background,
        foregroundColor: p.text,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        systemOverlayStyle: brightness == Brightness.dark
            ? SystemUiOverlayStyle.light
            : SystemUiOverlayStyle.dark,
      ),
      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        backgroundColor: p.card,
        selectedItemColor: p.accent,
        unselectedItemColor: p.secondaryText,
        type: BottomNavigationBarType.fixed,
      ),
    );
  }
}
