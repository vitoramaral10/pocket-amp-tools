// SPDX-License-Identifier: GPL-3.0-only

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pocket_amp_tools/src/tone3000/tone3000.dart';

http.Response _json(Object? body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: <String, String>{'content-type': 'application/json'},
);

Map<String, Object?> _token(String access, {String? refresh = 'r1'}) =>
    <String, Object?>{
      'access_token': access,
      'refresh_token': ?refresh,
      'token_type': 'bearer',
      'expires_in': 3600,
    };

void main() {
  late Directory dir;
  late File store;
  DateTime now = DateTime.utc(2026, 11, 22);

  Tone3000 client() => Tone3000(
    store: store,
    clientId: 'pk',
    wait: (Duration d) async => now = now.add(d),
    now: () => now,
  );

  Future<void> signIn(String access, {DateTime? expires}) =>
      store.writeAsString(
        jsonEncode(<String, Object?>{
          'access_token': access,
          'refresh_token': 'r1',
          'expires': (expires ?? now.add(const Duration(hours: 1)))
              .toIso8601String(),
        }),
      );

  setUp(() async {
    now = DateTime.utc(2026, 11, 22);
    dir = await Directory.systemTemp.createTemp('t3k');
    store = File('${dir.path}/tone3000.json');
  });
  tearDown(() => dir.delete(recursive: true));

  test('signs in with a device code, waiting longer when told to', () async {
    final List<Duration> waits = <Duration>[];
    final List<String> answers = <String>[
      'authorization_pending',
      'slow_down',
      'authorization_pending',
    ];
    final Tone3000 t = Tone3000(
      store: store,
      clientId: 'pk',
      wait: (Duration d) async {
        waits.add(d);
        now = now.add(d);
      },
      now: () => now,
    );
    await http.runWithClient(
      () async {
        final DeviceLogin login = await t.startLogin();
        expect(login.userCode, 'ABCD-EFGH');
        expect(login.verificationUriComplete, contains('ABCD-EFGH'));
        expect(await t.finishLogin(login), isTrue);
      },
      () => MockClient((http.Request r) async {
        expect(r.url.host, 'www.tone3000.com');
        expect(r.bodyFields['client_id'], 'pk');
        if (r.url.path.endsWith('/oauth/device_authorization')) {
          return _json(<String, Object?>{
            'device_code': 'dev',
            'user_code': 'ABCD-EFGH',
            'verification_uri': 'https://www.tone3000.com/activate',
            'verification_uri_complete':
                'https://www.tone3000.com/activate?user_code=ABCD-EFGH',
            'expires_in': 600,
            'interval': 5,
          });
        }
        expect(r.bodyFields['device_code'], 'dev');
        return answers.isEmpty
            ? _json(_token('a1'))
            : _json(<String, Object?>{'error': answers.removeAt(0)}, 400);
      }),
    );
    expect(waits.map((Duration d) => d.inSeconds), <int>[5, 5, 10, 10]);
    expect(await client().signedIn, isTrue, reason: 'kept across restarts');
    if (!Platform.isWindows) {
      expect(store.statSync().modeString(), 'rw-------');
    }
  });

  test('a refused or cancelled sign-in keeps nothing', () async {
    final Tone3000 t = client();
    const DeviceLogin login = DeviceLogin(
      deviceCode: 'dev',
      userCode: 'A',
      verificationUri: 'https://www.tone3000.com/activate',
      verificationUriComplete: 'https://www.tone3000.com/activate',
      interval: Duration(seconds: 5),
      expiresIn: Duration(seconds: 600),
    );
    await http.runWithClient(
      () async {
        await expectLater(
          t.finishLogin(login),
          throwsA(
            isA<Tone3000Exception>().having(
              (Tone3000Exception e) => e.message,
              'message',
              contains('refused'),
            ),
          ),
        );
        expect(await t.finishLogin(login, cancelled: () => true), isFalse);
      },
      () => MockClient(
        (_) async => _json(<String, Object?>{'error': 'access_denied'}, 400),
      ),
    );
    expect(await t.signedIn, isFalse);
  });

  test('a code nobody approves expires', () async {
    await http.runWithClient(
      () => expectLater(
        client().finishLogin(
          const DeviceLogin(
            deviceCode: 'dev',
            userCode: 'A',
            verificationUri: 'https://www.tone3000.com/activate',
            verificationUriComplete: 'https://www.tone3000.com/activate',
            interval: Duration(seconds: 5),
            expiresIn: Duration(seconds: 12),
          ),
        ),
        throwsA(isA<Tone3000Exception>()),
      ),
      () => MockClient(
        (_) async =>
            _json(<String, Object?>{'error': 'authorization_pending'}, 400),
      ),
    );
  });

  test('lists tones and tells which the pedal can take', () async {
    await signIn('a1');
    late Uri asked;
    final TonePage page = await http.runWithClient(
      () => client().tones(ToneList.favorited, page: 2),
      () => MockClient((http.Request r) async {
        asked = r.url;
        expect(r.headers['authorization'], 'Bearer a1');
        return _json(<String, Object?>{
          'data': <Object?>[
            <String, Object?>{
              'id': 7,
              'title': 'Plexi crunch',
              'gear': 'amp',
              'format': 'nam',
              'a2_models_count': 3,
              'license': 'cc-by',
              'url': 'https://www.tone3000.com/tones/plexi-7',
              'user': <String, Object?>{
                'username': 'someone',
                'display_name': null,
                'avatar_url': 'https://cdn.example/a.png',
              },
            },
            <String, Object?>{
              'id': 8,
              'title': 'Old capture',
              'gear': 'amp',
              'format': 'nam',
              'a2_models_count': 0,
              'user': <String, Object?>{
                'username': 'u',
                'display_name': 'Verified Name',
                'avatar_url': 'http://insecure.example/a.png',
              },
            },
            <String, Object?>{
              'id': 9,
              'title': 'A cab',
              'format': 'ir',
              'irs_count': 4,
            },
            'not a tone',
          ],
          'page': 2,
          'page_size': 25,
          'total': 60,
          'total_pages': 3,
        });
      }),
    );
    expect(asked.path, '/api/v1/tones/favorited');
    expect(asked.queryParameters, <String, String>{
      'page': '2',
      'page_size': '25',
    });
    expect(page.more, isTrue);
    expect(page.tones.map((Tone t) => t.fits(ir: false)), <bool>[
      true,
      false,
      false,
    ]);
    expect(page.tones.map((Tone t) => t.fits(ir: true)), <bool>[
      false,
      false,
      true,
    ]);
    expect(page.tones[0].creator, 'someone');
    expect(page.tones[0].avatarUrl, 'https://cdn.example/a.png');
    expect(page.tones[1].creator, 'Verified Name');
    expect(page.tones[1].avatarUrl, isNull, reason: 'not https');
  });

  test('the top-10 lists are asked without pages', () async {
    await signIn('a1');
    late Uri asked;
    final TonePage page = await http.runWithClient(
      () => client().tones(ToneList.trending),
      () => MockClient((http.Request r) async {
        asked = r.url;
        return _json(<String, Object?>{'data': <Object?>[]});
      }),
    );
    expect(asked.path, '/api/v1/tones/trending');
    expect(asked.hasQuery, isFalse);
    expect(page.more, isFalse);
  });

  test('searches the catalog for A2 NAM tones only', () async {
    await signIn('a1');
    late Uri asked;
    final TonePage page = await http.runWithClient(
      () => client().search('jcm 800', page: 3),
      () => MockClient((http.Request r) async {
        asked = r.url;
        return _json(<String, Object?>{
          'data': <Object?>[
            <String, Object?>{
              'id': 1,
              'title': 'JCM800',
              'format': 'nam',
              'a2_models_count': 1,
            },
          ],
          'total_pages': 3,
        });
      }),
    );
    expect(asked.path, '/api/v1/tones/search');
    expect(asked.queryParameters, <String, String>{
      'query': 'jcm 800',
      'format': 'nam',
      'architecture': '2',
      'page': '3',
      'page_size': '25',
    });
    expect(page.tones.single.title, 'JCM800');
    expect(page.more, isFalse);
  });

  test('in IR mode it asks for IRs, cabinets and every model', () async {
    await signIn('a1');
    final List<Uri> asked = <Uri>[];
    await http.runWithClient(
      () async {
        final Tone3000 t = client();
        await t.tones(ToneList.trending, ir: true);
        await t.tones(ToneList.latest, ir: true);
        await t.search('v30', ir: true);
        await t.models(9, ir: true);
      },
      () => MockClient((http.Request r) async {
        asked.add(r.url);
        return _json(<String, Object?>{'data': <Object?>[]});
      }),
    );
    expect(asked.map((Uri u) => u.queryParameters), <Map<String, String>>[
      <String, String>{'gear': 'cab'},
      <String, String>{},
      <String, String>{
        'query': 'v30',
        'format': 'ir',
        'page': '1',
        'page_size': '25',
      },
      <String, String>{'tone_id': '9', 'page_size': '100'},
    ]);
  });

  test('renews an access token that ran out, before and after a 401', () async {
    await signIn('old', expires: now.subtract(const Duration(minutes: 5)));
    final List<String> calls = <String>[];
    int renewals = 0;
    await http.runWithClient(
      () async {
        final Tone3000 t = client();
        await t.tones(ToneList.latest); // expired by the clock
        await t.tones(ToneList.latest); // refused by the server
      },
      () => MockClient((http.Request r) async {
        if (r.url.path.endsWith('/oauth/token')) {
          expect(r.bodyFields['grant_type'], 'refresh_token');
          expect(r.bodyFields['refresh_token'], 'r1');
          // The second answer leaves the refresh token out.
          return _json(
            _token('new${++renewals}', refresh: renewals == 1 ? 'r1' : null),
          );
        }
        calls.add(r.headers['authorization']!);
        return calls.length == 2
            ? _json(<String, Object?>{'error': 'unauthorized'}, 401)
            : _json(<String, Object?>{'data': <Object?>[]});
      }),
    );
    expect(calls, <String>['Bearer new1', 'Bearer new1', 'Bearer new2']);
    expect(await client().signedIn, isTrue);
  });

  test('a refresh token that ran out signs the user out', () async {
    await signIn('old', expires: now.subtract(const Duration(minutes: 5)));
    final Tone3000 t = client();
    await http.runWithClient(
      () => expectLater(
        t.tones(ToneList.latest),
        throwsA(isA<Tone3000SignedOut>()),
      ),
      () => MockClient(
        (_) async => _json(<String, Object?>{'error': 'invalid_grant'}, 400),
      ),
    );
    expect(await t.signedIn, isFalse);
    expect(store.existsSync(), isFalse);
  });

  test('without a sign-in nothing is asked', () async {
    await http.runWithClient(
      () => expectLater(client().models(1), throwsA(isA<Tone3000SignedOut>())),
      () => MockClient((_) async => fail('asked the service')),
    );
  });

  test('lists the A2 captures of a tone and downloads one', () async {
    await signIn('a1');
    final List<http.Request> seen = <http.Request>[];
    await http.runWithClient(
      () async {
        final Tone3000 t = client();
        final List<ToneModel> models = await t.models(7);
        expect(models.map((ToneModel m) => m.name), <String>['Clean', 'Lead']);
        expect(await t.download(models[0]), utf8.encode('{"a":1}'));
        expect(await t.download(models[1]), utf8.encode('{"b":2}'));
      },
      () => MockClient((http.Request r) async {
        seen.add(r);
        if (r.url.path == '/api/v1/models') {
          expect(r.url.queryParameters['tone_id'], '7');
          expect(r.url.queryParameters['architecture'], '2');
          return _json(<String, Object?>{
            'data': <Object?>[
              <String, Object?>{
                'id': 1,
                'name': 'Clean',
                'size': 'standard',
                'model_url': 'https://www.tone3000.com/api/v1/models/1/file',
              },
              <String, Object?>{
                'id': 2,
                'name': 'Lead',
                'size': 'standard',
                'model_url': 'https://files.example/lead.nam',
              },
              <String, Object?>{
                'id': 3,
                'name': 'In the clear',
                'model_url': 'http://www.tone3000.com/x.nam',
              },
            ],
          });
        }
        return http.Response(
          r.url.host == 'files.example' ? '{"b":2}' : '{"a":1}',
          200,
        );
      }),
    );
    expect(seen[1].headers['authorization'], 'Bearer a1');
    expect(
      seen[2].headers.containsKey('authorization'),
      isFalse,
      reason: 'the sign-in is not sent to another host',
    );
  });

  test('says when the service limits requests', () async {
    await signIn('a1');
    await http.runWithClient(
      () => expectLater(
        client().tones(ToneList.trending),
        throwsA(
          isA<Tone3000Exception>().having(
            (Tone3000Exception e) => e.message,
            'message',
            contains('limiting'),
          ),
        ),
      ),
      () => MockClient((_) async => http.Response('', 429)),
    );
  });
}
