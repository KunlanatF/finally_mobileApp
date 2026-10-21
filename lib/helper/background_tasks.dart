import 'dart:io' show Platform;
import 'dart:ui' show DartPluginRegistrant;
import 'package:flutter/widgets.dart';
import 'package:workmanager/workmanager.dart';
import 'notification_service.dart';

const String kAlertTask = 'checkAlertsTask';
const String kAlertTaskId = 'daily-alert-check';

/// ฟังก์ชันที่ระบบเรียกตอนรันงานเบื้องหลัง (แยก isolate จากแอป)
/// ต้องเป็น top-level และมี pragma นี้ ไม่งั้นโดนตัดตอน release build
@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    try {
      DartPluginRegistrant.ensureInitialized();
      await NotificationService.checkAndNotify(background: true);
      return true;
    } catch (_) {
      return false; // ให้ระบบลองใหม่ภายหลัง
    }
  });
}

class BackgroundTasks {
  /// เวลาที่อยากให้เช็คทุกวัน (ชั่วโมง 0-23) — Android อาจเลื่อนได้เล็กน้อย
  static const int dailyHour = 8;

  /// เรียกครั้งเดียวใน main() — ลงทะเบียนงานเช็คแจ้งเตือนวันละครั้ง
  static Future<void> init() async {
    if (!Platform.isAndroid) return; // iOS จำกัดงานเบื้องหลังมาก ไม่รองรับ

    await Workmanager().initialize(callbackDispatcher);
    await Workmanager().registerPeriodicTask(
      kAlertTaskId,
      kAlertTask,
      frequency: const Duration(hours: 24),
      initialDelay: _untilNext(dailyHour),
    );
  }

  static Duration _untilNext(int hour) {
    final now = DateTime.now();
    var t = DateTime(now.year, now.month, now.day, hour);
    if (!t.isAfter(now)) t = t.add(const Duration(days: 1));
    return t.difference(now);
  }
}

/// ครอบแอปไว้เพื่อเช็คแจ้งเตือนทุกครั้งที่กลับมาจาก background
/// ใช้: runApp(AlertLifecycleWatcher(child: MyApp()));
class AlertLifecycleWatcher extends StatefulWidget {
  final Widget child;
  const AlertLifecycleWatcher({super.key, required this.child});

  @override
  State<AlertLifecycleWatcher> createState() => _AlertLifecycleWatcherState();
}

class _AlertLifecycleWatcherState extends State<AlertLifecycleWatcher>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      NotificationService.checkAndNotify();
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
