# Contributing

Thanks for helping! Pocket AMP Tools is a small community tool, and the most useful contributions right now do not need any code.

## The most helpful things you can do

1. **Test it on your system and your pedal, and report back.** The Pocket AMP is sold under several brands (M-VAVE, Donner, Coolmusic PIXIE1, New Bee SK17) and the app runs on four systems; most combinations are still unreported, Android above all. Even "it detected my pedal" is valuable. Use the [hardware test report](../../issues/new?template=hardware_report.yml) form.
2. **Report bugs** with the log from **⋮ → Settings → Copy for a bug report** in the app ([bug report form](../../issues/new?template=bug_report.yml)).
3. **Share what you know** about the pedal, other M-VAVE devices or the JieLi update protocol in [Discussions](../../discussions).
4. **Improve the docs**: clearer steps, screenshots, translations of the README.

## Safety first

This app writes firmware. A bad change can leave someone's pedal unusable, so:

- Never test unreviewed update code on a pedal you cannot afford to lose.
- The read-only path is safe to test: opening the app only sends the identity query (`0x11`).
- Changes to the update path (`lib/src/pedal_updater.dart`, `lib/src/ota_protocol.dart`, `lib/src/midi/`) or to anything that writes to the pedal (`lib/src/presets/`) need a test against the simulated pedal in `test/support/fake_pedal.dart` and a clear description of how they were checked.
- Do not loosen the safety checks (known loader hash, product name, final identity) without discussing it in an issue first.
- Do not commit firmware files (`.fwsc`, `.bin`). They belong to M-VAVE; the app downloads them from M-VAVE's server.

## Development

Requires Flutter 3.47 or newer.

```bash
flutter pub get
flutter analyze
flutter test
flutter run -d linux   # or windows / macos / an Android device
```

- `test/` runs anywhere, with a simulated pedal.
- `test_hardware/` talks to a real pedal on Linux and only reads its identity.
- Set `POCKET_AMP_FWSC=/path/to/firmware.fwsc` to also run the tests against an official package.
- `test_screens/` renders the screenshots from the real UI and fails on a layout overflow at any window size. After a change to the interface, run `POCKET_AMP_FWSC=... flutter test test_screens --update-goldens` and then `python3 test_screens/compose.py`, which writes the images of the README, the website and the store listing.

Project layout:

| Path | What |
| --- | --- |
| `lib/src/firmware_package.dart` | `.fwsc` parsing and validation |
| `lib/src/ota_protocol.dart` | SysEx framing of the update protocol |
| `lib/src/pedal_updater.dart` | detection and the update procedure |
| `lib/src/midi/` | native USB-MIDI per platform (ALSA, WinMM, CoreMIDI, Android), and Bluetooth in `ble/` |
| `lib/src/presets/` | the preset layout, backups, live editing, IR and amp uploads, and the guard on every packet written |
| `lib/src/library/` | the user's IRs and amp captures on disk |
| `lib/src/assistant/` | the optional AI assistant and what it knows about the pedal |
| `lib/src/ui/` | the interface |

## Branches and releases

- `main` is the only long-lived branch. Open pull requests against it from a short branch named `feature/...`, `bugfix/...` or `docs/...`.
- A pull request runs `flutter analyze` and `flutter test`. The release builds do not run on a merge.
- Releases are made by [release-please](https://github.com/googleapis/release-please). After each merge to `main` it keeps one release pull request open ("chore(main): release X.Y.Z"), with the new version in `pubspec.yaml` (the `+N` build number goes up by one) and the notes in [CHANGELOG](CHANGELOG.md), built from the `feat:` and `fix:` commits since the last release. `chore:`, `docs:` and `ci:` commits do not open or change it. The PR waits until you decide to release.
- To release, merge that PR. The tag `vX.Y.Z` and the GitHub release are created, and the same workflow then builds Linux, Windows, macOS and Android and attaches the files with checksums. The F-Droid recipe points at that tag.
- Before merging, add `fastlane/metadata/android/en-US/changelogs/N.txt` for the new `+N` build number, and edit the CHANGELOG text if you want it friendlier for users.
- `feat:` raises the minor version, `fix:` the patch, and `feat!:` or a `BREAKING CHANGE:` footer the major (the minor while the version is 0.x). A pre-release (`v0.5.0-beta.1`) is still cut by hand: push the tag, and it is published as a pre-release.
- Merge pull requests with **squash** and write the PR title as the commit message (`fix: ...`), because release-please reads the merged commit, not the branch's commits.
- To try the builds before a release, run the `build` workflow by hand from the Actions tab.

## Pull requests

- Keep each PR focused on one change.
- Use [Conventional Commits](https://www.conventionalcommits.org/) for commit messages (`fix: ...`, `feat: ...`, `docs: ...`).
- `flutter analyze` and `flutter test` must pass; CI builds Linux, Windows and macOS after the merge.
- A change users will notice gets a line in [CHANGELOG.md](CHANGELOG.md).
- Say in the PR which systems and pedals you tested on, if any.

## Supporting other pedals

The FM-1 and other M-VAVE devices built on the JieLi AC791N may use the same update loader. Support for another product needs the package details and a successful update reported by an owner of that device. Open a discussion first.

## Code of conduct

Everyone taking part is expected to follow the [Code of Conduct](CODE_OF_CONDUCT.md).

By contributing you agree that your contribution is licensed under the GPL-3.0, like the rest of the project.
