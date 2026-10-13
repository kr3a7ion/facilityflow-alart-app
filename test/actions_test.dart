import 'dart:io';

import 'package:facilityflow_alerts/src/service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';

NotificationResponse _press(String? action, String? payload) => NotificationResponse(
      notificationResponseType: NotificationResponseType.selectedNotificationAction,
      actionId: action,
      payload: payload,
    );

void main() {
  group('the lock-screen buttons', () {
    /*
     * The buttons are sent without opening the app, which flutter_local_notifications
     * delivers as a broadcast to its ActionBroadcastReceiver. The plugin does not declare
     * that receiver itself; if the app's manifest does not either, every press is dropped
     * and the alarm can only be stopped by opening the app. Nothing else would catch its
     * removal before a phone on a site did.
     */
    test('their receiver is declared in the app manifest, and not exported', () {
      final manifest = File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
      final receiver = RegExp(
        r'<receiver[^>]*com\.dexterous\.flutterlocalnotifications\.ActionBroadcastReceiver[^>]*>',
        dotAll: true,
      ).firstMatch(manifest);
      expect(receiver, isNotNull);
      expect(receiver!.group(0), contains('android:exported="false"'));
    });
  });

  group('parseAction', () {
    test('reads the action and the record it is for', () {
      expect(parseAction(_press('accept', '{"action":"accept","id":"j1","key":"job:j1"}')),
          ('accept', 'j1'));
      expect(parseAction(_press('ring_ack', '{"action":"ring_ack","id":"r1"}')),
          ('ring_ack', 'r1'));
      expect(parseAction(_press('emergency_ack', '{"action":"emergency_ack","id":"e1"}')),
          ('emergency_ack', 'e1'));
    });

    test('still reads a notification posted by the previous version', () {
      expect(parseAction(_press('accept', '{"jobId":"j9"}')), ('accept', 'j9'));
    });

    test('a tap on the body, or a payload it cannot read, is not an action', () {
      expect(parseAction(_press(null, '{"id":"j1"}')), isNull);
      expect(parseAction(_press('accept', null)), isNull);
      expect(parseAction(_press('accept', 'not json')), isNull);
      expect(parseAction(_press('accept', '{"action":"accept"}')), isNull);
    });
  });
}
