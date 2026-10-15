import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:url_launcher/url_launcher.dart';

import 'api.dart';
import 'config.dart';
import 'readiness.dart';
import 'ringing.dart' show ServiceState;
import 'service.dart' show performAction;
import 'update.dart';

/// What the person sees when they open the app on purpose.
///
/// Deliberately thin. The app's job happens when nobody is looking at it, so this screen
/// exists to answer two questions and no others: **is it listening**, and **is anything
/// waiting for me** — an emergency, somebody ringing, or a job. Everything else — the job detail, the history, the photographs —
/// is the website's job, and the button at the bottom takes them there rather than this
/// app growing a second, worse copy of it.
class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.config,
    required this.onUnpair,
    required this.onStartService,
  });

  final Config config;
  final VoidCallback onUnpair;

  /// Start the listening service again, when it is not running.
  final Future<void> Function() onStartService;

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

  /// The host answered and no longer knows this phone. Said on screen rather than acted
  /// on: wiping the pairing on the spot also fired for a host restored from an older
  /// backup, and threw away a pairing the person had no way to know was gone.
  bool _unpairedOnHost = false;

  /// Whether the listening service is running, and what it says about itself. This card
  /// is the answer to "is it listening", so it comes from the service — not from this
  /// screen's own requests, which said "Listening" even with the service dead.
  bool? _serviceRunning;
  ServiceState? _service;
  bool _starting = false;
  Timer? _poll;

  /// What this phone's own settings say about whether it will be heard. Read here as well
  /// as by the service, so the person holding the phone sees it without asking the host.
  Readiness? _readiness;

  late final Api _api = Api(widget.config.baseUrl, widget.config.token);

  /// What the host hands out, when it is newer than this phone. Asked once when the screen
  /// opens; the service asks every few hours and notifies.
  HostApp? _newer;

  @override
  void initState() {
    super.initState();
    _refresh();
    _checkForUpdate();
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
    final readiness = await readReadiness();
    if (mounted) setState(() => _readiness = readiness);
    try {
      final running = await FlutterForegroundTask.isRunningService;
      final state = ServiceState.decode(
          await FlutterForegroundTask.getData<String>(key: ServiceState.storageKey));
      if (mounted) setState(() { _serviceRunning = running; _service = running ? state : null; });
    } catch (_) {
      // Leave the last answer; the next poll asks again.
    }
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
        _unpairedOnHost = false;
      });
    } on Unpaired {
      if (!mounted) return;
      setState(() { _reachable = true; _loading = false; _unpairedOnHost = true; });
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

  Future<void> _startListening() async {
    setState(() => _starting = true);
    try {
      await widget.onStartService();
    } finally {
      if (mounted) setState(() => _starting = false);
      await _refresh();
    }
  }

  Future<void> _checkForUpdate() async {
    try {
      final host = await fetchHostApp(widget.config.baseUrl);
      if (mounted && isNewer(host, myBuild)) setState(() => _newer = host);
    } catch (_) {
      // Unreachable: the status card already says so.
    }
  }

  Future<void> _update() async {
    final opened = await openInstaller(widget.config.baseUrl);
    if (!opened && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Open ${widget.config.baseUrl}/app.apk in your browser.'),
      ));
    }
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
    final problems = _readiness == null ? const <String>[] : problemsOf(_readiness!);
    final silent = problems.contains('volume_off');
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
            if (_unpairedOnHost || (_service?.unpaired ?? false))
              Card(
                color: Theme.of(context).colorScheme.errorContainer,
                child: ListTile(
                  leading: const Icon(Icons.link_off),
                  title: const Text('This phone is no longer paired'),
                  subtitle: const Text('It was unpaired on the website, or the account was '
                      'disabled. It will not ring until it is paired again.'),
                  trailing: FilledButton(
                    onPressed: widget.onUnpair,
                    child: const Text('Pair again'),
                  ),
                ),
              )
            else if (_serviceRunning == false)
              Card(
                color: Theme.of(context).colorScheme.errorContainer,
                child: ListTile(
                  leading: const Icon(Icons.notifications_off),
                  title: const Text('Not listening'),
                  subtitle: const Text('The part of the app that rings has stopped, so this '
                      'phone will not ring for jobs until it is started again.'),
                  trailing: FilledButton(
                    onPressed: _starting ? null : _startListening,
                    child: const Text('Start listening'),
                  ),
                ),
              )
            else if (_service != null && !_service!.connected)
              Card(
                color: Theme.of(context).colorScheme.errorContainer,
                child: ListTile(
                  leading: const Icon(Icons.wifi_off),
                  title: const Text('Not connected to the host'),
                  subtitle: Text('Trying again by itself. ${_heardWords(_service!.heardAt)} '
                      'Check the phone is on the property wifi.'),
                ),
              )
            else
              Card(
                color: _reachable || _service != null
                    ? Theme.of(context).colorScheme.secondaryContainer
                    : Theme.of(context).colorScheme.errorContainer,
                child: ListTile(
                  leading: Icon(_reachable || _service != null
                      ? Icons.wifi_tethering
                      : Icons.wifi_off),
                  title: Text(_reachable || _service != null
                      ? 'Listening for jobs'
                      : 'Cannot reach the host'),
                  subtitle: Text(_reachable || _service != null
                      ? '${c.displayName} · ${c.roleName}'
                      : 'Check the phone is on the property wifi.'),
                ),
              ),
            // The supervisor's screen shows the same list, from what the service reports.
            if (problems.isNotEmpty)
              Card(
                color: silent
                    ? Theme.of(context).colorScheme.errorContainer
                    : Theme.of(context).colorScheme.tertiaryContainer,
                child: ListTile(
                  leading: Icon(silent ? Icons.volume_off : Icons.warning_amber),
                  title: Text(silent ? 'This phone will not be heard' : 'This phone may not be heard'),
                  subtitle: Text([
                    for (final p in problems) problemWords(p, _readiness!.alarmVolume),
                  ].join('\n\n')),
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
                      subtitle: Text([
                        [
                          j.ref,
                          if (j.teamName != null) '${j.teamName} team',
                          if (j.pastDeadline)
                            'past its response time — your supervisor has been told',
                        ].join(' · '),
                        // Handed to a team this person leads, with nobody's name on it yet.
                        // Accept still works and stops the ringing; the website's banner
                        // offers Assign for the same job.
                        if (j.teamName != null)
                          'Needs someone’s name on it — assign it on the website, or accept it yourself.',
                      ].join('\n')),
                      trailing: FilledButton(
                        onPressed: () => _act('accept', j.id),
                        child: const Text('Accept'),
                      ),
                    ),
                  )),
            if (_newer != null)
              Card(
                child: ListTile(
                  leading: const Icon(Icons.system_update),
                  title: const Text('A newer version is on the host'),
                  subtitle: Text('The host has ${_newer!.words}; this phone has build $myBuild. '
                      'It installs the way this one did, and stays paired.'),
                  trailing: FilledButton(onPressed: _update, child: const Text('Update')),
                ),
              ),
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

/// "Last heard from it 4 minutes ago." — or nothing, when it never has been.
String _heardWords(DateTime? at) {
  if (at == null) return '';
  final ago = DateTime.now().difference(at);
  final words = ago.inMinutes < 1
      ? 'just now'
      : ago.inMinutes < 60
          ? '${ago.inMinutes} minute${ago.inMinutes == 1 ? '' : 's'} ago'
          : '${ago.inHours} hour${ago.inHours == 1 ? '' : 's'} ago';
  return 'Last heard from it $words.';
}
