// SPDX-License-Identifier: GPL-3.0-only
//
// Opening the Firmware section with a pedal on USB fetches the official
// firmware on its own and says whether there is anything to update.

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pocket_amp_tools/src/ui/home_page.dart';

import 'support/fake_pedal.dart';

void main() {
  Future<int> open(WidgetTester tester, String identity) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    int fetched = 0;
    await http.runWithClient(
      () async {
        await tester.pumpWidget(
          MaterialApp(
            home: HomePage(
              backend: FakePedal(
                identity: identity,
                image: Uint8List(1024),
                bank: demoBank(),
              ),
            ),
          ),
        );
        Future<void> settle(int n) async {
          for (int i = 0; i < n; i++) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 5)),
            );
            await tester.pump(const Duration(milliseconds: 50));
          }
        }

        await settle(400); // detection, then the presets read it starts
        await tester.tap(find.text('Firmware'));
        await settle(40);
        await tester.tap(find.text('Presets'));
        await settle(5);
        await tester.tap(find.text('Firmware')); // once per run, not per visit
        await settle(40);
      },
      () => MockClient((http.Request r) async {
        fetched++;
        expect(r.url.host, 'yms-file-store.oss-cn-hongkong.aliyuncs.com');
        return http.Response.bytes(
          buildFwsc(product: 'Pocket AMP_105', loader: Uint8List(64)),
          200,
        );
      }),
    );
    return fetched;
  }

  testWidgets('a pedal on the latest firmware is said to be up to date', (
    WidgetTester tester,
  ) async {
    expect(await open(tester, 'Pocket AMP_105'), 1);
    expect(find.text('Your pedal is up to date'), findsOneWidget);
    expect(
      find.text('It runs 1.05, the latest firmware from M-VAVE.'),
      findsOneWidget,
    );
    expect(find.text('Before you update'), findsNothing);
    expect(find.text('Update firmware'), findsNothing);
    expect(find.textContaining('already runs'), findsNothing);
  });

  testWidgets('a pedal on older firmware is offered the update', (
    WidgetTester tester,
  ) async {
    expect(await open(tester, 'Pocket AMP_103'), 1);
    expect(find.text('Your pedal is up to date'), findsNothing);
    expect(find.text('Update ready'), findsOneWidget);
    expect(find.text('Before you update'), findsOneWidget);
    expect(find.text('Update firmware'), findsOneWidget);
  });
}
