// SPDX-License-Identifier: GPL-3.0-only

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'app_theme.dart';

/// Each block's colour on the pedal's own screen: the table at `0x205cdf8`
/// in firmware V1.05, which is LVGL's `lv_palette_main` (red, pink, purple,
/// deep purple, indigo, blue). An "on" block is a solid box in this colour
/// with a white label.
const Map<String, Color> _blockSeeds = <String, Color>{
  'FX': Color(0xFFF44336),
  'AMP': Color(0xFFE91E63),
  'MOD': Color(0xFF9C27B0),
  'DLY': Color(0xFF673AB7),
  'REV': Color(0xFF3F51B5),
  'CAB': Color(0xFF2196F3),
  // Same table, entry 6.
  'EQ': Color(0xFF03A9F4),
};

/// The exact colour the pedal paints [block] with, or null for others.
Color? blockColor(String block) => _blockSeeds[block];

/// [block]'s colour for an icon or text on the page: the pedal's colour,
/// lightened on a dark page, where DLY and REV are too dark to read.
Color? blockInk(String block, Brightness b) {
  final Color? c = _blockSeeds[block];
  return c == null || b == Brightness.light
      ? c
      : Color.lerp(c, Colors.white, 0.35);
}

final Map<(Color, Brightness), ThemeData> _tinted =
    <(Color, Brightness), ThemeData>{};

/// [base] redrawn with [seed] as its primary colour.
ThemeData tinted(ThemeData base, Color seed) => _tinted.putIfAbsent((
  seed,
  base.brightness,
), () => themeFrom(accented(base.colorScheme, seed)));

/// [base] with the colours of [block], for everything drawn for that block.
ThemeData blockTheme(ThemeData base, String block) {
  final Color? seed = _blockSeeds[block];
  return seed == null ? base : tinted(base, seed);
}

/// The app's own drawing of a signal-chain block (`FX`, `AMP`, `MOD`, `DLY`,
/// `REV`, `CAB`), in [color] or the ambient icon colour.
class BlockIcon extends StatelessWidget {
  const BlockIcon(this.block, {super.key, this.size = 24, this.color});
  final String block;
  final double size;
  final Color? color;

  static const Set<String> _drawn = <String>{
    'FX',
    'AMP',
    'MOD',
    'DLY',
    'REV',
    'CAB',
  };

  @override
  Widget build(BuildContext context) {
    final Color c = color ?? IconTheme.of(context).color ?? Colors.black;
    if (!_drawn.contains(block)) {
      return Icon(Icons.extension_outlined, size: size, color: c);
    }
    return SvgPicture.asset(
      'assets/blocks/${block.toLowerCase()}.svg',
      width: size,
      height: size,
      colorFilter: ColorFilter.mode(c, BlendMode.srcIn),
      semanticsLabel: block,
    );
  }
}

/// An icon in a tinted circle, at the start of a row or a card.
class IconBadge extends StatelessWidget {
  const IconBadge(
    IconData this.icon, {
    super.key,
    this.size = 36,
    this.strong = false,
  }) : block = null;

  /// The badge for a signal-chain block, with its [BlockIcon].
  const IconBadge.block(
    String this.block, {
    super.key,
    this.size = 36,
    this.strong = false,
  }) : icon = null;
  final IconData? icon;
  final String? block;
  final double size;

  /// Primary colours instead of the softer secondary container.
  final bool strong;

  @override
  Widget build(BuildContext context) {
    final ColorScheme c = Theme.of(context).colorScheme;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: strong ? c.primary : c.secondaryContainer,
      ),
      child: block != null
          ? BlockIcon(
              block!,
              size: size * 0.6,
              color: strong ? c.onPrimary : c.onSecondaryContainer,
            )
          : Icon(
              icon,
              size: size * 0.55,
              color: strong ? c.onPrimary : c.onSecondaryContainer,
            ),
    );
  }
}

/// What a screen shows before it has anything: a large icon, a title, a line
/// on what to do and, when there is one, the button that does it.
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.action,
  });
  final IconData icon;
  final String title;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme c = theme.colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Container(
                width: 112,
                height: 112,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: c.primaryContainer,
                ),
                child: Icon(icon, size: 56, color: c.onPrimaryContainer),
              ),
              const SizedBox(height: 20),
              Text(
                title,
                style: theme.textTheme.titleLarge,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                message,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: c.onSurfaceVariant,
                ),
              ),
              if (action != null) ...<Widget>[
                const SizedBox(height: 20),
                action!,
              ],
            ],
          ),
        ),
      ),
    );
  }
}
