import 'dart:async';
import 'dart:convert';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'service.dart' show notificationId;

/// One entry from the person's bell on the website: an escalation, mains failure, a job
/// taken away or sent back, a sign-off.
class HostNotice {
  const HostNotice({
    required this.id,
    required this.kind,
    required this.title,
    required this.body,
    required this.level,
    required this.createdAt,
  });

  final String id;
  final String kind;
  final String title;
  final String? body;

  /// How loud the host says it is: quiet, chime, good or urgent. Null on rows from before
  /// the host had levels.
  final String? level;
  final String createdAt;

  static HostNotice fromJson(Map<String, dynamic> j) => HostNotice(
        id: j['id'] as String,
        kind: j['kind'] as String? ?? '',
        title: j['title'] as String? ?? '',
        body: j['body'] as String?,
        level: j['level'] as String?,
        createdAt: j['created_at'] as String? ?? '',
      );
}

/// A host from before phones could read notices refuses with this; the app then stops
/// asking until it next starts.
class NoticesUnsupported implements Exception {
  const NoticesUnsupported();
}

/// The person's notices, newest first.
Future<List<HostNotice>> fetchNotices(Api api) async {
  final r = await http
      .get(Uri.parse('${api.baseUrl}/api/notifications'),
          headers: {'Authorization': 'Bearer ${api.token}'})
      .timeout(const Duration(seconds: 15));
  if (r.statusCode == 401) throw const Unpaired();
  if (r.statusCode == 403) throw const NoticesUnsupported();
  if (r.statusCode != 200) throw http.ClientException('notifications failed: ${r.statusCode}');
  final body = jsonDecode(r.body) as Map<String, dynamic>;
  return (body['notifications'] as List<dynamic>? ?? const [])
      .map((e) => HostNotice.fromJson(e as Map<String, dynamic>))
      .toList();
}

/// Kinds the phone already rings for in its own way. "Assigned to you" is the job alarm,
/// with its Accept button; a second banner saying the same would only be noise.
const skippedKinds = {'wo.assigned'};

/// How far through the person's notices this phone has got: the newest time it has shown
/// and the ids at exactly that time, so two notices in the same millisecond are not lost.
class Seen {
  const Seen(this.at, this.ids);

  final String at;
  final Set<String> ids;

  static const storageKey = 'ff.noticesSeen';

  String encode() => jsonEncode({'at': at, 'ids': ids.toList()});

  static Seen? decode(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      return Seen(j['at'] as String, (j['ids'] as List<dynamic>).cast<String>().toSet());
    } catch (_) {
      return null;
    }
  }

  /// Where a phone that has never looked starts: after the newest, so pairing a phone
  /// does not replay weeks of the bell onto its lock screen.
  static Seen startingAfter(List<HostNotice> all) {
    if (all.isEmpty) return const Seen('', {});
    final newest = all.map((n) => n.createdAt).reduce((a, b) => a.compareTo(b) >= 0 ? a : b);
    return Seen(newest, all.where((n) => n.createdAt == newest).map((n) => n.id).toSet());
  }
}

/// What to show: newer than [seen], not a kind the phone rings for already. Oldest first,
/// so they stack on the lock screen in the order they happened.
List<HostNotice> newSince(List<HostNotice> all, Seen seen) {
  final fresh = all
      .where((n) =>
          n.createdAt.compareTo(seen.at) > 0 ||
          (n.createdAt == seen.at && !seen.ids.contains(n.id)))
      .toList()
    ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
  return fresh;
}

/// [seen] moved past everything in [all] that has now been handled.
Seen advance(Seen seen, List<HostNotice> handled) {
  var at = seen.at;
  var ids = {...seen.ids};
  for (final n in handled) {
    final c = n.createdAt.compareTo(at);
    if (c > 0) {
      at = n.createdAt;
      ids = {n.id};
    } else if (c == 0) {
      ids.add(n.id);
    }
  }
  return Seen(at, ids);
}

/// The channel a notice goes on, by how loud the host says it is. Android fixes a
/// channel's sound when it is created, so each loudness is its own channel.
String channelFor(String? level) => switch (level) {
      'urgent' => 'ff_notice_urgent',
      'quiet' => 'ff_notice_quiet',
      _ => 'ff_notice',
    };

/// Shows the person's notices on the phone as they arrive, by how loud the host says they
/// are. Driven by the stream's "notification" nudge and its reconnects, with its own slow
/// check underneath in case a nudge was missed.
///
/// It only reads: marking a notice read is the website's, where the bell is the record of
/// what the person has actually looked at.
class Notices {
  Notices(this._api, this._notifications);

  final Api _api;
  final FlutterLocalNotificationsPlugin _notifications;
  Timer? _floor;
  bool _unsupported = false;
  bool _checking = false;

  Future<void> start() async {
    final android = _notifications
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    await android?.createNotificationChannel(const AndroidNotificationChannel(
      'ff_notice_urgent', 'Urgent notices',
      description: 'Escalations and alarms from the host — loud, like the website',
      importance: Importance.max,
    ));
    await android?.createNotificationChannel(const AndroidNotificationChannel(
      'ff_notice', 'Notices',
      description: 'Jobs reassigned or sent back, sign-offs, plant changes',
      importance: Importance.high,
    ));
    await android?.createNotificationChannel(const AndroidNotificationChannel(
      'ff_notice_quiet', 'Quiet notices',
      description: 'Shown without a sound, as on the website',
      importance: Importance.low,
      playSound: false,
      enableVibration: false,
    ));
    _floor = Timer.periodic(const Duration(minutes: 2), (_) => unawaited(check()));
    await check();
  }

  void stop() => _floor?.cancel();

  /// Show whatever has arrived since the last look.
  Future<void> check() async {
    if (_unsupported || _checking) return;
    _checking = true;
    try {
      final all = await fetchNotices(_api);
      final prefs = await SharedPreferences.getInstance();
      final seen = Seen.decode(prefs.getString(Seen.storageKey));
      if (seen == null) {
        await prefs.setString(Seen.storageKey, Seen.startingAfter(all).encode());
        return;
      }
      final fresh = newSince(all, seen);
      for (final n in fresh.where((n) => !skippedKinds.contains(n.kind))) {
        await _show(n);
      }
      if (fresh.isNotEmpty) await prefs.setString(Seen.storageKey, advance(seen, fresh).encode());
    } on NoticesUnsupported {
      _unsupported = true;
      _floor?.cancel();
    } catch (_) {
      // Unpaired or unreachable: the service already says which. The next nudge or the
      // slow check tries again.
    } finally {
      _checking = false;
    }
  }

  Future<void> _show(HostNotice n) {
    final channel = channelFor(n.level);
    return _notifications.show(
      notificationId('notice:${n.id}'),
      n.title,
      n.body,
      NotificationDetails(
        android: AndroidNotificationDetails(
          channel,
          switch (channel) {
            'ff_notice_urgent' => 'Urgent notices',
            'ff_notice_quiet' => 'Quiet notices',
            _ => 'Notices',
          },
          importance: switch (channel) {
            'ff_notice_urgent' => Importance.max,
            'ff_notice_quiet' => Importance.low,
            _ => Importance.high,
          },
          priority: channel == 'ff_notice_quiet' ? Priority.low : Priority.high,
          autoCancel: true,
        ),
      ),
    );
  }
}
