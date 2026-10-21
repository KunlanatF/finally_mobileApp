import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'db_helper.dart';

/// ส่ง notification ขึ้นเครื่องสำหรับแจ้งเตือนใหม่ในตาราง notifications
class NotificationService {
  static final _plugin = FlutterLocalNotificationsPlugin();
  static bool _ready = false;

  /// [requestPermission] ต้องเป็น false เมื่อเรียกจากงานเบื้องหลัง
  /// (ขอสิทธิ์ได้เฉพาะตอนแอปเปิดอยู่)
  static Future<void> init({bool requestPermission = true}) async {
    if (_ready) return;
    const settings = InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      iOS: DarwinInitializationSettings(),
    );
    await _plugin.initialize(settings);

    // Android 13+ ต้องขออนุญาตแสดง notification
    if (requestPermission) {
      await _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.requestNotificationsPermission();
    }
    _ready = true;
  }

  /// คำนวณแจ้งเตือนใหม่ แล้วส่งเฉพาะรายการที่ยังไม่เคยแจ้ง
  /// เรียกตอนเปิดแอป และตอนแอปกลับมาจาก background
  static Future<void> checkAndNotify({bool background = false}) async {
    await init(requestPermission: !background);
    await DBHelper.refreshAlerts();

    final pending = await DBHelper.getUnnotifiedAlerts();
    final sentIds = <int>[];

    for (final a in pending) {
      final critical = a['severity'] == 'critical';
      await _plugin.show(
        a['id'] as int,
        a['title'] as String,
        a['message'] as String,
        NotificationDetails(
          android: AndroidNotificationDetails(
            critical ? 'critical_alerts' : 'warning_alerts',
            critical ? 'แจ้งเตือนด่วน (หมดสต็อก/หมดอายุ)' : 'แจ้งเตือนล่วงหน้า',
            importance: critical
                ? Importance.high
                : Importance.defaultImportance,
            priority: critical ? Priority.high : Priority.defaultPriority,
          ),
          iOS: const DarwinNotificationDetails(),
        ),
      );
      sentIds.add(a['id'] as int);
    }

    // บันทึกว่าส่งแจ้งเตือนรายการเหล่านี้เรียบร้อยแล้ว จะได้ไม่ส่งซ้ำซ้อน
    await DBHelper.markAlertsNotified(sentIds);
  }
}
