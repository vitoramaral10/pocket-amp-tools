// SPDX-License-Identifier: GPL-3.0-only

import 'dart:io';
import 'dart:typed_data';

import 'alsa_backend.dart';
import 'ble/ble_backend.dart';
import 'coremidi_backend.dart';
import 'winmm_backend.dart';

/// A bidirectional MIDI port as the operating system names it.
class MidiPortRef {
  const MidiPortRef({
    required this.id,
    required this.name,
    this.usbId,
    this.bluetooth = false,
  });

  /// Opaque, backend-specific id used to open the port.
  final String id;
  final String name;

  /// `vendor:product` in lowercase hex, when the backend can tell.
  final String? usbId;

  /// Reached over Bluetooth LE: presets only, never firmware.
  final bool bluetooth;

  @override
  String toString() => usbId == null ? name : '$name [$usbId]';
}

/// Thrown when the port is gone (pedal rebooted or unplugged).
class MidiPortGone implements Exception {
  const MidiPortGone([this.detail = '']);
  final String detail;
  @override
  String toString() => 'MIDI port disconnected $detail'.trim();
}

class MidiIoException implements Exception {
  const MidiIoException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// An open port. Every message handed out by [messages] is one complete SysEx
/// (`F0 ... F7`); everything else is dropped.
abstract class MidiConnection {
  /// Sends one complete SysEx and completes when the OS has taken all of it.
  Future<void> send(Uint8List sysex);

  /// Complete SysEx messages from the device. Emits [MidiPortGone] as an error
  /// when the device disappears.
  Stream<Uint8List> get messages;

  Future<void> close();
}

abstract class MidiBackend {
  Future<List<MidiPortRef>> listPorts();
  Future<MidiConnection> open(MidiPortRef port);

  static MidiBackend forPlatform() {
    if (Platform.isLinux) {
      // Bluetooth was checked on a pedal only through BlueZ.
      return CombinedBackend(AlsaBackend(), BleBackend());
    }
    if (Platform.isWindows) {
      return WinMmBackend();
    }
    if (Platform.isMacOS || Platform.isAndroid) {
      // On Android, USB-MIDI comes through android.media.midi in the same
      // plugin. Bluetooth there is not wired: BleBackend speaks BlueZ only.
      return CoreMidiBackend();
    }
    throw UnsupportedError('Unsupported platform');
  }
}
