import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_amp_tools/src/firmware_package.dart';
import 'package:pocket_amp_tools/src/midi/midi_backend.dart';
import 'package:pocket_amp_tools/src/ota_protocol.dart';
import 'package:pocket_amp_tools/src/pedal_updater.dart';
import 'package:pocket_amp_tools/src/presets/preset_service.dart';

import 'support/fake_pedal.dart';

const UpdateTimings fast = UpdateTimings(
  identityTimeout: Duration(milliseconds: 100),
  loaderIdle: Duration(milliseconds: 400),
  flashIdle: Duration(milliseconds: 400),
  minPhaseTotal: Duration(seconds: 5),
  afterSuccess: Duration(milliseconds: 50),
  waitLoader: Duration(seconds: 3),
  waitReboot: Duration(seconds: 3),
  rescanEvery: Duration(milliseconds: 20),
);

void main() {
  group('protocol', () {
    test('frame round-trips through parse', () {
      final List<int> payload = List<int>.generate(
        520,
        (int i) => (i * 31) & 0xFF,
      );
      final OtaMessage m = parseFrame(buildFrame(0x30, payload))!;
      expect(m.command, 0x30);
      expect(m.payload, payload.map((int b) => b & 0xFF).toList());
    });

    test('identity request matches the bytes the Python tool sent', () {
      // python3 -c 'from ota_pocket_amp import frame; print(frame(0x11).hex())'
      expect(
        buildFrame(cmdIdentity)
            .map((int b) => b.toRadixString(16).padLeft(2, '0'))
            .join(),
        'f0003245000000407ff7',
      );
    });

    test('data reply matches the bytes the Python tool sent', () {
      final List<int> payload = <int>[
        7, 0, 0x10, 0, 0, 0, 2, 0, //
        ...List<int>.generate(32, (int i) => 200 + i),
      ];
      expect(
        buildFrame(
          cmdData,
          payload,
        ).map((int b) => b.toRadixString(16).padLeft(2, '0')).join(),
        'f00032414102004003002000000040000048132b5e4c3933674f2147163d1a756a'
        '562f634e2d7b366e5d3d7f061e5c7871644b1b3f6e1ef7',
      );
    });

    test('parse rejects a bad checksum', () {
      final Uint8List f = buildFrame(0x11, <int>[1, 2, 3]);
      f[f.length - 3] ^= 1;
      expect(parseFrame(f), isNull);
    });

    test('splitter reassembles SysEx split across chunks', () {
      final SysexSplitter s = SysexSplitter();
      final Uint8List f = buildFrame(0x11, List<int>.filled(40, 65));
      expect(s.add(<int>[0x90, 0x40, ...f.sublist(0, 10)]), isEmpty);
      final List<Uint8List> out = s.add(<int>[...f.sublist(10), 0xF8]);
      expect(out.single, f);
    });
  });

  group('package', () {
    final Uint8List loader = Uint8List.fromList(
      List<int>.generate(19969, (int i) => i % 251),
    );

    test('a PIXIE1 is a Pocket AMP under another name', () {
      expect(familyOf('PIXIE1_007'), 'Pocket AMP');
      expect(familyOf('ota-PIXIE1_007'), 'Pocket AMP');
      expect(rebrandOf('PIXIE1_007'), 'PIXIE1');
      expect(rebrandOf('Pocket AMP_105'), isNull);
      expect(familyOf('FM-1_015'), 'FM-1');
    });

    test('an SK17 is a Pocket AMP under another name', () {
      expect(familyOf('SK17_006'), 'Pocket AMP');
      expect(familyOf('ota-SK17_006'), 'Pocket AMP');
      expect(rebrandOf('SK17_006'), 'SK17');
    });

    test('a Donner Pocket AMP is a Pocket AMP under another name', () {
      expect(familyOf('DONNER Pocket AMP_008'), 'Pocket AMP');
      expect(familyOf('ota-DONNER Pocket AMP_008'), 'Pocket AMP');
      expect(rebrandOf('DONNER Pocket AMP_008'), 'DONNER Pocket AMP');
      expect(versionOf('DONNER Pocket AMP_008'), '0.08');
    });

    test('a raw copy keeps the identity its file name was made from', () {
      // keepRaw writes `DONNER Pocket AMP_008` as `DONNER_Pocket_AMP_008`.
      final String? id = PresetService.rawIdentity(
        'raw-DONNER_Pocket_AMP_008-2026-11-10T205326.bin',
      );
      expect(id, 'DONNER Pocket AMP_008');
      expect(familyOf(id!), 'Pocket AMP');
      expect(
        PresetService.rawIdentity('raw-PIXIE1_007-2026-11-09T222607.bin'),
        'PIXIE1_007',
      );
      expect(PresetService.rawIdentity('backup.bin'), isNull);
    });

    test('parses a synthetic package', () {
      final FirmwarePackage p = FirmwarePackage.parse(
        buildFwsc(loader: loader),
      );
      expect(p.product, 'Pocket AMP_105');
      expect(p.version, '1.05');
      expect(p.productFamily, 'Pocket AMP');
      expect(p.entries.map((FirmwareEntry e) => e.name), <String>[
        'flash.bin',
        'ota.bin',
      ]);
      expect(p.hasKnownLoader, isFalse);
    });

    test('rejects a corrupted package', () {
      final Uint8List raw = buildFwsc(loader: loader);
      raw[2000] ^= 0xFF;
      expect(
        () => FirmwarePackage.parse(raw),
        throwsA(isA<FirmwareFormatException>()),
      );
    });

    final File official = File(Platform.environment['POCKET_AMP_FWSC'] ?? '');
    test('reads the official V1.05 package', () {
      final FirmwarePackage p = FirmwarePackage.parse(
        official.readAsBytesSync(),
      );
      expect(p.product, 'Pocket AMP_105');
      expect(p.hasKnownLoader, isTrue);
      expect(
        p.sha256,
        '9584e81da98215e8e70ddffc28311423ceaa1a5a8a12a478dc68f4679e10902b',
      );
    }, skip: official.existsSync() ? false : 'official package not available');
  });

  group('update', () {
    final Uint8List loader = Uint8List.fromList(
      List<int>.generate(4000, (int i) => i % 13),
    );
    final FirmwarePackage pkg = FirmwarePackage.parse(
      buildFwsc(loader: loader),
    );
    final Set<String> trusted = <String>{pkg.loaderSha256};

    PedalUpdater updater(FakePedal pedal, [List<String>? log]) => PedalUpdater(
      pedal,
      timings: fast,
      trustedLoaders: trusted,
      log: log?.add,
    );

    test('a package the app does not know has no official name', () {
      expect(pkg.officialName, isNull);
      expect(
        officialPackages.keys,
        contains(
          '9584e81da98215e8e70ddffc28311423ceaa1a5a8a12a478dc68f4679e10902b',
        ),
      );
    });

    test('a clone vendor package is refused', () {
      final FirmwarePackage sk = FirmwarePackage.parse(
        buildFwsc(product: 'SK17_007', loader: loader),
      );
      expect(sk.isSupportedProduct, isFalse);
      expect(
        updater(FakePedal(image: sk.image)).blockers(
          sk,
          const DetectedPedal(
            MidiPortRef(id: 'pedal', name: 'Pocket AMP'),
            'Pocket AMP_103',
          ),
        ),
        isNotEmpty,
      );
    });

    test('update refuses a pedal other than the one confirmed', () async {
      final FakePedal pedal = FakePedal(image: pkg.image, identity: 'SK17_006');
      await expectLater(
        updater(pedal).update(
          pkg,
          const DetectedPedal(
            MidiPortRef(id: 'pedal', name: 'Pocket AMP'),
            'Pocket AMP_103',
          ),
          (_) {},
        ),
        throwsA(isA<UpdateException>()),
      );
      expect(pedal.arms, 0);
    });

    test('nothing starts while another pedal is plugged in', () async {
      final FakePedal a = FakePedal(
        image: pkg.image,
        rebootDelay: const Duration(milliseconds: 600),
      );
      final FakePedal b = FakePedal(
        image: pkg.image,
        identity: 'Pocket AMP_105',
      );
      final PedalUpdater up = PedalUpdater(
        _Two(a, b),
        timings: fast,
        trustedLoaders: trusted,
      );
      // Port ids can move between pedals while one reboots: refuse.
      await expectLater(
        up.update(pkg, DetectedPedal(a.port, 'Pocket AMP_103'), (_) {}),
        throwsA(
          isA<UpdateException>().having(
            (UpdateException e) => e.message,
            'message',
            contains('Another pedal'),
          ),
        ),
      );
      expect(a.arms, 0);
      expect(b.arms, 0);
    });

    test('serves both phases and resumes on the rebooted port', () async {
      final FakePedal pedal = FakePedal(image: pkg.image);
      final PedalUpdater up = updater(pedal);

      final DetectedPedal found = (await up.detect())!;
      expect(found.identity, 'Pocket AMP_103');
      expect(
        pedal.sentToBystanders,
        isEmpty,
        reason: 'pedal port is probed first',
      );

      final List<UpdatePhase> phases = <UpdatePhase>[];
      final String result = await up.update(pkg, found, (UpdateProgress p) {
        if (phases.isEmpty || phases.last != p.phase) {
          phases.add(p.phase);
        }
      });

      expect(result, 'Pocket AMP_105');
      expect(
        pedal.sentToBystanders,
        isEmpty,
        reason: 'only the pedal is probed while waiting',
      );
      expect(pedal.arms, 2);
      expect(pedal.loaderReceived, pkg.image);
      expect(pedal.flashReceived, pkg.image);
      expect(phases, <UpdatePhase>[
        UpdatePhase.preparing,
        UpdatePhase.loader,
        UpdatePhase.waitingLoader,
        UpdatePhase.flash,
        UpdatePhase.rebooting,
        UpdatePhase.done,
      ]);
    });

    test('finds the pedal again when its port has a generic name (Donner on Windows)', () async {
      final FakePedal pedal = FakePedal(
        image: pkg.image,
        identity: 'DONNER Pocket AMP_008',
        portName: 'USB-MIDI',
      );
      final PedalUpdater up = updater(pedal);
      final DetectedPedal found = (await up.detect())!;
      expect(found.identity, 'DONNER Pocket AMP_008');
      // Detection asks every port; only the update must leave others alone.
      pedal.sentToBystanders.clear();
      expect(await up.update(pkg, found, (_) {}), 'Pocket AMP_105');
      expect(pedal.arms, 2);
      expect(pedal.flashReceived, pkg.image);
      expect(pedal.sentToBystanders, isEmpty);
    });

    test(
      'resumes a Donner pedal left in update mode under a generic port name',
      () async {
        final FakePedal pedal = FakePedal(
          image: pkg.image,
          identity: 'ota-DONNER Pocket AMP_008',
          portName: 'USB-MIDI',
        );
        final PedalUpdater up = updater(pedal);
        final DetectedPedal found = (await up.detect())!;
        expect(found.inLoader, isTrue);
        expect(await up.update(pkg, found, (_) {}), 'Pocket AMP_105');
        expect(pedal.arms, 1);
      },
    );

    test(
      'a pedal left in update mode goes straight to the flash phase',
      () async {
        final FakePedal pedal = FakePedal(
          image: pkg.image,
          identity: 'ota-Pocket AMP_103',
        );
        final PedalUpdater up = updater(pedal);
        final DetectedPedal found = (await up.detect())!;
        expect(found.inLoader, isTrue);
        expect(await up.update(pkg, found, (_) {}), 'Pocket AMP_105');
        expect(pedal.arms, 1);
        expect(pedal.loaderReceived, isNull);
      },
    );

    test('a pedal that stops asking for data fails the update', () async {
      final FakePedal pedal = FakePedal(image: pkg.image, stallInFlash: true);
      final PedalUpdater up = updater(pedal);
      final DetectedPedal found = (await up.detect())!;
      await expectLater(
        up.update(pkg, found, (_) {}),
        throwsA(isA<UpdateException>()),
      );
    });

    test('a pedal that declines in the loader phase says so', () async {
      final FakePedal pedal = FakePedal(image: pkg.image, stallInLoader: true);
      final PedalUpdater up = updater(pedal);
      final DetectedPedal found = (await up.detect())!;
      await expectLater(
        up.update(pkg, found, (_) {}),
        throwsA(
          isA<UpdateException>().having(
            (UpdateException e) => e.message,
            'message',
            contains('already runs this version'),
          ),
        ),
      );
    });

    test(
      'a pedal that comes back on another version fails the update',
      () async {
        final FakePedal pedal = FakePedal(
          image: pkg.image,
          newIdentity: 'Pocket AMP_103',
        );
        final PedalUpdater up = updater(pedal);
        final DetectedPedal found = (await up.detect())!;
        await expectLater(
          up.update(pkg, found, (_) {}),
          throwsA(isA<UpdateException>()),
        );
      },
    );

    test('an untrusted loader is refused before anything is sent', () async {
      final FakePedal pedal = FakePedal(image: pkg.image);
      final PedalUpdater up = PedalUpdater(pedal, timings: fast);
      final DetectedPedal found = (await up.detect())!;
      await expectLater(
        up.update(pkg, found, (_) {}),
        throwsA(isA<UpdateException>()),
      );
      expect(pedal.arms, 0);
    });

    test('a PIXIE1 is updated as a Pocket AMP', () async {
      final FakePedal pedal = FakePedal(
        image: pkg.image,
        identity: 'PIXIE1_007',
      );
      final PedalUpdater up = updater(pedal);
      final DetectedPedal found = (await up.detect())!;
      expect(found.family, 'Pocket AMP');
      expect(found.rebrand, 'PIXIE1');
      expect(up.blockers(pkg, found), isEmpty);
      expect(await up.update(pkg, found, (_) {}), 'Pocket AMP_105');
      expect(pedal.flashReceived, pkg.image);
    });

    test('an SK17 goes through a loader that keeps its own name', () async {
      final FakePedal pedal = FakePedal(image: pkg.image, identity: 'SK17_006');
      final List<String> log = <String>[];
      final PedalUpdater up = updater(pedal, log);
      final DetectedPedal found = (await up.detect())!;
      expect(found.rebrand, 'SK17');
      expect(up.blockers(pkg, found), isEmpty);
      expect(await up.update(pkg, found, (_) {}), 'Pocket AMP_105');
      expect(log, contains(contains('Found "ota-SK17_006"')));
      expect(pedal.loaderReceived, pkg.image);
      expect(pedal.flashReceived, pkg.image);
    });

    test("Donner's own package is refused, even for a Donner pedal", () {
      // Its real format: a 36-slot product name, which this parser does not
      // read, so it never gets as far as the product check.
      expect(
        () => FirmwarePackage.parse(
          buildFwsc(
            product: 'DONNER Pocket AMP_008',
            nameSlots: 36,
            loader: loader,
          ),
        ),
        throwsA(isA<FirmwareFormatException>()),
      );
    });

    test(
      'a package named like update mode, or with no version, is refused',
      () {
        for (final String name in <String>[
          'ota-Pocket AMP_105',
          'Pocket AMP',
        ]) {
          expect(
            FirmwarePackage.parse(buildFwsc(product: name, loader: loader))
                .isSupportedProduct,
            isFalse,
            reason: name,
          );
        }
      },
    );

    test('the flash goes only to the pedal that ran the loader', () async {
      final FakePedal a = FakePedal(
        image: pkg.image,
        rebootDelay: const Duration(milliseconds: 600),
      );
      // Appears only once the update started, already in update mode.
      final FakePedal c = FakePedal(
        image: pkg.image,
        identity: 'ota-PIXIE1_007',
      );
      final String result = await PedalUpdater(
        _Late(a, c),
        timings: fast,
        trustedLoaders: trusted,
      ).update(pkg, DetectedPedal(a.port, 'Pocket AMP_103'), (_) {});
      expect(result, 'Pocket AMP_105');
      expect(c.flashReceived, isNull);
      expect(a.flashReceived, pkg.image);
    });

    test('a Donner Pocket AMP is detected and takes the update', () async {
      final FakePedal pedal = FakePedal(
        image: pkg.image,
        identity: 'DONNER Pocket AMP_008',
      );
      final PedalUpdater up = updater(pedal);
      final DetectedPedal found = (await up.detect())!;
      expect(found.rebrand, 'DONNER Pocket AMP');
      expect(up.blockers(pkg, found), isEmpty);
      expect(await up.update(pkg, found, (_) {}), 'Pocket AMP_105');
      expect(pedal.flashReceived, pkg.image);
    });

    test('an SK17 resumes from its own update mode', () async {
      final FakePedal pedal = FakePedal(
        image: pkg.image,
        identity: 'ota-SK17_006',
      );
      final PedalUpdater up = updater(pedal);
      final DetectedPedal found = (await up.detect())!;
      expect(found.inLoader, isTrue);
      expect(found.rebrand, 'SK17');
      expect(await up.update(pkg, found, (_) {}), 'Pocket AMP_105');
      expect(pedal.loaderReceived, isNull);
      expect(pedal.flashReceived, pkg.image);
    });

    test('a pedal that is not on the list stays out', () async {
      final FakePedal pedal = FakePedal(image: pkg.image, identity: 'FM-1_015');
      expect(await updater(pedal).detect(), isNull);
      expect(pedal.arms, 0);
    });

    test(
      'a pedal not on the list with Pocket AMP presets is presets only',
      () async {
        final FakePedal pedal = FakePedal(
          image: pkg.image,
          identity: 'NEWBRAND_009',
          bank: demoBank(),
        );
        final PedalUpdater up = updater(pedal);
        final DetectedPedal found = (await up.detect())!;
        expect(found.identity, 'NEWBRAND_009');
        expect(found.presetsOnly, isTrue);
        expect(
          up.blockers(pkg, found).join(),
          contains('not on the list of pedals confirmed'),
        );
        await expectLater(
          up.update(pkg, found, (_) {}),
          throwsA(isA<UpdateException>()),
        );
        expect(pedal.arms, 0);
      },
    );

    test('stops if a different device takes over the port', () async {
      final FakePedal pedal = FakePedal(image: pkg.image, identity: 'FM-1_015');
      await expectLater(
        updater(pedal).update(
          pkg,
          const DetectedPedal(
            MidiPortRef(id: 'pedal', name: 'USB Composite Device'),
            'SK17_006',
          ),
          (_) {},
        ),
        throwsA(isA<UpdateException>()),
      );
      expect(pedal.arms, 0);
    });

    test('blockers refuse the version the pedal already runs', () {
      final List<String> reasons = updater(FakePedal(image: pkg.image))
          .blockers(
            pkg,
            const DetectedPedal(
              MidiPortRef(id: 'x', name: 'Pocket AMP'),
              'Pocket AMP_105',
            ),
          );
      expect(reasons.single, contains('already runs version 1.05'));
    });

    test('blockers refuse a package for another product', () {
      final FirmwarePackage other = FirmwarePackage.parse(
        buildFwsc(product: 'FM-1_015', loader: Uint8List(1000)),
      );
      final List<String> reasons = updater(FakePedal(image: pkg.image))
          .blockers(
            other,
            const DetectedPedal(
              MidiPortRef(id: 'x', name: 'Pocket AMP'),
              'Pocket AMP_103',
            ),
          );
      expect(reasons, hasLength(3));
    });
  });
}

/// Two pedals on one bus: [a] on its own ports, [b] on port "b".
class _Two implements MidiBackend {
  _Two(this.a, this.b);
  final FakePedal a;
  final FakePedal b;

  @override
  Future<List<MidiPortRef>> listPorts() async => <MidiPortRef>[
    ...await a.listPorts(),
    if (b.present) MidiPortRef(id: 'b', name: b.port.name),
  ];

  @override
  Future<MidiConnection> open(MidiPortRef p) =>
      p.id == 'b' ? b.open(b.port) : a.open(p);
}

/// [c] shows up only after [a] was armed.
class _Late implements MidiBackend {
  _Late(this.a, this.c);
  final FakePedal a;
  final FakePedal c;

  @override
  Future<List<MidiPortRef>> listPorts() async => <MidiPortRef>[
    ...await a.listPorts(),
    if (a.arms > 0) MidiPortRef(id: 'c', name: c.port.name),
  ];

  @override
  Future<MidiConnection> open(MidiPortRef p) =>
      p.id == 'c' ? c.open(c.port) : a.open(p);
}
