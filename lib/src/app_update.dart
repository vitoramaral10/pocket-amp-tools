// SPDX-License-Identifier: GPL-3.0-only
//
// Tells the user when a newer version of this app is out: at most once a
// day, the latest release on GitHub is compared with [appVersion]. Nothing
// about the user is sent; GitHub sees a request from this address, like
// opening the releases page. Builds whose store updates the app (F-Droid)
// turn it off with --dart-define=UPDATE_CHECK=false.

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'app_version.dart';
import 'net/capped_http.dart';

const bool updateCheckBuilt = bool.fromEnvironment(
  'UPDATE_CHECK',
  defaultValue: true,
);

const String _latest =
    'https://api.github.com/repos/vitoramaral10/pocket-amp-tools/releases/latest';
const String releasesPage =
    'https://github.com/vitoramaral10/pocket-amp-tools/releases/latest';

class AppRelease {
  const AppRelease(this.version, this.url);
  final String version;
  final String url;
}

/// The version numbers of [v] ("v1.2.3", "1.2.3+4"); null when it is not
/// one.
List<int>? _numbers(String v) {
  final RegExpMatch? m = RegExp(r'^v?(\d+)\.(\d+)\.(\d+)(?:\+\d+)?$')
      .firstMatch(v.trim());
  return m == null
      ? null
      : <int>[int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!)];
}

/// Whether version [a] is later than [b]; false when either is not a plain
/// x.y.z.
bool isNewer(String a, String b) {
  final List<int>? x = _numbers(a), y = _numbers(b);
  if (x == null || y == null) {
    return false;
  }
  for (int i = 0; i < 3; i++) {
    if (x[i] != y[i]) {
      return x[i] > y[i];
    }
  }
  return false;
}

/// What was checked and what the user said, in a small file of their own.
class AppUpdates {
  AppUpdates(this.file, {this.current = appVersion});

  final File file;
  final String current;

  static const Duration every = Duration(hours: 20);

  Future<Map<String, Object?>> _read() async {
    try {
      final Object? j = jsonDecode(await file.readAsString());
      if (j is Map<String, Object?>) {
        return j;
      }
    } on FileSystemException {
      // first run
    } on FormatException {
      // a broken file: start over
    }
    return <String, Object?>{};
  }

  Future<void> _write(Map<String, Object?> j) async {
    await file.parent.create(recursive: true);
    final File tmp = File('${file.path}.tmp');
    await tmp.writeAsString(jsonEncode(j), flush: true);
    await tmp.rename(file.path);
  }

  /// Whether the user wants to hear of new versions (on unless turned off).
  Future<bool> enabled() async =>
      updateCheckBuilt && (await _read())['check'] != false;

  Future<void> setEnabled(bool on) async =>
      _write(<String, Object?>{...await _read(), 'check': on});

  /// Not to be told of [version] again; a later one is told.
  Future<void> skip(String version) async =>
      _write(<String, Object?>{...await _read(), 'skipped': version});

  /// The newer release to tell the user of, if any. Asks GitHub at most
  /// once every [every]; in between, the last answer is used. Never throws:
  /// no network means nothing to tell.
  Future<AppRelease?> check({DateTime? now}) async {
    final Map<String, Object?> j = await _read();
    if (!updateCheckBuilt || j['check'] == false) {
      return null;
    }
    final DateTime t = now ?? DateTime.now();
    final Object? last = j['lastCheck'];
    final bool fresh =
        last is int &&
        t.difference(DateTime.fromMillisecondsSinceEpoch(last)) < every &&
        !t.isBefore(DateTime.fromMillisecondsSinceEpoch(last));
    if (!fresh) {
      try {
        final (int status, List<int> body) = await sendCapped(
          http.Request('GET', Uri.parse(_latest))
            ..headers['Accept'] = 'application/vnd.github+json',
          256 << 10,
          timeout: const Duration(seconds: 15),
          total: const Duration(seconds: 30),
        );
        final Object? r = status == 200 ? jsonDecode(utf8.decode(body)) : null;
        if (r is Map<String, Object?> &&
            r['tag_name'] is String &&
            _numbers(r['tag_name']! as String) != null) {
          j['latest'] = (r['tag_name']! as String).replaceFirst('v', '');
          final Object? url = r['html_url'];
          j['url'] =
              url is String &&
                  url.startsWith(
                    'https://github.com/vitoramaral10/pocket-amp-tools/',
                  )
              ? url
              : releasesPage;
        }
        j['lastCheck'] = t.millisecondsSinceEpoch;
        await _write(j);
      } on Object {
        return _known(j); // offline or GitHub down: try again next start
      }
    }
    return _known(j);
  }

  AppRelease? _known(Map<String, Object?> j) {
    final Object? v = j['latest'];
    if (v is! String || !isNewer(v, current) || j['skipped'] == v) {
      return null;
    }
    final Object? url = j['url'];
    return AppRelease(v, url is String ? url : releasesPage);
  }
}
