import 'package:facilityflow_alerts/src/notices.dart';
import 'package:flutter_test/flutter_test.dart';

HostNotice _n(String id, String at, {String kind = 'escalation', String? level}) =>
    HostNotice(id: id, kind: kind, title: 'T $id', body: null, level: level, createdAt: at);

void main() {
  test('a notice reads the fields the host sends', () {
    final n = HostNotice.fromJson({
      'id': 'n1', 'kind': 'escalation', 'title': 'WO-1042 is past its response time',
      'body': 'P1 · Lift stuck', 'level': 'urgent', 'created_at': '2026-10-13T09:00:00.000Z',
      'read_at': null, 'entity_type': 'work_order', 'entity_id': 'w1',
    });
    expect(n.kind, 'escalation');
    expect(n.level, 'urgent');
    expect(n.createdAt, '2026-10-13T09:00:00.000Z');
  });

  group('what is new', () {
    final older = _n('a', '2026-10-13T09:00:00.000Z');
    final newer = _n('b', '2026-10-13T09:05:00.000Z');

    test('a phone that has never looked starts after the newest, rather than replaying the bell', () {
      final seen = Seen.startingAfter([newer, older]);
      expect(newSince([newer, older], seen), isEmpty);
    });

    test('only what came after, oldest first', () {
      final third = _n('c', '2026-10-13T09:10:00.000Z');
      final fresh = newSince([third, newer, older], Seen(older.createdAt, {older.id}));
      expect(fresh.map((n) => n.id), ['b', 'c']);
    });

    test('two notices in the same millisecond are not lost', () {
      final twin = _n('b2', newer.createdAt);
      final seen = Seen(newer.createdAt, {newer.id});
      expect(newSince([twin, newer, older], seen).map((n) => n.id), ['b2']);
    });

    test('moving past what was shown', () {
      final third = _n('c', '2026-10-13T09:10:00.000Z');
      final seen = advance(Seen(older.createdAt, {older.id}), [newer, third]);
      expect(seen.at, third.createdAt);
      expect(newSince([third, newer, older], seen), isEmpty);
    });

    test('survives the trip through storage, and a bad value is no answer', () {
      final back = Seen.decode(const Seen('2026-10-13T09:00:00.000Z', {'a', 'b'}).encode())!;
      expect(back.at, '2026-10-13T09:00:00.000Z');
      expect(back.ids, {'a', 'b'});
      expect(Seen.decode(null), isNull);
      expect(Seen.decode('nope'), isNull);
    });
  });

  test('as loud as the host says, each loudness its own channel', () {
    expect(channelFor('urgent'), 'ff_notice_urgent');
    expect(channelFor('quiet'), 'ff_notice_quiet');
    expect(channelFor('chime'), 'ff_notice');
    expect(channelFor('good'), 'ff_notice');
    expect(channelFor(null), 'ff_notice');
  });

  test('"assigned to you" is left to the job alarm and its Accept button', () {
    expect(skippedKinds, contains('wo.assigned'));
    expect(skippedKinds, isNot(contains('wo.reassigned')));
  });
}
