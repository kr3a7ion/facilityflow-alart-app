import 'package:shared_preferences/shared_preferences.dart';

/// Where the host is and who this phone belongs to.
///
/// Both arrive together from one QR scan and then never change until the phone is
/// unpaired, so they live in the same small object. The token is the only secret the app
/// holds — there is no password here, by design: enrolment happens in a browser where
/// the person is already signed in, and losing this phone costs one revoked row on the
/// host rather than a password change.
class Config {
  const Config({
    required this.baseUrl,
    required this.token,
    required this.displayName,
    required this.roleName,
    required this.propertyName,
    required this.deviceId,
  });

  final String baseUrl;
  final String token;
  final String displayName;
  final String roleName;
  final String propertyName;
  final String deviceId;

  static const _kUrl = 'ff.url';
  static const _kToken = 'ff.token';
  static const _kName = 'ff.name';
  static const _kRole = 'ff.role';
  static const _kProperty = 'ff.property';
  static const _kDevice = 'ff.device';

  static Future<Config?> load() async {
    final p = await SharedPreferences.getInstance();
    // Reload matters: the foreground service runs in its own isolate and would otherwise
    // keep serving a cached copy from before the phone was paired.
    await p.reload();
    final url = p.getString(_kUrl);
    final token = p.getString(_kToken);
    if (url == null || token == null || url.isEmpty || token.isEmpty) return null;
    return Config(
      baseUrl: url,
      token: token,
      displayName: p.getString(_kName) ?? '',
      roleName: p.getString(_kRole) ?? '',
      propertyName: p.getString(_kProperty) ?? '',
      deviceId: p.getString(_kDevice) ?? '',
    );
  }

  Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kUrl, baseUrl);
    await p.setString(_kToken, token);
    await p.setString(_kName, displayName);
    await p.setString(_kRole, roleName);
    await p.setString(_kProperty, propertyName);
    await p.setString(_kDevice, deviceId);
  }

  static Future<void> clear() async {
    final p = await SharedPreferences.getInstance();
    for (final k in [_kUrl, _kToken, _kName, _kRole, _kProperty, _kDevice]) {
      await p.remove(k);
    }
  }
}
