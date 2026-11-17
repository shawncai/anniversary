import 'package:flutter/material.dart';

abstract final class ShiriTheme {
  static const fontFamily = 'SourceHanSansCN';
  static const albumInk = Color(0xFF3D474E);
  static const albumMuted = Color(0xFF6E7880);
  static const albumAccent = Color(0xFF526D7C);
  static const albumRule = Color(0xFFE7ECEF);
  static const ink = Color(0xFF141414);
  static const muted = Color(0xFF6B6B70);
  static const accent = Color(0xFF5146E5);
  static const rule = Color(0xFFE7E7EB);
  static ThemeData get light => ThemeData(
    useMaterial3: true,
    fontFamily: fontFamily,
    brightness: Brightness.light,
    scaffoldBackgroundColor: Colors.white,
    colorScheme: ColorScheme.fromSeed(
      seedColor: accent,
      primary: accent,
      surface: Colors.white,
    ),
    textTheme: const TextTheme(
      bodyLarge: TextStyle(fontSize: 17, height: 1.4, color: ink),
      bodyMedium: TextStyle(fontSize: 15, height: 1.4, color: ink),
      bodySmall: TextStyle(fontSize: 13, height: 1.35, color: muted),
      titleMedium: TextStyle(
        fontSize: 17,
        fontWeight: FontWeight.w600,
        color: ink,
      ),
      titleLarge: TextStyle(
        fontSize: 22,
        fontWeight: FontWeight.w600,
        color: ink,
      ),
    ),
    dividerTheme: const DividerThemeData(color: rule, thickness: .7, space: 1),
    appBarTheme: const AppBarTheme(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.transparent,
      foregroundColor: ink,
      elevation: 0,
      scrolledUnderElevation: 0,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: accent,
        foregroundColor: Colors.white,
        elevation: 0,
        minimumSize: const Size(48, 48),
        textStyle: const TextStyle(
          fontFamily: fontFamily,
          fontSize: 17,
          fontWeight: FontWeight.w500,
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: accent,
        minimumSize: const Size(48, 48),
        textStyle: const TextStyle(fontFamily: fontFamily, fontSize: 16),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(4)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
    ),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
  );

  static ThemeData get album {
    final base = light;
    return base.copyWith(
      colorScheme: base.colorScheme.copyWith(
        primary: albumAccent,
        onPrimary: Colors.white,
        onSurface: albumInk,
        onSurfaceVariant: albumMuted,
        outline: albumMuted,
        outlineVariant: albumRule,
      ),
      textTheme: base.textTheme
          .apply(bodyColor: albumInk, displayColor: albumInk)
          .copyWith(
            bodySmall: base.textTheme.bodySmall?.copyWith(color: albumMuted),
            titleLarge: base.textTheme.titleLarge?.copyWith(
              color: albumInk,
              fontWeight: FontWeight.w500,
            ),
          ),
      iconTheme: const IconThemeData(color: albumMuted),
      appBarTheme: base.appBarTheme.copyWith(foregroundColor: albumInk),
      dividerTheme: base.dividerTheme.copyWith(color: albumRule),
      textButtonTheme: TextButtonThemeData(
        style: base.textButtonTheme.style?.copyWith(
          foregroundColor: const WidgetStatePropertyAll(albumAccent),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: base.filledButtonTheme.style?.copyWith(
          backgroundColor: const WidgetStatePropertyAll(albumAccent),
        ),
      ),
    );
  }
}

class AlbumTheme extends StatelessWidget {
  const AlbumTheme({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) =>
      Theme(data: ShiriTheme.album, child: child);
}

String dateLabel(String iso) => iso.replaceAll('-', '.');
String groupedNumber(int value) => value.toString().replaceAllMapped(
  RegExp(r'(\d)(?=(\d{3})+(?!\d))'),
  (m) => '${m[1]},',
);
String byteLabel(int value) {
  if (value < 1024) return '$value B';
  if (value < 1024 * 1024) return '${(value / 1024).toStringAsFixed(1)} KB';
  if (value < 1024 * 1024 * 1024)
    return '${(value / 1024 / 1024).toStringAsFixed(1)} MB';
  return '${(value / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
}
