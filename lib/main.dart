import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'device.dart';
import 'home.dart';
import 'monitor.dart';
import 'setup.dart';
import 'strings.dart';

final incubator = Incubator();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterForegroundTask.initCommunicationPort();
  final prefs = await SharedPreferences.getInstance();
  lang.value = prefs.getString('lang') ?? (Platform.localeName.startsWith('ar') ? 'ar' : 'en');
  lang.addListener(() => prefs.setString('lang', lang.value));
  await incubator.load();
  await initNotifications();
  initMonitorService();
  runApp(const IncubatorApp());

  // Background alarms run whenever this phone is paired and has them switched on.
  var wasPaired = incubator.paired;
  WidgetsBinding.instance.addPostFrameCallback((_) => syncMonitorService(askPermissions: true));
  incubator.addListener(() {
    if (incubator.paired != wasPaired) {
      wasPaired = incubator.paired;
      syncMonitorService(askPermissions: true);
    }
  });
}

const seed = Color(0xFFE8833A);

class IncubatorApp extends StatelessWidget {
  const IncubatorApp({super.key});

  ThemeData _theme(Brightness b) {
    final scheme = ColorScheme.fromSeed(seedColor: seed, brightness: b);
    return ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      cardTheme: const CardThemeData(elevation: 0, margin: EdgeInsets.zero),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: lang,
      builder: (context, code, _) => MaterialApp(
        title: tr('app'),
        debugShowCheckedModeBanner: false,
        theme: _theme(Brightness.light),
        darkTheme: _theme(Brightness.dark),
        locale: Locale(code),
        supportedLocales: const [Locale('ar'), Locale('en')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: ListenableBuilder(
          listenable: incubator,
          builder: (context, _) => incubator.paired ? const HomeScreen() : const SetupScreen(),
        ),
      ),
    );
  }
}
