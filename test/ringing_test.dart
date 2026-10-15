import 'package:facilityflow_alerts/src/api.dart';
import 'package:facilityflow_alerts/src/ringing.dart';
import 'package:flutter_test/flutter_test.dart';

WaitingJob _job(String priority, {DateTime? ringUntil}) => WaitingJob(
      id: 'j-$priority',
      ref: 'WO-1',
      title: 'Lift stuck',
      priority: priority,
      respondBy: ringUntil,
      ringUntil: ringUntil,
    );

const _ring = Ring(id: 'r1', reason: null, byName: 'Grace');

Emergency _emergency({bool acknowledged = false}) => Emergency(
      id: 'e1',
      category: 'fire',
      message: 'Smoke on level 3',
      raisedBy: 'Grace',
      location: null,
      acknowledgedByMe: acknowledged,
    );

void main() {
  final now = DateTime.now();
  final fresh = now.subtract(const Duration(seconds: 30));
  final stale = now.subtract(staleAfter + const Duration(minutes: 1));
  final later = now.add(const Duration(hours: 1));

  group('what sounds', () {
    test('nothing, when nothing is waiting', () {
      expect(soundFor(Waiting(jobsAt: fresh, ringsAt: fresh, emergenciesAt: fresh), now),
          Sound.none);
    });

    test('an emergency or somebody ringing is urgent', () {
      expect(soundFor(Waiting(emergencies: [_emergency()], emergenciesAt: fresh), now),
          Sound.urgent);
      expect(soundFor(Waiting(rings: const [_ring], ringsAt: fresh), now), Sound.urgent);
    });

    test('a P1 job is urgent and any other job is the normal sound', () {
      expect(soundFor(Waiting(jobs: [_job('P1', ringUntil: later)], jobsAt: fresh), now),
          Sound.urgent);
      expect(soundFor(Waiting(jobs: [_job('P3', ringUntil: later)], jobsAt: fresh), now),
          Sound.normal);
    });

    test('an emergency this person has acknowledged does not', () {
      expect(soundFor(Waiting(emergencies: [_emergency(acknowledged: true)], emergenciesAt: fresh), now),
          Sound.none);
    });

    test('a job past its ring window does not', () {
      final past = now.subtract(const Duration(minutes: 1));
      expect(soundFor(Waiting(jobs: [_job('P1', ringUntil: past)], jobsAt: fresh), now),
          Sound.none);
    });
  });

  /*
   * Off the wifi, or with the host switched off, the phone used to ring about the last
   * thing it heard until somebody opened the app — and nothing can be accepted or
   * acknowledged without the host anyway.
   */
  group('when the host stops confirming', () {
    test('a ring, an emergency or a job it last heard about goes quiet', () {
      expect(soundFor(Waiting(rings: const [_ring], ringsAt: stale), now), Sound.none);
      expect(soundFor(Waiting(emergencies: [_emergency()], emergenciesAt: stale), now),
          Sound.none);
      expect(soundFor(Waiting(jobs: [_job('P1', ringUntil: later)], jobsAt: stale), now),
          Sound.none);
    });

    test('and says it has lost contact, rather than pretending all is well', () {
      expect(Waiting(rings: const [_ring], ringsAt: stale).lostContact(now), isTrue);
      expect(Waiting(rings: const [_ring], ringsAt: fresh).lostContact(now), isFalse);
    });

    test('but one list failing does not silence another the host did answer', () {
      final w = Waiting(
        rings: const [_ring],
        ringsAt: fresh,
        jobs: [_job('P3', ringUntil: later)],
        jobsAt: stale,
      );
      expect(soundFor(w, now), Sound.urgent);
    });

    test('with nothing waiting, an old answer is not "lost contact"', () {
      expect(Waiting(jobsAt: stale, ringsAt: stale, emergenciesAt: stale).lostContact(now),
          isFalse);
    });

    test('a list never answered at all does not sound', () {
      expect(soundFor(const Waiting(rings: [_ring]), now), Sound.none);
    });
  });

  group('ServiceState, as the service tells the screen', () {
    test('survives the trip through storage', () {
      final at = DateTime.utc(2026, 10, 13, 9, 30);
      final back = ServiceState.decode(
          ServiceState(connected: true, unpaired: false, heardAt: at).encode())!;
      expect(back.connected, isTrue);
      expect(back.unpaired, isFalse);
      expect(back.heardAt, at);
    });

    test('nothing stored, or something unreadable, is no answer rather than a crash', () {
      expect(ServiceState.decode(null), isNull);
      expect(ServiceState.decode(''), isNull);
      expect(ServiceState.decode('not json'), isNull);
    });
  });
}
