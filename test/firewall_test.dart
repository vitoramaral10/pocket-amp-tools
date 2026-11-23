import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_amp_tools/src/sync/firewall.dart';

void main() {
  test('the rules open the sync port to private networks only', () {
    for (final Firewall f in Firewall.values) {
      final String s = firewallScript(f);
      expect(s, contains('47913'));
      expect(s, contains('192.168.0.0/16'));
      expect(s, isNot(contains('0.0.0.0/0')));
    }
    expect(firewallScript(Firewall.firewalld), contains('protocol=udp'));
    expect(firewallScript(Firewall.firewalld), contains('--permanent'));
  });

  test('runs the rules through pkexec and says why it did not', () async {
    final List<List<String>> calls = <List<String>>[];
    Future<ProcessResult> run(int code) async => ProcessResult(0, code, '', '');
    expect(
      await openFirewall(
        Firewall.ufw,
        run: (String exe, List<String> a) {
          calls.add(<String>[exe, ...a]);
          return run(0);
        },
      ),
      isNull,
    );
    expect(calls.single.take(3), <String>['pkexec', 'sh', '-c']);
    expect(
      await openFirewall(Firewall.ufw, run: (_, _) => run(126)),
      'Cancelled.',
    );
  });

  test('finds ufw from its config file', () async {
    final Directory tmp = Directory.systemTemp.createTempSync('fw_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final File conf = File('${tmp.path}/ufw.conf')
      ..writeAsStringSync('# ufw\nENABLED=yes\nLOGLEVEL=low\n');
    Future<ProcessResult> run(String exe, List<String> a) async =>
        ProcessResult(0, exe == 'which' ? 0 : 3, '', '');
    expect(await activeFirewall(run: run, ufwConfig: conf), Firewall.ufw);
    conf.writeAsStringSync('ENABLED=no\n');
    expect(await activeFirewall(run: run, ufwConfig: conf), isNull);
  }, skip: !Platform.isLinux);
}
