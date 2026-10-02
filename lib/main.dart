import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'src/config.dart';
import 'src/home_screen.dart';
import 'src/pair_screen.dart';
import 'src/service.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Required before any call into the plugin from the UI isolate.
  FlutterForegroundTask.initCommunicationPort();
  runApp(const AlertsApp());
}

class AlertsApp extends StatefulWidget {
  const AlertsApp({super.key});

  @override
  State<AlertsApp> createState() => _AlertsAppState();
}

class _AlertsAppState extends State<AlertsApp> {
  Config? _config;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    final config = await Config.load();
    if (config != null) {
      await _requestPermissions();
      await _startService();
    }
    if (mounted) setState(() { _config = config; _loading = false; });
  }

  /// Asked for up front, and all at once, because every one of them is load-bearing.
  ///
  /// Without notifications the service cannot run in the foreground at all. Without
  /// battery-optimisation relief the handset stops it within hours — and on the phones
  /// most common on a Nigerian property, even that is not always enough, which is why the
  /// host tracks whether this phone is still holding its connection and tells a
  /// supervisor when it is not.
  Future<void> _requestPermissions() async {
    final notifications = await FlutterForegroundTask.checkNotificationPermission();
    if (notifications != NotificationPermission.granted) {
      await FlutterForegroundTask.requestNotificationPermission();
    }
    if (!await FlutterForegroundTask.isIgnoringBatteryOptimizations) {
      await FlutterForegroundTask.requestIgnoreBatteryOptimization();
    }
  }

  Future<void> _startService() async {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'ff_service',
        channelName: 'FacilityFlow Alerts',
        channelDescription: 'Keeps this phone listening for jobs assigned to you.',
        // The ongoing notification is not decoration: it is the thing that entitles the
        // service to keep running, and the honest indicator of whether it still is.
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
      ),
      iosNotificationOptions: const IOSNotificationOptions(),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(30000),
        autoRunOnBoot: true,
        autoRunOnMyPackageReplaced: true,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );

    if (await FlutterForegroundTask.isRunningService) {
      FlutterForegroundTask.sendDataToTask('refresh');
      return;
    }
    await FlutterForegroundTask.startService(
      serviceId: 4700,
      notificationTitle: 'Starting…',
      notificationText: 'Connecting to the host',
      callback: startAlertService,
    );
  }

  Future<void> _unpair() async {
    await FlutterForegroundTask.stopService();
    await Config.clear();
    if (mounted) setState(() => _config = null);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'FacilityFlow Alerts',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF2563C9)),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF2563C9), brightness: Brightness.dark),
      ),
      home: _loading
          ? const Scaffold(body: Center(child: CircularProgressIndicator()))
          : _config == null
              ? PairScreen(onPaired: (config) async {
                  setState(() => _config = config);
                  await _requestPermissions();
                  await _startService();
                })
              : HomeScreen(config: _config!, onUnpair: _unpair),
    );
  }
}
