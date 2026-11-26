import 'package:comptech_portal_app/widgets/app_dropdown.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget host({
    required ValueChanged<String?> onChanged,
    String? value,
    double top = 100,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: Padding(
          padding: EdgeInsets.only(top: top, left: 20, right: 20),
          child: Align(
            alignment: Alignment.topCenter,
            child: AppDropdown<String>(
              value: value,
              hint: const Text('Select a subject'),
              items: [
                for (var i = 1; i <= 12; i++)
                  DropdownMenuItem(value: 'c$i', child: Text('Class $i')),
              ],
              onChanged: onChanged,
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('opens below the button, at most five items tall', (tester) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(host(onChanged: (_) {}));
    final button = tester.getRect(find.text('Select a subject'));

    await tester.tap(find.text('Select a subject'));
    await tester.pumpAndSettle();

    final first = tester.getRect(find.text('Class 1'));
    expect(first.top, greaterThan(button.bottom), reason: 'list opens below');

    // Only about five rows are on screen; the rest need scrolling.
    final visible = [
      for (var i = 1; i <= 12; i++)
        if (find.text('Class $i').hitTestable().evaluate().isNotEmpty) i,
    ];
    expect(visible.length, lessThanOrEqualTo(6));
    expect(find.text('Class 12').hitTestable(), findsNothing);
  });

  testWidgets('picking an item reports it and closes the list', (tester) async {
    String? picked;
    await tester.pumpWidget(host(onChanged: (v) => picked = v));

    await tester.tap(find.text('Select a subject'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Class 3'));
    await tester.pumpAndSettle();

    expect(picked, 'c3');
    expect(find.text('Class 4'), findsNothing);
  });

  testWidgets('shows the selected item and is disabled without onChanged',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AppDropdown<String>(
            value: 'c2',
            items: const [
              DropdownMenuItem(value: 'c1', child: Text('Class 1')),
              DropdownMenuItem(value: 'c2', child: Text('Class 2')),
            ],
            onChanged: null,
          ),
        ),
      ),
    );
    expect(find.text('Class 2'), findsOneWidget);
    await tester.tap(find.text('Class 2'));
    await tester.pumpAndSettle();
    expect(find.text('Class 1'), findsNothing);
  });

  testWidgets('form mode shows the validator message', (tester) async {
    final form = GlobalKey<FormState>();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Form(
            key: form,
            child: AppDropdown<String>(
              decoration: const InputDecoration(labelText: 'Status'),
              items: const [
                DropdownMenuItem(value: 'r', child: Text('Regular')),
              ],
              onChanged: (_) {},
              validator: (v) => v == null ? 'Please select your status.' : null,
            ),
          ),
        ),
      ),
    );
    expect(form.currentState!.validate(), isFalse);
    await tester.pump();
    expect(find.text('Please select your status.'), findsOneWidget);
  });
}
