/// This build's version: the name from pubspec.yaml and the CI run that built it, as in
/// "1.0.0+57". The release workflow stamps it with --dart-define; a build made by hand
/// says "dev", so a supervisor can tell a stray debug build from a release on the host.
const buildVersion = String.fromEnvironment('APP_VERSION', defaultValue: 'dev');
