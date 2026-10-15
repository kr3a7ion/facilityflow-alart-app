import 'package:facilityflow_alerts/src/readiness.dart';
import 'package:flutter_test/flutter_test.dart';

Readiness _r({bool notes = true, bool? full = true, bool battery = true, int? volume = 80}) =>
    Readiness(notificationsOn: notes, fullScreenOn: full, batteryExempt: battery, alarmVolume: volume);

void main() {
  test('reads what the plugin returns, and what it could not read counts as fine', () {
    final r = Readiness.fromSettings(
        {'notificationsOn': false, 'fullScreenOn': null, 'batteryExempt': true, 'alarmVolume': 43});
    expect(r.notificationsOn, isFalse);
    expect(r.fullScreenOn, isNull);
    expect(r.alarmVolume, 43);
    expect(problemsOf(Readiness.fromSettings(const {})), isEmpty);
  });

  test('sends what the host expects', () {
    expect(_r(full: null).toJson().keys,
        containsAll(['appVersion', 'notificationsOn', 'fullScreenOn', 'batteryExempt', 'alarmVolume']));
    expect(_r(full: null).toJson()['fullScreenOn'], isNull);
  });

  group('what stands between this phone and being heard', () {
    test('nothing, when everything is set up', () => expect(problemsOf(_r()), isEmpty));

    test('worst first, in the same order the host gives', () {
      expect(problemsOf(_r(notes: false, full: false, battery: false, volume: 0)),
          ['volume_off', 'battery_saver', 'notifications_off', 'no_full_screen']);
    });

    test('a low alarm is low, an alarm at zero is off, and an unread one is neither', () {
      expect(problemsOf(_r(volume: 15)), ['volume_low']);
      expect(problemsOf(_r(volume: 30)), isEmpty);
      expect(problemsOf(_r(volume: 0)), ['volume_off']);
      expect(problemsOf(_r(volume: null)), isEmpty);
    });

    test('Android before 14 always allows full-screen, so null is not a problem', () {
      expect(problemsOf(_r(full: null)), isEmpty);
    });

    test('each one is said in plain words, with where to fix it', () {
      for (final p in problemsOf(_r(notes: false, full: false, battery: false, volume: 0))) {
        expect(problemWords(p, 0), isNot(p));
      }
      expect(problemWords('volume_low', 15), contains('15%'));
    });
  });

  group('when to tell the host', () {
    final now = DateTime(2026, 10, 15, 9);
    final r = _r();

    test('the first time', () => expect(reportDue(r, now: now), isTrue));

    test('not again while nothing has changed', () {
      expect(reportDue(r, sentKey: r.key, sentAt: now.subtract(const Duration(minutes: 5)), now: now),
          isFalse);
    });

    test('at once when something changes', () {
      expect(reportDue(_r(volume: 0), sentKey: r.key, sentAt: now, now: now), isTrue);
    });

    test('and hourly anyway, so the supervisor knows the answer is current', () {
      expect(reportDue(r, sentKey: r.key, sentAt: now.subtract(const Duration(hours: 1)), now: now),
          isTrue);
    });
  });
}
