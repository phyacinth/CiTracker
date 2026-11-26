import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

class StudentBottomNavigation extends StatelessWidget {
  const StudentBottomNavigation({
    super.key,
    required this.currentIndex,
    required this.onTap,
  }) : assert(currentIndex >= 0 && currentIndex < 4);

  final int currentIndex;
  final ValueChanged<int> onTap;

  // The bar uses the button blue, so its icons and labels are white.
  static const _selected = Colors.white;
  static const _muted = Color(0xC7FFFFFF);
  static const _labels = ['Home', 'Attendance & Classes', 'Scores', 'Profile'];
  static const _icons = [Icons.home_outlined, Icons.menu_book_outlined,
    Icons.bar_chart_outlined, Icons.person_outline_rounded];
  static const _activeIcons = [Icons.home_rounded, Icons.menu_book_rounded,
    Icons.bar_chart_rounded, Icons.person_rounded];

  @override
  Widget build(BuildContext context) {
    final duration = MediaQuery.of(context).disableAnimations
        ? Duration.zero : const Duration(milliseconds: 250);
    final labelHeight = MediaQuery.textScalerOf(context).scale(10) * 2.4;

    return Material(
      color: AppColors.button,
      child: DecoratedBox(
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: Color(0x33FFFFFF))),
        ),
        child: SafeArea(
          top: false,
          child: Center(
            heightFactor: 1,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1000),
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final tabWidth = constraints.maxWidth / 4;
                    final visualIndex =
                    Directionality.of(context) == TextDirection.rtl
                        ? 3 - currentIndex : currentIndex;
                    return SizedBox(
                      height: 48 + labelHeight,
                      child: Stack(
                        children: [
                          AnimatedPositioned(
                            duration: duration,
                            curve: Curves.easeInOutCubic,
                            left: visualIndex * tabWidth + 4,
                            width: tabWidth - 8,
                            top: 0,
                            bottom: 0,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.18),
                                borderRadius: BorderRadius.circular(14),
                                border: Border.all(
                                    color: Colors.white.withValues(alpha: 0.35)),
                              ),
                            ),
                          ),
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: List.generate(4, (index) {
                              final selected = index == currentIndex;
                              void select() {
                                if (!selected) onTap(index);
                              }
                              return Expanded(
                                child: Semantics(
                                  selected: selected,
                                  button: true,
                                  label: _labels[index],
                                  onTap: select,
                                  excludeSemantics: true,
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 4),
                                    child: InkWell(
                                      onTap: select,
                                      borderRadius: BorderRadius.circular(14),
                                      splashColor: Colors.white.withValues(alpha: 0.12),
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 4, vertical: 8),
                                        child: Column(
                                          mainAxisAlignment:
                                          MainAxisAlignment.center,
                                          children: [
                                            AnimatedScale(
                                              scale: selected ? 1.08 : 1,
                                              duration: duration,
                                              child: Icon(
                                                selected ? _activeIcons[index]
                                                    : _icons[index],
                                                color: selected
                                                    ? _selected : _muted,
                                                size: 24,
                                              ),
                                            ),
                                            const SizedBox(height: 4),
                                            SizedBox(
                                              height: labelHeight,
                                              child: Center(
                                                child: AnimatedDefaultTextStyle(
                                                  duration: duration,
                                                  style: TextStyle(
                                                    color: selected
                                                        ? _selected : _muted,
                                                    fontSize: 10,
                                                    height: 1.2,
                                                    fontWeight: selected
                                                        ? FontWeight.w600
                                                        : FontWeight.w400,
                                                  ),
                                                  child: Text(_labels[index],
                                                    textAlign: TextAlign.center,
                                                    maxLines: 2,
                                                    overflow:
                                                    TextOverflow.ellipsis,
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
                              );
                            }),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
