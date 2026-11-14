# Changelog

What changed in each release, for people who use the app. The commit-level list of every release is on the [releases page](https://github.com/vitoramaral10/pocket-amp-tools/releases).

## 0.3.0

First release outside beta, and the first that runs on Android.

### Android

- The app runs on Android 8 and newer, over a USB OTG cable or Bluetooth ([#33](https://github.com/vitoramaral10/pocket-amp-tools/issues/33)).
- **Pair over Bluetooth** in the app scans for the pedal and opens Android's pairing dialog; no terminal needed.
- Over Bluetooth you can read, edit and write presets and send IRs and amp captures. Firmware updates need the cable, so the Firmware section shows only with a pedal on USB.
- The layout fits a phone: labels sit above the sliders, the block row scrolls and every knob stays on screen.

### Presets

- Each preset can have a **name, description, genres, usage, tags and a 1 to 5 star rating**, kept on your computer, and the list can be filtered by them ([#31](https://github.com/vitoramaral10/pocket-amp-tools/issues/31)).
- **Keyboard shortcuts** for the whole editor: move through presets, open and toggle blocks, step models, filter, copy and paste, write to the pedal. **?** lists them ([#32](https://github.com/vitoramaral10/pocket-amp-tools/issues/32)).
- The editor was rebuilt: the chain chips open their block, a backup opened in the editor is marked as such with **Back to the pedal** and **Restore to pedal…**, and success is reported in a snackbar instead of staying on the page.
- Presets are read on their own once the pedal is detected, and plugging or unplugging the pedal needs no click.
- EQ bands are labelled by frequency (100Hz to 10kHz) and show their value in dB. Thanks to [@amagnolo](https://github.com/amagnolo).
- Writing an edit reads and checks only the presets that changed, instead of the whole bank before and after.
- **Ask before writing to the pedal** can be turned off in Settings.
- A pedal on older clone firmware (PIXIE1 V0.07) opens P01 to P79 to view, without the EQ, instead of failing to read.
- A pedal that is not on the list of confirmed clones but keeps its presets in the Pocket AMP layout is detected as *presets only*: backups and presets work, firmware updates stay blocked.

### Library

- A new **Library** section replaces Cabinets. It keeps your IRs (`.wav`) and amp captures (`.nam`) on the computer and sends them to the pedal's 20 CAB and 20 AMP slots, remembering which file went to which slot.
- **Amp captures**: an A2 `.nam` file from TONE3000 goes into an AMP slot. The pedal plays its small (Lite) model, copied as it is; A1 files are refused with the reason.
- IR copies that 0.2 kept in `Documents/Pocket AMP Tools/IRs` are not moved; add them to the library to use them again.

### Assistant

- The assistant is now a **side panel** next to the editor that talks over several turns and acts through tools: it reads and edits presets, sets their names and labels, lists the library and the pedal's slots, and can send a file to a slot or write presets.
- It asks before anything that writes the pedal's memory, unless you allow it in Settings.
- It knows what each model and knob does (in dB, Hz and seconds) instead of guessing from names.
- **Settings** lists 28 OpenAI-compatible services to pick from, plus a custom address, and shows the service's own error message when a request fails.

### Backups

- A backup can be deleted from the **Backups** section.
- A raw copy from a pedal whose name has spaces (a Donner) restores again.
- Backups saved by 0.2.0-beta.1 with the Phaser or Dual delay models restore again.

### App

- New look: app theme, block icons and colours, empty states, and a short introduction on first run.
- **Settings** has its own page, opened from the ⋮ menu, which also holds About and the session log.
- **Error reports** (Sentry) are off until you agree, asked once on first run; the bug button at the top changes the answer.
- macOS notices when the pedal is unplugged.
- Release files carry a build attestation: `gh attestation verify <file> --repo vitoramaral10/pocket-amp-tools`.

### Known limits

- Sending an IR or an amp capture over Bluetooth was not yet tried on a pedal.
- Firmware updates on Android (USB OTG) were not yet reported on a pedal.
- Windows and macOS have no Bluetooth; use the USB cable there.
