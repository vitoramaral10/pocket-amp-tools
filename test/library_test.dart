import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_amp_tools/src/library/library.dart';
import 'package:pocket_amp_tools/src/presets/ir_upload.dart';
import 'package:pocket_amp_tools/src/presets/nam_file.dart';

import 'ir_upload_test.dart' show wav;

void main() {
  late Directory tmp;
  late Library lib;
  final Uint8List nam = File('test/fixtures/a2_lite_synthetic.nam')
      .readAsBytesSync();

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('library_');
    lib = Library(Directory('${tmp.path}/Library'));
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  test('imports only what the pedal can take, without clobbering', () async {
    final LibraryItem a = await lib.import(LibraryKind.amp, 'ENGL.nam', nam);
    final LibraryItem b = await lib.import(LibraryKind.amp, 'ENGL.nam', nam);
    expect(<String>[a.name, b.name], <String>['ENGL', 'ENGL (2)']);
    await lib.import(LibraryKind.cab, 'Martin/HD28?.wav', wav());
    expect(
      (await lib.list(LibraryKind.cab)).single.name,
      'Martin_HD28_',
      reason: 'no path separators or reserved characters in the name',
    );
    await expectLater(
      lib.import(LibraryKind.amp, 'x.nam', Uint8List.fromList('{}'.codeUnits)),
      throwsA(isA<InvalidNamFile>()),
    );
    await expectLater(
      lib.import(LibraryKind.cab, 'x.wav', wav(bits: 16)),
      throwsA(isA<InvalidIrFile>()),
    );
    expect(await lib.list(LibraryKind.amp), hasLength(2));
  });

  test('links follow renames and go away with the file', () async {
    final LibraryItem a = await lib.import(LibraryKind.amp, 'ENGL.nam', nam);
    await lib.link(LibraryKind.amp, 19, a);
    expect(await lib.links(LibraryKind.amp), <int, String>{19: 'ENGL'});
    expect(await lib.links(LibraryKind.cab), isEmpty);

    final LibraryItem r = await lib.rename(a, 'ENGL Lead');
    expect(await lib.links(LibraryKind.amp), <int, String>{19: 'ENGL Lead'});
    final LibraryItem other = await lib.import(LibraryKind.amp, 'B.nam', nam);
    await expectLater(
      lib.rename(other, 'ENGL Lead'),
      throwsA(isA<LibraryException>()),
    );

    await lib.delete(r);
    expect(await lib.links(LibraryKind.amp), isEmpty);
  });
}
