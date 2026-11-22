// SPDX-License-Identifier: GPL-3.0-only
//
// TONE3000's API (v1, https://www.tone3000.com/api): sign in with a code the
// user types on tone3000.com (OAuth device authorization, RFC 8628), list the
// tones the user can reach, and download one A2 capture when asked. Only the
// bounded lists are used; the terms forbid mirroring or caching the catalog.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../net/capped_http.dart';

/// The app's publishable key from tone3000.com/settings: made to be shipped
/// in public apps. A fork sets its own with `--dart-define`; an empty one
/// hides the TONE3000 section.
const String tone3000ClientId = String.fromEnvironment(
  'TONE3000_CLIENT_ID',
  defaultValue: 't3k_pub_9F_hoyHYis1dzT_b3czn2BCcYvcg0lZG',
);

const String _host = 'www.tone3000.com';
const String _base = '/api/v1';

class Tone3000Exception implements Exception {
  const Tone3000Exception(this.message);
  final String message;
  @override
  String toString() => message;
}

/// The saved sign-in is gone or no longer accepted: sign in again.
class Tone3000SignedOut extends Tone3000Exception {
  const Tone3000SignedOut() : super('Sign in to TONE3000 again.');
}

/// What to show while the user approves the sign-in on tone3000.com.
class DeviceLogin {
  const DeviceLogin({
    required this.deviceCode,
    required this.userCode,
    required this.verificationUri,
    required this.verificationUriComplete,
    required this.interval,
    required this.expiresIn,
  });
  final String deviceCode;

  /// `XXXX-XXXX`, typed at [verificationUri].
  final String userCode;
  final String verificationUri;

  /// [verificationUri] with the code already filled in.
  final String verificationUriComplete;
  final Duration interval;
  final Duration expiresIn;
}

/// The lists an independent app may read.
enum ToneList {
  trending('Trending', '/tones/trending'),
  latest('Latest', '/tones/latest'),
  favorited('Favorites', '/tones/favorited'),
  downloaded('Downloaded', '/tones/downloaded'),
  created('Mine', '/tones/created');

  const ToneList(this.label, this.path);
  final String label;
  final String path;

  /// Trending and Latest are the site's own top 10, with no pages.
  bool get paged => index >= favorited.index;
}

class Tone {
  const Tone({
    required this.id,
    required this.title,
    required this.creator,
    required this.avatarUrl,
    this.imageUrl,
    required this.gear,
    required this.format,
    required this.a2Models,
    required this.irs,
    required this.license,
    required this.url,
  });
  final int id;
  final String title;

  /// The creator's display name, or the user name.
  final String creator;
  final String? avatarUrl;

  /// The first picture of the gear, when the creator gave one.
  final String? imageUrl;
  final String gear;
  final String format;

  /// How many A2 captures the tone has; the pedal takes no other kind.
  final int a2Models;

  /// How many IRs the tone has.
  final int irs;
  final String license;
  final String url;

  /// An amp captured with its cabinet (`full-rig` is the old name).
  bool get includesCab => gear == 'amp-cab' || gear == 'full-rig';

  /// The tone has something the pedal takes: an A2 capture, or with [ir]
  /// an IR (any WAV is converted).
  bool fits({required bool ir}) =>
      ir ? format == 'ir' && irs > 0 : format == 'nam' && a2Models > 0;

  static Tone? _from(Object? j) {
    if (j is! Map<String, Object?> || j['id'] is! int) {
      return null;
    }
    final Object? user = j['user'];
    final Map<String, Object?> u = user is Map<String, Object?>
        ? user
        : const <String, Object?>{};
    String text(Object? v) => v is String ? v : '';
    final String name = text(u['display_name']);
    return Tone(
      id: j['id']! as int,
      title: text(j['title']),
      creator: name.isEmpty ? text(u['username']) : name,
      avatarUrl: _https(u['avatar_url']),
      imageUrl:
          j['images'] is List && (j['images']! as List<Object?>).isNotEmpty
          ? _https((j['images']! as List<Object?>).first)
          : null,
      gear: text(j['gear']),
      format: text(j['format']),
      a2Models: j['a2_models_count'] is int ? j['a2_models_count']! as int : 0,
      irs: j['irs_count'] is int ? j['irs_count']! as int : 0,
      license: text(j['license']),
      url: _https(j['url']) ?? '',
    );
  }
}

class TonePage {
  const TonePage(this.tones, {required this.more});
  final List<Tone> tones;

  /// The list has another page after this one.
  final bool more;
}

class ToneModel {
  const ToneModel({
    required this.id,
    required this.name,
    required this.size,
    required this.url,
  });
  final int id;
  final String name;
  final String size;
  final Uri url;

  static ToneModel? _from(Object? j) {
    if (j is! Map<String, Object?> || j['id'] is! int) {
      return null;
    }
    final String? url = _https(j['model_url']);
    if (url == null) {
      return null;
    }
    return ToneModel(
      id: j['id']! as int,
      name: j['name'] is String ? j['name']! as String : 'capture',
      size: j['size'] is String ? j['size']! as String : '',
      url: Uri.parse(url),
    );
  }
}

/// [v] when it is an https address, so nothing the service names is fetched
/// in the clear or from the local machine.
String? _https(Object? v) {
  final Uri? u = v is String ? Uri.tryParse(v) : null;
  return u != null && u.scheme == 'https' && u.host.isNotEmpty
      ? u.toString()
      : null;
}

bool _isTone3000(Uri u) =>
    u.scheme == 'https' &&
    (u.host == 'tone3000.com' || u.host.endsWith('.tone3000.com'));

class Tone3000 {
  Tone3000({
    required this.store,
    this.clientId = tone3000ClientId,
    Future<void> Function(Duration)? wait,
    DateTime Function()? now,
  }) : _wait = wait ?? Future<void>.delayed,
       _now = now ?? DateTime.now;

  /// Where the sign-in is kept, readable only by the user where the system
  /// allows it.
  final File store;
  final String clientId;
  final Future<void> Function(Duration) _wait;
  final DateTime Function() _now;

  String? _access;
  String? _refresh;
  DateTime? _expires;
  bool _loaded = false;

  Future<bool> get signedIn async {
    await _load();
    return _refresh != null || _access != null;
  }

  Future<void> signOut() async {
    _access = _refresh = null;
    _expires = null;
    _loaded = true;
    try {
      await store.delete();
    } on FileSystemException {
      // Nothing saved.
    }
  }

  // --- sign-in ---------------------------------------------------------------

  Future<DeviceLogin> startLogin() async {
    final Map<String, Object?> j = _object(
      await _send(
        http.Request(
          'POST',
          Uri.https(_host, '$_base/oauth/device_authorization'),
        )..bodyFields = <String, String>{'client_id': clientId},
      ),
    );
    final Object? device = j['device_code'], user = j['user_code'];
    final String? uri = _https(j['verification_uri']);
    if (device is! String || user is! String || uri == null) {
      throw const Tone3000Exception('TONE3000 did not start the sign-in.');
    }
    return DeviceLogin(
      deviceCode: device,
      userCode: user,
      verificationUri: uri,
      verificationUriComplete: _https(j['verification_uri_complete']) ?? uri,
      interval: Duration(
        seconds: j['interval'] is int ? j['interval']! as int : 5,
      ),
      expiresIn: Duration(
        seconds: j['expires_in'] is int ? j['expires_in']! as int : 600,
      ),
    );
  }

  /// Waits until the user approves [login] on the site. Throws when it is
  /// refused or expires; returns false when [cancelled] says to stop.
  Future<bool> finishLogin(
    DeviceLogin login, {
    bool Function()? cancelled,
  }) async {
    Duration interval = login.interval;
    final DateTime end = _now().add(login.expiresIn);
    while (_now().isBefore(end)) {
      await _wait(interval);
      if (cancelled?.call() ?? false) {
        return false;
      }
      final (int status, Uint8List body) = await _raw(
        http.Request('POST', Uri.https(_host, '$_base/oauth/token'))
          ..bodyFields = <String, String>{
            'grant_type': 'urn:ietf:params:oauth:grant-type:device_code',
            'device_code': login.deviceCode,
            'client_id': clientId,
          },
      );
      if (status == 200) {
        await _keep(_decode(body));
        return true;
      }
      switch (_error(body)) {
        case 'authorization_pending':
          break;
        case 'slow_down':
          interval += const Duration(seconds: 5);
        case 'access_denied':
          throw const Tone3000Exception('The sign-in was refused on TONE3000.');
        case 'expired_token':
          throw const Tone3000Exception('The code expired. Start again.');
        default:
          throw Tone3000Exception(_failure(status, body));
      }
    }
    throw const Tone3000Exception('The code expired. Start again.');
  }

  // --- catalog ---------------------------------------------------------------

  /// One page of [list]; every tone is returned, see [Tone.fits]. With
  /// [ir], Trending is the cabinets' own.
  Future<TonePage> tones(ToneList list, {int page = 1, bool ir = false}) =>
      _tones(list.path, <String, String>{
        if (list.paged) ...<String, String>{'page': '$page', 'page_size': '25'},
        if (ir && list == ToneList.trending) 'gear': 'cab',
      }, page);

  /// One page of the tones that match [query]: IRs with [ir], A2 NAM
  /// captures otherwise. TONE3000 limits how often this may be asked, so it
  /// runs only when the user submits.
  Future<TonePage> search(String query, {int page = 1, bool ir = false}) =>
      _tones('/tones/search', <String, String>{
        'query': query,
        'format': ir ? 'ir' : 'nam',
        if (!ir) 'architecture': '2',
        'page': '$page',
        'page_size': '25',
      }, page);

  Future<TonePage> _tones(
    String path,
    Map<String, String> query,
    int page,
  ) async {
    final Map<String, Object?> j = _object(await _get(path, query));
    final Object? data = j['data'];
    final Object? pages = j['total_pages'];
    return TonePage(<Tone>[
      if (data is List)
        for (final Object? t in data) ?Tone._from(t),
    ], more: pages is int && page < pages);
  }

  /// The A2 captures of a tone, or with [ir] its IRs, in the creator's
  /// order.
  Future<List<ToneModel>> models(int toneId, {bool ir = false}) async {
    final Object? data = _object(
      await _get('/models', <String, String>{
        'tone_id': '$toneId',
        if (!ir) 'architecture': '2',
        'page_size': '100',
      }),
    )['data'];
    return <ToneModel>[
      if (data is List)
        for (final Object? m in data) ?ToneModel._from(m),
    ];
  }

  /// The file of [model]. An A2 capture with every size is a few hundred KB.
  Future<Uint8List> download(ToneModel model) async {
    await _fresh();
    final http.Request r = http.Request('GET', model.url);
    // The sign-in goes to TONE3000 only, wherever the file itself is kept.
    if (_isTone3000(model.url)) {
      r.headers['authorization'] = 'Bearer $_access';
    }
    final (int status, Uint8List body) = await _raw(r, limit: 16 << 20);
    if (status != 200) {
      throw Tone3000Exception(_failure(status, body));
    }
    return body;
  }

  // --- plumbing --------------------------------------------------------------

  Future<Uint8List> _get(String path, Map<String, String> query) async {
    await _fresh();
    http.Request request() => http.Request(
      'GET',
      Uri.https(_host, '$_base$path', query.isEmpty ? null : query),
    )..headers['authorization'] = 'Bearer $_access';
    (int, Uint8List) r = await _raw(request());
    if (r.$1 == 401 && _refresh != null) {
      await _renew();
      r = await _raw(request());
    }
    if (r.$1 == 401) {
      await signOut();
      throw const Tone3000SignedOut();
    }
    if (r.$1 != 200) {
      throw Tone3000Exception(_failure(r.$1, r.$2));
    }
    return r.$2;
  }

  /// Makes sure there is an access token that has not run out.
  Future<void> _fresh() async {
    await _load();
    if (_access == null && _refresh == null) {
      throw const Tone3000SignedOut();
    }
    final DateTime? e = _expires;
    if (_access == null ||
        (e != null &&
            !_now().isBefore(e.subtract(const Duration(minutes: 1))))) {
      await _renew();
    }
  }

  Future<void> _renew() async {
    final String? refresh = _refresh;
    if (refresh == null) {
      await signOut();
      throw const Tone3000SignedOut();
    }
    final (int status, Uint8List body) = await _raw(
      http.Request('POST', Uri.https(_host, '$_base/oauth/token'))
        ..bodyFields = <String, String>{
          'grant_type': 'refresh_token',
          'refresh_token': refresh,
          'client_id': clientId,
        },
    );
    if (status == 200) {
      await _keep(_decode(body));
    } else if (status == 400 || status == 401) {
      // invalid_grant: the refresh token ran out or was revoked.
      await signOut();
      throw const Tone3000SignedOut();
    } else {
      throw Tone3000Exception(_failure(status, body));
    }
  }

  Future<void> _keep(Object? token) async {
    if (token is! Map<String, Object?> || token['access_token'] is! String) {
      throw const Tone3000Exception('TONE3000 sent no sign-in.');
    }
    _access = token['access_token']! as String;
    // A refresh answer may leave the refresh token out: the old one stays.
    if (token['refresh_token'] is String) {
      _refresh = token['refresh_token']! as String;
    }
    final Object? seconds = token['expires_in'];
    _expires = seconds is int ? _now().add(Duration(seconds: seconds)) : null;
    _loaded = true;
    await _writePrivate(
      store,
      jsonEncode(<String, Object?>{
        'access_token': _access,
        'refresh_token': _refresh,
        'expires': _expires?.toUtc().toIso8601String(),
      }),
    );
  }

  Future<void> _load() async {
    if (_loaded) {
      return;
    }
    _loaded = true;
    try {
      final Object? j = jsonDecode(await store.readAsString());
      if (j is Map<String, Object?>) {
        _access = j['access_token'] as String?;
        _refresh = j['refresh_token'] as String?;
        _expires = DateTime.tryParse(j['expires'] as String? ?? '');
      }
    } catch (_) {
      // No sign-in saved, or a file that cannot be read: signed out.
    }
  }

  Future<Uint8List> _send(http.Request r) async {
    final (int status, Uint8List body) = await _raw(r);
    if (status != 200) {
      throw Tone3000Exception(_failure(status, body));
    }
    return body;
  }

  Future<(int, Uint8List)> _raw(http.Request r, {int limit = 2 << 20}) async {
    try {
      return await sendCapped(r, limit);
    } on TooLarge {
      throw const Tone3000Exception('TONE3000 answered more than expected.');
    } on Exception catch (e) {
      throw Tone3000Exception('Could not reach TONE3000: $e');
    }
  }

  static Object? _decode(Uint8List body) {
    try {
      return jsonDecode(utf8.decode(body));
    } on FormatException {
      return null;
    }
  }

  static Map<String, Object?> _object(Uint8List body) {
    final Object? j = _decode(body);
    if (j is! Map<String, Object?>) {
      throw const Tone3000Exception(
        'TONE3000 sent an answer the app cannot read.',
      );
    }
    return j;
  }

  static String? _error(Uint8List body) {
    final Object? j = _decode(body);
    final Object? e = j is Map<String, Object?> ? j['error'] : null;
    return e is String ? e : null;
  }

  static String _failure(int status, Uint8List body) => switch (status) {
    403 => 'TONE3000 does not let this account see that.',
    404 => 'TONE3000 no longer has that.',
    429 => 'TONE3000 is limiting requests. Try again in a minute.',
    _ =>
      'TONE3000 answered with error $status'
          '${_error(body) == null ? '' : ' (${_error(body)})'}.',
  };
}

/// Writes [text] to [file] so that it is never readable by others, even for
/// a moment: written aside, locked down, then given the real name.
Future<void> _writePrivate(File file, String text) async {
  await file.parent.create(recursive: true);
  final File tmp = File('${file.path}.tmp');
  await tmp.writeAsString('');
  if (Platform.isLinux || Platform.isMacOS) {
    try {
      await Process.run('chmod', <String>['600', tmp.path]);
    } catch (_) {
      // Best effort: the file still works.
    }
  }
  await tmp.writeAsString(text, flush: true);
  await tmp.rename(file.path);
}
