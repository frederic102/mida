import 'package:flutter_test/flutter_test.dart';
import 'package:mida/features/settings/settings_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  // A stored folder keeps init() from creating the real default one.
  Future<SettingsService> started(Map<String, Object> stored) async {
    SharedPreferences.setMockInitialValues({'download_path': 'C:/Out', ...stored});
    final settings = SettingsService();
    await settings.init();
    return settings;
  }

  test('the interval defaults to 60 minutes', () async {
    expect((await started({})).subscriptionIntervalMinutes, 60);
  });

  test('a change is stored and survives a restart', () async {
    final first = await started({});
    await first.setSubscriptionIntervalMinutes(120);
    expect((await SharedPreferences.getInstance()).getInt(SettingsService.keySubscriptionInterval), 120);
    expect((await started({SettingsService.keySubscriptionInterval: 120})).subscriptionIntervalMinutes, 120);
  });

  test('nothing above 24 hours is accepted, when set or when read back', () async {
    final settings = await started({});
    await settings.setSubscriptionIntervalMinutes(1440);
    expect(settings.subscriptionIntervalMinutes, 1440);
    await settings.setSubscriptionIntervalMinutes(1441);
    expect(settings.subscriptionIntervalMinutes, 1440);
    await settings.setSubscriptionIntervalMinutes(1 << 40);
    expect(settings.subscriptionIntervalMinutes, 1440);
    expect((await SharedPreferences.getInstance()).getInt(SettingsService.keySubscriptionInterval), 1440);
    expect((await started({SettingsService.keySubscriptionInterval: 1441})).subscriptionIntervalMinutes, 1440);
    expect((await started({SettingsService.keySubscriptionInterval: 5000000})).subscriptionIntervalMinutes, 1440);
  });

  test('nothing below 15 minutes is accepted, when set or when read back', () async {
    final settings = await started({});
    await settings.setSubscriptionIntervalMinutes(1);
    expect(settings.subscriptionIntervalMinutes, 15);
    expect((await SharedPreferences.getInstance()).getInt(SettingsService.keySubscriptionInterval), 15);
    expect((await started({SettingsService.keySubscriptionInterval: 0})).subscriptionIntervalMinutes, 15);
  });
}
