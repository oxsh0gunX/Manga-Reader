import 'package:flutter/material.dart';

import 'home.dart';
import 'library.dart';

void main() {
  runApp(const PdfReaderApp());
}

class PdfReaderApp extends StatefulWidget {
  const PdfReaderApp({super.key});

  @override
  State<PdfReaderApp> createState() => _PdfReaderAppState();
}

class _PdfReaderAppState extends State<PdfReaderApp> {
  final Library _library = Library();

  @override
  void initState() {
    super.initState();
    _library.load();
  }

  ThemeMode get _mode {
    switch (_library.settings.theme) {
      case 'light':
        return ThemeMode.light;
      case 'dark':
        return ThemeMode.dark;
      default:
        return ThemeMode.system;
    }
  }

  ThemeData _theme(Brightness brightness) {
    final neutral = brightness == Brightness.dark
        ? const Color(0xFF121212)
        : const Color(0xFFFAFAF8);
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF374151),
      brightness: brightness,
    );
    return ThemeData(
      colorScheme: scheme,
      scaffoldBackgroundColor: neutral,
      useMaterial3: true,
      appBarTheme: AppBarTheme(
        backgroundColor: neutral,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
      ),
      cardTheme: CardTheme(color: scheme.surface),
      sliderTheme: const SliderThemeData(showValueIndicator: ShowValueIndicator.always),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _library,
      builder: (ctx, _) => MaterialApp(
        title: 'Manga Reader',
        debugShowCheckedModeBanner: false,
        theme: _theme(Brightness.light),
        darkTheme: _theme(Brightness.dark),
        themeMode: _mode,
        home: HomePage(
          library: _library,
          onThemeChanged: (_) => setState(() {}),
        ),
      ),
    );
  }
}
