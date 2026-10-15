import 'dart:convert';

import 'api.dart';

/// How long the phone keeps sounding on what the host last said, once it cannot ask again.
///
/// Something that was waiting a second ago is still waiting now, so a dropped request must
/// not silence a job. But a phone carried off the property, or a host switched off, would
/// otherwise ring about the last thing it heard until somebody found the app — and nothing
/// can be accepted or acknowledged without the host anyway. Past this, the banners stay up
/// and the noise stops until the host answers again.
const staleAfter = Duration(minutes: 10);

/// Everything this phone could be asked to ring about, and when the host last confirmed
/// each list. A list that failed to load keeps its last answer and its old time.
class Waiting {
  const Waiting({
    this.jobs = const [],
    this.rings = const [],
    this.emergencies = const [],
    this.jobsAt,
    this.ringsAt,
    this.emergenciesAt,
  });

  final List<WaitingJob> jobs;
  final List<Ring> rings;
  final List<Emergency> emergencies;
  final DateTime? jobsAt;
  final DateTime? ringsAt;
  final DateTime? emergenciesAt;

  static bool _confirmed(DateTime? at, DateTime now) =>
      at != null && now.difference(at) <= staleAfter;

  /// Emergencies this person has not acknowledged.
  List<Emergency> get openEmergencies => emergencies.where((e) => !e.acknowledgedByMe).toList();

  /// What may make a sound at [now]: confirmed lately, not acknowledged, not past ringing.
  List<Emergency> soundingEmergencies(DateTime now) =>
      _confirmed(emergenciesAt, now) ? openEmergencies : const [];
  List<Ring> soundingRings(DateTime now) => _confirmed(ringsAt, now) ? rings : const [];
  List<WaitingJob> soundingJobs(DateTime now) =>
      _confirmed(jobsAt, now) ? jobs.where((j) => !j.ringingOver).toList() : const [];

  /// Something is waiting, but the host has not confirmed it lately: the phone has lost
  /// contact and is showing what it last knew.
  bool lostContact(DateTime now) =>
      (openEmergencies.isNotEmpty && !_confirmed(emergenciesAt, now)) ||
      (rings.isNotEmpty && !_confirmed(ringsAt, now)) ||
      (jobs.any((j) => !j.ringingOver) && !_confirmed(jobsAt, now));
}

enum Sound { none, normal, urgent }

/// One alarm, at the most urgent level anything confirmed calls for.
Sound soundFor(Waiting w, DateTime now) {
  if (w.soundingEmergencies(now).isNotEmpty || w.soundingRings(now).isNotEmpty) {
    return Sound.urgent;
  }
  final jobs = w.soundingJobs(now);
  if (jobs.isEmpty) return Sound.none;
  return jobs.any((j) => j.isEmergency) ? Sound.urgent : Sound.normal;
}

/// What the service tells the screen about itself, because the screen cannot see it.
///
/// The screen used to say "Listening for jobs" whenever its own request to the host
/// worked — which said nothing about the service that actually rings, and a dead service
/// looked exactly like a live one. Written by the service through the plugin's shared
/// storage on every change; read by the screen alongside whether the service is running.
class ServiceState {
  const ServiceState({required this.connected, required this.unpaired, this.heardAt});

  /// The live stream to the host is open.
  final bool connected;

  /// The host said it no longer knows this phone.
  final bool unpaired;

  /// The last time the host answered a request.
  final DateTime? heardAt;

  static const storageKey = 'ff.serviceState';

  String encode() => jsonEncode({
        'connected': connected,
        'unpaired': unpaired,
        if (heardAt != null) 'heardAt': heardAt!.toUtc().toIso8601String(),
      });

  static ServiceState? decode(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      return ServiceState(
        connected: j['connected'] == true,
        unpaired: j['unpaired'] == true,
        heardAt: j['heardAt'] is String ? DateTime.tryParse(j['heardAt'] as String) : null,
      );
    } catch (_) {
      return null;
    }
  }
}
