// SPDX-License-Identifier: GPL-3.0-only

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_amp_tools/src/sync/sync_channel.dart';

class _Me implements SyncIdentity {
  @override
  String get id => 'me';
  @override
  String get name => 'Me';
  @override
  List<int>? pairKey(String peerId) => null;
}

/// Connects to a fresh server, writes [chunks] one by one and returns what
/// [acceptLink] made of them.
Future<Object?> _acceptAfter(List<List<int>> chunks) async {
  final ServerSocket server = await ServerSocket.bind(
    InternetAddress.loopbackIPv4,
    0,
  );
  final Socket client = await Socket.connect(server.address, server.port);
  final Socket s = await server.first;
  final Future<Object> accepted = acceptLink(_Me(), s);
  for (final List<int> c in chunks) {
    client.add(c);
    await client.flush();
  }
  Object? error;
  try {
    await accepted;
  } catch (e) {
    error = e;
  }
  client.destroy();
  await server.close();
  return error;
}

List<int> _frame(List<int> body) => <int>[
  ...(ByteData(4)..setUint32(0, body.length)).buffer.asUint8List(),
  ...body,
];

void main() {
  test('a large hello split into small pieces is read whole', () async {
    final List<int> f = _frame(
      utf8.encode(
        jsonEncode(<String, Object?>{
          'app': syncApp,
          'v': syncVersion,
          'mode': 'sync',
          'id': 'other',
          'name': 'Other',
          'pad': 'x' * (1 << 20),
        }),
      ),
    );
    // The header itself is cut in two, then the body arrives in 4 KB pieces.
    final List<List<int>> chunks = <List<int>>[
      f.sublist(0, 2),
      for (int at = 2; at < f.length; at += 4096)
        f.sublist(at, at + 4096 > f.length ? f.length : at + 4096),
    ];

    // Unpaired, so it is refused, but only after the hello was parsed.
    final Object? e = await _acceptAfter(chunks);
    expect(e, isA<SyncException>());
    expect('$e', contains('not paired'));
  });

  test('a frame over the limit is refused', () async {
    final Object? e = await _acceptAfter(<List<int>>[
      (ByteData(4)..setUint32(0, 25 << 20)).buffer.asUint8List(),
    ]);
    expect('$e', contains('too much at once'));
  });
}
