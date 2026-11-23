// SPDX-License-Identifier: GPL-3.0-only
//
// On Linux, a firewall such as ufw or firewalld drops the hellos and links
// other devices send. This finds which one is on and, when the user asks,
// lets sync through it with the system's own password prompt (pkexec): for
// home and office networks only (private addresses), never the internet.
// Windows and macOS ask the user on their own the first time the app
// listens.

import 'dart:io';

import 'sync_service.dart' show syncPort;

enum Firewall {
  ufw('ufw'),
  firewalld('firewalld');

  const Firewall(this.label);
  final String label;
}

typedef RunProcess = Future<ProcessResult> Function(
  String exe,
  List<String> args,
);

Future<ProcessResult> _run(String exe, List<String> args) =>
    Process.run(exe, args);

/// The networks sync is allowed from: the private ranges a home or office
/// network uses.
const List<String> _private = <String>[
  '10.0.0.0/8',
  '172.16.0.0/12',
  '192.168.0.0/16',
];

/// The firewall that is on and can be opened from here, if any. Null on
/// other systems, inside a Flatpak, or without pkexec.
Future<Firewall?> activeFirewall({
  RunProcess run = _run,
  File? ufwConfig,
}) async {
  if (!Platform.isLinux || Platform.environment.containsKey('FLATPAK_ID')) {
    return null;
  }
  Future<bool> ok(String exe, List<String> args) async {
    try {
      return (await run(exe, args)).exitCode == 0;
    } on ProcessException {
      return false;
    }
  }

  if (!await ok('which', <String>['pkexec'])) {
    return null;
  }
  if (await ok('systemctl', <String>['is-active', '--quiet', 'firewalld'])) {
    return Firewall.firewalld;
  }
  // `ufw status` needs root; its config file says whether it is on.
  try {
    final String conf = await (ufwConfig ?? File('/etc/ufw/ufw.conf'))
        .readAsString();
    if (RegExp(r'^\s*ENABLED\s*=\s*yes\s*$', multiLine: true).hasMatch(conf)) {
      return Firewall.ufw;
    }
  } on FileSystemException {
    // no ufw
  }
  return null;
}

/// The commands that let sync through [f], run as root in one go.
String firewallScript(Firewall f) => switch (f) {
  Firewall.ufw => <String>[
    for (final String net in _private)
      "ufw allow from $net to any port $syncPort comment 'Pocket AMP Tools sync'",
  ].join(' && '),
  Firewall.firewalld => <String>[
    for (final String proto in <String>['tcp', 'udp'])
      for (final String net in _private)
        for (final String when in <String>['', ' --permanent'])
          "firewall-cmd$when --add-rich-rule='rule family=ipv4 source "
              "address=$net port port=$syncPort protocol=$proto accept'",
  ].join(' && '),
};

/// Lets sync through [f]; null when done, or why not.
Future<String?> openFirewall(Firewall f, {RunProcess run = _run}) async {
  final ProcessResult r;
  try {
    r = await run('pkexec', <String>['sh', '-c', firewallScript(f)]);
  } on ProcessException catch (e) {
    return 'The password prompt could not open: ${e.message}';
  }
  return switch (r.exitCode) {
    0 => null,
    126 => 'Cancelled.',
    127 => 'This account may not change the firewall.',
    _ =>
      '${f.label} refused: ${'${r.stderr}'.trim().isEmpty ? 'exit ${r.exitCode}' : '${r.stderr}'.trim()}',
  };
}
