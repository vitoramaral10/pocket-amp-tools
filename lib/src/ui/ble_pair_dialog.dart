// SPDX-License-Identifier: GPL-3.0-only
//
// Android: find a Pocket AMP in range and pair it, so it can be detected
// over Bluetooth without a trip to the system settings.

import 'package:flutter/material.dart';

import '../midi/ble/android_gatt.dart';
import '../midi/ble/ble_backend.dart';
import '../midi/ble/gatt.dart';

/// True when a pedal was paired.
Future<bool> showBlePairDialog(BuildContext context) async =>
    await showDialog<bool>(
      context: context,
      builder: (_) => const _BlePairDialog(),
    ) ??
    false;

class _BlePairDialog extends StatefulWidget {
  const _BlePairDialog();

  @override
  State<_BlePairDialog> createState() => _BlePairDialogState();
}

class _BlePairDialogState extends State<_BlePairDialog> {
  final AndroidGattClient _client = AndroidGattClient();
  List<BleDeviceInfo>? _found;
  String? _pairing;
  String? _error;

  @override
  void initState() {
    super.initState();
    _scan();
  }

  Future<void> _scan() async {
    setState(() {
      _found = null;
      _error = null;
    });
    try {
      if (!await _client.hasAdapter()) {
        throw 'Turn on Bluetooth and allow "Nearby devices".';
      }
      final List<BleDeviceInfo> found = await _client.nearbyUnpaired(
        isPedal: BleBackend.looksLikePedal,
      );
      if (mounted) {
        setState(() => _found = found);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _found = const <BleDeviceInfo>[];
          _error = '$e';
        });
      }
    }
  }

  Future<void> _pair(BleDeviceInfo d) async {
    setState(() {
      _pairing = d.id;
      _error = null;
    });
    try {
      await _client.pair(d.id);
      if (mounted) {
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _pairing = null;
          _error = 'Not paired: $e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final List<BleDeviceInfo>? found = _found;
    return AlertDialog(
      title: const Text('Pair over Bluetooth'),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            if (found == null) ...<Widget>[
              const LinearProgressIndicator(),
              const SizedBox(height: 12),
              const Text('Looking for a Pocket AMP nearby…'),
            ] else if (found.isEmpty && _error == null)
              const Text(
                'No unpaired pedal in range. Turn the pedal on, keep it '
                'close and look again. A pedal already paired is found by '
                'Detect again.',
              )
            else
              for (final BleDeviceInfo d in found)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.bluetooth),
                  title: Text(d.name.isEmpty ? d.address : d.name),
                  subtitle: Text(d.address),
                  trailing: _pairing == d.id
                      ? const SizedBox.square(
                          dimension: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : null,
                  enabled: _pairing == null,
                  onTap: () => _pair(d),
                ),
            if (_error != null) ...<Widget>[
              const SizedBox(height: 12),
              Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
            ],
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: found == null || _pairing != null ? null : _scan,
          child: const Text('Look again'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Close'),
        ),
      ],
    );
  }
}
