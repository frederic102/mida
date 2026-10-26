/// The one version string for MiDa: `mida-cli version` and the Settings
/// "About" card both read it. `test/cli/cli_parse_test.dart` fails when it
/// drifts from `version:` in pubspec.yaml (or from installer.iss), so a
/// release bump has to touch all three together.
const midaCliVersion = '2.4.0';
