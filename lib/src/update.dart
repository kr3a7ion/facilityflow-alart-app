import 'dart:async';
import 'dart:convert';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import 'version.dart';

/// The build number out of "1.0.0+57"; null for a build made by hand ("dev"), which is
/// never told to update — it is somebody's test phone, not the department's.
int? buildNumberOf(String version) {
  final plus = version.lastIndexOf('+');
  return plus < 0 ? null : int.tryParse(version.substring(plus + 1));
}

/// This phone's own build.
final int? myBuild = buildNumberOf(buildVersion);

/// The alert app the host hands out at /app.apk.
class HostApp {
  const HostApp({required this.version, required this.build});

  final String? version;

  /// Null when the host has the file but could not read it; never offered then.
  final int? build;

  /// From /api/health's `app`. Null for a host with no installer, or one from before it
  /// said which build it had.
  static HostApp? fromHealth(Map<String, dynamic> health) {
    final app = health['app'];
    if (app is! Map<String, dynamic>) return null;
    return HostApp(version: app['version'] as String?, build: (app['build'] as num?)?.toInt());
  }

  String get words => [
        if (version != null) 'version $version',
        if (build != null) 'build $build',
      ].join(', ');
}

/// Whether the host has a newer build than [mine].
bool isNewer(HostApp? host, int? mine) =>
    host?.build != null && mine != null && host!.build! > mine;

/// What the host is handing out. Asked without the phone's token: /api/health is open,
/// and a phone's token opens only what the app needs to ring.
Future<HostApp?> fetchHostApp(String baseUrl) async {
  final r = await http.get(Uri.parse('$baseUrl/api/health')).timeout(const Duration(seconds: 15));
  if (r.statusCode != 200) return null;
  return HostApp.fromHealth(jsonDecode(r.body) as Map<String, dynamic>);
}

/// Open the installer in the phone's browser: the same way the app was installed the first
/// time, so the phone already allows it.
Future<bool> openInstaller(String baseUrl) => launchUrl(
      Uri.parse('$baseUrl/app.apk'),
      mode: LaunchMode.externalApplication,
    ).catchError((_) => false);

/// From the service: tells the person once per new build, so a phone nobody opens still
/// hears that it is behind. Asks the host every few hours, not every tick.
class UpdateWatch {
  UpdateWatch(this._baseUrl, this._notifications);

  final String _baseUrl;
  final FlutterLocalNotificationsPlugin _notifications;
  DateTime? _checkedAt;

  static const every = Duration(hours: 6);
  static const _notifiedKey = 'ff.updateNotified';
  static const _channelId = 'ff_update';

  /// Clear of the service's own notification (4700) and the hashed ids, which are large.
  static const _notificationId = 4702;

  Future<void> check() async {
    final now = DateTime.now();
    if (_checkedAt != null && now.difference(_checkedAt!) < every) return;
    _checkedAt = now;
    try {
      final host = await fetchHostApp(_baseUrl);
      if (!isNewer(host, myBuild)) return;
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getInt(_notifiedKey) == host!.build) return;

      await _notifications
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
          ?.createNotificationChannel(const AndroidNotificationChannel(
            _channelId, 'App updates',
            description: 'A newer FacilityFlow Alerts is on the host',
            importance: Importance.defaultImportance,
          ));
      await _notifications.show(
        _notificationId,
        'Update FacilityFlow Alerts',
        'The host has a newer one (${host.words}). Open the app to install it.',
        const NotificationDetails(
          android: AndroidNotificationDetails(_channelId, 'App updates',
              importance: Importance.defaultImportance, autoCancel: true),
        ),
      );
      await prefs.setInt(_notifiedKey, host.build!);
    } catch (_) {
      // Unreachable, or a host that is not answering properly: asked again in a few hours.
    }
  }
}
