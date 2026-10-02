import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// A server-sent events client, written by hand.
///
/// Dart has no `EventSource`, and the packages that provide one tend to hide exactly the
/// behaviour this app depends on: how long it waits before reconnecting, whether it
/// notices a connection that is open but silent, and whether it tells the caller any of
/// it. On a property where the whole point is that a phone rings, a stream that has
/// quietly died while still looking connected is the worst possible failure — so this is
/// about sixty lines that can be read and reasoned about.
///
/// Three behaviours matter:
///
///  * **Reconnect forever, with a backoff.** A technician walks through a basement and
///    out of wifi twenty times a shift. Dropping is normal; giving up is not.
///  * **Treat silence as death.** The host sends a heartbeat every 25 seconds. If nothing
///    arrives for appreciably longer than that, the socket is open as far as the phone is
///    concerned and gone as far as the building is concerned. Tear it down and redial.
///  * **Say so.** Every state change is reported, because the home screen showing
///    "connected" while the phone is deaf is a lie that costs somebody a P1.
class SseClient {
  SseClient({
    required this.url,
    required this.token,
    required this.onEvent,
    required this.onState,
  });

  final String url;
  final String token;

  /// Called with the event name, e.g. `notification` or `jobs`. Heartbeats are swallowed.
  final void Function(String kind) onEvent;

  /// Called whenever the connection comes up or goes down.
  final void Function(bool connected) onState;

  static const Duration _silenceLimit = Duration(seconds: 70);
  static const Duration _minRetry = Duration(seconds: 2);
  static const Duration _maxRetry = Duration(seconds: 30);

  http.Client? _client;
  StreamSubscription<String>? _sub;
  Timer? _watchdog;
  DateTime _lastMessage = DateTime.now();
  Duration _retry = _minRetry;
  bool _closed = false;
  bool _connected = false;

  bool get connected => _connected;

  void start() {
    _closed = false;
    _connect();
    _watchdog = Timer.periodic(const Duration(seconds: 15), (_) {
      if (_closed || !_connected) return;
      if (DateTime.now().difference(_lastMessage) < _silenceLimit) return;
      // Open but silent. Nothing in the stack will tell us about this, so we decide.
      _drop();
      _connect();
    });
  }

  Future<void> _connect() async {
    if (_closed) return;
    try {
      final client = http.Client();
      _client = client;
      final request = http.Request('GET', Uri.parse('$url/api/events'))
        ..headers['Authorization'] = 'Bearer $token'
        ..headers['Accept'] = 'text/event-stream'
        ..headers['Cache-Control'] = 'no-cache';

      final response = await client.send(request);
      if (response.statusCode != 200) {
        // A 401 means this phone has been unpaired on the host. Retrying forever is
        // correct even so: the caller checks for it separately and shows the person what
        // happened, and a transient 503 must not permanently stop a phone from ringing.
        throw http.ClientException('stream refused: ${response.statusCode}');
      }

      _setConnected(true);
      _retry = _minRetry;
      _lastMessage = DateTime.now();

      String eventName = 'message';
      _sub = response.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(
        (line) {
          _lastMessage = DateTime.now();
          if (line.startsWith('event:')) {
            eventName = line.substring(6).trim();
          } else if (line.startsWith('data:')) {
            // The payload is only a nudge; the app refetches what it needs. Keeping it
            // that way means the stream never has to know what any screen is showing.
            if (eventName != 'ping') onEvent(eventName);
            eventName = 'message';
          } else if (line.isEmpty) {
            eventName = 'message';
          }
        },
        onDone: _retryLater,
        onError: (_) => _retryLater(),
        cancelOnError: true,
      );
    } catch (_) {
      _retryLater();
    }
  }

  void _retryLater() {
    if (_closed) return;
    _drop();
    final wait = _retry;
    _retry = Duration(
      milliseconds: (_retry.inMilliseconds * 2).clamp(
        _minRetry.inMilliseconds,
        _maxRetry.inMilliseconds,
      ),
    );
    Timer(wait, _connect);
  }

  void _drop() {
    _sub?.cancel();
    _sub = null;
    _client?.close();
    _client = null;
    _setConnected(false);
  }

  void _setConnected(bool value) {
    if (_connected == value) return;
    _connected = value;
    onState(value);
  }

  void stop() {
    _closed = true;
    _watchdog?.cancel();
    _watchdog = null;
    _drop();
  }
}
