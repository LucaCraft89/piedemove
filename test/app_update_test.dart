// The "newer beta" check: version order, picking the release, once a day.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:piedemove/app/app_update.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> _release(String tag, {bool apk = true, bool draft = false}) => {
      'tag_name': tag,
      'draft': draft,
      'html_url': 'https://github.com/x/releases/tag/$tag',
      'assets': [
        if (apk) {'browser_download_url': 'https://x/$tag/piedemove-$tag.apk'},
        {'browser_download_url': 'https://x/$tag/notes.sha256'},
      ],
    };

void main() {
  test('versions order by number, then beta, and a release beats its betas', () {
    expect(compareVersions('0.9.0-beta.8', '0.9.0-beta.7'), greaterThan(0));
    expect(compareVersions('0.9.0-beta.10', '0.9.0-beta.9'), greaterThan(0));
    expect(compareVersions('0.9.0', '0.9.0-beta.12'), greaterThan(0));
    expect(compareVersions('1.0.0-beta.1', '0.9.0'), greaterThan(0));
    expect(compareVersions('v0.9.0-beta.7', '0.9.0-beta.7'), 0);
    expect(compareVersions('lines-latest', '0.9.0-beta.1'), lessThan(0));
  });

  test('the newest release with an APK; drafts and data tags ignored', () {
    final r = newestRelease([
      _release('lines-latest', apk: false),
      _release('v0.9.0-beta.7'),
      _release('v0.9.0-beta.9', draft: true),
      _release('v0.9.0-beta.8'),
    ])!;
    expect(r.version, '0.9.0-beta.8');
    expect(r.apkUrl, endsWith('.apk'));
  });

  group('check', () {
    var calls = 0;
    http.Client server(List<Map<String, dynamic>> releases) =>
        MockClient((req) async {
          calls++;
          return http.Response(jsonEncode(releases), 200);
        });

    setUp(() {
      calls = 0;
      SharedPreferences.setMockInitialValues({});
    });

    test('offers a newer beta, not the installed one', () async {
      final c = server([_release('v0.9.0-beta.8')]);
      expect((await checkForUpdate(client: c, current: '0.9.0-beta.7'))!
          .version, '0.9.0-beta.8');
      expect(
          await checkForUpdate(
              client: c, current: '0.9.0-beta.8', force: true),
          isNull);
    });

    test('at most once a day; the last answer is kept between', () async {
      final c = server([_release('v0.9.0-beta.8')]);
      final t0 = DateTime(2026, 9, 26, 9);
      await checkForUpdate(client: c, current: '0.9.0-beta.7', now: () => t0);
      final again = await checkForUpdate(
          client: c,
          current: '0.9.0-beta.7',
          now: () => t0.add(const Duration(hours: 3)));
      expect(calls, 1);
      expect(again!.version, '0.9.0-beta.8', reason: 'from the kept answer');
      await checkForUpdate(
          client: c,
          current: '0.9.0-beta.7',
          now: () => t0.add(const Duration(days: 1, minutes: 1)));
      expect(calls, 2);
    });

    test('offline or rate limited: nothing, never a throw', () async {
      final down = MockClient((_) async => throw Exception('offline'));
      expect(await checkForUpdate(client: down, current: '0.9.0-beta.7'),
          isNull);
      final limited = MockClient((_) async => http.Response('{}', 403));
      expect(
          await checkForUpdate(
              client: limited, current: '0.9.0-beta.7', force: true),
          isNull);
    });
  });

  test('a stable install is offered stable releases only', () {
    final releases = [
      {..._release('v0.9.1-beta.1'), 'prerelease': true},
      _release('v0.9.0'),
    ];
    expect(newestRelease(releases)!.version, '0.9.1-beta.1');
    expect(newestRelease(releases, stableOnly: true)!.version, '0.9.0');
    expect(isPrerelease('0.9.0'), isFalse);
    expect(isPrerelease('0.9.0-beta.8'), isTrue);
  });

  test('stable 0.9.0 is newer than every 0.9.0 beta', () {
    expect(compareVersions('0.9.0', '0.9.0-beta.8'), greaterThan(0));
  });
}
