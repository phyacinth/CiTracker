import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Makes the app logo a light/dark mode switch, with a small sun or moon
/// badge so it reads as a button. Used on the login and registration
/// screens, where the Profile screen's theme setting isn't reachable yet.
class ThemeToggleLogo extends StatelessWidget {
  const ThemeToggleLogo({
    super.key,
    required this.child,
    this.borderRadius = const BorderRadius.all(Radius.circular(16)),
  });

  final Widget child;
  final BorderRadius borderRadius;

  @override
  Widget build(BuildContext context) {
    final dark = AppTheme.isDark;
    final label = dark ? 'Switch to light mode' : 'Switch to dark mode';

    return Tooltip(
      message: label,
      child: Semantics(
        button: true,
        label: label,
        excludeSemantics: true,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            child,
            // Above the logo so the ripple shows over its background.
            Positioned.fill(
              child: Material(
                color: Colors.transparent,
                borderRadius: borderRadius,
                child: InkWell(
                  borderRadius: borderRadius,
                  onTap: () => AppTheme.setMode(
                    dark ? ThemeMode.light : ThemeMode.dark,
                  ),
                ),
              ),
            ),
            Positioned(
              right: -6,
              bottom: -6,
              child: IgnorePointer(
                child: Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: AppColors.card,
                    shape: BoxShape.circle,
                    border: Border.all(color: AppColors.border),
                  ),
                  child: Icon(
                    dark ? Icons.light_mode_rounded : Icons.dark_mode_rounded,
                    size: 14,
                    color: AppColors.accent,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
