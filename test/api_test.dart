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
}
