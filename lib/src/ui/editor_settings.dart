// SPDX-License-Identifier: GPL-3.0-only

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// Whether writing the editor's presets over what was read from the pedal
/// asks first (a backup restored over presets the app has not read always
/// asks), and how large the whole app is drawn.
abstract final class EditorSettings {
  static Future<File> _file([String name = 'editor.json']) async => File(
    '${(await getApplicationSupportDirectory()).path}'
    '${Platform.pathSeparator}$name',
  );

  /// On when there is no file or it cannot be read.
  static Future<bool> confirmWrite() async {
    try {
      final Object? j = jsonDecode(await (await _file()).readAsString());
      return j is! Map<String, Object?> || j['confirmWrite'] != false;
    } on Exception {
      return true;
    }
  }

  static Future<void> setConfirmWrite(bool on) async {
    final File f = await _file();
    await f.parent.create(recursive: true);
    await f.writeAsString(jsonEncode(<String, Object>{'confirmWrite': on}));
  }

  /// How many times larger than normal the app is drawn, 1 to 2; 1 until
  /// [loadZoom] reads another.
  static final ValueNotifier<double> zoom = ValueNotifier<double>(1);

  /// Reads the saved [zoom]; it stays at 1 when there is no file or it cannot
  /// be read.
  static Future<void> loadZoom() async {
    try {
      final Object? j = jsonDecode(
        await (await _file('zoom.json')).readAsString(),
      );
      if (j is Map<String, Object?> && j['zoom'] is num) {
        zoom.value = (j['zoom']! as num).toDouble().clamp(1, 2);
      }
    } on Exception {
      // no file yet: normal size
    }
  }

  /// Applies [z] at once, then saves it.
  static Future<void> setZoom(double z) async {
    zoom.value = z.clamp(1, 2);
    final File f = await _file('zoom.json');
    await f.parent.create(recursive: true);
    await f.writeAsString(jsonEncode(<String, Object>{'zoom': zoom.value}));
  }
}

/// Desktop only: Android and iOS have their own display size setting.
bool get zoomAvailable => switch (defaultTargetPlatform) {
  TargetPlatform.linux ||
  TargetPlatform.windows ||
  TargetPlatform.macOS => true,
  _ => false,
};

/// The narrowest layout the app is tested at; the zoom never goes below it.
const double _minZoomedWidth = 360;

/// Draws [child] [EditorSettings.zoom] times larger, laid out as in a window
/// that many times smaller, so text, graphics and touch scale together.
/// Ctrl (⌘ on macOS) with plus, minus and 0 change it from the keyboard.
class AppZoom extends StatelessWidget {
  const AppZoom({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => !zoomAvailable
      ? child
      : ValueListenableBuilder<double>(
          valueListenable: EditorSettings.zoom,
          child: child,
          builder: (BuildContext context, double chosen, Widget? child) {
            final MediaQueryData m = MediaQuery.of(context);
            // A narrow window gets less zoom than chosen, never a layout under 360.
            final double z = math.min(
              chosen,
              math.max(1, m.size.width / _minZoomedWidth),
            );
            final bool mac = defaultTargetPlatform == TargetPlatform.macOS;
            SingleActivator ctrl(
              LogicalKeyboardKey key, {
              bool shift = false,
            }) => SingleActivator(key, control: !mac, meta: mac, shift: shift);
            // A zoom left unsaved lasts until the app closes.
            void to(double z) => EditorSettings.setZoom(z).ignore();
            void zoomIn() => to(z + .25);
            void zoomOut() => to(z - .25);
            void reset() => to(1);
            // The same tree at 100%, so a change of zoom keeps every page's state.
            return CallbackShortcuts(
              // Plus is shifted on some layouts and not on others.
              bindings: <ShortcutActivator, VoidCallback>{
                ctrl(LogicalKeyboardKey.equal): zoomIn,
                ctrl(LogicalKeyboardKey.equal, shift: true): zoomIn,
                ctrl(LogicalKeyboardKey.add): zoomIn,
                ctrl(LogicalKeyboardKey.add, shift: true): zoomIn,
                ctrl(LogicalKeyboardKey.numpadAdd): zoomIn,
                ctrl(LogicalKeyboardKey.minus): zoomOut,
                ctrl(LogicalKeyboardKey.numpadSubtract): zoomOut,
                ctrl(LogicalKeyboardKey.digit0): reset,
                ctrl(LogicalKeyboardKey.numpad0): reset,
              },
              child: FittedBox(
                alignment: Alignment.topLeft,
                child: SizedBox.fromSize(
                  size: m.size / z,
                  child: MediaQuery(
                    data: m.copyWith(
                      size: m.size / z,
                      devicePixelRatio: m.devicePixelRatio * z,
                      padding: m.padding / z,
                      viewPadding: m.viewPadding / z,
                      viewInsets: m.viewInsets / z,
                      systemGestureInsets: m.systemGestureInsets / z,
                    ),
                    child: child!,
                  ),
                ),
              ),
            );
          },
        );
}

/// How large the app is drawn, as [AppZoom] applies it.
class ZoomSettingsCard extends StatefulWidget {
  const ZoomSettingsCard({super.key});

  @override
  State<ZoomSettingsCard> createState() => _ZoomSettingsCardState();
}

class _ZoomSettingsCardState extends State<ZoomSettingsCard> {
  /// While the slider is dragged; applied on release, so the slider does not
  /// grow under the finger.
  double? _drag;

  Future<void> _set(double z) async {
    setState(() => _drag = null);
    try {
      await EditorSettings.setZoom(z);
    } on Exception catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not save the setting: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return ValueListenableBuilder<double>(
      valueListenable: EditorSettings.zoom,
      builder: (BuildContext context, double zoom, _) {
        final double z = _drag ?? zoom;
        final String percent = '${(z * 100).round()}%';
        return Card.outlined(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    const Icon(Icons.zoom_in),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text('Zoom', style: theme.textTheme.titleMedium),
                    ),
                    Text(percent, style: theme.textTheme.titleMedium),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  'Draws text and graphics larger, to read the screen from a '
                  'distance.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                Slider(
                  value: z,
                  min: 1,
                  max: 2,
                  divisions: 4,
                  label: percent,
                  onChanged: (double v) => setState(() => _drag = v),
                  onChangeEnd: _set,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// The preset editor's settings.
class EditorSettingsCard extends StatefulWidget {
  const EditorSettingsCard({super.key});

  @override
  State<EditorSettingsCard> createState() => _EditorSettingsCardState();
}

class _EditorSettingsCardState extends State<EditorSettingsCard> {
  bool? _confirm;

  @override
  void initState() {
    super.initState();
    EditorSettings.confirmWrite().then((bool v) {
      if (mounted) {
        setState(() => _confirm = v);
      }
    });
  }

  Future<void> _set(bool v) async {
    setState(() => _confirm = v);
    try {
      await EditorSettings.setConfirmWrite(v);
    } on Exception catch (e) {
      if (mounted) {
        setState(() => _confirm = !v);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not save the setting: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Card.outlined(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                const Icon(Icons.tune),
                const SizedBox(width: 12),
                Text('Preset editor', style: theme.textTheme.titleMedium),
              ],
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _confirm ?? true,
              onChanged: _confirm == null ? null : _set,
              title: const Text('Ask before writing to the pedal'),
              subtitle: const Text(
                'Off: Write to pedal and Ctrl+S write your edits at once. '
                'Restoring a backup over presets not read from the pedal '
                'always asks.',
              ),
            ),
          ],
        ),
      ),
    );
  }
}
