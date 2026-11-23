// SPDX-License-Identifier: GPL-3.0-only

import 'dart:io';

import 'package:flutter/material.dart';

import '../sync/firewall.dart';
import '../sync/sync_service.dart';

/// Turns syncing on, pairs devices and shows how each pairing is doing.
/// Pairing requests from other devices are asked here, so the page must be
/// open on the device being paired.
class SyncPage extends StatefulWidget {
  const SyncPage({super.key, required this.service});

  final SyncService service;

  @override
  State<SyncPage> createState() => _SyncPageState();
}

class _SyncPageState extends State<SyncPage> {
  SyncService get _s => widget.service;
  bool _pairing = false;
  Firewall? _firewall;
  bool _opening = false;

  @override
  void initState() {
    super.initState();
    _s.onPairRequest = (String name, String code) =>
        _askCode(name, code, incoming: true);
    activeFirewall().then((Firewall? f) {
      if (mounted) {
        setState(() => _firewall = f);
      }
    });
  }

  Future<void> _openFirewall(Firewall f) async {
    setState(() => _opening = true);
    final ScaffoldMessengerState m = ScaffoldMessenger.of(context);
    final String? error = await openFirewall(f);
    if (error == null) {
      await _s.markFirewallOpened(f.name);
    }
    m.showSnackBar(
      SnackBar(
        content: Text(
          error == null
              ? 'Sync now gets through ${f.label}, from home and office '
                    'networks only.'
              : 'The firewall was not changed. $error',
        ),
      ),
    );
    if (mounted) {
      setState(() => _opening = false);
    }
  }

  Widget _firewallCard(ThemeData theme, Firewall f) => Padding(
    padding: const EdgeInsets.only(top: 16),
    child: Card.filled(
      margin: EdgeInsets.zero,
      color: theme.colorScheme.tertiaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              'The ${f.label} firewall is on',
              style: theme.textTheme.titleSmall?.copyWith(
                color: theme.colorScheme.onTertiaryContainer,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'It keeps other devices from finding and reaching this one. '
              'Letting sync through opens port $syncPort to home and office '
              'networks only (private addresses), never to the internet. '
              'The system asks for your password.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onTertiaryContainer,
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _opening ? null : () => _openFirewall(f),
              icon: const Icon(Icons.shield_outlined),
              label: const Text('Let sync through'),
            ),
          ],
        ),
      ),
    ),
  );

  @override
  void dispose() {
    _s.onPairRequest = null;
    super.dispose();
  }

  Future<bool> _askCode(
    String name,
    String code, {
    bool incoming = false,
  }) async {
    if (!mounted) {
      return false;
    }
    final ThemeData theme = Theme.of(context);
    return await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (BuildContext context) => AlertDialog(
            title: Text(incoming ? '$name wants to pair' : 'Pair with $name'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text('Check that $name shows this same code:'),
                const SizedBox(height: 16),
                Center(
                  child: SelectableText(
                    '${code.substring(0, 3)} ${code.substring(3)}',
                    style: theme.textTheme.displaySmall?.copyWith(
                      fontFeatures: const <FontFeature>[
                        FontFeature.tabularFigures(),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  'If the codes differ, cancel: another device may be in '
                  'the way.',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Codes match'),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _pair(NearbyDevice d) async {
    setState(() => _pairing = true);
    final ScaffoldMessengerState m = ScaffoldMessenger.of(context);
    try {
      final SyncPeer? p = await _s.pair(
        d,
        (String name, String code) => _askCode(name, code),
      );
      m.showSnackBar(
        SnackBar(
          content: Text(
            p == null
                ? 'Not paired: one of the two devices said no.'
                : 'Paired with ${p.name}. They now stay in sync while the '
                      'app is open on both.',
          ),
        ),
      );
    } on Object catch (e) {
      m.showSnackBar(SnackBar(content: Text('Not paired: $e')));
    } finally {
      if (mounted) {
        setState(() => _pairing = false);
      }
    }
  }

  Future<void> _forget(SyncPeer p) async {
    final bool? yes = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text('Forget ${p.name}?'),
        content: const Text(
          'This device stops syncing with it. Nothing is deleted on either. '
          'Forget this device on the other one too, or pair them again.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Forget'),
          ),
        ],
      ),
    );
    if (yes == true) {
      await _s.forget(p.id);
    }
  }

  Future<void> _rename() async {
    final TextEditingController c = TextEditingController(text: _s.name);
    final String? to = await showDialog<String>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('Name of this device'),
        content: TextField(
          controller: c,
          autofocus: true,
          maxLength: 40,
          onSubmitted: (String v) => Navigator.pop(context, v),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, c.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    c.dispose();
    if (to != null) {
      await _s.rename(to);
    }
  }

  /// Desktop systems may block devices that call in.
  String _firewallHint() => Platform.isLinux && _firewall == null
      ? '\n\nNothing after a minute? A firewall may be blocking it: allow '
            'port $syncPort, TCP and UDP (with ufw: sudo ufw allow $syncPort).'
      : Platform.isWindows || Platform.isMacOS
      ? '\n\nIf the system asks whether Pocket AMP Tools may use the '
            'network, allow it.'
      : '';

  String _ago(DateTime t) {
    final Duration d = DateTime.now().difference(t);
    return d.inSeconds < 60
        ? 'just now'
        : d.inMinutes < 60
        ? '${d.inMinutes} min ago'
        : d.inHours < 24
        ? '${d.inHours} h ago'
        : '${d.inDays} d ago';
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Sync devices')),
      body: ListenableBuilder(
        listenable: _s,
        builder: (BuildContext context, _) {
          final List<NearbyDevice> strangers = <NearbyDevice>[
            for (final NearbyDevice d in _s.nearby.values)
              if (!_s.peers.containsKey(d.id)) d,
          ];
          return ListView(
            padding: const EdgeInsets.all(24),
            children: <Widget>[
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 640),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      Card.outlined(
                        margin: EdgeInsets.zero,
                        child: Column(
                          children: <Widget>[
                            SwitchListTile(
                              title: const Text('Keep my devices in sync'),
                              subtitle: const Text(
                                'While the app is open on them, devices paired '
                                'on this network share the library, preset '
                                'backups and preset names, notes and ratings, '
                                'by themselves. Nothing leaves your network; '
                                'keys, sign-ins and settings stay on each '
                                'device.',
                              ),
                              value: _s.enabled,
                              onChanged: (bool on) => _s.setEnabled(on),
                            ),
                            const Divider(height: 1),
                            ListTile(
                              leading: const Icon(Icons.badge_outlined),
                              title: Text(_s.name),
                              subtitle: const Text(
                                'How other devices see this one',
                              ),
                              trailing: IconButton(
                                tooltip: 'Rename',
                                onPressed: _rename,
                                icon: const Icon(Icons.edit_outlined),
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (_s.enabled &&
                          _firewall != null &&
                          _s.firewallOpened != _firewall!.name)
                        _firewallCard(theme, _firewall!),
                      if (_s.enabled) ...<Widget>[
                        const SizedBox(height: 24),
                        Text(
                          'Paired devices',
                          style: theme.textTheme.titleMedium,
                        ),
                        const SizedBox(height: 8),
                        if (_s.peers.isEmpty)
                          Text(
                            'None yet. Pair one below.',
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          )
                        else
                          Card.outlined(
                            margin: EdgeInsets.zero,
                            clipBehavior: Clip.antiAlias,
                            child: Column(
                              children: <Widget>[
                                for (final SyncPeer p in _s.peers.values)
                                  ListTile(
                                    leading: Icon(
                                      _s.nearby.containsKey(p.id)
                                          ? Icons.devices
                                          : Icons.devices_other_outlined,
                                    ),
                                    title: Text(p.name),
                                    subtitle: Text(
                                      <String>[
                                        _s.nearby.containsKey(p.id)
                                            ? 'On this network'
                                            : 'Not in sight (the app is closed '
                                                  'or it is on another network)',
                                        if (p.lastSync != null)
                                          'last synced ${_ago(p.lastSync!)}',
                                        if (p.lastError != null) p.lastError!,
                                      ].join(' · '),
                                      maxLines: 3,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    trailing: IconButton(
                                      tooltip: 'Forget',
                                      onPressed: () => _forget(p),
                                      icon: const Icon(Icons.link_off),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        const SizedBox(height: 24),
                        Text(
                          'Other devices on this network',
                          style: theme.textTheme.titleMedium,
                        ),
                        const SizedBox(height: 8),
                        if (strangers.isEmpty)
                          Row(
                            children: <Widget>[
                              const SizedBox.square(
                                dimension: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  'Looking… Open this page on the other '
                                  'device, on the same Wi-Fi, with sync on.'
                                  '${_firewallHint()}',
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ),
                            ],
                          )
                        else
                          Card.outlined(
                            margin: EdgeInsets.zero,
                            clipBehavior: Clip.antiAlias,
                            child: Column(
                              children: <Widget>[
                                for (final NearbyDevice d in strangers)
                                  ListTile(
                                    leading: const Icon(Icons.devices_other),
                                    title: Text(d.name),
                                    trailing: FilledButton.tonal(
                                      onPressed: _pairing
                                          ? null
                                          : () => _pair(d),
                                      child: const Text('Pair'),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
