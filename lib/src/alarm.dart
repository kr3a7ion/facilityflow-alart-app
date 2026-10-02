import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:vibration/vibration.dart';

/// The noise.
///
/// Two decisions here matter more than the rest of this file.
///
/// **It plays on the alarm stream, not the notification stream.** A technician's phone
/// spends the shift on silent — in a meeting, in a pocket, in a plant room where nobody
/// wants a message tone every thirty seconds. Android keeps the alarm stream separate
/// from the ringer precisely so that a clock can still wake you, and a job assignment on
/// a property with no internet is the same class of thing. It is a deliberate choice to
/// be able to override silent, which is why only the two roles who are dispatched work
/// get this app pointed at them.
///
/// **It loops until something stops it, and the thing that stops it is the host.** Not a
/// dismiss button, not a timeout the app invents — the alarm stops when the job stops
/// being unaccepted, which happens when it is accepted from any device, reassigned, or
/// cancelled. One source of truth for whether anybody still needs to be shouted at.
class Alarm {
  Alarm() {
    _player.setReleaseMode(ReleaseMode.loop);
  }

  final AudioPlayer _player = AudioPlayer();
  bool _running = false;
  String? _voice;
  Timer? _buzz;

  bool get running => _running;

  Future<void> start({required bool urgent}) async {
    final voice = urgent ? 'alarm_urgent.wav' : 'alarm_notify.wav';
    // Already making exactly this noise: leave it alone rather than restarting the loop
    // every time another event arrives, which would stutter it into something that
    // sounds broken.
    if (_running && _voice == voice) return;

    _voice = voice;
    _running = true;

    await _player.setAudioContext(
      AudioContext(
        android: const AudioContextAndroid(
          isSpeakerphoneOn: true,
          stayAwake: true,
          contentType: AndroidContentType.sonification,
          // The whole point. ALARM usage is what gets past a phone set to silent.
          usageType: AndroidUsageType.alarm,
          audioFocus: AndroidAudioFocus.gainTransientMayDuck,
        ),
        iOS: AudioContextIOS(
          category: AVAudioSessionCategory.playback,
          options: {AVAudioSessionOptions.duckOthers},
        ),
      ),
    );

    await _player.stop();
    await _player.play(AssetSource(voice), volume: 1.0);

    // Vibration alongside, not instead: a phone in a thick pocket next to a running set
    // is felt long before it is heard.
    if (await Vibration.hasVibrator()) {
      _buzz?.cancel();
      _buzz = Timer.periodic(Duration(seconds: urgent ? 3 : 8), (_) {
        Vibration.vibrate(
          pattern: urgent ? [0, 400, 200, 400, 200, 400] : [0, 300, 200, 300],
        );
      });
      Vibration.vibrate(pattern: urgent ? [0, 400, 200, 400] : [0, 300]);
    }
  }

  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    _voice = null;
    _buzz?.cancel();
    _buzz = null;
    Vibration.cancel();
    await _player.stop();
  }

  Future<void> dispose() async {
    await stop();
    await _player.dispose();
  }
}
