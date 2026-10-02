import 'dart:async';
import 'dart:convert';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'alarm.dart';
import 'api.dart';
import 'config.dart';
import 'sse.dart';

/// Entry point for the foreground service isolate.
///
/// Must be a top-level function: Android restarts this isolate from scratch after the
/// system kills it, and it needs a symbol it can look up rather than a closure.
@pragma('vm:entry-point')
void startAlertService() {
  FlutterForegroundTask.setTaskHandler(AlertTaskHandler());
}

/// What the phone does while nobody is looking at it.
///
/// This is the whole reason the app exists. A browser on this network cannot be woken —
/// service workers need a secure context and web push needs a service on the internet,
/// and the property has neither by design. A foreground service has neither problem: it
/// holds a socket to the host on the office wifi and raises an alarm when work lands.
///
/// It is written to be honest about its own health, because the failure that matters is
/// not loud. Android manufacturers kill background services whatever permissions you
/// grant — Transsion handsets most of all, which is most of the phones on a Nigerian
/// property — and a phone that has quietly stopped listening looks exactly like one that
/// is listening. So the service reports its connection to the host continuously, and the
/// supervisor's screen shows a paired phone that has stopped holding its line. You cannot
/// stop Android doing this. You can make sure a human finds out before an outage does.
class AlertTaskHandler extends TaskHandler {
  SseClient? _sse;
  Alarm? _alarm;
  Config? _config;
  Api? _api;
  final _notifications = FlutterLocalNotificationsPlugin();

  List<WaitingJob> _waiting = const [];
  bool _connected = false;
  bool _unpaired = false;
  DateTime _lastCheck = DateTime.fromMillisecondsSinceEpoch(0);

  static const _channelId = 'ff_jobs';

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    _config = await Config.load();
    final config = _config;
    if (config == null) {
      await FlutterForegroundTask.updateService(
        notificationTitle: 'Not set up',
        notificationText: 'Open FacilityFlow Alerts and scan a pairing code.',
      );
      return;
    }

    _api = Api(config.baseUrl, config.token);
    _alarm = Alarm();

    await _notifications.initialize(
      const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      ),
      onDidReceiveNotificationResponse: _onNotificationAction,
      onDidReceiveBackgroundNotificationResponse: notificationActionBackground,
    );
    await _notifications
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(const AndroidNotificationChannel(
          _channelId,
          'Job alerts',
          description: 'A job has been assigned to you',
          importance: Importance.max,
          playSound: false, // the alarm stream handles the noise, not the channel
          enableVibration: false,
        ));

    _sse = SseClient(
      url: config.baseUrl,
      token: config.token,
      onEvent: (_) => unawaited(_refresh()),
      onState: (up) {
        _connected = up;
        unawaited(_updateOngoing());
      },
    )..start();

    await _refresh();
  }

  /// Called on the service's own timer. A floor under the live stream, not a replacement
  /// for it: if the socket died in a way nothing noticed, this still catches the job
  /// within a minute rather than never.
  @override
  Future<void> onRepeatEvent(DateTime timestamp) async {
    if (DateTime.now().difference(_lastCheck) > const Duration(seconds: 50)) {
      await _refresh();
    }
    await _updateOngoing();
  }

  Future<void> _refresh() async {
    final api = _api;
    if (api == null) return;
    _lastCheck = DateTime.now();
    try {
      final jobs = await api.outstanding();
      _unpaired = false;
      await _apply(jobs);
    } on Unpaired {
      // The host no longer knows this phone. Stop making noise and say so plainly — this
      // is somebody's phone having been unpaired, or their account disabled, and ringing
      // about work they can no longer accept helps nobody.
      _unpaired = true;
      await _alarm?.stop();
      await _updateOngoing();
    } catch (_) {
      // A network blip. The stream will reconnect and this will run again; the alarm is
      // deliberately left alone, because a job that was waiting a second ago is still
      // waiting now.
    }
  }

  Future<void> _apply(List<WaitingJob> jobs) async {
    final live = jobs.where((j) => !j.pastDeadline).toList();
    final before = _waiting.map((j) => j.id).toSet();
    _waiting = jobs;

    if (live.isEmpty) {
      await _alarm?.stop();
      await _notifications.cancelAll();
    } else {
      await _alarm?.start(urgent: live.any((j) => j.isEmergency));
      for (final j in live) {
        // Re-post an existing one only when it is new, so the heads-up banner does not
        // re-slam over whatever the person is doing every fifteen seconds.
        if (before.contains(j.id)) continue;
        await _show(j);
      }
    }
    await _updateOngoing();
  }

  Future<void> _show(WaitingJob job) async {
    await _notifications.show(
      job.id.hashCode & 0x7fffffff,
      '${job.priority} · ${job.title}',
      'Assigned to you — ${job.ref}',
      NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          'Job alerts',
          importance: Importance.max,
          priority: Priority.max,
          category: AndroidNotificationCategory.alarm,
          // Wakes the screen on the lock screen rather than waiting to be pulled down.
          fullScreenIntent: job.isEmergency,
          ongoing: true,
          autoCancel: false,
          playSound: false,
          enableVibration: false,
          actions: const [
            AndroidNotificationAction('accept', 'Accept',
                showsUserInterface: false, cancelNotification: false),
          ],
        ),
      ),
      payload: jsonEncode({'action': 'accept', 'jobId': job.id}),
    );
  }

  Future<void> _updateOngoing() async {
    final config = _config;
    final String title;
    final String text;

    if (_unpaired) {
      title = 'This phone has been unpaired';
      text = 'Pair it again from the website to get job alerts.';
    } else if (_waiting.isNotEmpty) {
      final n = _waiting.length;
      title = n == 1 ? 'A job is waiting for you' : '$n jobs are waiting for you';
      text = _waiting.first.title;
    } else if (_connected) {
      title = 'Listening for jobs';
      text = config == null
          ? 'Connected'
          : 'Connected to ${config.propertyName}';
    } else {
      // The state worth being blunt about: the app is running and cannot hear anything.
      title = 'Not connected';
      text = 'Check you are on the property wifi.';
    }

    await FlutterForegroundTask.updateService(
      notificationTitle: title,
      notificationText: text,
    );
  }

  void _onNotificationAction(NotificationResponse response) {
    unawaited(_handleAction(response));
  }

  Future<void> _handleAction(NotificationResponse response) async {
    if (response.actionId != 'accept' || response.payload == null) return;
    final payload = jsonDecode(response.payload!) as Map<String, dynamic>;
    final jobId = payload['jobId'] as String?;
    if (jobId == null) return;
    await _acceptAndRefresh(jobId);
  }

  Future<void> _acceptAndRefresh(String jobId) async {
    try {
      await _api?.accept(jobId);
    } catch (_) {
      // Somebody else took it, or it was withdrawn while the phone rang. The refresh
      // below settles it either way.
    }
    await _notifications.cancel(jobId.hashCode & 0x7fffffff);
    await _refresh();
  }

  @override
  Future<void> onDestroy(DateTime timestamp) async {
    _sse?.stop();
    await _alarm?.dispose();
  }

  @override
  void onReceiveData(Object data) {
    // The UI isolate asking for an immediate check — after pairing, or when the person
    // opens the app and wants to see the truth rather than the last cached answer.
    if (data == 'refresh') {
      unawaited(_refresh());
    } else if (data is String && data.startsWith('accept:')) {
      // The lock-screen Accept button, handed over from the notification's background
      // isolate. Accepting here as well as there is harmless; refreshing here is what
      // silences the alarm.
      unawaited(_acceptAndRefresh(data.substring('accept:'.length)));
    }
  }

  @override
  void onNotificationPressed() {
    FlutterForegroundTask.launchApp();
  }
}

/// Handles the Accept button when the app's UI isolate is not running at all — which is
/// the normal case, since the whole point is a phone in a pocket.
@pragma('vm:entry-point')
void notificationActionBackground(NotificationResponse response) {
  if (response.actionId != 'accept' || response.payload == null) return;
  final payload = jsonDecode(response.payload!) as Map<String, dynamic>;
  final jobId = payload['jobId'] as String?;
  if (jobId == null) return;
  // Hand it to the service isolate, which already holds the token and will refresh and
  // silence the alarm once the host confirms.
  try {
    FlutterForegroundTask.sendDataToTask('accept:$jobId');
  } catch (_) {
    // Service not reachable from here; the direct call below still accepts the job.
  }
  unawaited(_acceptDirect(jobId));
}

/// A direct call as well as the hand-off, because the service isolate may itself have
/// been killed. Accepting twice is harmless — the host's state machine refuses the
/// second — whereas accepting zero times leaves a phone screaming at somebody who has
/// already pressed the button.
Future<void> _acceptDirect(String jobId) async {
  final config = await Config.load();
  if (config == null) return;
  try {
    await Api(config.baseUrl, config.token).accept(jobId);
  } catch (_) {
    // Nothing useful to do from a background handler with no UI.
  }
}
