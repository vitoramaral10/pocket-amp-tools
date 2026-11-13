// SPDX-License-Identifier: GPL-3.0-only
//
// macOS: CoreMIDI through the flutter_midi_command plugin, whose Darwin side
// splits outgoing SysEx into MIDIPacketList chunks and reassembles incoming
// SysEx before handing it to Dart.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_midi_command/flutter_midi_command.dart';

import '../ota_protocol.dart';
import 'midi_backend.dart';

class CoreMidiBackend implements MidiBackend {
  final MidiCommand _midi = MidiCommand();
  final Map<String, MidiDevice> _devices = <String, MidiDevice>{};

  @override
  Future<List<MidiPortRef>> listPorts() async {
    final List<MidiDevice> devices = await _midi.devices ?? <MidiDevice>[];
    _devices.clear();
    final List<MidiPortRef> out = <MidiPortRef>[];
    for (final MidiDevice d in devices) {
      if (d.type != MidiDeviceType.serial) {
        continue;
      }
      _devices[d.id] = d;
      out.add(MidiPortRef(id: d.id, name: d.name));
    }
    return out;
  }

  @override
  Future<MidiConnection> open(MidiPortRef port) async {
    final MidiDevice? device = _devices[port.id];
    if (device == null) {
      throw MidiPortGone('(${port.name} not found)');
    }
    try {
      await _midi.connectToDevice(
        device,
        awaitConnectionTimeout: const Duration(seconds: 5),
      );
    } catch (e) {
      throw MidiIoException('Could not open ${port.name}: $e');
    }
    return _CoreMidiConnection(_midi, device);
  }
}

/// MidiPortImpl.MAX_PACKET_DATA_SIZE in android.media.midi.
const int androidMaxSend = 1016;

/// [sysex] cut into pieces Android accepts, in order, without copying.
Iterable<Uint8List> androidSendSlices(Uint8List sysex) sync* {
  for (int at = 0; at < sysex.length; at += androidMaxSend) {
    final int end = at + androidMaxSend;
    yield Uint8List.sublistView(
      sysex,
      at,
      end < sysex.length ? end : sysex.length,
    );
  }
}

class _CoreMidiConnection implements MidiConnection {
  _CoreMidiConnection(this._midi, this._device) {
    _sub = _midi.onMidiPacketReceived?.listen((MidiPacket p) {
      if (p.device.id != _device.id) {
        return;
      }
      for (final Uint8List m in _splitter.add(p.data)) {
        _messages.add(m);
      }
    });
    // CoreMIDI does not fail a send to a device that is gone: notice the
    // unplug from the setup changes instead.
    _setup = _midi.onMidiSetupChanged?.listen((MidiSetupChange c) async {
      if (c != MidiSetupChange.deviceDisappeared &&
          c != MidiSetupChange.deviceDisconnected) {
        return;
      }
      final List<MidiDevice> now = await _midi.devices ?? <MidiDevice>[];
      if (!now.any((MidiDevice d) => d.id == _device.id)) {
        _gone = true;
        if (!_messages.isClosed) {
          _messages.addError(const MidiPortGone('(unplugged)'));
        }
      }
    });
  }

  final MidiCommand _midi;
  final MidiDevice _device;
  StreamSubscription<MidiPacket>? _sub;
  StreamSubscription<MidiSetupChange>? _setup;
  bool _closed = false;
  bool _gone = false;
  final StreamController<Uint8List> _messages = StreamController<Uint8List>();
  final SysexSplitter _splitter = SysexSplitter();

  @override
  Stream<Uint8List> get messages => _messages.stream;

  @override
  Future<void> send(Uint8List sysex) async {
    if (_closed || _gone) {
      throw const MidiPortGone();
    }
    if (!Platform.isAndroid) {
      _midi.sendData(sysex, deviceId: _device.id);
      return;
    }
    // MidiInputPort.send refuses more than 1016 bytes at once; the IR
    // chunks are larger. The USB-MIDI driver carries a SysEx across sends.
    for (final Uint8List part in androidSendSlices(sysex)) {
      _midi.sendData(part, deviceId: _device.id);
    }
  }

  @override
  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    await _sub?.cancel();
    await _setup?.cancel();
    try {
      _midi.disconnectDevice(_device);
    } catch (_) {
      // The pedal may already be gone after a reboot.
    }
    await _messages.close();
  }
}
