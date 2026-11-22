import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Where the app keeps its subscriptions and the download archive: the same
/// per-user folder `shared_preferences` uses for the other settings
/// (Windows: `%APPDATA%\MiDa\MiDa`). The formats are the CLI's, and the
/// archive name is the one `mida-cli sync` picks by default for
/// `--subscriptions <file>`, so
/// `mida-cli sync --subscriptions <subscriptions.json>` works on the same data.
class SubscriptionPaths {
  const SubscriptionPaths(this.subscriptions, this.archive, {this.temporary = false});

  factory SubscriptionPaths.inDir(Directory dir, {bool temporary = false}) => SubscriptionPaths(
        File(p.join(dir.path, 'subscriptions.json')),
        File(p.join(dir.path, 'subscriptions.json.archive')),
        temporary: temporary,
      );

  static Future<SubscriptionPaths> appSupport() async => SubscriptionPaths.inDir(await getApplicationSupportDirectory());

  /// Used when there is no per-user data folder: the system temp folder,
  /// flagged so the Subscriptions screen warns about it.
  factory SubscriptionPaths.temporaryFallback() =>
      SubscriptionPaths.inDir(Directory(p.join(Directory.systemTemp.path, 'MiDa')), temporary: true);

  static const temporaryWarning =
      'MiDa could not find its data folder, so your subscriptions and the download archive are kept in the '
      'temporary folder. Windows may clean that folder, which would forget them. Restart MiDa to try again.';

  final File subscriptions;
  final File archive;

  /// True for the temp-folder fallback.
  final bool temporary;
}
