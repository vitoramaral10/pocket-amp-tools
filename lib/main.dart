// SPDX-License-Identifier: GPL-3.0-only

import 'package:flutter/material.dart';

import 'src/midi/midi_backend.dart';
import 'src/ui/app_theme.dart';
import 'src/telemetry.dart';
import 'src/ui/home_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Telemetry.startIfAllowed();
  runApp(const PocketAmpApp());
}

class PocketAmpApp extends StatelessWidget {
  const PocketAmpApp({super.key, this.backend});

  /// Injected in tests and screenshots; the platform backend otherwise.
  final MidiBackend? backend;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Pocket AMP Tools',
      debugShowCheckedModeBanner: false,
      theme: themeFrom(lightColors),
      darkTheme: themeFrom(darkColors),
      home: HomePage(backend: backend),
      // Past compact a floating snackbar spanning the window reads as a
      // banner; Material 3 keeps it to a readable width.
      builder: (BuildContext context, Widget? child) {
        if (MediaQuery.sizeOf(context).width < 600) {
          return child!;
        }
        final ThemeData t = Theme.of(context);
        return Theme(
          data: t.copyWith(snackBarTheme: t.snackBarTheme.copyWith(width: 560)),
          child: child!,
        );
      },
    );
  }
}
