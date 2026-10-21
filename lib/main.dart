import 'package:flutter/material.dart';
import 'helper/image_helper.dart';
import 'home/home_screen.dart';
import 'helper/notification_service.dart';
import 'helper/background_tasks.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  try {
    await BackgroundTasks.init();
    await NotificationService.checkAndNotify();
  } catch (e) {
    debugPrint('Notification setup failed: $e');
  }

  runApp(const AlertLifecycleWatcher(child: PriceScannerApp()));
}

class PriceScannerApp extends StatelessWidget {
  const PriceScannerApp({super.key});

  @override
  Widget build(BuildContext context) {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF1B8A5A),
    );

    return MaterialApp(
      title: 'สแกนเช็คราคา',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: colorScheme,
        useMaterial3: true,
        appBarTheme: AppBarTheme(
          centerTitle: true,
          elevation: 0,
          backgroundColor: colorScheme.primary,
          foregroundColor: colorScheme.onPrimary,
        ),
      ),
      home: const HomeScreen(),
    );
  }
}
