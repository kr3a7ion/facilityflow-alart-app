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

/// A notification id that is the same in every isolate and every run.
///
/// `String.hashCode` is not promised to be stable, and the id has to match between the
/// isolate that posts a notification and the one that cancels it.
int notificationId(String key) {
  var h = 0x811c9dc5;
  for (final unit in key.codeUnits) {
    h ^= unit;
    h = (h * 0x01000193) & 0x7fffffff;
  }
  // Keep clear of the foreground service's own notification id.
  return h == 4700 ? 4701 : h;
}

/// Everything this phone could be asked to ring about, fetched together.
class _Snapshot {
  const _Snapshot(this.jobs, this.rings, this.emergencies);
  final List<WaitingJob> jobs;
  final List<Ring> rings;
  final List<Emergency> emergencies;
}

/// What the phone does while nobody is looking at it.
///
/// This is the whole reason the app exists. A browser on this network cannot be woken —
/// service workers need a secure context and web push needs a service on the internet,
/// and the property has neither by design. A foreground service has neither problem: it
/// holds a socket to the host on the office wifi and raises an alarm when work lands.
///
/// Three things ring it, in this order of importance:
///
///  1. **An emergency alert** this person has not acknowledged — the building comes first.
///  2. **Somebody ringing this person** — a supervisor who needs them now.
///  3. **A job assigned to them** and not yet accepted.
///
/// The host sends a one-word nudge down the stream (`jobs`, `ring`, `emergency`) and this
/// asks for all three lists every time, so a nudge of any kind — or the reconnect after a
/// walk through the basement — settles every one of them.
///
/// It is written to be honest about its own health, because the failure that matters is
/// not loud. Android manufacturers kill background services whatever permissions you
/// grant — Transsion handsets most of all, which is most of the phones on a Nigerian
/// property — and a phone that has quietly stopped listening looks exactly like one that
/// is listening. So the service reports its connection to the host continuously, and the
/// supervisor's screen shows a paired phone that has stopped holding its line.
class AlertTaskHandler extends TaskHandler {
  SseClient? _sse;
  Alarm? _alarm;
  Config? _config;
  Api? _api;
  String? _userId;
  final _notifications = FlutterLocalNotificationsPlugin();

  _Snapshot _state = const _Snapshot([], [], []);
  bool _connected = false;
  bool _unpaired = false;
  DateTime _lastCheck = DateTime.fromMillisecondsSinceEpoch(0);

  /// Notification ids this service has posted and not yet withdrawn.
  final Set<int> _posted = {};
  bool _refreshing = false;
  bool _again = false;

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
    _userId = config.userId.isEmpty ? null : config.userId;
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
          description: 'A job, a ring or an emergency for you',
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
        // Whatever happened while the line was down was never delivered.
        if (up) unawaited(_refresh());
        unawaited(_updateOngoing());
      },
    )..start();

    await _refresh();
  }

  /// Called on the service's own timer. A floor under the live stream, not a replacement
  /// for it: if the socket died in a way nothing noticed, this still catches the job, the
  /// ring or the alert within a minute rather than never.
  @override
  Future<void> onRepeatEvent(DateTime timestamp) async {
    if (DateTime.now().difference(_lastCheck) > const Duration(seconds: 50)) {
      await _refresh();
    }
    await _updateOngoing();
  }

  /// Ask the host for everything at once.
  ///
  /// Nudges arrive in bursts — an emergency, then a dozen acknowledgements — so a refresh
  /// already in flight is followed by exactly one more rather than a queue of them.
  Future<void> _refresh() async {
    final api = _api;
    if (api == null) return;
    if (_refreshing) {
      _again = true;
      return;
    }
    _refreshing = true;
    try {
      do {
        _again = false;
        _lastCheck = DateTime.now();
        await _refreshOnce(api);
      } while (_again);
    } finally {
      _refreshing = false;
    }
  }

  Future<void> _refreshOnce(Api api) async {
    try {
      _userId ??= await api.myUserId();
      final userId = _userId!;
      // Each list on its own: a host that refuses one must not stop the others ringing.
      // A failure keeps the last known answer, because something that was waiting a
      // second ago is still waiting now.
      final results = await Future.wait<Object?>([
        api.outstanding().then<Object?>((v) => v, onError: _keepOrRethrow),
        api.rings().then<Object?>((v) => v, onError: _keepOrRethrow),
        api.emergencies(userId).then<Object?>((v) => v, onError: _keepOrRethrow),
      ]);
      _unpaired = false;
      await _apply(_Snapshot(
        results[0] is List<WaitingJob> ? results[0] as List<WaitingJob> : _state.jobs,
        results[1] is List<Ring> ? results[1] as List<Ring> : _state.rings,
        results[2] is List<Emergency> ? results[2] as List<Emergency> : _state.emergencies,
      ));
    } on Unpaired {
      // The host no longer knows this phone. Stop making noise and say so plainly — this
      // is somebody's phone having been unpaired, or their account disabled, and ringing
      // about work they can no longer accept helps nobody.
      _unpaired = true;
      await _alarm?.stop();
      await _withdrawAll();
      await _updateOngoing();
    } catch (_) {
      // A network blip. The stream will reconnect and this will run again; the alarm is
      // deliberately left alone.
    }
  }

  /// Unpaired must still stop everything; any other failure becomes "no new answer".
  Object? _keepOrRethrow(Object error) {
    if (error is Unpaired) throw error;
    return null;
  }

  Future<void> _apply(_Snapshot next) async {
    _state = next;

    final emergencies = next.emergencies.where((e) => !e.acknowledgedByMe).toList();
    final rings = next.rings;
    final jobs = next.jobs.where((j) => !j.pastDeadline).toList();

    // ---- the noise: one alarm, at the most urgent level anything calls for ----
    if (emergencies.isNotEmpty || rings.isNotEmpty) {
      await _alarm?.start(urgent: true);
    } else if (jobs.isNotEmpty) {
      await _alarm?.start(urgent: jobs.any((j) => j.isEmergency));
    } else {
      await _alarm?.stop();
    }

    // ---- the notifications: post what is new, withdraw what has gone ----------
    // Re-posting one that is already up would re-slam the heads-up banner over whatever
    // the person is doing every time a nudge arrives, so only new ones are shown.
    final wanted = <int>{};
    Future<void> want(String key, Future<void> Function() show) async {
      final nid = notificationId(key);
      wanted.add(nid);
      if (!_posted.contains(nid)) await show();
    }

    for (final e in emergencies) {
      await want('em:${e.id}', () => _showEmergency(e));
    }
    for (final r in rings) {
      await want('ring:${r.id}', () => _showRing(r));
    }
    for (final j in jobs) {
      await want('job:${j.id}', () => _showJob(j));
    }

    for (final id in _posted.difference(wanted).toList()) {
      await _notifications.cancel(id);
      _posted.remove(id);
    }
    await _updateOngoing();
  }

  Future<void> _withdrawAll() async {
    for (final id in _posted.toList()) {
      await _notifications.cancel(id);
    }
    _posted.clear();
  }

  Future<void> _post(String key, String title, String body, String action,
      String actionLabel, String id, {required bool fullScreen}) async {
    final nid = notificationId(key);
    await _notifications.show(
      nid,
      title,
      body,
      NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          'Job alerts',
          importance: Importance.max,
          priority: Priority.max,
          category: AndroidNotificationCategory.alarm,
          // Wakes the screen on the lock screen rather than waiting to be pulled down.
          fullScreenIntent: fullScreen,
          ongoing: true,
          autoCancel: false,
          playSound: false,
          enableVibration: false,
          actions: [
            AndroidNotificationAction(action, actionLabel,
                showsUserInterface: false, cancelNotification: false),
          ],
        ),
      ),
      payload: jsonEncode({'action': action, 'id': id, 'key': key}),
    );
    _posted.add(nid);
  }

  Future<void> _showJob(WaitingJob job) => _post(
        'job:${job.id}',
        '${job.priority} · ${job.title}',
        'Assigned to you — ${job.ref}',
        'accept',
        'Accept',
        job.id,
        fullScreen: job.isEmergency,
      );

  Future<void> _showRing(Ring ring) => _post(
        'ring:${ring.id}',
        '${ring.byName} is ringing you',
        ring.reason == null || ring.reason!.isEmpty
            ? 'They need you now.'
            : '“${ring.reason}”',
        'ring_ack',
        'I am here',
        ring.id,
        fullScreen: true,
      );

  Future<void> _showEmergency(Emergency e) => _post(
        'em:${e.id}',
        '${e.categoryWord.toUpperCase()} — ${e.message}',
        [
          if (e.raisedBy.isNotEmpty) 'Raised by ${e.raisedBy}',
          if (e.location != null && e.location!.isNotEmpty) e.location!,
        ].join(' · '),
        'emergency_ack',
        'I have seen this',
        e.id,
        fullScreen: true,
      );

  Future<void> _updateOngoing() async {
    final config = _config;
    final String title;
    final String text;
    final emergencies = _state.emergencies.where((e) => !e.acknowledgedByMe).toList();

    if (_unpaired) {
      title = 'This phone has been unpaired';
      text = 'Pair it again from the website to get job alerts.';
    } else if (emergencies.isNotEmpty) {
      title = '${emergencies.first.categoryWord} alert';
      text = emergencies.first.message;
    } else if (_state.rings.isNotEmpty) {
      title = '${_state.rings.first.byName} is ringing you';
      text = 'Open the notification and press "I am here".';
    } else if (_state.jobs.isNotEmpty) {
      final n = _state.jobs.length;
      title = n == 1 ? 'A job is waiting for you' : '$n jobs are waiting for you';
      text = _state.jobs.first.title;
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
    final action = parseAction(response);
    if (action != null) unawaited(_act(action.$1, action.$2));
  }

  /// Do what a notification button asked, then let the host's answer silence the alarm.
  Future<void> _act(String action, String id) async {
    final api = _api;
    if (api == null) return;
    try {
      await performAction(api, action, id);
    } catch (_) {
      // Somebody else took the job, the ring was already answered, the alert was stood
      // down. The refresh below settles it whichever it was.
    }
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
    } else if (data is String && data.contains(':')) {
      // A notification button, handed over from the background isolate, or a button on
      // the home screen. Acting here as well as there is harmless; refreshing here is
      // what silences the alarm.
      final i = data.indexOf(':');
      unawaited(_act(data.substring(0, i), data.substring(i + 1)));
    }
  }

  @override
  void onNotificationPressed() {
    FlutterForegroundTask.launchApp();
  }
}

/// (action, id) from a notification button, or null for a tap on the body.
(String, String)? parseAction(NotificationResponse response) {
  final action = response.actionId;
  if (action == null || response.payload == null) return null;
  try {
    final payload = jsonDecode(response.payload!) as Map<String, dynamic>;
    // `jobId` is what notifications posted by the previous version carried.
    final id = (payload['id'] ?? payload['jobId']) as String?;
    if (id == null) return null;
    return (action, id);
  } catch (_) {
    return null;
  }
}

/// The one place that knows which endpoint each button calls.
Future<void> performAction(Api api, String action, String id) {
  switch (action) {
    case 'accept':
      return api.accept(id);
    case 'ring_ack':
      return api.answerRing(id);
    case 'emergency_ack':
      return api.acknowledgeEmergency(id);
    default:
      return Future.value();
  }
}

/// Handles a notification button when the app's UI isolate is not running at all —
/// which is the normal case, since the whole point is a phone in a pocket.
@pragma('vm:entry-point')
void notificationActionBackground(NotificationResponse response) {
  final action = parseAction(response);
  if (action == null) return;
  // Hand it to the service isolate, which already holds the token and will refresh and
  // silence the alarm once the host confirms.
  try {
    FlutterForegroundTask.sendDataToTask('${action.$1}:${action.$2}');
  } catch (_) {
    // Service not reachable from here; the direct call below still does it.
  }
  unawaited(_actDirect(action.$1, action.$2));
}

/// A direct call as well as the hand-off, because the service isolate may itself have
/// been killed. Doing it twice is harmless — the host ignores a second accept or
/// acknowledgement — whereas doing it zero times leaves a phone screaming at somebody who
/// has already pressed the button.
Future<void> _actDirect(String action, String id) async {
  final config = await Config.load();
  if (config == null) return;
  try {
    await performAction(Api(config.baseUrl, config.token), action, id);
  } catch (_) {
    // Nothing useful to do from a background handler with no UI.
  }
}
