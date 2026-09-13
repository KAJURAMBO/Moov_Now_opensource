import 'package:flutter_foreground_task/flutter_foreground_task.dart';

/// Holds a foreground service so the app keeps running with the screen off.
///
/// Android freezes a backgrounded app. When that happens the BLE scan stops
/// and the GATT link drops, so the only way back is another button press —
/// the Moov advertises for just a few seconds and then sleeps. A foreground
/// service is the only supported way to keep a BLE connection alive in the
/// background.
///
/// The trade-off is a persistent notification, which Android requires. There
/// is no way around that for background BLE.
///
/// No Dart task runs inside the service: it exists purely to keep the process
/// alive, and the BLE work stays on the main isolate.
class MoovForeground {
  static const int _serviceId = 301;
  static bool _initialised = false;

  /// Diagnostics, surfaced in the UI. A service that silently failed to start
  /// looks exactly like one that is running, until the phone is locked.
  static bool running = false;
  static String lastError = '';
  static bool batteryExempt = false;

  static void _init() {
    if (_initialised) return;
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'moov_tracking',
        channelName: 'Moov Now tracking',
        channelDescription:
            'Keeps the connection to your Moov Now alive while the screen is off.',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
        enableVibration: false,
        playSound: false,
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(),
      foregroundTaskOptions: ForegroundTaskOptions(
        // Nothing to run in the service isolate - it only holds the process up.
        eventAction: ForegroundTaskEventAction.nothing(),
        allowWakeLock: true,
      ),
    );
    _initialised = true;
  }

  /// Requests the notification permission Android 13+ requires before a
  /// foreground service can show its (mandatory) notification.
  static Future<void> requestPermission() async {
    _init();
    final permission = await FlutterForegroundTask.checkNotificationPermission();
    if (permission != NotificationPermission.granted) {
      await FlutterForegroundTask.requestNotificationPermission();
    }
  }

  /// Starts the service, or updates its text if it is already running.
  static Future<void> start({required String text}) async {
    _init();
    try {
      if (await FlutterForegroundTask.isRunningService) {
        await FlutterForegroundTask.updateService(
          notificationTitle: 'Moov Now',
          notificationText: text,
        );
        return;
      }
      await FlutterForegroundTask.startService(
        serviceId: _serviceId,
        notificationTitle: 'Moov Now',
        notificationText: text,
      );
      lastError = '';
    } catch (e) {
      // Recorded rather than swallowed: if the service did not start, tracking
      // stops the moment the screen locks, and the reason matters.
      lastError = e.toString();
    }
    running = await isRunning();
  }

  static Future<void> stop() async {
    try {
      if (await FlutterForegroundTask.isRunningService) {
        await FlutterForegroundTask.stopService();
      }
    } catch (_) {}
    running = false;
  }

  static Future<bool> isRunning() async {
    try {
      return await FlutterForegroundTask.isRunningService;
    } catch (_) {
      return false;
    }
  }

  /// Asks the OS to stop managing this app's battery.
  ///
  /// Many manufacturers (Xiaomi, Oppo, Vivo, Samsung) kill foreground services
  /// anyway unless the app is exempt from battery optimisation. Android shows a
  /// system dialog; the user has to accept it.
  static Future<void> requestBatteryExemption() async {
    try {
      batteryExempt = await FlutterForegroundTask.isIgnoringBatteryOptimizations;
      if (!batteryExempt) {
        batteryExempt = await FlutterForegroundTask.requestIgnoreBatteryOptimization();
      }
    } catch (e) {
      lastError = 'battery: $e';
    }
  }
}
