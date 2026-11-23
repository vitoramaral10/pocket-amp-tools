import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_amp_tools/src/presets/preset_meta.dart';
import 'package:pocket_amp_tools/src/private_file.dart';
import 'package:pocket_amp_tools/src/sync/sync_data.dart';

void main() {
  late Directory tmp;
  late SyncData data;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('sync_data_');
    data = SyncData(
      library: Directory('${tmp.path}/Library'),
      backups: tmp,
      details: PresetDetails(),
    );
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  Uint8List j(Object o) => utf8.encode(jsonEncode(o));

  test('keys from another device never point outside the folders', () async {
    for (final String key in <String>[
      'amp/../x.nam',
      'amp/a/b.nam',
      'amp/.nam',
      'amp/x.wav',
      'cab/..\\x.wav',
      'backup/../../etc.json',
      'other/x.json',
      'preset/P81',
    ]) {
      await expectLater(
        data.write(key, j(<String, Object>{})),
        throwsA(isA<FormatException>()),
        reason: key,
      );
    }
  });

  test('links are taken only in the shape the library reads', () async {
    await data.write(
      'links',
      j(<String, Object>{
        'amp': <String, String>{'0': 'ENGL.nam'},
        'cab': <String, String>{'19': 'V30.wav'},
        'ampWithCab': <String>['ENGL.nam'],
      }),
    );
    for (final Object bad in <Object>[
      <Object>[],
      <String, Object>{'amp': <String>[]},
      <String, Object>{
        'amp': <String, String>{'20': 'x.nam'},
      },
      <String, Object>{
        'amp': <String, String>{'00': 'x.nam'},
      },
      <String, Object>{
        'amp': <String, String>{'0': '../x.nam'},
      },
      <String, Object>{
        'cab': <String, String>{'0': 'x.nam'},
      },
      <String, Object>{
        'ampWithCab': <Object>[3],
      },
    ]) {
      await expectLater(
        data.write('links', j(bad)),
        throwsA(isA<FormatException>()),
        reason: jsonEncode(bad),
      );
    }
  });

  test('a private file is owner-only from the start', () async {
    final File f = File('${tmp.path}/secret.json');
    File('${f.path}.tmp').writeAsStringSync('old'); // a leftover, 644
    await writePrivate(f, '{"key": 1}');
    expect(f.readAsStringSync(), '{"key": 1}');
    expect(f.statSync().mode & 0x1FF, 0x180, reason: 'rw-------');
  }, skip: Platform.isWindows);

  test('a rewrite that keeps size and modified time is still seen', () async {
    final File f = File('${tmp.path}/Library/Amps/ENGL.nam')
      ..createSync(recursive: true)
      ..writeAsStringSync('aaaa');
    final String first = (await data.scan())['amp/ENGL.nam']!;
    final DateTime m = f.lastModifiedSync();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    f
      ..writeAsStringSync('bbbb')
      ..setLastModifiedSync(m);
    expect((await data.scan())['amp/ENGL.nam'], isNot(first));
  }, skip: Platform.isWindows);
}
