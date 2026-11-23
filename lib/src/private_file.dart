// SPDX-License-Identifier: GPL-3.0-only

import 'dart:io';

/// Writes [text] to [file] so that it is never readable by others, even for
/// a moment: on Linux and macOS the file is born owner-only (umask 077, so
/// no one can open it before it is locked down), filled, then given the
/// real name. Throws [FileSystemException] when it cannot be made private.
Future<void> writePrivate(File file, String text) async {
  await file.parent.create(recursive: true);
  final File tmp = File('${file.path}.tmp');
  if (await tmp.exists()) {
    await tmp.delete(); // a leftover keeps its old, maybe open, mode
  }
  if (Platform.isLinux || Platform.isMacOS) {
    final ProcessResult r = await Process.run('sh', <String>[
      '-c',
      r'umask 077 && : > "$1"',
      'sh',
      tmp.path,
    ]);
    if (r.exitCode != 0) {
      throw FileSystemException('Cannot make a private file', tmp.path);
    }
  }
  await tmp.writeAsString(text, flush: true);
  await tmp.rename(file.path);
}
