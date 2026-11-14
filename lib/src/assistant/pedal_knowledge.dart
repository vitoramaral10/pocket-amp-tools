// SPDX-License-Identifier: GPL-3.0-only
//
// What the assistant knows about the pedal's sounds beyond their names.
// Two kinds of fact, kept apart so the model can say which it is using:
// - "knobs" and the "does" notes come from the firmware V1.05 reconstruction
//   (pocket-amp-firmware/reconstrucao/audio-r3/AUDIO.md §2): how each knob
//   maps to dB, Hz or seconds, and what some models really do;
// - "likely" is the real gear a model seems to copy, read from its name
//   only. No public source names them (searched November 2026), so it is a
//   guess and is labelled one.

/// What a block's knobs do, from the firmware.
const Map<String, String> blockKnobGuide = <String, String>{
  'FX':
      'Gate (every model): a noise gate after the effect; 0 off, higher '
      'closes sooner. Boost: Gain up to 60 gives up to about +4 dB, then a '
      'peak limiter. Compress: Sustain is the amount of compression, '
      'Attack how fast it grabs, Level the output. Drive pedals (MW-): Gain '
      'or Fuzz or Sustain is the drive, Tone/Filter the brightness (on RAT '
      'more Filter is darker), Level the output; 50 is about unity.',
  'AMP':
      'Gain: drive into the amp model. Level: output volume of the block. '
      'Bass is a low shelf near 150 Hz (about ±20 dB), Mid a peak near '
      '425 Hz (about ±15 dB), Treble a high shelf near 1.8 kHz (about '
      '±10 dB); 50 is flat on all three, and a few steps already change a '
      'lot. A slot replaced by a NAM capture plays that capture with the '
      'same five knobs.',
  'MOD':
      'Speed is the rate (Chorus: about 0.1 to 5 Hz, rising faster near the '
      'top), Depth the amount, Mix the wet/dry blend (Tremolo: Level). '
      'Left and right move a quarter cycle apart, so most of them sound '
      'wide.',
  'DLY':
      'Time: up to 900 ms at 100 (Dual: up to 450 ms); 10-15 is a slapback, '
      '35-60 a typical rhythmic echo. Fb: number of repeats. Mix: echo '
      'level. Speed/Depth: modulation of the repeats (wobble). Grit: '
      'dirt and filtering (Dtape, Lofi). How Time maps to ms between 0 and '
      '100 is not measured.',
  'REV':
      'Decay: about 0.3 s at 0 up to 10 s at 100 (0.3 + 0.097 per step). '
      'Mix: reverb level; 15-30 is natural, 40+ is an effect. HPass and '
      'LPass: in the firmware the labels look swapped (HPass drives a '
      'low-pass filter, LPass a high-pass), so to darken the tail lower '
      'HPass. Depth/RiseT/Combs/Amt/Diff: the model\'s own character knob.',
  'CAB':
      'Level: output, 0.5 dB per step (100 is full level, 80 is about '
      '-10 dB). Low Cut: 0..100 maps to 20..300 Hz, removes low end (raise '
      'it to tighten or thin the sound). High Cut: 0..100 maps to '
      '5..18 kHz, lower it to tame fizz and harshness.',
};

/// The post-chain EQ, from the firmware.
const String eqGuide =
    'EQ bands, in order: 100 Hz low shelf, 250 Hz, 800 Hz, 2 kHz (peaks) '
    'and 10 kHz high shelf. Each step is 0.5 dB, so -6..6 is -3..+3 dB: a '
    'gentle finishing EQ, not a big tone change. Head puts it before the '
    'whole chain, Tail after it.';

/// One model: what it seems to copy and what it is known to do.
class ModelInfo {
  const ModelInfo({this.likely, this.does, this.use});

  /// The real gear its name points to: a guess, see the file comment.
  final String? likely;

  /// What it does, from the firmware or the plain meaning of the effect.
  final String? does;

  /// Where it fits.
  final String? use;

  Map<String, Object?> toJson() => <String, Object?>{
    if (likely != null) 'likely_gear (guessed from the name)': likely,
    if (does != null) 'does': does,
    if (use != null) 'use': use,
  };
}

const Map<String, Map<String, ModelInfo>> modelInfo =
    <String, Map<String, ModelInfo>>{
      'FX': <String, ModelInfo>{
        'Noise Gate': ModelInfo(does: 'Noise gate only.', use: 'high gain'),
        'Boost': ModelInfo(
          does: 'Clean boost of up to about 4 dB with a peak limiter.',
          use: 'solos, pushing the amp a little',
        ),
        'Compress': ModelInfo(
          does:
              'Compressor with soft knee and a little tube-like '
              'saturation.',
          use: 'clean funk, country, sustain for leads',
        ),
        'AI Ms Gate': ModelInfo(
          does: 'Smarter noise gate; Bias moves its threshold.',
          use: 'high gain with fast stops',
        ),
        'MW-808': ModelInfo(
          likely: 'Ibanez TS808 Tube Screamer',
          does: 'Mid-focused soft-clipping overdrive.',
          use: 'blues, tightening a high-gain amp (low Gain, high Level)',
        ),
        'MW-GOLD': ModelInfo(
          likely: 'Klon Centaur (gold "klone")',
          does: 'Transparent overdrive: clean and driven paths mixed.',
          use: 'blues, rock, light crunch keeping the guitar\'s voice',
        ),
        'MW-OCD': ModelInfo(
          likely: 'Fulltone OCD',
          does:
              'Amp-like overdrive to distortion; Type and Mode switch '
              'voicings (low/high pass, version).',
          use: 'classic rock, crunch',
        ),
        'MW-RAT': ModelInfo(
          likely: 'ProCo RAT',
          does: 'Hard-clipping distortion; Filter darkens as it rises.',
          use: 'grunge, punk, rock',
        ),
        'MW-MUFF': ModelInfo(
          likely: 'Electro-Harmonix Big Muff',
          does: 'Thick sustaining fuzz, two clipping stages.',
          use: 'stoner, shoegaze, Gilmour-style leads',
        ),
        'MW-FACE': ModelInfo(
          likely: 'Dallas Arbiter Fuzz Face',
          does: 'Vintage germanium-style fuzz.',
          use: '60s rock, Hendrix',
        ),
      },
      'AMP': <String, ModelInfo>{
        '1J900_CL': ModelInfo(
          likely: 'Marshall JCM900, clean channel',
          use: 'clean',
        ),
        '2FD_CL': ModelInfo(
          likely: 'Fender (Deluxe/Twin type) clean',
          use: 'clean, country, funk, pedal platform',
        ),
        '3JC120_CL': ModelInfo(
          likely: 'Roland JC-120 Jazz Chorus',
          use: 'very clean and bright, jazz, chorus sounds',
        ),
        '4BLUE_OD': ModelInfo(likely: 'a bluesy overdrive amp', use: 'blues'),
        '5RAT_OD': ModelInfo(
          likely: 'an amp voiced like a RAT-driven tone',
          use: 'rock',
        ),
        '6M-VAVE_OD': ModelInfo(
          likely: 'M-VAVE\'s own overdrive voicing',
          use: 'crunch, rock',
        ),
        '7SUPA_OD': ModelInfo(
          likely: 'Supro or Marshall Super Lead style overdrive',
          use: 'classic rock',
        ),
        '8DARKS_DS': ModelInfo(likely: 'a dark distortion', use: 'metal'),
        '9J900_DS': ModelInfo(
          likely: 'Marshall JCM900, lead channel',
          use: '90s rock, hard rock',
        ),
        '10JHS_DS': ModelInfo(
          likely: 'a JHS distortion pedal into an amp',
          use: 'rock, hard rock',
        ),
        '11EVH_5150': ModelInfo(
          likely: 'EVH / Peavey 5150',
          use: 'metal, hard rock',
        ),
        '12FRIMAN': ModelInfo(
          likely: 'Friedman (BE-100 type)',
          use: 'modern hard rock, hot-rodded Marshall tone',
        ),
        '13XC_DS': ModelInfo(likely: 'a high-gain distortion', use: 'metal'),
        '14ROOM40': ModelInfo(likely: 'unknown from the name'),
        '15JVM': ModelInfo(likely: 'Marshall JVM', use: 'rock to high gain'),
        '16AgDb750_BS': ModelInfo(
          likely: 'Aguilar DB 750 bass amp',
          use: 'bass only',
        ),
        '17ApSVT_BS': ModelInfo(likely: 'Ampeg SVT bass amp', use: 'bass only'),
        '18PjBuddy_BS': ModelInfo(
          likely: 'Phil Jones Bass Buddy',
          use: 'bass only',
        ),
        '19DgXu_BS': ModelInfo(
          likely: 'Darkglass Microtubes X Ultra',
          use: 'bass only, modern distorted bass',
        ),
        '20MarkLm_BS': ModelInfo(
          likely: 'Markbass Little Mark',
          use: 'bass only',
        ),
      },
      'MOD': <String, ModelInfo>{
        'Chorus': ModelInfo(does: 'Stereo chorus.'),
        'Phaser': ModelInfo(
          does: 'Sweeping phaser; MidCut and Reso shape the notches.',
        ),
        'Tremolo': ModelInfo(does: 'Volume tremolo.'),
        'Flanger': ModelInfo(does: 'Stereo flanger; Fb adds the jet sound.'),
        'Vibrato': ModelInfo(does: 'Pure pitch vibrato (0 to 10 ms delay).'),
        'Univibe': ModelInfo(
          likely: 'Shin-ei Uni-Vibe',
          does: 'Throbbing phase-shift, Depth sets the sweep position.',
          use: 'Hendrix, psychedelic',
        ),
        'Autofilter': ModelInfo(
          does: 'Auto-wah: a filter swept by an LFO between Min and Max.',
          use: 'funk',
        ),
      },
      'DLY': <String, ModelInfo>{
        'Analog': ModelInfo(
          does: 'Warm analog-style delay; Phaser and Pitch add movement.',
        ),
        'Duck': ModelInfo(
          does:
              'Ducking delay: repeats stay quiet while you play and come '
              'up in the gaps.',
          use: 'leads that stay clear',
        ),
        'Dtape': ModelInfo(does: 'Tape echo with wobble and grit.'),
        'Dual': ModelInfo(
          does: 'Two-tap delay (ratio set by T-Mode), up to 450 ms.',
          use: 'rhythmic patterns',
        ),
        'Lofi': ModelInfo(does: 'Dirty, filtered lo-fi delay.'),
      },
      'REV': <String, ModelInfo>{
        'Room': ModelInfo(does: 'Small room.', use: 'natural ambience'),
        'Hall': ModelInfo(does: 'Large hall.', use: 'leads, ballads'),
        'Swell': ModelInfo(
          does: 'Reverb that swells in (RiseT sets how slowly).',
          use: 'ambient pads',
        ),
        'Spring': ModelInfo(
          does: 'Spring reverb from a real spring impulse response.',
          use: 'surf, vintage clean, Fender tones',
        ),
        'Shimmer': ModelInfo(
          does: 'Reverb with a pitch-shifted (octave up by default) tail.',
          use: 'ambient, post-rock',
        ),
        'Cloud': ModelInfo(
          does: 'Dense, diffuse, modulated wash (Diff sets the smear).',
          use: 'ambient',
        ),
      },
      'CAB': <String, ModelInfo>{
        '1AC-SeVin': ModelInfo(
          likely: 'Vox AC-type cab with vintage Celestion speakers',
          use: 'chime, British clean and crunch',
        ),
        '2JVM_1960_57': ModelInfo(
          likely: 'Marshall 1960 4x12, Shure SM57',
          use: 'classic and hard rock',
        ),
        '3V30_MD421': ModelInfo(
          likely: 'Celestion Vintage 30 speaker, Sennheiser MD 421',
          use: 'rock, high gain, mid-forward',
        ),
        '4G12-EVH_CT': ModelInfo(
          likely: 'EVH 4x12 with Celestion G12-EVH',
          use: 'hard rock, metal',
        ),
        '5HIFI_OK': ModelInfo(likely: 'a hi-fi, flat cab', use: 'clean'),
        '6WANGS212_ECM': ModelInfo(
          likely: 'a 2x12 cab with a condenser mic',
          use: 'clean to crunch',
        ),
        '7VOX_AC30': ModelInfo(
          likely: 'Vox AC30 2x12',
          use: 'chime, British pop and rock',
        ),
        '8FRMAN112': ModelInfo(
          likely: 'Friedman 1x12',
          use: 'rock, tight high gain',
        ),
        '9MeOSick-III': ModelInfo(
          likely: 'Mesa/Boogie (Oversized 4x12 or Mark III cab)',
          use: 'metal, heavy rock',
        ),
        '10SoldSC412': ModelInfo(likely: 'Soldano 4x12', use: 'hard rock'),
        '11FD_TW1980': ModelInfo(
          likely: 'Fender Twin Reverb (1980) 2x12',
          use: 'sparkling clean, country, funk',
        ),
        '12MESA_412': ModelInfo(
          likely: 'Mesa/Boogie 4x12',
          use: 'metal, modern high gain',
        ),
        '13HIW412SWF': ModelInfo(
          likely: 'Hiwatt 4x12 (Fane speakers)',
          use: 'big clean and crunch, 70s rock',
        ),
        '14Recto_112': ModelInfo(
          likely: 'Mesa Rectifier 1x12',
          use: 'high gain, tighter than a 4x12',
        ),
        '15JC120_BOX': ModelInfo(
          likely: 'Roland JC-120 cab',
          use: 'very clean, jazz',
        ),
        '16Agula410': ModelInfo(likely: 'Aguilar 4x10', use: 'bass only'),
        '17AgSVT410': ModelInfo(likely: 'Ampeg SVT 4x10', use: 'bass only'),
        '18DgDG212N': ModelInfo(likely: 'Darkglass DG212N', use: 'bass only'),
        '19MbSway210': ModelInfo(likely: 'a 2x10 bass cab', use: 'bass only'),
        '20Tace412': ModelInfo(
          likely: 'Trace Elliot 4x12 (bass)',
          use: 'bass only',
        ),
      },
    };
