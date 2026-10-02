import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:url_launcher/url_launcher.dart';

import 'api.dart';
import 'config.dart';
import 'service.dart' show performAction;

/// What the person sees when they open the app on purpose.
///
/// Deliberately thin. The app's job happens when nobody is looking at it, so this screen
/// exists to answer two questions and no others: **is it listening**, and **is anything
/// waiting for me** — an emergency, somebody ringing, or a job. Everything else — the job detail, the history, the photographs —
/// is the website's job, and the button at the bottom takes them there rather than this
/// app growing a second, worse copy of it.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.config, required this.onUnpair});

  final Config config;
  final VoidCallback onUnpair;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<WaitingJob> _jobs = const [];
  List<Ring> _rings = const [];
  List<Emergency> _emergencies = const [];
  String? _userId;
  bool _reachable = true;
  bool _loading = true;
  Timer? _poll;

  late final Api _api = Api(widget.config.baseUrl, widget.config.token);

  @override
  void initState() {
    super.initState();
    _refresh();
    // The service holds the live connection; this screen only needs to look current
    // while somebody is actually watching it.
    _poll = Timer.periodic(const Duration(seconds: 10), (_) => _refresh());
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final userId = _userId ??=
          widget.config.userId.isNotEmpty ? widget.config.userId : await _api.myUserId();
      final results = await Future.wait([
        _api.outstanding(),
        _api.rings(),
        _api.emergencies(userId),
      ]);
      if (!mounted) return;
      setState(() {
        _jobs = results[0] as List<WaitingJob>;
        _rings = results[1] as List<Ring>;
        _emergencies = (results[2] as List<Emergency>).where((e) => !e.acknowledgedByMe).toList();
        _reachable = true;
        _loading = false;
      });
    } on Unpaired {
      if (!mounted) return;
      setState(() { _reachable = true; _loading = false; });
      widget.onUnpair();
    } catch (_) {
      if (!mounted) return;
      setState(() { _reachable = false; _loading = false; });
    }
  }

  /// Accept a job, answer a ring, acknowledge an alert — the same calls the notification
  /// buttons make. The service is told too, because it is the one holding the alarm.
  Future<void> _act(String action, String id) async {
    try {
      await performAction(_api, action, id);
    } catch (_) {
      // Taken by somebody else, already answered, or withdrawn. The refresh settles it.
    }
    FlutterForegroundTask.sendDataToTask('refresh');
    await _refresh();
  }

  Future<void> _openWebsite() async {
    final opened = await launchUrl(
      Uri.parse(widget.config.baseUrl),
      mode: LaunchMode.externalApplication,
    ).catchError((_) => false);
    if (!opened && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Open ${widget.config.baseUrl} in your browser.'),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.config;
    return Scaffold(
      appBar: AppBar(
        title: Text(c.propertyName.isEmpty ? 'FacilityFlow' : c.propertyName),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: _refresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              color: _reachable
                  ? Theme.of(context).colorScheme.secondaryContainer
                  : Theme.of(context).colorScheme.errorContainer,
              child: ListTile(
                leading: Icon(_reachable ? Icons.wifi_tethering : Icons.wifi_off),
                title: Text(_reachable ? 'Listening for jobs' : 'Cannot reach the host'),
                subtitle: Text(_reachable
                    ? '${c.displayName} · ${c.roleName}'
                    : 'Check you are on the property wifi. The app cannot alert you from '
                      'outside the building.'),
              ),
            ),
            const SizedBox(height: 16),
            // The building first, then a person, then the work.
            for (final e in _emergencies)
              Card(
                color: Theme.of(context).colorScheme.error,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text('${e.categoryWord.toUpperCase()} ALERT',
                          style: TextStyle(
                              color: Theme.of(context).colorScheme.onError,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 1.2)),
                      const SizedBox(height: 6),
                      Text(e.message,
                          style: TextStyle(
                              color: Theme.of(context).colorScheme.onError,
                              fontSize: 18,
                              fontWeight: FontWeight.w600)),
                      const SizedBox(height: 4),
                      Text(
                          [
                            if (e.raisedBy.isNotEmpty) 'Raised by ${e.raisedBy}',
                            if (e.location != null && e.location!.isNotEmpty) e.location!,
                          ].join(' · '),
                          style: TextStyle(color: Theme.of(context).colorScheme.onError)),
                      const SizedBox(height: 12),
                      FilledButton(
                        style: FilledButton.styleFrom(
                          backgroundColor: Theme.of(context).colorScheme.onError,
                          foregroundColor: Theme.of(context).colorScheme.error,
                        ),
                        onPressed: () => _act('emergency_ack', e.id),
                        child: const Text('I have seen this'),
                      ),
                    ],
                  ),
                ),
              ),
            for (final r in _rings)
              Card(
                color: Theme.of(context).colorScheme.tertiaryContainer,
                child: ListTile(
                  leading: const Icon(Icons.notifications_active),
                  title: Text('${r.byName} is ringing you',
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: Text(r.reason == null || r.reason!.isEmpty
                      ? 'They need you now.'
                      : '“${r.reason}”'),
                  trailing: FilledButton(
                    onPressed: () => _act('ring_ack', r.id),
                    child: const Text('I am here'),
                  ),
                ),
              ),
            if (_emergencies.isNotEmpty || _rings.isNotEmpty) const SizedBox(height: 8),
            if (_loading)
              const Center(child: Padding(
                padding: EdgeInsets.all(24), child: CircularProgressIndicator()))
            else if (_jobs.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 28),
                child: Column(children: [
                  Icon(Icons.check_circle_outline, size: 42),
                  SizedBox(height: 10),
                  Text('Nothing waiting for you',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                  SizedBox(height: 6),
                  Text('You can close this. The phone will still ring.',
                      textAlign: TextAlign.center),
                ]),
              )
            else
              ..._jobs.map((j) => Card(
                    child: ListTile(
                      isThreeLine: true,
                      leading: CircleAvatar(
                        backgroundColor: j.isEmergency
                            ? Theme.of(context).colorScheme.error
                            : Theme.of(context).colorScheme.primary,
                        foregroundColor: Colors.white,
                        child: Text(j.priority,
                            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                      ),
                      title: Text(j.title,
                          style: const TextStyle(fontWeight: FontWeight.w600)),
                      subtitle: Text(j.pastDeadline
                          ? '${j.ref} · past its response time — your supervisor has been told'
                          : j.ref),
                      trailing: FilledButton(
                        onPressed: () => _act('accept', j.id),
                        child: const Text('Accept'),
                      ),
                    ),
                  )),
            const SizedBox(height: 24),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.open_in_new),
              title: const Text('Open the full system'),
              subtitle: Text(c.baseUrl),
              onTap: _openWebsite,
            ),
            ListTile(
              leading: const Icon(Icons.battery_alert),
              title: const Text('Stop this phone killing the app'),
              subtitle: const Text(
                  'Tecno, Infinix, Xiaomi and Oppo shut background apps down after a few '
                  'hours. Turn battery optimisation off for FacilityFlow Alerts.'),
              onTap: () => FlutterForegroundTask.openIgnoreBatteryOptimizationSettings(),
            ),
            ListTile(
              leading: const Icon(Icons.link_off),
              title: const Text('Unpair this phone'),
              subtitle: const Text('It will stop ringing until you pair it again.'),
              onTap: widget.onUnpair,
            ),
          ],
        ),
      ),
    );
  }
}
