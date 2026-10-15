import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final manifest = File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
  final service = RegExp(
    r'<service[^>]*flutter_foreground_task\.service\.ForegroundService.*?</service>',
    dotAll: true,
  ).firstMatch(manifest)?.group(0);

  /*
   * Android 15 stops a dataSync foreground service after six hours in any twenty-four and
   * refuses to start one at boot. A listener that goes deaf mid-shift, or after a restart,
   * is the failure this app exists to prevent, and nothing short of a phone left running
   * for a day would show it — so the type is pinned here.
   */
  group('the listening service', () {
    test('is declared specialUse, not dataSync', () {
      expect(service, isNotNull);
      expect(service, contains('android:foregroundServiceType="specialUse"'));
      expect(manifest, isNot(contains('foregroundServiceType="dataSync"')));
    });

    test('says what the special use is, as Android 14+ requires', () {
      expect(service, contains('android.app.PROPERTY_SPECIAL_USE_FGS_SUBTYPE'));
    });

    test('holds the permission for that type', () {
      expect(manifest, contains('android.permission.FOREGROUND_SERVICE_SPECIAL_USE'));
      expect(manifest, isNot(contains('FOREGROUND_SERVICE_DATA_SYNC')));
    });
  });
}
