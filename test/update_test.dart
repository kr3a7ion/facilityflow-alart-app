import 'package:facilityflow_alerts/src/update.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the build number is the part after the plus', () {
    expect(buildNumberOf('1.0.0+57'), 57);
    expect(buildNumberOf('1.2.0+120'), 120);
  });

  test('a build made by hand has none, and is never told to update', () {
    expect(buildNumberOf('dev'), isNull);
    expect(isNewer(const HostApp(version: '1.0.0', build: 99), buildNumberOf('dev')), isFalse);
  });

  test('reads what /api/health says the host hands out', () {
    final h = HostApp.fromHealth({
      'ok': true,
      'app': {'version': '1.0.0', 'build': 14},
    })!;
    expect(h.version, '1.0.0');
    expect(h.build, 14);
    expect(h.words, 'version 1.0.0, build 14');
  });

  test('no installer, or a host from before it said, is no answer', () {
    expect(HostApp.fromHealth({'ok': true, 'app': null}), isNull);
    expect(HostApp.fromHealth({'ok': true}), isNull);
  });

  group('whether to offer it', () {
    const host = HostApp(version: '1.0.0', build: 14);
    test('only when the host has a later build', () {
      expect(isNewer(host, 12), isTrue);
      expect(isNewer(host, 14), isFalse);
      expect(isNewer(host, 15), isFalse);
    });
    test('not when the host could not read its own file', () {
      expect(isNewer(const HostApp(version: null, build: null), 12), isFalse);
    });
    test('not when there is nothing on the host', () => expect(isNewer(null, 12), isFalse));
  });
}
