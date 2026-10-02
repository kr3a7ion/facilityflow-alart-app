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
        .timeout(const Duration(seconds: 20));
    final body = jsonDecode(r.body) as Map<String, dynamic>;
    if (r.statusCode != 201) {
      throw Exception(body['message'] as String? ??
          'That did not work. Generate a fresh code on the website and try again.');
    }
    return body;
  }
}
