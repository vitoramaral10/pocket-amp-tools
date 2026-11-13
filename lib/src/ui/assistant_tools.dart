// SPDX-License-Identifier: GPL-3.0-only
//
// The assistant's tools: what it may read and do in the app. They work on
// the editor's draft (heard live when the pedal is connected) and, through
// the host, on the library and the pedal's flash.

import 'dart:io';

import '../assistant/agent.dart';
import '../assistant/assistant.dart';
import '../assistant/pedal_knowledge.dart';
import '../library/library.dart';
import '../presets/block_models.dart';
import '../presets/ir_upload.dart';
import '../presets/nam_file.dart';
import '../presets/mefcs.dart';
import '../presets/preset_backup.dart';
import '../presets/preset_meta.dart';
import 'presets_page.dart';

/// What the tools need from the app.
abstract class AssistantHost {
  PresetWorkspace get workspace;

  /// The connected pedal in a few words, or null when none is.
  String? get pedal;

  /// Files can be sent to a slot now (a pedal on USB, nothing else running).
  bool get canUpload;

  /// Presets can be written now.
  bool get canWrite;

  Future<List<LibraryItem>> library(LibraryKind kind);

  /// The library file each slot (0..19) was last written from.
  Future<Map<int, String>> links(LibraryKind kind);

  /// Sends [item] to slot [slot] (0..19) as [name]; returns what was done.
  /// Throws when it fails.
  Future<String> uploadToSlot(LibraryItem item, int slot, String name);

  /// Writes [presets] (a frozen copy of the editor's draft): the presets
  /// that differ from the pedal. Returns what was done; throws when it fails.
  Future<String> writePresets(PresetBackup presets);
}

const Map<String, Object?> _presetArg = <String, Object?>{
  'type': 'string',
  'description': 'P01 to P80. Leave out for the preset open in the editor.',
};

const Map<String, Object?> _kindArg = <String, Object?>{
  'type': 'string',
  'enum': <String>['amp', 'cab'],
  'description':
      'amp: amp captures (.nam) and AMP slots; cab: impulse '
      'responses (.wav) and CAB slots.',
};

List<AssistantTool> assistantTools(AssistantHost host) {
  PresetWorkspace w() => host.workspace;
  PresetBackup draft() =>
      w().draft ??
      (throw const ToolError(
        'No presets are loaded. Ask the user to connect the pedal or open a '
        'backup file.',
      ));
  int idOf(Object? v) => v == null ? w().selected : _presetId(v);

  /// What write_presets showed the user, to write exactly that.
  PresetBackup? toWrite;

  return <AssistantTool>[
    AssistantTool(
      name: 'get_state',
      description:
          'The pedal connection, the preset open in the editor, and the '
          'presets edited but not yet written to the pedal.',
      parameters: _object(<String, Object?>{}),
      annotations: const ToolAnnotations(
        title: 'Look at the app',
        readOnly: true,
      ),
      run: (_) async => <String, Object?>{
        'pedal': host.pedal ?? 'not connected',
        'presets_loaded': w().draft != null,
        'open_preset': w().draft == null ? null : _name(w().selected),
        'edited_not_written': <String>[
          for (final int id in w().changed.toList()..sort()) _name(id),
        ],
        'heard_live_on_pedal': w().live != null,
        'labels_for_preset_details': <String, Object?>{
          for (final MetaCategory c in MetaCategory.values)
            c.name: w().details.offered(c),
        },
      },
    ),
    AssistantTool(
      name: 'list_presets',
      description:
          'One line per preset (P01..P80): AMP and CAB in use, the blocks '
          'that are on, and the name, rating and labels the user gave it. '
          'Use get_preset for the details of one.',
      parameters: _object(<String, Object?>{}),
      annotations: const ToolAnnotations(title: 'List presets', readOnly: true),
      run: (_) async {
        final PresetBackup d = draft();
        return <String>[
          for (int id = 0; id < presetCount; id++) _summary(w(), d, id),
        ];
      },
    ),
    AssistantTool(
      name: 'get_preset',
      description:
          'One preset in full: volume, chain, each block (on, model, knobs '
          'by name) and the EQ. AMP and CAB also show the name of what their '
          'slot holds on the pedal. "details" is what the user wrote about '
          'it in the app: name, description, genres, uses, tags, rating.',
      parameters: _object(<String, Object?>{'preset': _presetArg}),
      annotations: const ToolAnnotations(
        title: 'Read a preset',
        readOnly: true,
      ),
      describe: (Map<String, Object?> a) =>
          'Read ${a['preset'] ?? 'the open preset'}',
      run: (Map<String, Object?> a) async {
        final PresetBackup d = draft();
        final int id = idOf(a['preset']);
        final Map<String, Object> f = d.presetFields(id);
        final Map<String, Object> blocks = Map<String, Object>.of(
          f['blocks']! as Map<String, Object>,
        );
        for (final String b in <String>['AMP', 'CAB']) {
          blocks[b] = <String, Object>{
            ...blocks[b]! as Map<String, Object>,
            'on_pedal': w().modelLabel(b, d.model(id, blockNames.indexOf(b))),
          };
        }
        final PresetMeta meta = w().details.metas[id];
        return <String, Object?>{
          if (!meta.isEmpty) 'details': meta.toJson(),
          ...f,
          'blocks': blocks,
          'eq_guide': eqGuide,
          if (!_eqWritable(d, id))
            'eq_note':
                'Stored in a form this app cannot change; edits leave '
                'it as it is.',
        };
      },
    ),
    AssistantTool(
      name: 'list_models',
      description:
          'The models of one block, each with its knob names, what it does '
          'and the real gear it likely copies (a guess from its name: say so '
          'when you use it), plus a guide to what the knobs do in dB, Hz or '
          'seconds. For AMP and CAB also the name each slot holds on the '
          'pedal and the library file it came from. Read it before choosing '
          'a model or setting knobs.',
      parameters: _object(
        <String, Object?>{
          'block': <String, Object?>{'type': 'string', 'enum': blockNames},
        },
        required: <String>['block'],
      ),
      annotations: const ToolAnnotations(title: 'List models', readOnly: true),
      describe: (Map<String, Object?> a) => 'List ${a['block']} models',
      run: (Map<String, Object?> a) async {
        final String block = _block(a['block']);
        final LibraryKind? kind = _kindOfBlock(block);
        final Map<int, String> links = kind == null
            ? const <int, String>{}
            : await host.links(kind);
        return <String, Object?>{
          'knob_guide': blockKnobGuide[block],
          'models': <Map<String, Object?>>[
            for (final (int i, (String name, _)) in blockModels[block]!.indexed)
              <String, Object?>{
                'model': name,
                ...?modelInfo[block]?[name]?.toJson(),
                'knobs': <String>[
                  for (final String k in knobNames(block, i))
                    if (!k.startsWith('knob')) k,
                ],
                if (kind != null) ...<String, Object?>{
                  'slot': i + 1,
                  'on_pedal': w().modelLabel(block, i),
                  if (links[i] != null) 'library_file': links[i],
                },
              },
          ],
        };
      },
    ),
    AssistantTool(
      name: 'select_preset',
      description:
          'Opens a preset in the editor; with the pedal connected it is '
          'heard at once.',
      parameters: _object(
        <String, Object?>{'preset': _presetArg},
        required: <String>['preset'],
      ),
      annotations: const ToolAnnotations(title: 'Open a preset'),
      describe: (Map<String, Object?> a) => 'Open ${a['preset']}',
      run: (Map<String, Object?> a) async {
        draft();
        final int id = idOf(a['preset']);
        w().select(id);
        return '${_name(id)} is open.';
      },
    ),
    AssistantTool(
      name: 'edit_preset',
      description:
          'Changes a preset in the editor: give only what changes. Blocks '
          'are turned on or off, given a model (a name from list_models) and '
          'knob values (0-100) by knob name; the chain is the six block '
          'names in signal order (FX and AMP first). Heard at once when the '
          'pedal is connected and the preset is open; stored on the pedal '
          'only by write_presets.',
      parameters: _object(<String, Object?>{
        'preset': _presetArg,
        'volume': <String, Object?>{
          'type': 'integer',
          'minimum': 0,
          'maximum': 100,
        },
        'chain': <String, Object?>{
          'type': 'array',
          'items': <String, Object?>{'type': 'string', 'enum': blockNames},
          'minItems': 6,
          'maxItems': 6,
        },
        'blocks': <String, Object?>{
          'type': 'object',
          'description': 'By block name (FX, AMP, MOD, DLY, REV, CAB).',
          'additionalProperties': <String, Object?>{
            'type': 'object',
            'properties': <String, Object?>{
              'on': <String, Object?>{'type': 'boolean'},
              'model': <String, Object?>{'type': 'string'},
              'knobs': <String, Object?>{
                'type': 'object',
                'description': 'Knob name to value, 0-100.',
                'additionalProperties': <String, Object?>{'type': 'integer'},
              },
            },
          },
        },
        'eq': <String, Object?>{
          'type': 'object',
          'properties': <String, Object?>{
            'on': <String, Object?>{'type': 'boolean'},
            'position': <String, Object?>{
              'type': 'string',
              'enum': <String>['head', 'tail'],
            },
            'bands': <String, Object?>{
              'type': 'array',
              'items': <String, Object?>{
                'type': 'integer',
                'minimum': -6,
                'maximum': 6,
              },
              'minItems': 5,
              'maxItems': 5,
            },
          },
        },
      }),
      annotations: const ToolAnnotations(title: 'Edit a preset'),
      describe: (Map<String, Object?> a) =>
          'Edit ${a['preset'] ?? 'the open preset'}',
      run: (Map<String, Object?> a) async {
        final PresetBackup d = draft();
        final int id = idOf(a['preset']);
        final Map<String, Object?> change = <String, Object?>{
          for (final String k in <String>['volume', 'chain', 'blocks', 'eq'])
            if (a[k] != null) k: a[k],
        };
        if (change.isEmpty) {
          throw const ToolError('Nothing to change was given.');
        }
        return _apply(w(), d, id, change);
      },
    ),
    AssistantTool(
      name: 'set_preset_details',
      description:
          'Sets what the user keeps about a preset in the app (it is never '
          'stored on the pedal): name, description, genres, uses, tags and '
          'a rating of 1 to 5 stars. Give only what changes. A list replaces '
          'the old one; an empty text, an empty list or rating 0 clears. '
          'Prefer the labels get_state lists; a new one joins the user\'s '
          'list.',
      parameters: _object(<String, Object?>{
        'preset': _presetArg,
        'name': <String, Object?>{'type': 'string'},
        'description': <String, Object?>{'type': 'string'},
        for (final MetaCategory c in MetaCategory.values)
          c.name: <String, Object?>{
            'type': 'array',
            'items': <String, Object?>{'type': 'string'},
          },
        'rating': <String, Object?>{
          'type': 'integer',
          'minimum': 0,
          'maximum': 5,
        },
      }),
      annotations: const ToolAnnotations(title: 'Set preset details'),
      describe: (Map<String, Object?> a) =>
          'Set the details of ${a['preset'] ?? 'the open preset'}',
      run: (Map<String, Object?> a) async {
        // As with the tools that read them: no presets, nothing to describe.
        draft();
        final int id = idOf(a['preset']);
        // Everything is checked before anything changes.
        final Object? name = a['name'];
        final Object? description = a['description'];
        final Object? rating = a['rating'];
        if (name is! String? || description is! String?) {
          throw const ToolError('name and description must be text.');
        }
        if (rating != null &&
            (rating is! num ||
                rating != rating.round() ||
                rating < 0 ||
                rating > 5)) {
          throw const ToolError('rating must be a whole number, 0 to 5.');
        }
        final Map<MetaCategory, List<String>> labels =
            <MetaCategory, List<String>>{};
        for (final MetaCategory c in MetaCategory.values) {
          final Object? v = a[c.name];
          if (v == null) {
            continue;
          }
          if (v is! List || v.any((Object? e) => e is! String)) {
            throw ToolError('${c.name} must be a list of text.');
          }
          labels[c] = <String>[
            for (final Object? e in v)
              if ((e! as String).trim().isNotEmpty) e as String,
          ];
        }
        if (name == null &&
            description == null &&
            rating == null &&
            labels.isEmpty) {
          throw const ToolError('Nothing to change was given.');
        }
        final PresetDetails details = w().details;
        final PresetMeta m = details.metas[id];
        if (name != null) {
          m.name = name.trim();
        }
        if (description != null) {
          m.description = description.trim();
        }
        if (rating is num) {
          m.rating = rating.round();
        }
        labels.forEach((MetaCategory c, List<String> l) {
          m.labels[c]!
            ..clear()
            ..addAll(<String>[
              for (final String x in l) details.useLabel(c, x),
            ]);
        });
        details.changed();
        return <String, Object?>{'preset': _name(id), ...m.toJson()};
      },
    ),
    AssistantTool(
      name: 'copy_preset',
      description:
          'Copies a preset\'s sound (volume, chain, blocks, EQ) over another '
          'one in the editor. The target keeps the name, description, rating '
          'and labels the user gave it; say so.',
      parameters: _object(
        <String, Object?>{
          'from': _presetArg,
          'to': <String, Object?>{
            'type': 'string',
            'description': 'P01 to P80.',
          },
        },
        required: <String>['from', 'to'],
      ),
      annotations: const ToolAnnotations(title: 'Copy a preset'),
      describe: (Map<String, Object?> a) => 'Copy ${a['from']} to ${a['to']}',
      run: (Map<String, Object?> a) async {
        final PresetBackup d = draft();
        final int from = idOf(a['from']);
        final int to = _presetId(a['to']);
        final bool keepEq = !_eqWritable(d, from) || !_eqWritable(d, to);
        try {
          d.setPresetFields(to, d.presetFields(from), keepEq: keepEq);
        } on FormatException catch (e) {
          throw ToolError('${_name(from)} cannot be copied: ${e.message}');
        }
        if (to == w().selected) {
          w().showOnPedal();
        }
        w().edited();
        return '${_name(from)} copied to ${_name(to)}'
            '${keepEq ? ', except the EQ, kept as stored' : ''}. Not written '
            'to the pedal yet.';
      },
    ),
    AssistantTool(
      name: 'list_library',
      description:
          'The files in the user\'s library: amp captures (.nam) or impulse '
          'responses (.wav), and the slots each was last sent to. Amp '
          'captures also tell the gear captured, the tone type, how much it '
          'saturates (gain, 0 clean to 1 very driven) and its loudness.',
      parameters: _object(
        <String, Object?>{'kind': _kindArg},
        required: <String>['kind'],
      ),
      annotations: const ToolAnnotations(
        title: 'Look at the library',
        readOnly: true,
      ),
      describe: (Map<String, Object?> a) =>
          a['kind'] == 'amp' ? 'List amp captures' : 'List IRs',
      run: (Map<String, Object?> a) async {
        final LibraryKind kind = _kind(a['kind']);
        final List<LibraryItem> items = await host.library(kind);
        final Map<int, String> links = await host.links(kind);
        return <Map<String, Object?>>[
          for (final LibraryItem it in items)
            <String, Object?>{
              'file': it.name,
              if (kind == LibraryKind.amp) ...await _namAbout(it),
              'in_slots': <int>[
                for (final MapEntry<int, String> l in links.entries)
                  if (l.value == it.name) l.key + 1,
              ],
            },
        ];
      },
    ),
    AssistantTool(
      name: 'list_slots',
      description:
          'The 20 AMP or CAB slots of the pedal: the name each holds and the '
          'library file it was sent from, when known.',
      parameters: _object(
        <String, Object?>{'kind': _kindArg},
        required: <String>['kind'],
      ),
      annotations: const ToolAnnotations(
        title: 'Look at the slots',
        readOnly: true,
      ),
      describe: (Map<String, Object?> a) =>
          a['kind'] == 'amp' ? 'List AMP slots' : 'List CAB slots',
      run: (Map<String, Object?> a) async {
        final LibraryKind kind = _kind(a['kind']);
        final String block = kind == LibraryKind.amp ? 'AMP' : 'CAB';
        final Map<int, String> links = await host.links(kind);
        return <Map<String, Object?>>[
          for (int i = 0; i < blockModels[block]!.length; i++)
            <String, Object?>{
              'slot': i + 1,
              'name': w().modelLabel(block, i),
              if (links[i] != null) 'library_file': links[i],
            },
        ];
      },
    ),
    AssistantTool(
      name: 'upload_to_slot',
      description:
          'Sends a library file to an AMP or CAB slot of the pedal, replacing '
          'what the slot holds for good (the app cannot read it back). '
          'Presets that use the slot then play the new file. Needs the pedal '
          'on USB.',
      parameters: _object(
        <String, Object?>{
          'kind': _kindArg,
          'file': <String, Object?>{
            'type': 'string',
            'description': 'A file name from list_library.',
          },
          'slot': <String, Object?>{
            'type': 'integer',
            'minimum': 1,
            'maximum': 20,
          },
          'name': <String, Object?>{
            'type': 'string',
            'description':
                'Name shown on the pedal, up to $irNameMaxLength plain '
                'characters. Defaults to the file name.',
          },
        },
        required: <String>['kind', 'file', 'slot'],
      ),
      annotations: const ToolAnnotations(
        title: 'Send to a slot',
        destructive: true,
      ),
      describe: (Map<String, Object?> a) {
        final String block = a['kind'] == 'amp' ? 'AMP' : 'CAB';
        final int? slot = a['slot'] is int ? a['slot']! as int : null;
        final String now = slot == null || slot < 1 || slot > 20
            ? ''
            : ', replacing "${host.workspace.modelLabel(block, slot - 1)}"';
        return 'Send "${a['file']}" to $block slot ${a['slot']}$now';
      },
      run: (Map<String, Object?> a) async {
        final LibraryKind kind = _kind(a['kind']);
        final Object? slot = a['slot'];
        if (slot is! int || slot < 1 || slot > 20) {
          throw const ToolError('slot must be a number from 1 to 20.');
        }
        final List<LibraryItem> items = await host.library(kind);
        final LibraryItem? item = items
            .where(
              (LibraryItem i) => i.name == a['file'] || i.fileName == a['file'],
            )
            .firstOrNull;
        if (item == null) {
          throw ToolError(
            'No ${kind == LibraryKind.amp ? 'amp capture' : 'IR'} named '
            '"${a['file']}" in the library.',
          );
        }
        if (!host.canUpload) {
          throw const ToolError(
            'The pedal is not ready to take a file: it must be connected by '
            'USB, with nothing else running.',
          );
        }
        final String name = sanitizeIrName(
          a['name'] is String && (a['name']! as String).trim().isNotEmpty
              ? a['name']! as String
              : item.name,
        );
        if (name.trim().isEmpty) {
          throw const ToolError('The name on the pedal would be empty.');
        }
        return host.uploadToSlot(item, slot - 1, name);
      },
    ),
    AssistantTool(
      name: 'write_presets',
      description:
          'Stores on the pedal every preset edited in the app and not yet '
          'written, replacing those presets there.',
      parameters: _object(<String, Object?>{}),
      annotations: const ToolAnnotations(
        title: 'Write presets',
        destructive: true,
      ),
      // Shown before the user's yes, so the presets it names are frozen
      // then: an edit made while the question waits is not written with it.
      describe: (_) {
        final List<int> ids = w().changed.toList()..sort();
        toWrite = w().draft?.copy();
        return ids.isEmpty
            ? 'Write presets to the pedal'
            : 'Write ${ids.map(_name).join(', ')} to the pedal';
      },
      run: (_) async {
        final PresetBackup? frozen = toWrite;
        toWrite = null;
        if (w().changed.isEmpty) {
          throw const ToolError('Nothing to write: the pedal already matches.');
        }
        final PresetBackup? now = w().draft;
        if (frozen == null ||
            now == null ||
            !_sameBytes(frozen.presets, now.presets) ||
            !_sameBytes(frozen.eq, now.eq)) {
          throw const ToolError(
            'The presets changed while the user was being asked; nothing was '
            'written. Ask again if they still want it.',
          );
        }
        if (!host.canWrite) {
          throw const ToolError(
            'The pedal is not ready to be written: connect it, with nothing '
            'else running.',
          );
        }
        return host.writePresets(frozen);
      },
    ),
  ];
}

/// Applies [change] (the preset file's shape, partial) to preset [id] and
/// says what changed.
String _apply(
  PresetWorkspace w,
  PresetBackup d,
  int id,
  Map<String, Object?> change,
) {
  final Map<String, Object> before = d.presetFields(id);
  final bool keepEq = !_eqWritable(d, id);
  if (keepEq && change.containsKey('eq')) {
    throw ToolError(
      'The EQ of ${_name(id)} is stored in a form this app cannot change; '
      'leave "eq" out.',
    );
  }
  final Object? blocks = change['blocks'];
  if (blocks is Map) {
    final Map<String, Object?> now = before['blocks']! as Map<String, Object?>;
    for (final MapEntry<Object?, Object?> e in blocks.entries) {
      final String name = '${e.key}';
      if (!blockNames.contains(name)) {
        throw ToolError(
          'No block named "$name"; use ${blockNames.join(', ')}.',
        );
      }
      final Object? asked = e.value;
      if (asked is! Map) {
        throw ToolError('$name: expected an object.');
      }
      final Object? model = asked['model'];
      final Object? current = (now[name]! as Map<String, Object?>)['model'];
      if (model != null && model != current) {
        final int i = blockModels[name]!.indexWhere(
          ((String, List<String>) m) => m.$1 == model,
        );
        if (i < 0) {
          throw ToolError(
            '$name has no model "$model"; use a name from list_models.',
          );
        }
        // The new model's knobs mean other things: they must all be set.
        final List<String> want = <String>[
          for (final String k in knobNames(name, i))
            if (!k.startsWith('knob')) k,
        ];
        final Object? knobs = asked['knobs'];
        final List<String> missing = <String>[
          for (final String k in want)
            if (knobs is! Map || knobs[k] == null) k,
        ];
        if (missing.isNotEmpty) {
          throw ToolError(
            'Changing $name to $model: give a value for each of its knobs '
            '(${want.join(', ')}); missing ${missing.join(', ')}.',
          );
        }
      }
      final Object? knobs = asked['knobs'];
      if (knobs is Map) {
        final int i = model == null
            ? d.model(id, blockNames.indexOf(name))
            : blockModels[name]!.indexWhere(
                ((String, List<String>) m) => m.$1 == model,
              );
        final List<String> names = knobNames(name, i);
        for (final Object? k in knobs.keys) {
          if (!names.contains(k)) {
            throw ToolError(
              '$name has no knob "$k"; its knobs are '
              '${names.where((String n) => !n.startsWith('knob')).join(', ')}.',
            );
          }
        }
      }
    }
  }
  final Map<String, Object?> merged = mergeSuggestion(before, change);
  if (keepEq) {
    merged.remove('eq');
  }
  try {
    d.setPresetFields(id, merged, keepEq: keepEq);
  } on FormatException catch (e) {
    throw ToolError('Not a preset the pedal can take: ${e.message}');
  }
  if (id == w.selected) {
    w.showOnPedal();
  }
  w.edited();
  final List<String> diff = _diff(before, d.presetFields(id));
  return diff.isEmpty
      ? 'Nothing changed: ${_name(id)} already had those values.'
      : '${_name(id)}: ${diff.join('; ')}. Not written to the pedal yet.';
}

/// What differs between two presets in the file's shape, in short words.
List<String> _diff(Map<String, Object> a, Map<String, Object> b) {
  final List<String> out = <String>[];
  if (a['volume'] != b['volume']) {
    out.add('volume ${a['volume']} → ${b['volume']}');
  }
  if ('${a['chain']}' != '${b['chain']}') {
    out.add('chain ${(b['chain']! as List<Object?>).join(' > ')}');
  }
  final Map<String, Object?> ba = a['blocks']! as Map<String, Object?>;
  final Map<String, Object?> bb = b['blocks']! as Map<String, Object?>;
  for (final String n in blockNames) {
    final Map<String, Object?> x = ba[n]! as Map<String, Object?>;
    final Map<String, Object?> y = bb[n]! as Map<String, Object?>;
    if (x['on'] != y['on']) {
      out.add('$n ${y['on'] == true ? 'on' : 'off'}');
    }
    if (x['model'] != y['model']) {
      out.add('$n model ${y['model']}');
    }
    final List<Object?> kx = x['knobs']! as List<Object?>;
    final List<Object?> ky = y['knobs']! as List<Object?>;
    for (int k = 0; k < ky.length; k++) {
      final Map<String, Object?> ny = ky[k]! as Map<String, Object?>;
      final Object? vx = k < kx.length
          ? (kx[k]! as Map<String, Object?>)['value']
          : null;
      final String label = '${ny['label']}';
      if (vx != ny['value'] && !label.startsWith('knob')) {
        out.add('$n $label ${vx ?? '-'} → ${ny['value']}');
      }
    }
  }
  final Object? ea = a['eq'];
  final Object? eb = b['eq'];
  if (ea is Map && eb is Map) {
    if (ea['on'] != eb['on']) {
      out.add('EQ ${eb['on'] == true ? 'on' : 'off'}');
    }
    if (ea['position'] != eb['position']) {
      out.add('EQ at the ${eb['position']}');
    }
    final Object? ba = ea['bands'];
    final Object? bb = eb['bands'];
    if (ba is List && bb is List && ba.length == bb.length) {
      for (int i = 0; i < bb.length; i++) {
        // A band is a number or a labelled value.
        final Object? va = ba[i] is Map ? (ba[i] as Map)['value'] : ba[i];
        final Object? vb = bb[i] is Map ? (bb[i] as Map)['value'] : bb[i];
        if (va != vb) {
          out.add('EQ band ${i + 1} $va → $vb');
        }
      }
    }
  }
  return out;
}

String _summary(PresetWorkspace w, PresetBackup d, int id) {
  final String amp = w.modelLabel('AMP', d.model(id, 1));
  final String cab = w.modelLabel('CAB', d.model(id, 5));
  final List<String> on = <String>[
    for (final int b in d.chain(id))
      if (b < blockNames.length && d.isOn(id, b)) blockNames[b],
  ];
  final PresetMeta m = w.details.metas[id];
  final List<String> labels = <String>[
    for (final MetaCategory c in MetaCategory.values) ...m.labels[c]!,
  ];
  return '${_name(id)}: AMP $amp, CAB $cab, on: '
      '${on.isEmpty ? 'none' : on.join(' > ')}'
      '${m.name.isEmpty ? '' : ', named "${m.name}"'}'
      '${m.rating == 0 ? '' : ', ${m.rating} of 5 stars'}'
      '${labels.isEmpty ? '' : ', labels: ${labels.join(', ')}'}';
}

/// What a library capture says about itself; nothing if it cannot be read.
Future<Map<String, Object?>> _namAbout(LibraryItem it) async {
  try {
    final Map<String, Object?> m = namMetadata(await it.file.readAsString());
    return <String, Object?>{
      for (final MapEntry<String, Object?> e in m.entries)
        if (e.key != 'name') e.key: e.value,
    };
  } on FileSystemException {
    return const <String, Object?>{};
  } on FormatException {
    return const <String, Object?>{};
  }
}

bool _sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) {
    return false;
  }
  for (int i = 0; i < a.length; i++) {
    if (a[i] != b[i]) {
      return false;
    }
  }
  return true;
}

bool _eqWritable(PresetBackup d, int id) {
  try {
    saveEqPacket(id, d.eqRecord(id));
    return true;
  } on ArgumentError {
    return false;
  }
}

String _name(int id) => 'P${(id + 1).toString().padLeft(2, '0')}';

/// "P05", "p5", "5" or 5 → 4.
int _presetId(Object? v) {
  final String s = '$v'.trim().toUpperCase();
  final int? n = int.tryParse(s.startsWith('P') ? s.substring(1) : s);
  if (n == null || n < 1 || n > presetCount) {
    throw ToolError('"$v" is not a preset; use P01 to P$presetCount.');
  }
  return n - 1;
}

String _block(Object? v) => blockNames.contains(v)
    ? v! as String
    : throw ToolError('"$v" is not a block; use ${blockNames.join(', ')}.');

LibraryKind _kind(Object? v) => switch (v) {
  'amp' => LibraryKind.amp,
  'cab' => LibraryKind.cab,
  _ => throw ToolError('kind must be "amp" or "cab", not "$v".'),
};

LibraryKind? _kindOfBlock(String block) => switch (block) {
  'AMP' => LibraryKind.amp,
  'CAB' => LibraryKind.cab,
  _ => null,
};

Map<String, Object?> _object(
  Map<String, Object?> properties, {
  List<String> required = const <String>[],
}) => <String, Object?>{
  'type': 'object',
  'properties': properties,
  if (required.isNotEmpty) 'required': required,
};
