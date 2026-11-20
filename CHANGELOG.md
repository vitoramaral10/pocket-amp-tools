# Changelog

What changed in each release, for people who use the app. The commit-level list of every release is on the [releases page](https://github.com/vitoramaral10/pocket-amp-tools/releases).

## [0.5.0](https://github.com/vitoramaral10/pocket-amp-tools/compare/pocket_amp_tools-v0.4.0...pocket_amp_tools-v0.5.0) (2026-11-18)


### ⚠ BREAKING CHANGES

* **backup:** list knobs by position, with labels only to read
* the binary, release files and AppImage are now named pocket-amp-tools; new backups go to Documents/Pocket AMP Tools.

### Features

* add cross-platform Pocket AMP firmware updater ([2c8a4ae](https://github.com/vitoramaral10/pocket-amp-tools/commit/2c8a4ae2ed40fada51618a717f66198c305f6863))
* add Sentry telemetry, onboarding and visual refresh ([519dabb](https://github.com/vitoramaral10/pocket-amp-tools/commit/519dabb210109082d3026a6b17a29f20d3523ea6))
* add Sentry telemetry, onboarding, visual refresh and AMP/IR upload ([ccd9d94](https://github.com/vitoramaral10/pocket-amp-tools/commit/ccd9d947a12c887117f3594cc19da19a72b3c6a5))
* add the New Bee SK17 as a Pocket AMP rebrand ([b9b29c1](https://github.com/vitoramaral10/pocket-amp-tools/commit/b9b29c1da672baca9b908d7d26745b2fc91aa308))
* add the New Bee SK17 as a Pocket AMP rebrand ([0a66865](https://github.com/vitoramaral10/pocket-amp-tools/commit/0a668654bdadfe421cd5a9436ea42bb87ebe1b64))
* **android:** bluetooth via universal_ble, raw flash preset writes and in-app pairing ([5ac1dda](https://github.com/vitoramaral10/pocket-amp-tools/commit/5ac1dda6a11754b6063438911303efc7b0b85e57))
* **android:** run on Android over USB-MIDI, ready for F-Droid ([5222fae](https://github.com/vitoramaral10/pocket-amp-tools/commit/5222fae73fc1ecb9ff70425ab2b4c3230301eb04))
* **android:** run on Android over USB-MIDI, ready for F-Droid ([a32bdfb](https://github.com/vitoramaral10/pocket-amp-tools/commit/a32bdfbe9b47c88c1f6c7610dc82ecf3e72221c0)), closes [#33](https://github.com/vitoramaral10/pocket-amp-tools/issues/33)
* **android:** save preset files through Android's save dialog ([616ef86](https://github.com/vitoramaral10/pocket-amp-tools/commit/616ef86ddbc625766f1c147d4d918b75e218c42a))
* **android:** save preset files through Android's save dialog ([eeff9e3](https://github.com/vitoramaral10/pocket-amp-tools/commit/eeff9e387e18875dc3923ffdb734c28c9e5e63a3))
* **assistant:** agent in a side panel, settings page with the log ([bbe76ed](https://github.com/vitoramaral10/pocket-amp-tools/commit/bbe76edd984d1ffe553ba1912fd08cf3fd630a69))
* **assistant:** pass on each service's error and name it in the dialog ([a8718be](https://github.com/vitoramaral10/pocket-amp-tools/commit/a8718be3e1e533d5b31c4f33c956cb9d98d5a137))
* **assistant:** pick the AI service from a list of providers ([5dff76d](https://github.com/vitoramaral10/pocket-amp-tools/commit/5dff76d0093f46a9041b5a48e10eb639d7b87458))
* **assistant:** teach the assistant what the models and knobs do ([663b28e](https://github.com/vitoramaral10/pocket-amp-tools/commit/663b28e7e6f6ef171e25c4e3769f487732548b46))
* **assistant:** turn the assistant into an agent in a side panel ([4c41174](https://github.com/vitoramaral10/pocket-amp-tools/commit/4c41174c2bdcec3d4d8ad32e603be73b37e76970))
* back up and restore presets around firmware updates ([24848a6](https://github.com/vitoramaral10/pocket-amp-tools/commit/24848a64b4f0d69cfb6c2dd2870b7372cd92441f))
* **backup:** list knobs by position, with labels only to read ([c5c0dce](https://github.com/vitoramaral10/pocket-amp-tools/commit/c5c0dce5e6004307608ff615b1c59f7a50dc5285)), closes [#11](https://github.com/vitoramaral10/pocket-amp-tools/issues/11)
* **backup:** restore P01-P79 from a PIXIE1 V0.07 raw copy ([f49757a](https://github.com/vitoramaral10/pocket-amp-tools/commit/f49757a116f299df8ff7c00e87981f19fbf96eee))
* **backup:** restore P01-P79 from a PIXIE1 V0.07 raw copy ([52fe615](https://github.com/vitoramaral10/pocket-amp-tools/commit/52fe615d4046e41d9c707851c53c88a601330185)), closes [#10](https://github.com/vitoramaral10/pocket-amp-tools/issues/10)
* build the app around a preset editor ([b964843](https://github.com/vitoramaral10/pocket-amp-tools/commit/b964843edce6f2809b0adcd1c85b2474e241a2ef))
* edit presets live, upload IRs and guard every write ([f7c2a28](https://github.com/vitoramaral10/pocket-amp-tools/commit/f7c2a28d7924cb96fddb4fb330b206265497e2ee))
* **eq:** label EQ bands by frequency and show values in dB ([dc06d15](https://github.com/vitoramaral10/pocket-amp-tools/commit/dc06d15ebe3c5a212352a7e11f56905f5e9330a4))
* **eq:** label EQ bands by frequency and show values in dB ([9826e3b](https://github.com/vitoramaral10/pocket-amp-tools/commit/9826e3bd283dce274ceb8232c678dd06af6517b4))
* **library:** keep amp captures and IRs in a local library ([058d8b2](https://github.com/vitoramaral10/pocket-amp-tools/commit/058d8b266510b1a8c1786374a2505bafb81a6136))
* list every preset as plain fields in the backup file ([cb4f9a2](https://github.com/vitoramaral10/pocket-amp-tools/commit/cb4f9a225da13e79614006d90d0a20c97856e4a7)), closes [#11](https://github.com/vitoramaral10/pocket-amp-tools/issues/11)
* **presets:** add list, block and file shortcuts ([7b35b23](https://github.com/vitoramaral10/pocket-amp-tools/commit/7b35b23fcaadae14a2c133e0b119ba134e3193a1))
* **presets:** add names, labels, ratings and filtering to presets ([a811303](https://github.com/vitoramaral10/pocket-amp-tools/commit/a8113030bf0d34127f610206dba8fd6e4351fc38))
* **presets:** add names, labels, ratings and filtering to presets ([1af5b51](https://github.com/vitoramaral10/pocket-amp-tools/commit/1af5b51f7d987e4b6a2c3d140dec1d0ead4aaf8a)), closes [#31](https://github.com/vitoramaral10/pocket-amp-tools/issues/31)
* **presets:** carry preset details in backup files ([5f252ab](https://github.com/vitoramaral10/pocket-amp-tools/commit/5f252ab05880ffe15b4ab29b624438b0aab452b4))
* **presets:** carry preset details in backup files ([d42703a](https://github.com/vitoramaral10/pocket-amp-tools/commit/d42703a850590c4bcdbb4a000d9ec37d401229d3)), closes [#58](https://github.com/vitoramaral10/pocket-amp-tools/issues/58)
* **presets:** filter with Ctrl+F, clear it with Esc, copy and paste with Ctrl+Shift+C/V ([8b86b0a](https://github.com/vitoramaral10/pocket-amp-tools/commit/8b86b0a4edba09125accecc41fdc09210d9a0f8d))
* **presets:** include details when copying a preset ([7e57b25](https://github.com/vitoramaral10/pocket-amp-tools/commit/7e57b25523e37c8d294dffa939d94a922f109c5c))
* **presets:** include details when copying a preset ([95e6394](https://github.com/vitoramaral10/pocket-amp-tools/commit/95e6394f03d5c11e90bd90410d7e4093d2d26be9)), closes [#59](https://github.com/vitoramaral10/pocket-amp-tools/issues/59)
* **presets:** let the editor header use the full width ([ade1722](https://github.com/vitoramaral10/pocket-amp-tools/commit/ade17223d33d1d62d5adbe86c55dd8f23c92af6a))
* **presets:** let the editor header use the full width ([fb6af50](https://github.com/vitoramaral10/pocket-amp-tools/commit/fb6af50f58eb634edd17df186493bcd458a36e6f)), closes [#60](https://github.com/vitoramaral10/pocket-amp-tools/issues/60)
* **presets:** navigate presets from the keyboard ([884cc06](https://github.com/vitoramaral10/pocket-amp-tools/commit/884cc06e562ef423098b1812d02d90cb852efa2a))
* **presets:** navigate presets from the keyboard ([3cc6f6f](https://github.com/vitoramaral10/pocket-amp-tools/commit/3cc6f6f552927a0601a7f15dd59e142a8ec11b34)), closes [#32](https://github.com/vitoramaral10/pocket-amp-tools/issues/32)
* **presets:** rebuild preset details on the new editor ([6de6d63](https://github.com/vitoramaral10/pocket-amp-tools/commit/6de6d6357ea5f2a301996ca828ad50549149bc2a)), closes [#31](https://github.com/vitoramaral10/pocket-amp-tools/issues/31)
* **presets:** send a .nam capture to an AMP slot, with a local library ([e7515fe](https://github.com/vitoramaral10/pocket-amp-tools/commit/e7515feef055936409ada2d7d0ea241f6befa594))
* **presets:** show each block's number key on its chip ([315a88b](https://github.com/vitoramaral10/pocket-amp-tools/commit/315a88b3757369e58d5734c244f3ed9758a3cf6b))
* **presets:** show older clone firmware presets without the EQ ([799bb33](https://github.com/vitoramaral10/pocket-amp-tools/commit/799bb33d7d0cb9793aa0ffe74f6c9f6c981adf37))
* **presets:** show older clone firmware presets without the EQ ([0263cf4](https://github.com/vitoramaral10/pocket-amp-tools/commit/0263cf4921064108b6edb6fad80d73bb8727288f))
* **presets:** show preset details as a summary, edit them in a dialog ([14fb7c6](https://github.com/vitoramaral10/pocket-amp-tools/commit/14fb7c6ade7d0c6834597daea83d93ff1a60ae06))
* **presets:** toggle the open block with Space and step its model with [ ] ([8f92aa8](https://github.com/vitoramaral10/pocket-amp-tools/commit/8f92aa84bdb9eab75afa812a77da887c1291ebcc))
* **presets:** treat an unlisted pedal with Pocket AMP presets as presets only ([5965df0](https://github.com/vitoramaral10/pocket-amp-tools/commit/5965df09463ec6101f0d4d6847fbe6e89c31c027))
* **presets:** treat an unlisted pedal with Pocket AMP presets as presets only ([39c1aa6](https://github.com/vitoramaral10/pocket-amp-tools/commit/39c1aa63c41110db464473f271253e0d6f66ae9b))
* **presets:** turn an A2 .nam capture into a pedal network image ([32a6c84](https://github.com/vitoramaral10/pocket-amp-tools/commit/32a6c84d92f4eec643ec887bdb6d83ab044707cd))
* **presets:** upload a network image to an AMP slot ([13e23cf](https://github.com/vitoramaral10/pocket-amp-tools/commit/13e23cf43144c2c002cbab8c0a2b878d07ff9c58))
* **presets:** write to the pedal with Ctrl+S and discard with Ctrl+Z ([bddd6d3](https://github.com/vitoramaral10/pocket-amp-tools/commit/bddd6d3f51885a22fee5ecc0c974fda5d1e0de9c))
* reach the pedal over Bluetooth on Linux ([5c5cd29](https://github.com/vitoramaral10/pocket-amp-tools/commit/5c5cd29fe27b97f1827fca1047745c34c5f4f3cc))
* **settings:** choose whether writing the editor to the pedal asks first ([65d96af](https://github.com/vitoramaral10/pocket-amp-tools/commit/65d96af1447d2623eae9665b52236f42ae6a5e17))
* suggest presets with a user-configured AI service ([eeb04a5](https://github.com/vitoramaral10/pocket-amp-tools/commit/eeb04a52ab1e4ecd98fbb68fbf2c0adcc9fbd8f4))
* **ui:** add an Amps section to put a .nam capture in an AMP slot ([04f15a0](https://github.com/vitoramaral10/pocket-amp-tools/commit/04f15a0bc0a7ff234222d125ff8e527ef9da7faf))
* **ui:** backups, preset editor and pedal handling ([fc82c01](https://github.com/vitoramaral10/pocket-amp-tools/commit/fc82c014f66735bf8f7d9c81ac3d349892ec8fdd))
* **ui:** bring the visual refresh to the Library page ([8805520](https://github.com/vitoramaral10/pocket-amp-tools/commit/8805520ef20c55e1f5c7a7ddb2af0f2a834345a6))
* **ui:** introduce the app as an editor for every Pocket AMP brand ([14e0b81](https://github.com/vitoramaral10/pocket-amp-tools/commit/14e0b818c50babe5f1566ddcb4eb51eaf2a7a8b3))
* **ui:** let the Backups page delete a backup ([f6b6e65](https://github.com/vitoramaral10/pocket-amp-tools/commit/f6b6e6533fc61ee3a036701349c689729f8205d7))
* **ui:** read the presets on their own once the pedal is detected ([e9c5ff4](https://github.com/vitoramaral10/pocket-amp-tools/commit/e9c5ff45bf462b460d5cc50f7f5c8888481eb85c))
* **ui:** read the presets on their own once the pedal is detected ([199d593](https://github.com/vitoramaral10/pocket-amp-tools/commit/199d593c3fd2cbd33818d31f5d50264731096703))
* **ui:** rework the preset editor, menu and pedal handling ([38671b1](https://github.com/vitoramaral10/pocket-amp-tools/commit/38671b1e9fa21d850c421e4f4c1e248307ef7198))
* update the Coolmusic PIXIE1 as a Pocket AMP ([fd7a7d8](https://github.com/vitoramaral10/pocket-amp-tools/commit/fd7a7d806bbbb3a36b0d19422688b0635a027a67))
* update the Coolmusic PIXIE1 as a Pocket AMP ([30a3332](https://github.com/vitoramaral10/pocket-amp-tools/commit/30a3332e637ddd276ea18df2be2c38146b4c3648)), closes [#2](https://github.com/vitoramaral10/pocket-amp-tools/issues/2)
* update the Donner Pocket AMP as a Pocket AMP ([21d0e48](https://github.com/vitoramaral10/pocket-amp-tools/commit/21d0e486c2ecaf8b75cb58f676e49df8aa6bde8e))
* update the Donner Pocket AMP as a Pocket AMP ([b737c36](https://github.com/vitoramaral10/pocket-amp-tools/commit/b737c36dc5a3f7237a0889f78057622ab4813a52))


### Bug Fixes

* **android:** raise minSdk to 26 for sentry_flutter ([f0e96e8](https://github.com/vitoramaral10/pocket-amp-tools/commit/f0e96e8d5ba8b8adfd81cd714eea864fd366af63))
* ask before closing on macOS and allow saving files ([7d05435](https://github.com/vitoramaral10/pocket-amp-tools/commit/7d05435f13dfe5fbcc162e0a9b28266c8526fd01))
* **assistant:** edit presets whose EQ record cannot be written back ([bdb5f61](https://github.com/vitoramaral10/pocket-amp-tools/commit/bdb5f611c03310c2d7aa8fc31cb5e67fd52a7770))
* **backup:** read version 2 files that use former knob names ([4a69e3a](https://github.com/vitoramaral10/pocket-amp-tools/commit/4a69e3a61e50c3160c9e2d83e4e0f74b56142014))
* **backup:** restore a raw copy from a pedal whose name has spaces ([62e1244](https://github.com/vitoramaral10/pocket-amp-tools/commit/62e1244bad26aa041d499b1edaf36e0ceaaf27a8))
* **backup:** restore a raw copy from a pedal whose name has spaces ([17af765](https://github.com/vitoramaral10/pocket-amp-tools/commit/17af765c800d3c9eb339dfba0c6c18df70bebef7)), closes [#10](https://github.com/vitoramaral10/pocket-amp-tools/issues/10)
* block labels taken from both the pedal UI and the M-EFCS app ([046d6fb](https://github.com/vitoramaral10/pocket-amp-tools/commit/046d6fbd43715939a1afea4c49285ff45058c61f))
* check every restore packet before writing the first one ([f2a4328](https://github.com/vitoramaral10/pocket-amp-tools/commit/f2a43284c7634ee9ff96d4e879f3b27a54e16087))
* close the port when probing it fails with an I/O error ([#20](https://github.com/vitoramaral10/pocket-amp-tools/issues/20)) ([c437643](https://github.com/vitoramaral10/pocket-amp-tools/commit/c437643213d89aee3e81ac555b7204e582cb2c62))
* keep beta.1 backups restorable, plus follow-ups ([a372b85](https://github.com/vitoramaral10/pocket-amp-tools/commit/a372b85e4479bcf7a51b670b86ac3150836184e0))
* let a PIXIE1 on V0.07 update without a preset backup ([221b1d7](https://github.com/vitoramaral10/pocket-amp-tools/commit/221b1d7618bfc01fc8690db9b923219fc92b0528)), closes [#2](https://github.com/vitoramaral10/pocket-amp-tools/issues/2)
* let backups and interrupted writes complete ([f90b8f8](https://github.com/vitoramaral10/pocket-amp-tools/commit/f90b8f8776198f1c337cc807898739880c5b7dc0))
* **midi:** notice a pedal unplugged on macOS ([b4a865d](https://github.com/vitoramaral10/pocket-amp-tools/commit/b4a865d01978b5b4ee64689aa6009c91e08aa08f))
* **midi:** recover cleanly from stalls and Bluetooth drops ([247a70f](https://github.com/vitoramaral10/pocket-amp-tools/commit/247a70f482b74875765a2f4852bbdf27c5b9dfa6))
* name the slot in the restore error and say block names are assumed ([6b513dd](https://github.com/vitoramaral10/pocket-amp-tools/commit/6b513ddb25da1be4d113610bcddd70e5f97c33d8))
* **security:** harden the assistant, downloads and file reads ([1256f15](https://github.com/vitoramaral10/pocket-amp-tools/commit/1256f1563cdc1ab7366807b31155f8bb0b482390))
* **telemetry:** scrub home folder reliably and test the privacy path ([a2e280a](https://github.com/vitoramaral10/pocket-amp-tools/commit/a2e280a88b2ea545ef899c3f4455e0a85bdad06a))
* **telemetry:** scrub the home folder reliably and add Telemetry tests ([9281483](https://github.com/vitoramaral10/pocket-amp-tools/commit/9281483dda7bd7dde466708071568391d2d32dbc))
* third review: safer updates, restores, transport and UI ([8a1834a](https://github.com/vitoramaral10/pocket-amp-tools/commit/8a1834a994fee3a3c5490f7a4d84bf20d0186cf1))
* **ui:** close the gaps found in the third review ([bd34134](https://github.com/vitoramaral10/pocket-amp-tools/commit/bd34134a4db8c39238ef67a70957ede2d57e04bb))
* **ui:** keep snackbars and the Backups header readable per window size ([6004c87](https://github.com/vitoramaral10/pocket-amp-tools/commit/6004c879122fd2f9296b8f74ecc5434957b1a428))
* **ui:** keep the last knob on screen on compact windows ([f003808](https://github.com/vitoramaral10/pocket-amp-tools/commit/f003808c19889c8e8777e3741d2968d75b8c6821))
* **ui:** keep the last knob on screen on compact windows ([3c2d843](https://github.com/vitoramaral10/pocket-amp-tools/commit/3c2d8433e65fec09b45584356d4cf131c66cedf8))
* **ui:** keep the write bar and the library rows on screen on a phone ([8d8c419](https://github.com/vitoramaral10/pocket-amp-tools/commit/8d8c4195d58b8f8ba09928994444984fa595600b))
* **ui:** put slider labels above the slider on compact windows ([da117a4](https://github.com/vitoramaral10/pocket-amp-tools/commit/da117a469740270f262679c5c7aa13157f3c1740))
* **ui:** put slider labels above the slider on compact windows ([2498413](https://github.com/vitoramaral10/pocket-amp-tools/commit/249841359372b1c5ad5d764ec0a5a3c3debb268f))
* **ui:** report a raw copy that cannot be read instead of failing ([1ec0fd2](https://github.com/vitoramaral10/pocket-amp-tools/commit/1ec0fd226222205440b7acec1ed3810a53d24ebf))
* **ui:** stop returning a Future from setState on backups reload ([a0d191e](https://github.com/vitoramaral10/pocket-amp-tools/commit/a0d191e9de13f89025c134b8a31b9611b881c469))
* update only the confirmed pedal with a known package ([2c1ec90](https://github.com/vitoramaral10/pocket-amp-tools/commit/2c1ec90b76ef5fdede35fb3024acef4164cb276b))
* update only the confirmed pedal, with one pedal plugged in ([95fa716](https://github.com/vitoramaral10/pocket-amp-tools/commit/95fa7161b8a77adb40989055222958d17e04b2d4))
* **updater:** find a pedal whose port has a generic name after it restarts ([edc0992](https://github.com/vitoramaral10/pocket-amp-tools/commit/edc0992a2c13b66b57c3a9fe11fe08f422793e2d))
* **updater:** find a pedal whose port has a generic name after it restarts ([ac03127](https://github.com/vitoramaral10/pocket-amp-tools/commit/ac03127509e39fad6fa6c5f2dc8982aeea83c32f))


### Performance Improvements

* **presets:** read only the edited slots when writing edits to the pedal ([84aad55](https://github.com/vitoramaral10/pocket-amp-tools/commit/84aad559737f9a307484b49f287814078ddcac04))


### Code Refactoring

* rename the app to Pocket AMP Tools ([922d330](https://github.com/vitoramaral10/pocket-amp-tools/commit/922d330e1ef6c7189d7291347d73512905e48037))

## 0.4.0

Preset details travel with the presets, and Android can save files where you choose.

### Presets

- Saved preset files and backups now carry the preset names, descriptions, labels and ratings. Opening one that has different details asks whether to use them, so the details travel with the presets to another computer or phone ([#58](https://github.com/vitoramaral10/pocket-amp-tools/issues/58)).
- **Copy as JSON** takes the preset's name, description, labels and rating along, and pasting gives them to the target slot ([#59](https://github.com/vitoramaral10/pocket-amp-tools/issues/59)).
- On a wide window the editor's header uses the full width, with the volume on the right, so descriptions are no longer cut short ([#60](https://github.com/vitoramaral10/pocket-amp-tools/issues/60)).

### Android

- **Save file…** opens Android's save dialog, so a preset file can go to Downloads, a cloud drive or another app and be opened on another device. Before, it stayed in the app's private folder.

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
