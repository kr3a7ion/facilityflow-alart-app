import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:phone_settings/phone_settings.dart';

import 'api.dart';
import 'version.dart';

/// Whether a ring on this phone would be heard, read off the phone's own settings.
///
/// Holding the connection open says the app is running. It does not say anybody will hear
/// it: the alarm volume can be at zero, the app's notifications blocked, and on Tecno,
/// Infinix and Itel the battery manager stops an app it has not been told to leave alone.
/// The host cannot see any of that, so the phone says — and shows the person holding it.
class Readiness {
  const Readiness({
    required this.notificationsOn,
    required this.fullScreenOn,
    required this.batteryExempt,
    required this.alarmVolume,
  });

  final bool notificationsOn;

  /// Null before Android 14, which always allows it.
  final bool? fullScreenOn;
  final bool batteryExempt;

  /// Percent of the alarm stream's maximum; null where the phone could not read it.
  final int? alarmVolume;

  /// From what the plugin read. Anything it could not read counts as fine rather than as a
  /// problem nobody can fix.
  static Readiness fromSettings(Map<String, Object?> m) => Readiness(
        notificationsOn: m['notificationsOn'] as bool? ?? true,
        fullScreenOn: m['fullScreenOn'] as bool?,
        batteryExempt: m['batteryExempt'] as bool? ?? true,
        alarmVolume: (m['alarmVolume'] as num?)?.toInt(),
      );

  Map<String, Object?> toJson() => {
        'appVersion': buildVersion,
        'notificationsOn': notificationsOn,
        'fullScreenOn': fullScreenOn,
        'batteryExempt': batteryExempt,
        'alarmVolume': alarmVolume,
      };

  /// What the host was last told, to compare against.
  String get key => jsonEncode(toJson());
}

/// Below this the alarm is easy to miss in a noisy plant room. The host uses the same line.
const lowVolume = 30;

/// What stands between this phone and somebody hearing it, worst first — the same rules
/// the host applies, so the phone and the supervisor's screen say the same thing.
List<String> problemsOf(Readiness r) => [
      if (r.alarmVolume == 0) 'volume_off',
      if (!r.batteryExempt) 'battery_saver',
      if (!r.notificationsOn) 'notifications_off',
      if (r.fullScreenOn == false) 'no_full_screen',
      if (r.alarmVolume != null && r.alarmVolume! > 0 && r.alarmVolume! < lowVolume) 'volume_low',
    ];

/// Each problem in the words of the person holding the phone, with where to fix it.
String problemWords(String problem, int? volume) => switch (problem) {
      'volume_off' => 'Alarm volume is off, so it will only vibrate. '
          'Turn up the alarm volume under Sound in the phone’s settings.',
      'battery_saver' => 'The battery saver may stop this app. '
          'Allow it to run in the background under Battery.',
      'notifications_off' => 'Notifications are blocked, so there is no Accept button. '
          'Allow notifications for FacilityFlow Alerts.',
      'no_full_screen' => 'It will not light up the screen when it rings. '
          'Allow full-screen notifications for FacilityFlow Alerts.',
      'volume_low' => 'Alarm volume is low (${volume ?? 0}%). Turn it up under Sound.',
      _ => problem,
    };

/// What the phone reads now. Null where there is nothing to read — not Android, or a
/// build without the plugin — rather than a guess.
Future<Readiness?> readReadiness() async {
  try {
    return Readiness.fromSettings(await readPhoneSettings());
  } catch (_) {
    return null;
  }
}

/// A host from before phones could say how they are set up.
class ReadinessUnsupported implements Exception {
  const ReadinessUnsupported();
}

Future<void> sendReadiness(Api api, Readiness r) async {
  final res = await http
      .post(Uri.parse('${api.baseUrl}/api/me/phone'),
          headers: {
            'Authorization': 'Bearer ${api.token}',
            'Content-Type': 'application/json',
          },
          body: jsonEncode(r.toJson()))
      .timeout(const Duration(seconds: 15));
  if (res.statusCode == 401) throw const Unpaired();
  // An older host either has no such route or refuses it to a phone.
  if (res.statusCode == 403 || res.statusCode == 404) throw const ReadinessUnsupported();
  if (res.statusCode != 200) throw http.ClientException('phone report failed: ${res.statusCode}');
}

/// Whether to tell the host: when something changed, and at least hourly so the
/// supervisor's screen knows the answer is current.
bool reportDue(Readiness r, {String? sentKey, DateTime? sentAt, required DateTime now}) =>
    sentKey != r.key || sentAt == null || now.difference(sentAt) >= const Duration(hours: 1);

/// Keeps the host told, from the service. Reading the settings is cheap, so it reads on
/// every tick of the service's timer and only sends when [reportDue].
class ReadinessReporter {
  ReadinessReporter(this._api);

  final Api _api;
  String? _sentKey;
  DateTime? _sentAt;
  bool _unsupported = false;
  bool _sending = false;

  Future<void> check() async {
    if (_unsupported || _sending) return;
    final r = await readReadiness();
    if (r == null || !reportDue(r, sentKey: _sentKey, sentAt: _sentAt, now: DateTime.now())) return;
    _sending = true;
    try {
      await sendReadiness(_api, r);
      _sentKey = r.key;
      _sentAt = DateTime.now();
    } on ReadinessUnsupported {
      _unsupported = true;
    } catch (_) {
      // Unpaired or unreachable: the service already says which. The next tick tries again.
    } finally {
      _sending = false;
    }
  }
}
