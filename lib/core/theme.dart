import 'package:flutter/material.dart';

class AppColors {
  static const bg = Color(0xFFEAEFF2);
  static const surface = Color(0xFFFFFFFF);
  static const ink = Color(0xFF12202B);
  static const mute = Color(0xFF6B7C89);
  static const line = Color(0xFFD8E0E5);

  static const laptop = Color(0xFF3D4FE0);
  static const laptopSoft = Color(0xFFE6E9FC);
  static const phone = Color(0xFF0F9D77);
  static const phoneSoft = Color(0xFFDCF2EA);

  static const danger = Color(0xFFD14343);
}

ThemeData buildTheme() {
  return ThemeData(
    useMaterial3: true,
    scaffoldBackgroundColor: AppColors.bg,
    colorScheme: ColorScheme.fromSeed(
      seedColor: AppColors.phone,
      brightness: Brightness.light,
    ),
    fontFamily: 'Roboto', // You can later add Instrument Sans if you want
    appBarTheme: const AppBarTheme(
      backgroundColor: AppColors.bg,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        color: AppColors.ink,
        fontSize: 26,
        fontWeight: FontWeight.bold,
      ),
    ),
  );
}