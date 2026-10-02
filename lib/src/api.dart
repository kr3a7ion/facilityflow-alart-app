import 'dart:convert';

import 'package:http/http.dart' as http;

/// A job handed to this person and not yet picked up.
class WaitingJob {
  const WaitingJob({
    required this.id,
    required this.ref,
    required this.title,
    required this.priority,
    required this.respondBy,
  });

  final String id;
  final String ref;
  final String title;
  final String priority;
  final DateTime? respondBy;

  bool get isEmergency => priority == 'P1';

  /// Past this the host escalates to a team lead and then a supervisor. The phone stops
  /// ringing at the same moment: a handset that alarms all night is a handset in a
  /// drawer by morning, and a human chasing it is a better answer than more volume.
  bool get pastDeadline =>
      respondBy != null && DateTime.now().toUtc().isAfter(respondBy!);

  static WaitingJob fromJson(Map<String, dynamic> j) => WaitingJob(
        id: j['id'] as String,
        ref: j['ref'] as String? ?? '',
        title: j['title'] as String? ?? '',
        priority: j['priority'] as String? ?? 'P3',
        respondBy: j['respond_by'] == null
            ? null
            : DateTime.tryParse(j['respond_by'] as String)?.toUtc(),
      );
}

/// Somebody — a supervisor, a team lead — ringing this person's device.
///
/// Not a job: a person who needs them now. It rings until it is answered with "I am here",
/// from this phone or any other device signed in as them, or until the host stops listing
/// it half an hour later.
class Ring {
  const Ring({required this.id, required this.reason, required this.byName});

  final String id;
  final String? reason;
  final String byName;

  static Ring fromJson(Map<String, dynamic> j) => Ring(
        id: j['id'] as String,
        reason: j['reason'] as String?,
        byName: j['rung_by_name'] as String? ?? 'Somebody',
      );
}

/// An emergency alert raised to the whole property — fire, power, water, security.
///
/// It rings until this person acknowledges it, and then goes quiet on this phone even
/// though the alert itself stays live until somebody stands it down: the roll call is the
/// point, and "I have seen this" is how this person gets onto it.
class Emergency {
  const Emergency({
    required this.id,
    required this.category,
    required this.message,
    required this.raisedBy,
    required this.location,
    required this.acknowledgedByMe,
  });

  final String id;
  final String category;
  final String message;
  final String raisedBy;
  final String? location;
  final bool acknowledgedByMe;

  String get categoryWord => const {
        'fire': 'Fire',
        'power': 'Power',
        'water': 'Water',
        'security': 'Security',
        'medical': 'Medical',
      }[category] ??
      'Emergency';

  static Emergency fromJson(Map<String, dynamic> j, String myUserId) {
    final roll = (j['rollCall'] as List<dynamic>? ?? const [])
        .cast<Map<String, dynamic>>();
    final me = roll.where((p) => p['userId'] == myUserId).firstOrNull;
    return Emergency(
      id: j['id'] as String,
      category: j['category'] as String? ?? 'other',
      message: j['message'] as String? ?? '',
      raisedBy: j['raised_by_name'] as String? ?? '',
      location: j['location_name'] as String?,
      acknowledgedByMe: me != null && me['acknowledgedAt'] != null,
    );
  }
}

/// Raised when the host no longer recognises this phone — unpaired, or the account
/// disabled. Distinct from a network failure on purpose: one means stop and tell the
/// person, the other means keep trying.
class Unpaired implements Exception {
  const Unpaired();
}

/// The handful of calls this app makes.
///
/// Every one of them is a call the website makes too, with the same permissions behind
/// it. That is the design: the app is a second door into the same room, so accepting a
/// job from a lock screen and accepting it in a browser are the same event, and the
/// ringing stops everywhere at once.
class Api {
  Api(this.baseUrl, this.token);

  final String baseUrl;
  final String token;

  Map<String, String> get _headers => {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
      };

  Future<List<WaitingJob>> outstanding() async {
    final r = await http
        .get(Uri.parse('$baseUrl/api/me/outstanding'), headers: _headers)
        .timeout(const Duration(seconds: 15));
    if (r.statusCode == 401) throw const Unpaired();
    if (r.statusCode != 200) {
      throw http.ClientException('outstanding failed: ${r.statusCode}');
    }
    final body = jsonDecode(r.body) as Map<String, dynamic>;
    return (body['unaccepted'] as List<dynamic>)
        .map((e) => WaitingJob.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<Map<String, dynamic>> _getJson(String path) async {
    final r = await http
        .get(Uri.parse('$baseUrl$path'), headers: _headers)
        .timeout(const Duration(seconds: 15));
    if (r.statusCode == 401) throw const Unpaired();
    if (r.statusCode != 200) {
      throw http.ClientException('$path failed: ${r.statusCode}');
    }
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  Future<void> _post(String path, [Map<String, dynamic> body = const {}]) async {
    final r = await http
        .post(Uri.parse('$baseUrl$path'), headers: _headers, body: jsonEncode(body))
        .timeout(const Duration(seconds: 15));
    if (r.statusCode == 401) throw const Unpaired();
    if (r.statusCode >= 400) {
      throw http.ClientException('$path failed: ${r.statusCode} ${r.body}');
    }
  }

  /// Who this phone belongs to. Needed to find this person on an emergency's roll call,
  /// and asked of the host for phones paired before the id was kept in [Config].
  Future<String> myUserId() async {
    final body = await _getJson('/api/me');
    return (body['user'] as Map<String, dynamic>)['id'] as String;
  }

  /// Rings waiting for this person: unanswered and less than half an hour old.
  Future<List<Ring>> rings() async {
    final body = await _getJson('/api/me/rings');
    return (body['rings'] as List<dynamic>? ?? const [])
        .map((e) => Ring.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// "I am here." Stops the ringing on every device of this person's, and tells whoever
  /// rang that they answered.
  Future<void> answerRing(String ringId) => _post('/api/me/rings/$ringId/ack');

  /// Every live emergency, whether or not this person has acknowledged it yet.
  Future<List<Emergency>> emergencies(String myUserId) async {
    final body = await _getJson('/api/alerts/emergency');
    return (body['active'] as List<dynamic>? ?? const [])
        .map((e) => Emergency.fromJson(e as Map<String, dynamic>, myUserId))
        .toList();
  }

  /// "I have seen this." The host records it as reached by phone on the roll call.
  Future<void> acknowledgeEmergency(String alertId) =>
      _post('/api/alerts/emergency/$alertId/ack', {'via': 'phone'});

  Future<void> accept(String jobId) async {
    final r = await http
        .post(Uri.parse('$baseUrl/api/jobs/$jobId/accept'),
            headers: _headers, body: '{}')
        .timeout(const Duration(seconds: 15));
    if (r.statusCode == 401) throw const Unpaired();
    if (r.statusCode >= 400) {
      // A 409 here is ordinary rather than an error: somebody else took it, or it was
      // withdrawn while the phone was ringing. The caller refetches and finds it gone.
      throw http.ClientException('accept failed: ${r.statusCode} ${r.body}');
    }
  }

  /// Exchange a pairing code for this phone's own token. The one call made before the
  /// app has any credentials.
  static Future<Map<String, dynamic>> pair({
    required String baseUrl,
    required String code,
    required String deviceName,
    String appVersion = '1.0.0',
  }) async {
    final r = await http
        .post(
          Uri.parse('$baseUrl/api/devices/pair'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'code': code.trim().toUpperCase(),
            'deviceName': deviceName,
            'platform': 'android',
            'appVersion': appVersion,
          }),
        )
        .timeout(const Duration(seconds: 10));
    Map<String, dynamic>? body;
    try {
      body = jsonDecode(r.body) as Map<String, dynamic>;
    } catch (_) {
      // Something answered that is not FacilityFlow — a router's login page, another
      // service on that port. Say so rather than failing on the parse.
    }
    if (r.statusCode != 201 || body == null) {
      throw Exception(body?['message'] as String? ??
          'That did not work. Generate a fresh code on the website and try again.');
    }
    return body;
  }
}
