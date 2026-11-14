// SPDX-License-Identifier: GPL-3.0-only

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_amp_tools/src/ui/onboarding.dart';

Future<Object?> _run(WidgetTester t, {required bool askReports}) async {
  Object? answer = 'open';
  await t.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (BuildContext context) => TextButton(
          onPressed: () async => answer = await showDialog<bool>(
            context: context,
            builder: (_) => OnboardingDialog(askReports: askReports),
          ),
          child: const Text('go'),
        ),
      ),
    ),
  );
  await t.tap(find.text('go'));
  await t.pumpAndSettle();
  expect(find.text('Welcome to Pocket AMP Tools'), findsOneWidget);
  await t.tap(find.text('Next'));
  await t.pumpAndSettle();
  expect(find.text('Connect the pedal'), findsOneWidget);
  await t.tap(find.text('Back'));
  await t.pumpAndSettle();
  expect(find.text('Welcome to Pocket AMP Tools'), findsOneWidget);
  await t.tap(find.text('Next'));
  await t.pumpAndSettle();
  if (askReports) {
    await t.tap(find.text('Next'));
    await t.pumpAndSettle();
    expect(find.text('Send error reports?'), findsOneWidget);
    await t.tap(find.text("Don't send"));
  } else {
    expect(find.text('Next'), findsNothing);
    await t.tap(find.text('Start'));
  }
  await t.pumpAndSettle();
  return answer;
}

void main() {
  testWidgets('without reporting, the introduction ends on Start', (
    WidgetTester t,
  ) async {
    expect(await _run(t, askReports: false), isNull);
  });

  testWidgets('with reporting, the last page asks and returns the answer', (
    WidgetTester t,
  ) async {
    expect(await _run(t, askReports: true), isFalse);
  });
}
