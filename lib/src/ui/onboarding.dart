// SPDX-License-Identifier: GPL-3.0-only

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../telemetry.dart';

/// Whether the introduction was already shown. When this cannot be told
/// (no app folder), it counts as shown: the introduction must never keep the
/// app from detecting the pedal.
Future<bool> onboardingSeen() async {
  try {
    return (await _seenFile()).existsSync();
  } catch (_) {
    return true;
  }
}

Future<void> _markSeen() async {
  try {
    final File f = await _seenFile();
    await f.parent.create(recursive: true);
    await f.writeAsString('1');
  } catch (_) {}
}

Future<File> _seenFile() async => File(
  '${(await getApplicationSupportDirectory()).path}'
  '${Platform.pathSeparator}onboarded',
);

/// What error reports hold, shown wherever the user is asked about them.
const String reportsExplained =
    'Reports help fix crashes and show which pedals update well. They hold '
    'the error, the recent log lines, the app version, your system, and the '
    'pedal and firmware names. No presets, files or user name are sent, and '
    'your IP address is not stored. You can change this later with the bug '
    'button at the top.';

/// The first-run introduction. With error reporting built in, its last page
/// asks for that permission, so the answer is stored too.
Future<void> showOnboarding(BuildContext context) async {
  final bool? reports = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (BuildContext context) =>
        OnboardingDialog(askReports: Telemetry.available),
  );
  await _markSeen();
  if (reports != null && Telemetry.available) {
    await Telemetry.choose(reports);
  }
}

class OnboardingDialog extends StatefulWidget {
  const OnboardingDialog({super.key, required this.askReports});

  /// Ends with the error-report question; closes with its answer.
  final bool askReports;

  @override
  State<OnboardingDialog> createState() => _OnboardingDialogState();
}

/// One page: the picture on top, a title and a list of points.
typedef _Page = (Widget Function(ColorScheme) art, String, List<_Point>);
typedef _Point = (IconData, String);

class _OnboardingDialogState extends State<OnboardingDialog> {
  int _page = 0;

  static final List<_Page> _pages = <_Page>[
    (
      (_) => Image.asset('assets/icon/app_icon.png', width: 96, height: 96),
      'Welcome to Pocket AMP Tools',
      <_Point>[
        (
          Icons.tune,
          'Edit the 80 presets of a Pocket AMP, whatever brand is printed '
              'on it, and hear each change on the pedal',
        ),
        (
          Icons.library_music_outlined,
          'Send your own IRs and amp captures to its CAB and AMP slots',
        ),
        (
          Icons.system_update_alt,
          'Update its firmware. Your presets are backed up first',
        ),
      ],
    ),
    (
      (ColorScheme c) => Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          for (final (int i, IconData icon) in <IconData>[
            Icons.battery_charging_full,
            Icons.usb,
            Icons.computer,
          ].indexed) ...<Widget>[
            if (i > 0)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Icon(Icons.arrow_forward, color: c.onPrimaryContainer),
              ),
            CircleAvatar(
              radius: 30,
              backgroundColor: c.primary,
              child: Icon(icon, size: 30, color: c.onPrimary),
            ),
          ],
        ],
      ),
      'Connect the pedal',
      <_Point>[
        (Icons.battery_charging_full, 'Charge it and turn it on'),
        (
          Icons.cable,
          'Use a USB data cable. Many cables only charge, and the pedal is '
              'not found with them',
        ),
        (
          Icons.do_not_disturb_on_outlined,
          'Close the M-VAVE app, DAWs and browser tabs with Web MIDI: only one '
              'app can talk to the pedal at a time',
        ),
      ],
    ),
    (
      (ColorScheme c) => Icon(
        Icons.privacy_tip_outlined,
        size: 72,
        color: c.onPrimaryContainer,
      ),
      'Send error reports?',
      <_Point>[
        (
          Icons.bug_report_outlined,
          'They help fix crashes and show which pedals update well',
        ),
        (
          Icons.check_circle_outline,
          'Sent: the error, recent log lines, app version, system, and the '
              'pedal and firmware names',
        ),
        (
          Icons.block,
          'Never sent: presets, files or your user name. Your IP address is '
              'not stored',
        ),
        (
          Icons.settings_outlined,
          'Change it later with the bug button at the top',
        ),
      ],
    ),
  ];

  int get _count => widget.askReports ? _pages.length : _pages.length - 1;
  bool get _last => _page == _count - 1;

  Widget _pageView(ThemeData theme, _Page page) {
    final ColorScheme c = theme.colorScheme;
    final (
      Widget Function(ColorScheme) art,
      String title,
      List<_Point> points,
    ) = page;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Container(
          height: 150,
          width: double.infinity,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: c.primaryContainer,
            borderRadius: BorderRadius.circular(20),
          ),
          child: ExcludeSemantics(child: art(c)),
        ),
        const SizedBox(height: 20),
        Text(title, style: theme.textTheme.headlineSmall),
        const SizedBox(height: 16),
        for (final (IconData icon, String text) in points)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                CircleAvatar(
                  radius: 16,
                  backgroundColor: c.secondaryContainer,
                  child: Icon(icon, size: 18, color: c.onSecondaryContainer),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(text, style: theme.textTheme.bodyMedium),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme c = theme.colorScheme;
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        // On a short window the pages scroll and the buttons stay in view.
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    // Every page is laid out, so the dialog keeps the height of the
                    // tallest and the buttons stay in place.
                    IndexedStack(
                      index: _page,
                      children: <Widget>[
                        for (int i = 0; i < _count; i++)
                          _pageView(theme, _pages[i]),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Semantics(
                      label: 'Page ${_page + 1} of $_count',
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: <Widget>[
                          for (int i = 0; i < _count; i++)
                            AnimatedContainer(
                              duration: const Duration(milliseconds: 200),
                              width: i == _page ? 20 : 8,
                              height: 8,
                              margin: const EdgeInsets.symmetric(horizontal: 3),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(4),
                                color: i == _page
                                    ? c.primary
                                    : c.outlineVariant,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 20),
              child: Row(
                children: <Widget>[
                  if (_page > 0)
                    TextButton(
                      onPressed: () => setState(() => _page--),
                      child: const Text('Back'),
                    ),
                  const Spacer(),
                  if (_last && widget.askReports) ...<Widget>[
                    TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text("Don't send"),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('Send reports'),
                    ),
                  ] else if (_last)
                    FilledButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Start'),
                    )
                  else
                    FilledButton.icon(
                      onPressed: () => setState(() => _page++),
                      iconAlignment: IconAlignment.end,
                      icon: const Icon(Icons.arrow_forward),
                      label: const Text('Next'),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
