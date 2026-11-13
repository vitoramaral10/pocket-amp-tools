import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pocket_amp_tools/src/assistant/agent.dart';
import 'package:pocket_amp_tools/src/assistant/assistant.dart';
import 'package:pocket_amp_tools/src/assistant/pedal_knowledge.dart';
import 'package:pocket_amp_tools/src/presets/block_models.dart';
import 'package:pocket_amp_tools/src/library/library.dart';
import 'package:pocket_amp_tools/src/presets/mefcs.dart';
import 'package:pocket_amp_tools/src/presets/nam_file.dart';
import 'package:pocket_amp_tools/src/presets/preset_backup.dart';
import 'package:pocket_amp_tools/src/presets/preset_meta.dart';
import 'package:flutter/painting.dart';
import 'package:pocket_amp_tools/src/ui/assistant_panel.dart';
import 'package:pocket_amp_tools/src/ui/assistant_tools.dart';
import 'package:pocket_amp_tools/src/ui/presets_page.dart';

import 'support/fake_pedal.dart';

PresetBackup _bank([Uint8List? area]) {
  final Uint8List a = area ?? demoBank();
  return PresetBackup(
    identity: 'Pocket AMP_105',
    created: DateTime.utc(2026),
    presets: Uint8List.sublistView(a, 0, eqTableAddress),
    eq: Uint8List.sublistView(a, eqTableAddress),
  );
}

/// P01's EQ as some pedals store it: position 128, bands past ±6.
Uint8List _lockedEq() =>
    demoBank()..setAll(eqTableAddress + eqHeaderLength, <int>[
      1, 0x80, 3, 0x78, 1, 0xBC, 0x1E, //
    ]);

const AssistantSettings _settings = AssistantSettings(
  baseUrl: 'https://ai.example/v1/',
  model: 'some-model',
  apiKey: 'k',
);

/// A chat-completions answer: some text, or tool calls.
http.Response _reply({
  String? text,
  List<(String, Map<String, Object?>)> calls = const [],
}) => http.Response(
  jsonEncode(<String, Object?>{
    'choices': <Object?>[
      <String, Object?>{
        'message': <String, Object?>{
          'role': 'assistant',
          'content': text,
          if (calls.isNotEmpty)
            'tool_calls': <Object?>[
              for (final (int i, (String name, Map<String, Object?> args))
                  in calls.indexed)
                <String, Object?>{
                  'id': 'c$i',
                  'type': 'function',
                  'function': <String, Object?>{
                    'name': name,
                    'arguments': jsonEncode(args),
                  },
                },
            ],
        },
        'finish_reason': calls.isEmpty ? 'stop' : 'tool_calls',
      },
    ],
  }),
  200,
);

class _Host implements AssistantHost {
  _Host(PresetBackup b) {
    workspace.load(b, 'test', fromPedal: true);
  }
  @override
  final PresetWorkspace workspace = PresetWorkspace();
  final List<String> did = <String>[];
  @override
  String? get pedal => 'Pocket AMP, firmware 1.05, USB';
  @override
  bool canUpload = true;
  @override
  bool get canWrite => true;
  @override
  Future<List<LibraryItem>> library(LibraryKind kind) async => <LibraryItem>[
    LibraryItem(kind, File('/lib/Mesa 4x12.${kind.extension}')),
  ];
  @override
  Future<Map<int, String>> links(LibraryKind kind) async => <int, String>{
    2: 'Mesa 4x12',
  };
  @override
  Future<String> uploadToSlot(LibraryItem item, int slot, String name) async {
    did.add('upload ${item.name} $slot $name');
    return 'sent';
  }

  @override
  Future<String> writePresets(PresetBackup presets) async {
    did.add('write');
    return 'written';
  }
}

AssistantTool _tool(List<AssistantTool> tools, String name) =>
    tools.firstWhere((AssistantTool t) => t.name == name);

void main() {
  test('a partial answer becomes a whole preset the pedal can take', () {
    final PresetBackup b = _bank();
    final Map<String, Object> current = b.presetFields(4);
    final Map<String, Object?> merged = mergeSuggestion(
      current,
      <String, Object?>{
        'volume': 70,
        'blocks': <String, Object?>{
          // A new model with only some knobs, no "knobN".
          'DLY': <String, Object?>{
            'on': true,
            'model': 'Duck',
            'knobs': <String, int>{'Time': 30, 'Mix': 25},
          },
          // Same model, one knob changed, by position as in the file.
          'AMP': <String, Object?>{
            'knobs': <Object?>[
              <String, Object?>{'label': 'Gain', 'value': 20},
            ],
          },
        },
      },
    );
    b.setPresetFields(4, merged);
    expect(b.volume(4), 70);
    expect(b.model(4, 3), 1); // Duck
    expect(b.isOn(4, 3), isTrue);
    expect(b.knob(4, 3, 0), 30);
    expect(b.knob(4, 3, 1), 0); // Fb, not given
    expect(b.knob(4, 1, 0), 20);
    expect(b.knob(4, 1, 1), _bank().knob(4, 1, 1), reason: 'kept');
    expect(b.chain(4), _bank().chain(4));
  });

  group('agent', () {
    test('calls tools, feeds their answers back and replies', () async {
      final List<Map<String, Object?>> sent = <Map<String, Object?>>[];
      int n = 0;
      final AssistantAgent a = AssistantAgent(
        settings: () async => _settings,
        tools: <AssistantTool>[
          AssistantTool(
            name: 'look',
            description: 'd',
            parameters: const <String, Object?>{'type': 'object'},
            annotations: const ToolAnnotations(title: 'Look', readOnly: true),
            run: (Map<String, Object?> args) async => 'seen ${args['what']}',
          ),
        ],
      );
      await http.runWithClient(
        () => a.send('what is on?'),
        () => MockClient((http.Request r) async {
          sent.add(jsonDecode(r.body) as Map<String, Object?>);
          expect(r.headers['authorization'], 'Bearer k');
          expect(r.url.toString(), 'https://ai.example/v1/chat/completions');
          return n++ == 0
              ? _reply(
                  calls: <(String, Map<String, Object?>)>[
                    ('look', <String, Object?>{'what': 'amp'}),
                  ],
                )
              : _reply(text: 'The amp is on.');
        }),
      );
      expect(sent, hasLength(2));
      expect(sent.first['tools'], hasLength(1));
      expect(
        (sent.first['messages']! as List<Object?>).first,
        containsPair('role', 'system'),
      );
      final List<Object?> second = sent[1]['messages']! as List<Object?>;
      // The assistant's call goes back without an empty text beside it.
      expect(second[2], isNot(contains('content')));
      expect(second[3], <String, Object?>{
        'role': 'tool',
        'tool_call_id': 'c0',
        'content': '{"result":"seen amp"}',
      });
      expect(a.entries.map((ChatEntry e) => e.role), <ChatRole>[
        ChatRole.user,
        ChatRole.tool,
        ChatRole.assistant,
      ]);
      expect(a.entries[1].status, ToolStatus.done);
      expect(a.busy, isFalse);
    });

    AssistantAgent destructive(List<String> ran, {bool autoWrite = false}) =>
        AssistantAgent(
          settings: () async => AssistantSettings(
            baseUrl: _settings.baseUrl,
            model: _settings.model,
            autoWrite: autoWrite,
          ),
          tools: <AssistantTool>[
            AssistantTool(
              name: 'burn',
              description: 'd',
              parameters: const <String, Object?>{'type': 'object'},
              annotations: const ToolAnnotations(
                title: 'Burn',
                destructive: true,
              ),
              run: (_) async {
                ran.add('burn');
                return 'burnt';
              },
            ),
          ],
        );

    Future<void> twoSteps(AssistantAgent a, List<String> answers) {
      int n = 0;
      return http.runWithClient(
        () => a.send('burn it'),
        () => MockClient((http.Request r) async {
          if (n++ == 0) {
            return _reply(
              calls: <(String, Map<String, Object?>)>[
                ('burn', <String, Object?>{}),
              ],
            );
          }
          final List<Object?> m =
              (jsonDecode(r.body) as Map<String, Object?>)['messages']!
                  as List<Object?>;
          answers.add('${(m.last! as Map<String, Object?>)['content']}');
          return _reply(text: 'ok');
        }),
      );
    }

    test('a tool that writes the pedal waits for the user', () async {
      final List<String> ran = <String>[];
      final List<String> answers = <String>[];
      final AssistantAgent a = destructive(ran);
      final Future<void> done = twoSteps(a, answers);
      while (a.waiting == null) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(ran, isEmpty, reason: 'nothing before the yes');
      a.answer(a.waiting!, true);
      await done;
      expect(ran, <String>['burn']);
      expect(answers.single, contains('burnt'));
    });

    test('a declined write is not done and the model is told', () async {
      final List<String> ran = <String>[];
      final List<String> answers = <String>[];
      final AssistantAgent a = destructive(ran);
      final Future<void> done = twoSteps(a, answers);
      while (a.waiting == null) {
        await Future<void>.delayed(Duration.zero);
      }
      a.answer(a.waiting!, false);
      await done;
      expect(ran, isEmpty);
      expect(answers.single, contains('declined'));
      expect(a.entries[1].status, ToolStatus.declined);
    });

    test('with writes allowed in Settings it does not ask', () async {
      final List<String> ran = <String>[];
      await twoSteps(destructive(ran, autoWrite: true), <String>[]);
      expect(ran, <String>['burn']);
    });

    test('bad calls are answered as errors, and the loop is capped', () async {
      int calls = 0;
      final AssistantAgent a = AssistantAgent(
        settings: () async => _settings,
        maxSteps: 3,
        tools: const <AssistantTool>[],
      );
      await http.runWithClient(
        () => a.send('loop'),
        () => MockClient((http.Request r) async {
          calls++;
          return _reply(
            calls: <(String, Map<String, Object?>)>[
              ('nope', <String, Object?>{}),
            ],
          );
        }),
      );
      expect(calls, 3);
      expect(a.entries.last.text, contains('Stopped after 3 steps'));
    });

    test("each service's own error words are passed on", () async {
      Future<String> failure(http.Response answer) async {
        final AssistantAgent a = AssistantAgent(
          settings: () async => _settings,
          tools: const <AssistantTool>[],
        );
        await http.runWithClient(
          () => a.send('x'),
          () => MockClient((_) async => answer),
        );
        return a.entries.last.text;
      }

      // OpenAI and most others, Gemini (in a list), and a bare string.
      expect(
        await failure(
          http.Response('{"error":{"message":"model x not found"}}', 404),
        ),
        allOf(contains('does not know'), contains('model x not found')),
      );
      expect(
        await failure(http.Response('[{"error":{"message":"quota"}}]', 429)),
        allOf(contains('rate-limiting'), contains('quota')),
      );
      expect(
        await failure(http.Response('{"error":"bad key"}', 401)),
        allOf(contains('API key'), contains('bad key')),
      );
      expect(
        await failure(http.Response('<html>', 500)),
        endsWith('HTTP 500.'),
      );
      expect(
        serviceError(utf8.encode('{"message":"${'a' * 400}"}')),
        hasLength(301),
      );
    });

    test('a hostile answer neither hangs nor fills memory', () async {
      final AssistantAgent a = AssistantAgent(
        settings: () async => _settings,
        tools: const <AssistantTool>[],
      );
      await http.runWithClient(
        () => a.send('x'),
        () => MockClient((_) async => http.Response('x' * (2 << 20), 200)),
      );
      expect(a.entries.last.text, contains('too much'));
    });
  });

  group('tools', () {
    test('edit_preset changes knobs by name and says what changed', () async {
      final _Host h = _Host(_bank());
      final List<AssistantTool> tools = assistantTools(h);
      final int gain = h.workspace.draft!.knob(0, 1, 0);
      final int newGain = gain == 10 ? 11 : 10;
      final Object? said = await _tool(tools, 'edit_preset').run(
        <String, Object?>{
          'preset': 'P01',
          'volume': 33,
          'blocks': <String, Object?>{
            'AMP': <String, Object?>{
              'knobs': <String, Object?>{'Gain': newGain},
            },
            'DLY': <String, Object?>{'on': true},
          },
          'chain': <String>['AMP', 'FX', 'MOD', 'DLY', 'REV', 'CAB'],
        },
      );
      final PresetBackup d = h.workspace.draft!;
      expect(d.volume(0), 33);
      expect(d.knob(0, 1, 0), newGain);
      expect(d.isOn(0, 3), isTrue);
      expect(d.chain(0).take(2), <int>[1, 0]);
      expect(said, allOf(contains('volume'), contains('AMP Gain')));
      expect(h.workspace.changed, <int>{0});
    });

    test('an EQ given only in part keeps the rest', () async {
      final _Host h = _Host(_bank());
      final PresetBackup d = h.workspace.draft!;
      d.setEqOn(0, true);
      d.setEqBand(0, 0, -2);
      final Object? said = await _tool(assistantTools(h), 'edit_preset').run(
        <String, Object?>{
          'eq': <String, Object?>{
            'bands': <int>[-6, 1, -3, -2, 2],
          },
        },
      );
      expect(d.eqOn(0), isTrue, reason: 'not given, kept');
      expect(d.eqBand(0, 0), -6);
      expect(said, contains('EQ band 1 -2 → -6'));
    });

    test('edit_preset refuses what the pedal cannot take', () async {
      final _Host h = _Host(_bank());
      final AssistantTool edit = _tool(assistantTools(h), 'edit_preset');
      final Uint8List before = Uint8List.fromList(h.workspace.draft!.presets);
      Future<String> refusal(Map<String, Object?> args) async {
        try {
          await edit.run(args);
        } on ToolError catch (e) {
          return e.message;
        }
        fail('accepted $args');
      }

      expect(
        await refusal(<String, Object?>{
          'blocks': <String, Object?>{
            'DLY': <String, Object?>{'model': 'Duck'},
          },
        }),
        contains('give a value for each of its knobs'),
      );
      expect(
        await refusal(<String, Object?>{
          'blocks': <String, Object?>{
            'AMP': <String, Object?>{
              'knobs': <String, Object?>{'Fuzz': 3},
            },
          },
        }),
        contains('no knob "Fuzz"'),
      );
      expect(
        await refusal(<String, Object?>{
          'chain': <String>['MOD', 'FX', 'AMP', 'DLY', 'REV', 'CAB'],
        }),
        contains('pedal can take'),
      );
      expect(
        await refusal(<String, Object?>{'preset': 'P99', 'volume': 1}),
        contains('P01 to P80'),
      );
      expect(h.workspace.draft!.presets, before, reason: 'untouched');
    });

    test('an EQ the app cannot write back stays as stored', () async {
      final _Host h = _Host(_bank(_lockedEq()));
      final List<AssistantTool> tools = assistantTools(h);
      final List<int> eq = List<int>.of(h.workspace.draft!.eqRecord(0));
      expect(
        await _tool(tools, 'get_preset').run(<String, Object?>{}),
        containsPair('eq_note', contains('cannot change')),
      );
      await _tool(tools, 'edit_preset').run(<String, Object?>{'volume': 12});
      expect(h.workspace.draft!.volume(0), 12);
      expect(h.workspace.draft!.eqRecord(0), eq);
      await expectLater(
        _tool(tools, 'edit_preset').run(<String, Object?>{
          'eq': <String, Object?>{'on': false},
        }),
        throwsA(isA<ToolError>()),
      );
    });

    test('upload and write go through the host, checked first', () async {
      final _Host h = _Host(_bank());
      final List<AssistantTool> tools = assistantTools(h);
      final AssistantTool upload = _tool(tools, 'upload_to_slot');
      expect(upload.annotations.destructive, isTrue);
      expect(
        upload.describe!(<String, Object?>{
          'kind': 'cab',
          'file': 'Mesa 4x12',
          'slot': 3,
        }),
        startsWith('Send "Mesa 4x12" to CAB slot 3, replacing'),
      );
      await upload.run(<String, Object?>{
        'kind': 'cab',
        'file': 'Mesa 4x12',
        'slot': 3,
        'name': 'Mesa/4x12 cabinet!',
      });
      expect(h.did.single, startsWith('upload Mesa 4x12 2 '));
      await expectLater(
        upload.run(<String, Object?>{'kind': 'cab', 'file': 'x', 'slot': 3}),
        throwsA(isA<ToolError>()),
      );
      h.canUpload = false;
      await expectLater(
        upload.run(<String, Object?>{
          'kind': 'cab',
          'file': 'Mesa 4x12',
          'slot': 3,
        }),
        throwsA(isA<ToolError>()),
      );
      final AssistantTool write = _tool(tools, 'write_presets');
      await expectLater(
        write.run(<String, Object?>{}),
        throwsA(isA<ToolError>()),
        reason: 'nothing edited yet',
      );
      await _tool(tools, 'edit_preset').run(<String, Object?>{'volume': 1});
      expect(write.describe!(<String, Object?>{}), contains('P01'));
      await write.run(<String, Object?>{});
      expect(h.did.last, 'write');

      // An edit made while the user is asked is not written with the yes.
      await _tool(tools, 'edit_preset').run(<String, Object?>{'volume': 2});
      write.describe!(<String, Object?>{});
      await _tool(
        tools,
        'edit_preset',
      ).run(<String, Object?>{'preset': 'P02', 'volume': 3});
      await expectLater(
        write.run(<String, Object?>{}),
        throwsA(
          isA<ToolError>().having(
            (ToolError e) => e.message,
            'message',
            contains('changed while'),
          ),
        ),
      );
      expect(h.did.where((String d) => d == 'write'), hasLength(1));
    });

    test('preset details are read, set and checked', () async {
      final _Host h = _Host(_bank());
      final List<AssistantTool> tools = assistantTools(h);
      final AssistantTool set = _tool(tools, 'set_preset_details');
      expect(
        await set.run(<String, Object?>{
          'preset': 'P03',
          'name': ' Glassy Clean ',
          'genres': <Object?>['blues', 'Shoegaze'],
          'rating': 4,
        }),
        <String, Object?>{
          'preset': 'P03',
          'name': 'Glassy Clean',
          // An offered label keeps its spelling; a new one joins the list.
          'genres': <String>['Blues', 'Shoegaze'],
          'rating': 4,
        },
      );
      final PresetDetails details = h.workspace.details;
      expect(details.labels[MetaCategory.genres], contains('Shoegaze'));
      expect(
        (await _tool(tools, 'list_presets').run(<String, Object?>{})
            as List<String>)[2],
        endsWith(
          ', named "Glassy Clean", 4 of 5 stars, labels: Blues, Shoegaze',
        ),
      );
      expect(
        await _tool(
          tools,
          'get_preset',
        ).run(<String, Object?>{'preset': 'P03'}),
        containsPair('details', containsPair('name', 'Glassy Clean')),
      );
      expect(
        await _tool(
          tools,
          'get_preset',
        ).run(<String, Object?>{'preset': 'P04'}),
        isNot(contains('details')),
      );
      // The pedal's presets are untouched.
      expect(h.workspace.changed, isEmpty);

      // A bad value changes nothing, not even the good ones beside it.
      await expectLater(
        set.run(<String, Object?>{'preset': 'P03', 'name': 'x', 'rating': 9}),
        throwsA(isA<ToolError>()),
      );
      await expectLater(
        set.run(<String, Object?>{'preset': 'P03'}),
        throwsA(isA<ToolError>()),
      );
      expect(details.metas[2].name, 'Glassy Clean');
      // Without presets loaded there is nothing to describe.
      final _Host empty = _Host(_bank())..workspace.draft = null;
      await expectLater(
        _tool(
          assistantTools(empty),
          'set_preset_details',
        ).run(<String, Object?>{'rating': 5}),
        throwsA(isA<ToolError>()),
      );
      expect(empty.workspace.details.metas[0].isEmpty, isTrue);
      // An empty list clears; what was not given stays.
      await set.run(<String, Object?>{'preset': 'P03', 'genres': <Object?>[]});
      expect(details.metas[2].labels[MetaCategory.genres], isEmpty);
      expect(details.metas[2].rating, 4);
    });

    test('the read tools describe presets, models, slots and files', () async {
      final _Host h = _Host(_bank());
      final List<AssistantTool> tools = assistantTools(h);
      expect(
        await _tool(tools, 'list_presets').run(<String, Object?>{}),
        hasLength(presetCount),
      );
      final Map<String, Object?> amp =
          (await _tool(
                tools,
                'list_models',
              ).run(<String, Object?>{'block': 'AMP'}))!
              as Map<String, Object?>;
      expect(amp['knob_guide'], contains('150 Hz'));
      final List<Object?> amps = amp['models']! as List<Object?>;
      expect(amps.first, containsPair('slot', 1));
      expect(amps[2], containsPair('library_file', 'Mesa 4x12'));
      expect(
        amps[2],
        containsPair('likely_gear (guessed from the name)', contains('JC-120')),
      );
      expect(
        await _tool(
          tools,
          'list_library',
        ).run(<String, Object?>{'kind': 'cab'}),
        <Object?>[
          <String, Object?>{
            'file': 'Mesa 4x12',
            'in_slots': <int>[3],
          },
        ],
      );
      expect(
        await _tool(tools, 'get_state').run(<String, Object?>{}),
        containsPair('open_preset', 'P01'),
      );
      // Every tool has a schema object the services take.
      for (final AssistantTool t in tools) {
        expect(t.parameters['type'], 'object', reason: t.name);
      }
    });
  });

  test('replies show bold, code and lists without the marks', () {
    const TextStyle base = TextStyle(fontSize: 14);
    final TextSpan span = markdownLite(
      '## Done\n**Amp:** Bass `45` → 20\n- one\n* two\n3) three',
      base,
    );
    expect(
      span.toPlainText(),
      'Done\nAmp: Bass 45 → 20\n•  one\n•  two\n3.  three',
    );
    final List<String> bold = <String>[];
    span.visitChildren((InlineSpan s) {
      if (s is TextSpan && s.style?.fontWeight == FontWeight.w600) {
        bold.add(s.text!);
      }
      return true;
    });
    expect(bold, <String>['Done', 'Amp:']);
  });

  test('a capture tells the assistant what gear it is', () {
    // As TONE3000 writes it.
    expect(
      namMetadata(
        jsonEncode(<String, Object?>{
          'metadata': <String, Object?>{
            'name': 'ENGL FB25 Lead - Modern',
            'modeled_by': 'dissonaunte',
            'gear_type': 'amp',
            'gear_make': 'Horizon Devices Precision Drive',
            'gear_model': 'Horizon Devices Precision Drive',
            'tone_type': 'metal',
            'gain': 0.680658,
            'loudness': -15.843637,
            'input_level_dbu': 10,
          },
        }),
      ),
      <String, Object?>{
        'name': 'ENGL FB25 Lead - Modern',
        'gear': 'Horizon Devices Precision Drive',
        'gear_type': 'amp',
        'tone_type': 'metal',
        'gain': 0.68,
        'loudness_db': -15.8,
        'captured_by': 'dissonaunte',
      },
    );
    expect(
      namMetadata(
        '{"metadata":{"gear_make":"Marshall","gear_model":"JCM800"}}',
      ),
      <String, Object?>{'gear': 'Marshall JCM800'},
    );
    expect(namMetadata('not json'), isEmpty);
  });

  test('every model of the pedal has a line in the catalog', () {
    for (final MapEntry<String, List<(String, List<String>)>> b
        in blockModels.entries) {
      expect(blockKnobGuide[b.key], isNotNull, reason: b.key);
      for (final (String name, _) in b.value) {
        expect(modelInfo[b.key]?[name], isNotNull, reason: '${b.key} $name');
      }
    }
  });
}
