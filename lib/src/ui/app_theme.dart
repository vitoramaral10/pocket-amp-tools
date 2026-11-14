// SPDX-License-Identifier: GPL-3.0-only

import 'package:flutter/material.dart';

/// The app's colours, written out by hand: the brand orange of the icon,
/// neutral greys (no tint from the orange) and, in dark mode, the near-black
/// of the pedal's own screen. Every colour role the app uses is set here, so
/// none is left for the framework to derive.
const ColorScheme lightColors = ColorScheme(
  brightness: Brightness.light,
  primary: Color(0xFFC4511A),
  onPrimary: Color(0xFFFFFFFF),
  primaryContainer: Color(0xFFFFE3D3),
  onPrimaryContainer: Color(0xFF5C2004),
  secondary: Color(0xFF4A4A4A),
  onSecondary: Color(0xFFFFFFFF),
  secondaryContainer: Color(0xFFECECEC),
  onSecondaryContainer: Color(0xFF242424),
  tertiary: Color(0xFF00897B),
  onTertiary: Color(0xFFFFFFFF),
  tertiaryContainer: Color(0xFFCCEFEA),
  onTertiaryContainer: Color(0xFF00382F),
  error: Color(0xFFC62828),
  onError: Color(0xFFFFFFFF),
  errorContainer: Color(0xFFFDE7E7),
  onErrorContainer: Color(0xFF7F1010),
  surface: Color(0xFFFFFFFF),
  onSurface: Color(0xFF1C1C1C),
  onSurfaceVariant: Color(0xFF5F5F5F),
  surfaceContainerLowest: Color(0xFFFFFFFF),
  surfaceContainerLow: Color(0xFFF8F8F8),
  surfaceContainer: Color(0xFFF2F2F2),
  surfaceContainerHigh: Color(0xFFEBEBEB),
  surfaceContainerHighest: Color(0xFFE3E3E3),
  outline: Color(0xFF9E9E9E),
  outlineVariant: Color(0xFFDDDDDD),
  inverseSurface: Color(0xFF2B2B2B),
  onInverseSurface: Color(0xFFF2F2F2),
  inversePrimary: Color(0xFFFF8A50),
  shadow: Color(0xFF000000),
  scrim: Color(0xFF000000),
);

const ColorScheme darkColors = ColorScheme(
  brightness: Brightness.dark,
  primary: Color(0xFFFF8A50),
  onPrimary: Color(0xFF2B0E00),
  primaryContainer: Color(0xFF5A2A12),
  onPrimaryContainer: Color(0xFFFFD9C6),
  secondary: Color(0xFFBDBDBD),
  onSecondary: Color(0xFF1A1A1A),
  secondaryContainer: Color(0xFF333333),
  onSecondaryContainer: Color(0xFFEDEDED),
  tertiary: Color(0xFF4DD0C1),
  onTertiary: Color(0xFF00201B),
  tertiaryContainer: Color(0xFF0F4A43),
  onTertiaryContainer: Color(0xFFB6F2EA),
  error: Color(0xFFFF6B6B),
  onError: Color(0xFF3B0000),
  errorContainer: Color(0xFF5C1414),
  onErrorContainer: Color(0xFFFFD6D6),
  surface: Color(0xFF1A1A1A),
  onSurface: Color(0xFFEDEDED),
  onSurfaceVariant: Color(0xFFA8A8A8),
  surfaceContainerLowest: Color(0xFF0E0E0E),
  surfaceContainerLow: Color(0xFF161616),
  surfaceContainer: Color(0xFF1F1F1F),
  surfaceContainerHigh: Color(0xFF262626),
  surfaceContainerHighest: Color(0xFF303030),
  outline: Color(0xFF6E6E6E),
  outlineVariant: Color(0xFF3A3A3A),
  inverseSurface: Color(0xFFEDEDED),
  onInverseSurface: Color(0xFF1A1A1A),
  inversePrimary: Color(0xFFC4511A),
  shadow: Color(0xFF000000),
  scrim: Color(0xFF000000),
);

/// The whole theme, built from [c]. Component colours are taken from [c]
/// here and nowhere else, so a recoloured scheme gives a consistent theme.
ThemeData themeFrom(ColorScheme c) {
  final bool dark = c.brightness == Brightness.dark;
  final BorderRadius r10 = BorderRadius.circular(10);
  final RoundedRectangleBorder shape10 = RoundedRectangleBorder(
    borderRadius: r10,
  );
  const EdgeInsets buttonPadding = EdgeInsets.symmetric(
    horizontal: 18,
    vertical: 14,
  );
  // Text styles start from the theme's own typography, so they keep its font.
  final TextTheme t = ThemeData(
    useMaterial3: false,
    brightness: c.brightness,
  ).textTheme;
  WidgetStateProperty<Color?> when(Color on, Color off) =>
      WidgetStateProperty.resolveWith(
        (Set<WidgetState> s) => s.contains(WidgetState.selected) ? on : off,
      );
  return ThemeData(
    useMaterial3: false,
    brightness: c.brightness,
    colorScheme: c,
    primaryColor: c.primary,
    scaffoldBackgroundColor: dark
        ? c.surfaceContainerLowest
        : c.surfaceContainerLow,
    canvasColor: c.surface,
    cardColor: c.surface,
    dividerColor: c.outlineVariant,
    disabledColor: c.onSurface.withValues(alpha: 0.38),
    hintColor: c.onSurfaceVariant,
    splashFactory: InkRipple.splashFactory,
    appBarTheme: AppBarTheme(
      backgroundColor: c.surface,
      foregroundColor: c.onSurface,
      elevation: 0,
      scrolledUnderElevation: 0,
      shape: Border(bottom: BorderSide(color: c.outlineVariant)),
      iconTheme: IconThemeData(color: c.onSurfaceVariant),
      actionsIconTheme: IconThemeData(color: c.onSurfaceVariant),
    ),
    cardTheme: CardThemeData(
      color: c.surface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: c.outlineVariant),
      ),
    ),
    // Colours come from the scheme (primary, or the tonal secondary
    // container): a colour here would also paint the tonal buttons.
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(shape: shape10, padding: buttonPadding),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: c.primary,
        foregroundColor: c.onPrimary,
        shape: shape10,
        padding: buttonPadding,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: c.primary,
        side: BorderSide(color: c.outline),
        shape: shape10,
        padding: buttonPadding,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: c.primary,
        shape: shape10,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(foregroundColor: c.onSurfaceVariant),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: when(c.primary, dark ? c.outline : c.surface),
      trackColor: when(
        c.primary.withValues(alpha: 0.45),
        c.onSurface.withValues(alpha: 0.22),
      ),
    ),
    sliderTheme: SliderThemeData(
      activeTrackColor: c.primary,
      inactiveTrackColor: c.primary.withValues(alpha: 0.22),
      thumbColor: c.primary,
      overlayColor: c.primary.withValues(alpha: 0.12),
      valueIndicatorColor: c.primary,
      valueIndicatorTextStyle: t.labelLarge?.copyWith(color: c.onPrimary),
    ),
    checkboxTheme: CheckboxThemeData(
      fillColor: when(c.primary, Colors.transparent),
      checkColor: WidgetStatePropertyAll<Color>(c.onPrimary),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: c.primary,
      linearTrackColor: c.primary.withValues(alpha: 0.2),
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: c.surface,
      useIndicator: true,
      indicatorColor: c.primaryContainer,
      selectedIconTheme: IconThemeData(color: c.onPrimaryContainer),
      unselectedIconTheme: IconThemeData(color: c.onSurfaceVariant),
      selectedLabelTextStyle: t.labelLarge?.copyWith(
        color: c.primary,
        fontWeight: FontWeight.w600,
      ),
      unselectedLabelTextStyle: t.labelLarge?.copyWith(
        color: c.onSurfaceVariant,
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: c.surface,
      indicatorColor: c.primaryContainer,
      iconTheme: WidgetStateProperty.resolveWith(
        (Set<WidgetState> s) => IconThemeData(
          color: s.contains(WidgetState.selected)
              ? c.onPrimaryContainer
              : c.onSurfaceVariant,
        ),
      ),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: c.surfaceContainerHigh,
      selectedColor: c.primaryContainer,
      checkmarkColor: c.onPrimaryContainer,
      labelStyle: t.labelLarge?.copyWith(color: c.onSurface),
      side: BorderSide.none,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        backgroundColor: when(c.primaryContainer, Colors.transparent),
        foregroundColor: when(c.onPrimaryContainer, c.onSurface),
        side: WidgetStatePropertyAll<BorderSide>(BorderSide(color: c.outline)),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: c.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: c.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: c.inverseSurface,
      contentTextStyle: t.bodyMedium?.copyWith(color: c.onInverseSurface),
      actionTextColor: c.inversePrimary,
      behavior: SnackBarBehavior.floating,
      shape: shape10,
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: c.inverseSurface,
        borderRadius: BorderRadius.circular(6),
      ),
      textStyle: t.bodySmall?.copyWith(color: c.onInverseSurface),
    ),
    badgeTheme: BadgeThemeData(backgroundColor: c.error, textColor: c.onError),
    dividerTheme: DividerThemeData(color: c.outlineVariant, space: 1),
    listTileTheme: ListTileThemeData(
      iconColor: c.onSurfaceVariant,
      textColor: c.onSurface,
      selectedColor: c.onSurface,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: c.surfaceContainer,
      border: OutlineInputBorder(
        borderRadius: r10,
        borderSide: BorderSide(color: c.outlineVariant),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: r10,
        borderSide: BorderSide(color: c.outlineVariant),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: r10,
        borderSide: BorderSide(color: c.primary, width: 2),
      ),
    ),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: c.primary,
      selectionColor: c.primary.withValues(alpha: 0.3),
      selectionHandleColor: c.primary,
    ),
  );
}

/// [c] with [accent] as its primary colour, for a part of the screen drawn in
/// one colour (a signal-chain block). Containers are [accent] mixed into the
/// surface, so they stay readable in both modes.
ColorScheme accented(ColorScheme c, Color accent) {
  final bool dark = c.brightness == Brightness.dark;
  final Color primary = dark ? Color.lerp(accent, Colors.white, 0.2)! : accent;
  return c.copyWith(
    primary: primary,
    onPrimary: dark ? const Color(0xFF111111) : Colors.white,
    primaryContainer: Color.lerp(c.surface, accent, dark ? 0.28 : 0.14),
    onPrimaryContainer: dark
        ? Color.lerp(accent, Colors.white, 0.7)
        : Color.lerp(accent, Colors.black, 0.5),
  );
}
