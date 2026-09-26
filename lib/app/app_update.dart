/// "A newer beta is out": checks the GitHub releases at most once a day, in
/// the foreground, and offers the APK. Best effort and silent: offline, rate
/// limited or malformed answers simply show nothing.
///
/// Installing over the old app needs every build signed with the same key
/// (the release keystore in CI's PM_* secrets); the download is left to the
/// browser and the system installer, so the app needs no install permission.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piedemove/places/photon.dart' show userAgent;

const releasesUrl =
    'https://api.github.com/repos/LucaCraft89/piedemove/releases?per_page=10';
const updateCheckInterval = Duration(days: 1);
const _checkedKey = 'pm.update.checkedAt';
const _cachedKey = 'pm.update.latest';
const _app = MethodChannel('piedemove/app');

@immutable
class AppRelease {
  const AppRelease({required this.version, required this.apkUrl, required this.page});

  /// `0.9.0-beta.8`, without the tag's leading `v`.
  final String version;
  final String apkUrl;
  final String page;

  Map<String, dynamic> toJson() =>
      {'version': version, 'apk': apkUrl, 'page': page};
  static AppRelease fromJson(Map<String, dynamic> j) => AppRelease(
      version: j['version'] as String,
      apkUrl: j['apk'] as String,
      page: j['page'] as String);
}

/// Orders `0.9.0-beta.7` style versions: numbers first, then a release is
/// newer than any pre-release of it, then the pre-release number. A version
/// that does not parse compares as the oldest.
int compareVersions(String a, String b) {
  List<int>? parse(String v) {
    final m = RegExp(r'^v?(\d+)\.(\d+)\.(\d+)(?:-[a-z]+\.?(\d+))?').firstMatch(v);
    if (m == null) return null;
    return [
      int.parse(m[1]!),
      int.parse(m[2]!),
      int.parse(m[3]!),
      // No pre-release suffix: the final release, after every beta.
      m[4] == null ? 1 << 30 : int.parse(m[4]!),
    ];
  }

  final pa = parse(a), pb = parse(b);
  if (pa == null || pb == null) return (pa == null ? 0 : 1) - (pb == null ? 0 : 1);
  for (var i = 0; i < 4; i++) {
    if (pa[i] != pb[i]) return pa[i].compareTo(pb[i]);
  }
  return 0;
}

/// The newest release in a GitHub `/releases` answer that ships an APK.
AppRelease? newestRelease(List<dynamic> releases) {
  AppRelease? best;
  for (final r in releases.whereType<Map>()) {
    if (r['draft'] == true) continue;
    final tag = (r['tag_name'] as String?) ?? '';
    final apk = (r['assets'] as List? ?? const [])
        .whereType<Map>()
        .map((a) => a['browser_download_url'] as String?)
        .whereType<String>()
        .where((u) => u.endsWith('.apk'))
        .firstOrNull;
    if (apk == null) continue;
    final version = tag.startsWith('v') ? tag.substring(1) : tag;
    if (best == null || compareVersions(version, best.version) > 0) {
      best = AppRelease(
          version: version,
          apkUrl: apk,
          page: (r['html_url'] as String?) ?? '');
    }
  }
  return best;
}

/// This build's version name, from the platform; null off Android.
Future<String?> installedVersion() async {
  try {
    return await _app.invokeMethod<String>('version');
  } catch (_) {
    return null;
  }
}

/// Opens [url] in the browser (the APK downloads there). Never throws.
Future<bool> openUrl(String url) async {
  try {
    return await _app.invokeMethod<bool>('openUrl', {'url': url}) ?? false;
  } catch (_) {
    return false;
  }
}

/// The newest release when it is newer than this build, else null. Checks
/// the network at most once per [updateCheckInterval] (the last answer is
/// kept in between); [force] checks now.
Future<AppRelease?> checkForUpdate({
  bool force = false,
  http.Client? client,
  String? current,
  DateTime Function() now = DateTime.now,
}) async {
  final installed = current ?? await installedVersion();
  if (installed == null) return null;
  SharedPreferences? prefs;
  try {
    prefs = await SharedPreferences.getInstance();
  } catch (_) {}
  AppRelease? latest;
  final last = prefs?.getInt(_checkedKey);
  final due = force ||
      last == null ||
      now().millisecondsSinceEpoch - last >= updateCheckInterval.inMilliseconds;
  if (due) {
    final c = client ?? http.Client();
    try {
      final r = await c.get(Uri.parse(releasesUrl), headers: const {
        'User-Agent': userAgent,
        'Accept': 'application/vnd.github+json',
      }).timeout(const Duration(seconds: 15));
      if (r.statusCode == 200) {
        latest = newestRelease(jsonDecode(utf8.decode(r.bodyBytes)) as List);
        await prefs?.setInt(_checkedKey, now().millisecondsSinceEpoch);
        if (latest != null) {
          await prefs?.setString(_cachedKey, jsonEncode(latest.toJson()));
        }
      }
    } catch (e) {
      debugPrint('pm: update check: $e');
    } finally {
      if (client == null) c.close();
    }
  }
  if (latest == null) {
    try {
      final raw = prefs?.getString(_cachedKey);
      if (raw != null) {
        latest = AppRelease.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      }
    } catch (_) {}
  }
  if (latest == null || compareVersions(latest.version, installed) <= 0) {
    return null;
  }
  return latest;
}

/// A newer release, checked once per app start (and daily at most).
final appUpdateProvider =
    FutureProvider<AppRelease?>((ref) => checkForUpdate());

/// The version the user dismissed the chip for; it stays hidden for that one.
final dismissedUpdateProvider = StateProvider<String?>((_) => null);
