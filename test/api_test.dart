import 'package:facilityflow_alerts/src/api.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('WaitingJob.fromJson', () {
    test('reads the fields the host sends', () {
      final job = WaitingJob.fromJson({
        'id': 'j1',
        'ref': 'WO-1042',
        'title': 'Generator not starting',
        'priority': 'P1',
        'respond_by': '2099-01-01T00:00:00Z',
      });
      expect(job.id, 'j1');
      expect(job.ref, 'WO-1042');
      expect(job.isEmergency, isTrue);
      expect(job.pastDeadline, isFalse);
    });

    test('defaults missing optional fields', () {
      final job = WaitingJob.fromJson({'id': 'j2'});
      expect(job.ref, '');
      expect(job.title, '');
      expect(job.priority, 'P3');
      expect(job.isEmergency, isFalse);
      expect(job.respondBy, isNull);
      expect(job.pastDeadline, isFalse);
    });

    test('a passed deadline stops it counting as live', () {
      final job = WaitingJob.fromJson({
        'id': 'j3',
        'respond_by': '2000-01-01T00:00:00Z',
      });
      expect(job.pastDeadline, isTrue);
    });
  });

  group('WaitingJob.ringingOver', () {
    test('a job handed out after its deadline still rings until the host says stop', () {
      final job = WaitingJob.fromJson({
        'id': 'j4',
        'respond_by': '2000-01-01T00:00:00Z',
        'ring_until': '2099-01-01T00:00:00Z',
      });
      expect(job.pastDeadline, isTrue);
      expect(job.ringUntil, DateTime.utc(2099));
      expect(job.ringingOver, isFalse);
    });

    test('and stops once that window has gone too', () {
      final job = WaitingJob.fromJson({
        'id': 'j5',
        'respond_by': '2000-01-01T00:00:00Z',
        'ring_until': '2000-01-01T00:30:00Z',
      });
      expect(job.ringingOver, isTrue);
    });

    test('a host older than ring_until falls back to the response deadline', () {
      final overdue = WaitingJob.fromJson({'id': 'j6', 'respond_by': '2000-01-01T00:00:00Z'});
      final fresh = WaitingJob.fromJson({'id': 'j7', 'respond_by': '2099-01-01T00:00:00Z'});
      expect(overdue.ringUntil, isNull);
      expect(overdue.ringingOver, isTrue);
      expect(fresh.ringingOver, isFalse);
    });

    test('with no deadline at all it keeps ringing', () {
      expect(WaitingJob.fromJson({'id': 'j8'}).ringingOver, isFalse);
    });
  });
}
