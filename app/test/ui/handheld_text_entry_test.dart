// SPDX-License-Identifier: GPL-3.0-or-later
// Spec: docs/specs/handheld-ui.md (On-screen keyboard)
import 'package:dena_emu/src/shell/handheld.dart';
import 'package:dena_emu/src/ui/onscreen_keyboard.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets('A on a text field types it on the on-screen keyboard', (
    tester,
  ) async {
    final c = TextEditingController(text: 'ab');
    String? changed, submitted;
    await tester.pumpWidget(
      Handheld(
        enabled: true,
        child: MaterialApp(
          builder: (context, child) => HandheldTextEntry(child: child!),
          home: Scaffold(
            body: TextField(
              controller: c,
              autofocus: true,
              textInputAction: TextInputAction.done,
              decoration: const InputDecoration(labelText: 'Cheat code'),
              onChanged: (t) => changed = t,
              onSubmitted: (t) => submitted = t,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonA);
    await tester.pumpAndSettle();
    expect(find.byType(OnScreenKeyboard), findsOneWidget);
    expect(find.text('Cheat code'), findsOneWidget);
    await tester.tap(find.text('c'));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonStart);
    await tester.pumpAndSettle();
    expect(find.byType(OnScreenKeyboard), findsNothing);
    expect(c.text, 'abc');
    expect(changed, 'abc');
    expect(submitted, 'abc');
  });

  testWidgets('A elsewhere still activates', (tester) async {
    var pressed = false;
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => HandheldTextEntry(child: child!),
        home: Scaffold(
          body: TextButton(
            autofocus: true,
            onPressed: () => pressed = true,
            child: const Text('Go'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonA);
    await tester.pumpAndSettle();
    expect(pressed, isTrue);
    expect(find.byType(OnScreenKeyboard), findsNothing);
  });
}
