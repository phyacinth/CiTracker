import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// The app's dropdown. Flutter's built-in dropdown opens its list over the
/// button and grows upward past it when there are many items; this one opens
/// directly below its button, at the button's width, shows up to five items
/// and scrolls for more. It flips above only when there's no room below.
///
/// Takes the same settings as DropdownButton (with [value]) and
/// DropdownButtonFormField (with [initialValue], [decoration], [validator]),
/// so a dropdown can switch over by changing only its widget name.
class AppDropdown<T> extends StatefulWidget {
  const AppDropdown({
    super.key,
    required this.items,
    required this.onChanged,
    this.value,
    this.initialValue,
    this.hint,
    this.style,
    this.decoration,
    this.validator,
    this.dropdownColor,
    this.borderRadius,
    this.iconEnabledColor,
    this.iconDisabledColor,
    this.isExpanded = true,
    this.outerPadding = 0,
  });

  final List<DropdownMenuItem<T>> items;

  /// Null disables the dropdown.
  final ValueChanged<T?>? onChanged;

  /// The selected value. [initialValue] is the same, for form-field callers.
  final T? value;
  final T? initialValue;
  final Widget? hint;
  final TextStyle? style;

  /// With a decoration, it's a form field: outlined, labelled, validated.
  final InputDecoration? decoration;
  final FormFieldValidator<T>? validator;

  final Color? dropdownColor;
  final BorderRadius? borderRadius;
  final Color? iconEnabledColor;
  final Color? iconDisabledColor;

  /// Kept so DropdownButton callers don't change; it always fills the width.
  final bool isExpanded;

  /// Horizontal padding of a box around a plain dropdown, so the list lines
  /// up with the box's edges instead of the text inside it.
  final double outerPadding;

  static const visibleItems = 5;
  static const itemHeight = 48.0;

  @override
  State<AppDropdown<T>> createState() => _AppDropdownState<T>();
}

class _AppDropdownState<T> extends State<AppDropdown<T>> {
  final _menu = MenuController();

  T? get _value => widget.value ?? widget.initialValue;
  bool get _enabled => widget.onChanged != null;

  void _toggle() {
    if (!_enabled) return;
    _menu.isOpen ? _menu.close() : _menu.open();
  }

  Widget? _selected() {
    for (final item in widget.items) {
      if (item.value == _value) return item.child;
    }
    return null;
  }

  Widget _arrow() => Icon(
    Icons.arrow_drop_down_rounded,
    color: _enabled
        ? widget.iconEnabledColor ?? AppColors.accent
        : widget.iconDisabledColor ?? AppColors.secondaryText,
  );

  Widget _text(Widget child) => DefaultTextStyle.merge(
    style: widget.style ?? TextStyle(color: AppColors.text, fontSize: 14),
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    child: child,
  );

  Widget _plainField() {
    return InkWell(
      onTap: _enabled ? _toggle : null,
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(
        height: AppDropdown.itemHeight,
        child: Row(
          children: [
            Expanded(
              child: Align(
                alignment: Alignment.centerLeft,
                child: _text(_selected() ?? widget.hint ?? const SizedBox()),
              ),
            ),
            _arrow(),
          ],
        ),
      ),
    );
  }

  Widget _formField() {
    // Recreated when the value changes, so the form always validates the
    // current value and a fixed error disappears.
    return FormField<T>(
      key: ValueKey(_value),
      initialValue: _value,
      validator: widget.validator,
      builder: (state) {
        final selected = _selected();
        final showHint = selected == null && widget.hint != null;
        return InkWell(
          onTap: _enabled ? _toggle : null,
          borderRadius: BorderRadius.circular(12),
          child: InputDecorator(
            decoration: widget.decoration!.copyWith(
              errorText: state.errorText,
              enabled: _enabled,
              suffixIcon: _arrow(),
            ),
            isEmpty: selected == null && !showHint,
            isFocused: _menu.isOpen,
            child: _text(
              selected ??
                  (showHint
                      ? DefaultTextStyle.merge(
                          style: TextStyle(color: AppColors.secondaryText),
                          child: widget.hint!,
                        )
                      : const SizedBox()),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth + widget.outerPadding * 2;
        return MenuAnchor(
          controller: _menu,
          alignmentOffset: Offset(-widget.outerPadding, 6),
          onOpen: () => setState(() {}),
          onClose: () => setState(() {}),
          style: MenuStyle(
            backgroundColor: WidgetStatePropertyAll(
              widget.dropdownColor ?? AppColors.card,
            ),
            surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
            elevation: const WidgetStatePropertyAll(6),
            padding: const WidgetStatePropertyAll(
              EdgeInsets.symmetric(vertical: 6),
            ),
            // A clear outline so the open list stands out from the page:
            // white in dark mode, the deep blue of the buttons in light mode.
            shape: WidgetStatePropertyAll(
              RoundedRectangleBorder(
                borderRadius:
                    widget.borderRadius ?? BorderRadius.circular(16),
                side: BorderSide(
                  color: AppTheme.isDark ? Colors.white : AppColors.button,
                  width: 1.5,
                ),
              ),
            ),
            minimumSize: WidgetStatePropertyAll(Size(width, 0)),
            maximumSize: WidgetStatePropertyAll(
              Size(
                width,
                AppDropdown.itemHeight * AppDropdown.visibleItems + 12,
              ),
            ),
          ),
          menuChildren: [
            for (final item in widget.items)
              MenuItemButton(
                onPressed: item.enabled
                    ? () {
                        widget.onChanged?.call(item.value);
                      }
                    : null,
                style: MenuItemButton.styleFrom(
                  minimumSize: Size(width, AppDropdown.itemHeight),
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  foregroundColor: AppColors.text,
                  backgroundColor: item.value == _value
                      ? AppColors.accent.withValues(alpha: .12)
                      : null,
                ),
                child: SizedBox(width: width - 32, child: _text(item.child)),
              ),
          ],
          builder: (context, controller, child) => widget.decoration == null
              ? _plainField()
              : _formField(),
        );
      },
    );
  }
}
