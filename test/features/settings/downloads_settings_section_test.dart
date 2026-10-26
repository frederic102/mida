import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mida/features/settings/settings_service.dart';
import 'package:mida/features/settings/widgets/downloads_settings_section.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('Downloads settings section', () {
    for (final brightness in Brightness.values) {
      testWidgets('toggle defaults on and flips the setting (${brightness.name})', (tester) async {
        final settings = SettingsService();
        await tester.pumpWidget(ChangeNotifierProvider.value(
          value: settings,
          child: MaterialApp(
            theme: ThemeData(useMaterial3: true, brightness: brightness),
            home: const Scaffold(body: DownloadsSettingsSection()),
          ),
        ));
        final toggle = find.byKey(const ValueKey('open-folder-after-download'));
        expect(tester.widget<SwitchListTile>(toggle).value, isTrue);

        await tester.tap(toggle);
        await tester.pump();
        expect(settings.openFolderAfterDownload, isFalse);
        expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
      });
    }
  });

  group('openFolderAfterDownload persistence', () {
    test('defaults to on when nothing is stored', () async {
      // A stored folder keeps init() from creating the real default one.
      SharedPreferences.setMockInitialValues({'download_path': 'C:/Out'});
      final settings = SettingsService();
      await settings.init();
      expect(settings.openFolderAfterDownload, isTrue);
    });

    test('a change survives a restart (new SettingsService, same store)', () async {
      SharedPreferences.setMockInitialValues({'download_path': 'C:/Out'});
      final first = SettingsService();
      await first.init();
      await first.setOpenFolderAfterDownload(false);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(SettingsService.keyOpenFolderAfterDownload), isFalse);

      final second = SettingsService();
      await second.init();
      expect(second.openFolderAfterDownload, isFalse);
    });
  });
}
