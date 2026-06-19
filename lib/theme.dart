import 'package:flutter/material.dart';

// Warm, soft palette for a calm bedtime feel. Material 3 derives the rest of
// the palette from the single seed — change `warmSeed` to retint the whole app.
const warmSeed = Color(0xFFE6896B); // terracotta / peach
const warmCream = Color(0xFFFFF6EF); // page background
const warmBrown = Color(0xFF5B463E); // headings on cream

// Soft top-to-bottom backdrop for the setup screens.
const warmBackdrop = LinearGradient(
  begin: Alignment.topCenter,
  end: Alignment.bottomCenter,
  colors: [Color(0xFFFFF1E6), Color(0xFFFCE3D6)],
);

final babyTheme = ThemeData(
  useMaterial3: true,
  colorScheme: ColorScheme.fromSeed(
    seedColor: warmSeed,
    brightness: Brightness.light,
  ).copyWith(surface: warmCream),
  scaffoldBackgroundColor: warmCream,
  cardTheme: CardThemeData(
    elevation: 0,
    color: Colors.white,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
  ),
  filledButtonTheme: FilledButtonThemeData(
    style: FilledButton.styleFrom(
      padding: const EdgeInsets.symmetric(vertical: 16),
      textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
    ),
  ),
);
