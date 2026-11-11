// SPDX-License-Identifier: GPL-3.0-only

/// Models of each block in firmware V1.05, in the order the pedal lists them,
/// with the names of their knobs. Collected by @amagnolo in issue #11. The
/// model number stored in a preset is taken as the index in this list; that
/// and the knob order are not yet checked against a pedal.
/// Names the list below. Backup files carry it: their model and knob names
/// only mean the same bytes with the same list, so a file written with
/// another list is refused instead of restoring different bytes. Change it
/// whenever an entry, the order or a knob name changes.
const String modelListId = 'v1.05-issue11';

const Map<String, List<(String, List<String>)>> blockModels =
    <String, List<(String, List<String>)>>{
      'FX': <(String, List<String>)>[
        ('Noise Gate', <String>['Gate']),
        ('Boost', <String>['Gate', 'Gain']),
        ('Compress', <String>['Gate', 'Sustain', 'Attack', 'Level']),
        ('AI Ms Gate', <String>['Gate', 'Bias']),
        ('MW-808', <String>['Gate', 'Gain', 'Tone', 'Level']),
        ('MW-GOLD', <String>['Gate', 'Gain', 'Tone', 'Level']),
        ('MW-OCD', <String>['Gate', 'Gain', 'Tone', 'Type', 'Mode', 'Level']),
        ('MW-RAT', <String>['Gate', 'Gain', 'Filter', 'Level']),
        ('MW-MUFF', <String>['Gate', 'Sustain', 'Tone', 'Level']),
        ('MW-FACE', <String>['Gate', 'Fuzz', 'Level']),
      ],
      'AMP': <(String, List<String>)>[
        ('1J900_CL', <String>['Gain', 'Level', 'Bass', 'Mid', 'Treble']),
        ('2FD_CL', <String>['Gain', 'Level', 'Bass', 'Mid', 'Treble']),
        ('3JC120_CL', <String>['Gain', 'Level', 'Bass', 'Mid', 'Treble']),
        ('4BLUE_OD', <String>['Gain', 'Level', 'Bass', 'Mid', 'Treble']),
        ('5RAT_OD', <String>['Gain', 'Level', 'Bass', 'Mid', 'Treble']),
        ('6M-VAVE_OD', <String>['Gain', 'Level', 'Bass', 'Mid', 'Treble']),
        ('7SUPA_OD', <String>['Gain', 'Level', 'Bass', 'Mid', 'Treble']),
        ('8DARKS_DS', <String>['Gain', 'Level', 'Bass', 'Mid', 'Treble']),
        ('9J900_DS', <String>['Gain', 'Level', 'Bass', 'Mid', 'Treble']),
        ('10JHS_DS', <String>['Gain', 'Level', 'Bass', 'Mid', 'Treble']),
        ('11EVH_5150', <String>['Gain', 'Level', 'Bass', 'Mid', 'Treble']),
        ('12FRIMAN', <String>['Gain', 'Level', 'Bass', 'Mid', 'Treble']),
        ('13XC_DS', <String>['Gain', 'Level', 'Bass', 'Mid', 'Treble']),
        ('14ROOM40', <String>['Gain', 'Level', 'Bass', 'Mid', 'Treble']),
        ('15JVM', <String>['Gain', 'Level', 'Bass', 'Mid', 'Treble']),
        ('16AgDb750_BS', <String>['Gain', 'Level', 'Bass', 'Mid', 'Treble']),
        ('17ApSVT_BS', <String>['Gain', 'Level', 'Bass', 'Mid', 'Treble']),
        ('18PjBuddy_BS', <String>['Gain', 'Level', 'Bass', 'Mid', 'Treble']),
        ('19DgXu_BS', <String>['Gain', 'Level', 'Bass', 'Mid', 'Treble']),
        ('20MarkLm_BS', <String>['Gain', 'Level', 'Bass', 'Mid', 'Treble']),
      ],
      'MOD': <(String, List<String>)>[
        ('Chorus', <String>['Speed', 'Depth', 'Mix']),
        ('Phaser', <String>['Speed', 'MidCut (ParamA)', 'Reso (ParamB)', 'Fb']),
        ('Tremolo', <String>['Speed', 'Depth', 'Level']),
        ('Flanger', <String>['Speed', 'Depth', 'Fb', 'Mix']),
        ('Vibrato', <String>['Speed', 'Depth']),
        ('Univibe', <String>['Speed', 'Depth', 'Mix']),
        ('Autofilter', <String>['Speed', 'Min', 'Max', 'Mix', 'Fb']),
      ],
      'DLY': <(String, List<String>)>[
        ('Analog', <String>['Time', 'Fb', 'Mix', 'Phaser', 'Pitch']),
        ('Duck', <String>['Time', 'Fb', 'Mix', 'Unpack', 'Speed', 'Depth']),
        ('Dtape', <String>['Time', 'Fb', 'Mix', 'Grit', 'Speed', 'Depth']),
        ('Dual', <String>['Time', 'Fb', 'Mix', 'T-Mode (Grit)', 'Speed', 'Depth']),
        ('Lofi', <String>['Time', 'Fb', 'Mix', 'Grit', 'Speed', 'Depth']),
      ],
      'REV': <(String, List<String>)>[
        ('Room', <String>['Decay', 'Mix', 'HPass', 'LPass', 'Depth']),
        ('Hall', <String>['Decay', 'Mix', 'HPass', 'LPass', 'Depth']),
        ('Swell', <String>['Decay', 'Mix', 'HPass', 'LPass', 'RiseT']),
        ('Spring', <String>['Decay', 'Mix', 'HPass', 'LPass', 'Combs']),
        ('Shimmer', <String>['Decay', 'Mix', 'Tone', 'Pitch', 'Amt']),
        ('Cloud', <String>['Decay', 'Mix', 'HPass', 'LPass', 'Diff']),
      ],
      'CAB': <(String, List<String>)>[
        ('1AC-SeVin', <String>['Level', 'Low Cut', 'High Cut']),
        ('2JVM_1960_57', <String>['Level', 'Low Cut', 'High Cut']),
        ('3V30_MD421', <String>['Level', 'Low Cut', 'High Cut']),
        ('4G12-EVH_CT', <String>['Level', 'Low Cut', 'High Cut']),
        ('5HIFI_OK', <String>['Level', 'Low Cut', 'High Cut']),
        ('6WANGS212_ECM', <String>['Level', 'Low Cut', 'High Cut']),
        ('7VOX_AC30', <String>['Level', 'Low Cut', 'High Cut']),
        ('8FRMAN112', <String>['Level', 'Low Cut', 'High Cut']),
        ('9MeOSick-III', <String>['Level', 'Low Cut', 'High Cut']),
        ('10SoldSC412', <String>['Level', 'Low Cut', 'High Cut']),
        ('11FD_TW1980', <String>['Level', 'Low Cut', 'High Cut']),
        ('12MESA_412', <String>['Level', 'Low Cut', 'High Cut']),
        ('13HIW412SWF', <String>['Level', 'Low Cut', 'High Cut']),
        ('14Recto_112', <String>['Level', 'Low Cut', 'High Cut']),
        ('15JC120_BOX', <String>['Level', 'Low Cut', 'High Cut']),
        ('16Agula410', <String>['Level', 'Low Cut', 'High Cut']),
        ('17AgSVT410', <String>['Level', 'Low Cut', 'High Cut']),
        ('18DgDG212N', <String>['Level', 'Low Cut', 'High Cut']),
        ('19MbSway210', <String>['Level', 'Low Cut', 'High Cut']),
        ('20Tace412', <String>['Level', 'Low Cut', 'High Cut']),
      ],
    };
