// SPDX-License-Identifier: GPL-3.0-only

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:url_launcher/url_launcher.dart';

import '../library/library.dart';
import '../presets/nam_file.dart';
import '../tone3000/tone3000.dart';
import 'visuals.dart';

/// The official TONE3000 logo, [height] tall. Its colors read on light and
/// dark backgrounds alike, so it is drawn as it is.
class Tone3000Logo extends StatelessWidget {
  const Tone3000Logo({super.key, this.height = 24});
  final double height;

  @override
  Widget build(BuildContext context) => SvgPicture.asset(
    'assets/tone3000/tone3000_logo.svg',
    height: height,
    semanticsLabel: 'TONE3000',
  );
}

/// Opens [url] in the system's browser; false when it could not.
Future<bool> openInBrowser(String url) async {
  try {
    return await launchUrl(
      Uri.parse(url),
      mode: LaunchMode.externalApplication,
    );
  } on Exception {
    return false; // no browser, or a platform without a way to open one
  }
}

/// Shows the user's TONE3000 lists and puts the captures, or with [ir] the
/// IRs, they pick in the library through [onImport].
Future<void> showTone3000(
  BuildContext context, {
  required Tone3000 client,
  bool ir = false,
  required Future<LibraryItem> Function(
    String fileName,
    Uint8List bytes,
    Tone tone,
  )
  onImport,
  Future<bool> Function(String url) open = openInBrowser,
}) => showDialog<void>(
  context: context,
  builder: (BuildContext context) {
    final Widget body = Tone3000Browser(
      client: client,
      ir: ir,
      onImport: onImport,
      open: open,
    );
    return MediaQuery.sizeOf(context).width < 600
        ? Dialog.fullscreen(child: body)
        : Dialog(
            clipBehavior: Clip.antiAlias,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640, maxHeight: 720),
              child: body,
            ),
          );
  },
);

class Tone3000Browser extends StatefulWidget {
  const Tone3000Browser({
    super.key,
    required this.client,
    this.ir = false,
    required this.onImport,
    required this.open,
  });
  final Tone3000 client;

  /// IRs for the CAB slots instead of A2 captures for the AMP slots.
  final bool ir;

  /// Keeps a download in the library; [Tone] says what was captured.
  final Future<LibraryItem> Function(
    String fileName,
    Uint8List bytes,
    Tone tone,
  )
  onImport;
  final Future<bool> Function(String url) open;

  @override
  State<Tone3000Browser> createState() => _Tone3000BrowserState();
}

class _Tone3000BrowserState extends State<Tone3000Browser> {
  /// Null until the saved sign-in is looked up.
  bool? _signedIn;
  DeviceLogin? _login;
  ToneList _list = ToneList.trending;

  /// What was searched for; empty while a list is shown.
  String _query = '';
  final TextEditingController _search = TextEditingController();
  List<Tone>? _tones;
  int _page = 1;
  bool _more = false;
  bool _loading = false;

  /// The tone being fetched, so only its row shows progress.
  int? _getting;
  String? _message;
  bool _error = false;
  bool _closed = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    _closed = true; // stops a sign-in still waiting for the site
    _search.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    final bool inside = await widget.client.signedIn;
    if (!mounted) {
      return;
    }
    setState(() => _signedIn = inside);
    if (inside) {
      await _load();
    }
  }

  /// What this browser lists, in the words of its messages.
  String get _what => widget.ir ? 'IR' : 'A2 NAM capture';

  void _say(String? message, {bool error = false}) => setState(() {
    _message = message;
    _error = error;
  });

  /// Runs [action]; a sign-in that is no longer accepted goes back to the
  /// sign-in screen, any other failure is shown.
  Future<void> _guard(Future<void> Function() action) async {
    try {
      await action();
    } on Tone3000SignedOut {
      if (mounted) {
        setState(() {
          _signedIn = false;
          _tones = null;
          _message = 'TONE3000 asked you to sign in again.';
          _error = false;
        });
      }
    } on Object catch (e) {
      if (e is! Tone3000Exception &&
          e is! InvalidNamFile &&
          e is! LibraryException &&
          e is! FileSystemException) {
        rethrow;
      }
      if (mounted) {
        _say('$e', error: true);
      }
    }
  }

  Future<void> _signIn() => _guard(() async {
    _say(null);
    final DeviceLogin login = await widget.client.startLogin();
    if (!mounted) {
      return;
    }
    setState(() => _login = login);
    unawaited(widget.open(login.verificationUriComplete));
    try {
      final bool ok = await widget.client.finishLogin(
        login,
        cancelled: () => _closed || _login != login,
      );
      if (ok && mounted) {
        setState(() {
          _login = null;
          _signedIn = true;
        });
        await _load();
      }
    } finally {
      if (mounted && _login == login) {
        setState(() => _login = null);
      }
    }
  });

  Future<void> _signOut() async {
    await widget.client.signOut();
    if (mounted) {
      setState(() {
        _signedIn = false;
        _tones = null;
        _message = null;
      });
    }
  }

  Future<void> _load({bool next = false}) async {
    final ToneList list = _list;
    final String query = _query;
    final int page = next ? _page + 1 : 1;
    setState(() {
      _loading = true;
      if (!next) {
        _tones = null;
      }
    });
    await _guard(() async {
      final TonePage p = query.isEmpty
          ? await widget.client.tones(list, page: page, ir: widget.ir)
          : await widget.client.search(query, page: page, ir: widget.ir);
      if (mounted && list == _list && query == _query) {
        setState(() {
          _tones = <Tone>[...?(next ? _tones : null), ...p.tones];
          _page = page;
          _more = p.more;
          _message = null;
        });
      }
    });
    if (mounted) {
      setState(() => _loading = false);
    }
  }

  Future<void> _get(Tone tone) async {
    setState(() => _getting = tone.id);
    await _guard(() async {
      final List<ToneModel> models = await widget.client.models(
        tone.id,
        ir: widget.ir,
      );
      if (!mounted) {
        return;
      }
      if (models.isEmpty) {
        throw Tone3000Exception('This tone has no $_what to get.');
      }
      final ToneModel? model = models.length == 1
          ? models.single
          : await _chooseModel(tone, models);
      if (model == null || !mounted) {
        return;
      }
      final Uint8List bytes = await widget.client.download(model);
      final LibraryItem item = await widget.onImport(
        '${model.name}.${widget.ir ? 'wav' : 'nam'}',
        bytes,
        tone,
      );
      if (mounted) {
        _say(
          'Added "${item.name}" to your library.'
          '${!widget.ir && tone.includesCab ? ' It holds its cabinet: presets that play it get their CAB block turned off.' : ''}',
        );
      }
    });
    if (mounted) {
      setState(() => _getting = null);
    }
  }

  Future<ToneModel?> _chooseModel(Tone tone, List<ToneModel> models) =>
      showDialog<ToneModel>(
        context: context,
        builder: (BuildContext context) => SimpleDialog(
          title: Text(
            'Which ${widget.ir ? 'IR' : 'capture'} of "${tone.title}"?',
          ),
          children: <Widget>[
            for (final ToneModel m in models)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(context, m),
                child: Text(m.name),
              ),
          ],
        ),
      );

  /// Opens [url], or copies it where the system cannot open one.
  Future<void> _visit(String url) async {
    if (await widget.open(url)) {
      return;
    }
    await Clipboard.setData(ClipboardData(text: url));
    if (mounted) {
      _say('Link copied: open it in your browser.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final String? message = _message;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 8, 0),
          child: Row(
            children: <Widget>[
              const Tone3000Logo(),
              const SizedBox(width: 12),
              Expanded(
                // On a phone the logo says it alone.
                child: MediaQuery.sizeOf(context).width < 600
                    ? const SizedBox()
                    : Text(
                        widget.ir ? 'IRs' : 'Captures',
                        style: theme.textTheme.titleLarge,
                        overflow: TextOverflow.ellipsis,
                      ),
              ),
              if (_signedIn ?? false)
                TextButton(onPressed: _signOut, child: const Text('Sign out')),
              IconButton(
                tooltip: 'Close',
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close),
              ),
            ],
          ),
        ),
        if (message != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
            child: Text(
              message,
              style: _error ? TextStyle(color: theme.colorScheme.error) : null,
            ),
          ),
        Expanded(
          child: switch (_signedIn) {
            null => const Center(child: CircularProgressIndicator()),
            false => _login == null ? _welcome(theme) : _code(theme, _login!),
            true => _browser(theme),
          },
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: () => _visit('https://www.tone3000.com'),
              child: const Text('Powered by TONE3000 · tone3000.com'),
            ),
          ),
        ),
      ],
    );
  }

  Widget _welcome(ThemeData theme) => SingleChildScrollView(
    padding: const EdgeInsets.all(24),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          'TONE3000 hosts free amp captures and IRs made by its community. '
          'Sign in with your account there to see what is trending, search, '
          'and put ${widget.ir ? 'IRs' : 'A2 captures'} in your library '
          'without leaving the app.',
        ),
        const SizedBox(height: 8),
        Text(
          'You approve the sign-in on tone3000.com; the app never sees your '
          'password. It only reads your lists and downloads what you pick.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 24),
        FilledButton(
          onPressed: _signIn,
          child: const Text('Sign in with TONE3000'),
        ),
      ],
    ),
  );

  Widget _code(ThemeData theme, DeviceLogin login) => SingleChildScrollView(
    padding: const EdgeInsets.all(24),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text('Approve the sign-in on TONE3000 with this code:'),
        const SizedBox(height: 12),
        SelectableText(
          login.userCode,
          style: theme.textTheme.displaySmall?.copyWith(letterSpacing: 2),
        ),
        const SizedBox(height: 12),
        SelectableText(login.verificationUri),
        const SizedBox(height: 16),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          children: <Widget>[
            FilledButton.tonal(
              onPressed: () => _visit(login.verificationUriComplete),
              child: const Text('Open TONE3000'),
            ),
            OutlinedButton(
              onPressed: () => setState(() => _login = null),
              child: const Text('Cancel'),
            ),
          ],
        ),
        const SizedBox(height: 24),
        Row(
          children: <Widget>[
            const SizedBox.square(
              dimension: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Waiting for you to approve. You can use a phone or another '
                'computer for it.',
                style: theme.textTheme.bodySmall,
              ),
            ),
          ],
        ),
      ],
    ),
  );

  Widget _browser(ThemeData theme) {
    final List<Tone>? all = _tones;
    final List<Tone> tones = <Tone>[
      for (final Tone t in all ?? const <Tone>[])
        if (t.fits(ir: widget.ir)) t,
    ];
    final int hidden = (all?.length ?? 0) - tones.length;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      children: <Widget>[
        TextField(
          controller: _search,
          textInputAction: TextInputAction.search,
          decoration: const InputDecoration(
            hintText: 'Search TONE3000: an amp, a pedal, a creator…',
            prefixIcon: Icon(Icons.search),
            border: OutlineInputBorder(),
            isDense: true,
          ),
          onSubmitted: (String text) {
            setState(() => _query = text.trim());
            _load();
          },
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: <Widget>[
            for (final ToneList l in ToneList.values)
              ChoiceChip(
                label: Text(l.label),
                selected: _query.isEmpty && l == _list,
                onSelected: (_) {
                  _search.clear();
                  setState(() {
                    _list = l;
                    _query = '';
                  });
                  _load();
                },
              ),
          ],
        ),
        const SizedBox(height: 12),
        if (all == null)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 48),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (tones.isEmpty)
          EmptyState(
            icon: Icons.graphic_eq,
            title: 'Nothing here for the pedal',
            message: _query.isNotEmpty
                ? 'No $_what matches "$_query".'
                : _list == ToneList.favorited
                ? 'Favorite a tone on tone3000.com and it shows up here. The '
                      'pedal takes ${widget.ir ? 'IRs' : 'A2 NAM captures'}.'
                : 'This list has no $_what right now.',
          )
        else
          Card.outlined(
            margin: EdgeInsets.zero,
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: <Widget>[
                for (final (int i, Tone t) in tones.indexed) ...<Widget>[
                  if (i > 0) const Divider(height: 1),
                  _tile(theme, t),
                ],
              ],
            ),
          ),
        if (hidden > 0)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              '$hidden other tone${hidden == 1 ? ' is' : 's are'} not shown: '
              '${widget.ir ? 'only IRs are listed here' : 'the pedal takes A2 NAM captures only'}.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        if (_more)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Center(
              child: OutlinedButton(
                onPressed: _loading ? null : () => _load(next: true),
                child: const Text('Show more'),
              ),
            ),
          ),
      ],
    );
  }

  /// [url] decoded at the size it is shown, so a large photo is scaled
  /// once, smoothly, instead of on every frame.
  ImageProvider _sized(String url, double logical) => ResizeImage(
    NetworkImage(url),
    width: (logical * MediaQuery.devicePixelRatioOf(context)).ceil(),
    policy: ResizeImagePolicy.fit,
  );

  Widget _tile(ThemeData theme, Tone t) {
    final String initial = t.creator.isEmpty ? '?' : t.creator[0].toUpperCase();
    final String? avatar = t.avatarUrl;
    final String? picture = t.imageUrl ?? avatar;
    final bool busy = _getting != null;
    const double side = 48;
    final Widget fallback = ColoredBox(
      color: theme.colorScheme.secondaryContainer,
      child: Center(
        child: Text(
          initial,
          style: TextStyle(color: theme.colorScheme.onSecondaryContainer),
        ),
      ),
    );
    return ListTile(
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Container(
          width: side,
          height: side,
          // Shown while the picture loads, so the row keeps its shape.
          color: theme.colorScheme.surfaceContainerHighest,
          child: picture == null
              ? fallback
              : Image(
                  image: _sized(picture, side),
                  fit: BoxFit.cover,
                  filterQuality: FilterQuality.medium,
                  errorBuilder: (_, _, _) => fallback,
                ),
        ),
      ),
      title: Text(t.title, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Row(
        children: <Widget>[
          if (avatar != null) ...<Widget>[
            CircleAvatar(
              radius: 8,
              backgroundColor: theme.colorScheme.secondaryContainer,
              foregroundImage: _sized(avatar, 16),
              onForegroundImageError: (_, _) {},
            ),
            const SizedBox(width: 6),
          ],
          Expanded(
            child: Text(
              <String>[
                'by ${t.creator}',
                if (t.gear.isNotEmpty) t.gear,
                if (widget.ir) 'IR' else 'NAM',
                if (t.license.isNotEmpty) t.license,
              ].join(' · '),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          // On a phone the title needs the room more than the link does.
          if (t.url.isNotEmpty && MediaQuery.sizeOf(context).width >= 600)
            IconButton(
              tooltip: 'See it on TONE3000',
              onPressed: () => _visit(t.url),
              icon: const Icon(Icons.open_in_new),
            ),
          _getting == t.id
              ? const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 20),
                  child: SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              : TextButton(
                  onPressed: busy ? null : () => _get(t),
                  child: const Text('Get'),
                ),
        ],
      ),
    );
  }
}
