// SPDX-License-Identifier: GPL-3.0-only

import 'package:flutter/material.dart';

import '../presets/preset_meta.dart';

/// Name, rating, description and labels of one preset, at a glance, with the
/// button that edits them; a preset that has none gets the button alone.
class MetaSummary extends StatelessWidget {
  const MetaSummary({super.key, required this.meta, required this.onEdit});
  final PresetMeta meta;
  final VoidCallback onEdit;

  static const String editTooltip = 'Name, labels and rating';

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final PresetMeta m = meta;
    if (m.isEmpty) {
      return Align(
        alignment: AlignmentDirectional.centerStart,
        child: Tooltip(
          message: editTooltip,
          child: TextButton.icon(
            onPressed: onEdit,
            icon: const Icon(Icons.edit_note),
            label: const Text('Add a name'),
          ),
        ),
      );
    }
    final Color muted = theme.colorScheme.onSurfaceVariant;
    final String labels = <String>[
      for (final MetaCategory c in MetaCategory.values)
        if (m.labels[c]!.isNotEmpty) m.labels[c]!.join(', '),
    ].join('  ·  ');
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Flexible(
                child: Text(
                  m.name.isEmpty ? 'No name' : m.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: m.name.isEmpty ? muted : null,
                  ),
                ),
              ),
              if (m.rating > 0) ...<Widget>[
                const SizedBox(width: 12),
                Semantics(
                  label: '${m.rating} of 5 stars',
                  child: ExcludeSemantics(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        for (int s = 1; s <= 5; s++)
                          Icon(
                            s <= m.rating ? Icons.star : Icons.star_border,
                            size: 16,
                            color: s <= m.rating
                                ? theme.colorScheme.primary
                                : muted,
                          ),
                      ],
                    ),
                  ),
                ),
              ],
              const SizedBox(width: 4),
              IconButton(
                tooltip: editTooltip,
                visualDensity: VisualDensity.compact,
                iconSize: 18,
                onPressed: onEdit,
                icon: const Icon(Icons.edit_outlined),
              ),
            ],
          ),
          if (m.description.isNotEmpty)
            Text(
              m.description,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(color: muted),
            ),
          if (labels.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                labels,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(color: muted),
              ),
            ),
        ],
      ),
    );
  }
}

/// Opens [showMetaFilter]; marked while a filter is on.
class FilterButton extends StatelessWidget {
  const FilterButton({super.key, required this.details, required this.count});
  final PresetDetails details;

  /// How many presets there are to filter.
  final int count;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: details.filtering ? 'Filter presets (on)' : 'Filter presets',
    onPressed: () => showMetaFilter(context, details, count),
    icon: Badge(
      isLabelVisible: details.filtering,
      child: const Icon(Icons.filter_list),
    ),
  );
}

// Room for the fields on a wide window; a phone gets all but a thin margin.
const EdgeInsets _dialogInset = EdgeInsets.symmetric(
  horizontal: 16,
  vertical: 24,
);

/// Edits the name, rating, description and labels of preset [id].
Future<void> showMetaEditor(
  BuildContext context,
  PresetDetails details,
  int id,
  String title,
) => showDialog<void>(
  context: context,
  builder: (BuildContext context) => AlertDialog(
    insetPadding: _dialogInset,
    title: Text(title),
    content: SizedBox(
      width: 560,
      child: SingleChildScrollView(
        child: MetaFields(details: details, id: id),
      ),
    ),
    actions: <Widget>[
      FilledButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Done'),
      ),
    ],
  ),
);

/// The fields of [showMetaEditor]; every change is saved as it is made.
class MetaFields extends StatefulWidget {
  const MetaFields({super.key, required this.details, required this.id});
  final PresetDetails details;
  final int id;

  @override
  State<MetaFields> createState() => _MetaFieldsState();
}

class _MetaFieldsState extends State<MetaFields> {
  late final TextEditingController _name = TextEditingController(
    text: _meta.name,
  );
  late final TextEditingController _description = TextEditingController(
    text: _meta.description,
  );

  PresetMeta get _meta => widget.details.metas[widget.id];

  @override
  void initState() {
    super.initState();
    widget.details.addListener(_sync);
  }

  // A change from outside (the assistant) must reach the fields, or the next
  // keystroke would undo it. The user's own typing already matches.
  void _sync() {
    if (_name.text.trim() != _meta.name) {
      _name.text = _meta.name;
    }
    if (_description.text.trim() != _meta.description) {
      _description.text = _meta.description;
    }
  }

  @override
  void dispose() {
    widget.details.removeListener(_sync);
    _name.dispose();
    _description.dispose();
    super.dispose();
  }

  void _edit(void Function(PresetMeta m) change) {
    change(_meta);
    widget.details.changed();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.details,
    builder: (BuildContext context, _) {
      final ThemeData theme = Theme.of(context);
      final PresetMeta m = _meta;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          TextField(
            controller: _name,
            decoration: const InputDecoration(
              labelText: 'Name',
              hintText: 'A short name for this sound',
            ),
            onChanged: (String v) => _edit((PresetMeta m) => m.name = v.trim()),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _description,
            minLines: 1,
            maxLines: 4,
            decoration: const InputDecoration(
              labelText: 'Description',
              hintText: 'How it sounds and how it is built',
            ),
            onChanged: (String v) =>
                _edit((PresetMeta m) => m.description = v.trim()),
          ),
          const SizedBox(height: 8),
          StarRating(
            rating: m.rating,
            onChanged: (int r) => _edit((PresetMeta m) => m.rating = r),
          ),
          for (final MetaCategory c in MetaCategory.values) ...<Widget>[
            const SizedBox(height: 8),
            Text(c.title, style: theme.textTheme.labelLarge),
            const SizedBox(height: 4),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: <Widget>[
                for (final String l in m.labels[c]!) Chip(label: Text(l)),
                ActionChip(
                  avatar: Icon(
                    m.labels[c]!.isEmpty ? Icons.add : Icons.edit_outlined,
                    size: 18,
                  ),
                  label: Text(
                    m.labels[c]!.isEmpty
                        ? 'Add ${c.singular.toLowerCase()}'
                        : 'Change',
                  ),
                  tooltip: 'Pick ${c.title.toLowerCase()}',
                  onPressed: () =>
                      showLabelEditor(context, widget.details, c, meta: m),
                ),
              ],
            ),
          ],
        ],
      );
    },
  );
}

/// Five stars; tapping the current rating clears it.
class StarRating extends StatelessWidget {
  const StarRating({super.key, required this.rating, required this.onChanged});
  final int rating;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final Color c = Theme.of(context).colorScheme.primary;
    return Semantics(
      container: true,
      label: rating == 0 ? 'Not rated' : 'Rated $rating of 5',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          for (int s = 1; s <= 5; s++)
            IconButton(
              visualDensity: VisualDensity.compact,
              tooltip: s == rating ? 'Clear the rating' : '$s of 5',
              onPressed: () => onChanged(s == rating ? 0 : s),
              icon: Icon(
                s <= rating ? Icons.star : Icons.star_border,
                color: s <= rating ? c : null,
              ),
            ),
        ],
      ),
    );
  }
}

/// Adds and removes the labels offered for [c]; with [meta], also picks
/// which of them that preset has.
Future<void> showLabelEditor(
  BuildContext context,
  PresetDetails details,
  MetaCategory c, {
  PresetMeta? meta,
}) => showDialog<void>(
  context: context,
  builder: (BuildContext context) => AlertDialog(
    insetPadding: _dialogInset,
    title: Text(c.title),
    content: SizedBox(
      width: 420,
      child: _LabelEditor(details: details, category: c, meta: meta),
    ),
    actions: <Widget>[
      FilledButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Done'),
      ),
    ],
  ),
);

class _LabelEditor extends StatefulWidget {
  const _LabelEditor({
    required this.details,
    required this.category,
    required this.meta,
  });
  final PresetDetails details;
  final MetaCategory category;
  final PresetMeta? meta;

  @override
  State<_LabelEditor> createState() => _LabelEditorState();
}

class _LabelEditorState extends State<_LabelEditor> {
  final TextEditingController _add = TextEditingController();

  @override
  void dispose() {
    _add.dispose();
    super.dispose();
  }

  /// Adds what was typed; a label already on the list is picked instead.
  void _submit() {
    final PresetDetails details = widget.details;
    final MetaCategory c = widget.category;
    final String typed = _add.text.trim();
    if (typed.isEmpty) {
      return;
    }
    final String label = details.useLabel(c, typed);
    widget.meta?.labels[c]!.add(label);
    details.changed();
    _add.clear();
  }

  @override
  Widget build(BuildContext context) {
    final PresetDetails details = widget.details;
    final MetaCategory c = widget.category;
    final PresetMeta? meta = widget.meta;
    return ListenableBuilder(
      listenable: details,
      builder: (BuildContext context, _) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: TextField(
                  controller: _add,
                  autofocus: meta == null,
                  decoration: InputDecoration(
                    labelText: 'New ${c.singular.toLowerCase()}',
                  ),
                  onSubmitted: (_) => _submit(),
                ),
              ),
              IconButton(
                tooltip: 'Add',
                onPressed: _submit,
                icon: const Icon(Icons.add),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Flexible(
            child: SingleChildScrollView(
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  for (final String l in details.offered(c))
                    InputChip(
                      label: Text(l),
                      selected: meta?.labels[c]!.contains(l) ?? false,
                      onSelected: meta == null
                          ? null
                          : (bool v) {
                              v
                                  ? meta.labels[c]!.add(l)
                                  : meta.labels[c]!.remove(l);
                              details.changed();
                            },
                      deleteButtonTooltipMessage: 'Remove "$l"',
                      onDeleted: () => _remove(context, details, c, l),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

Future<void> _remove(
  BuildContext context,
  PresetDetails details,
  MetaCategory c,
  String label,
) async {
  final int used = details.metas
      .where((PresetMeta m) => m.labels[c]!.contains(label))
      .length;
  if (used > 0) {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text('Remove "$label"?'),
        content: Text(
          used == 1
              ? '1 preset has it; it loses the ${c.singular.toLowerCase()}.'
              : '$used presets have it; they lose the '
                    '${c.singular.toLowerCase()}.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok != true) {
      return;
    }
  }
  details.removeLabel(c, label);
}

/// Faceted filter on the list of [count] presets; applies as it is changed.
Future<void> showMetaFilter(
  BuildContext context,
  PresetDetails details,
  int count,
) => showDialog<void>(
  context: context,
  builder: (BuildContext context) => AlertDialog(
    insetPadding: _dialogInset,
    title: const Text('Filter presets'),
    content: SizedBox(
      width: 480,
      child: ListenableBuilder(
        listenable: details,
        builder: (BuildContext context, _) {
          final ThemeData theme = Theme.of(context);
          int shown = 0;
          for (int i = 0; i < count; i++) {
            if (details.matches(i)) {
              shown++;
            }
          }
          return SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  'Any value within a group, every group at once. '
                  '$shown of $count presets match.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                for (final MetaCategory c in MetaCategory.values)
                  if (details.offered(c).isNotEmpty) ...<Widget>[
                    const SizedBox(height: 16),
                    Text(c.title, style: theme.textTheme.labelLarge),
                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: <Widget>[
                        for (final String l in details.offered(c))
                          FilterChip(
                            label: Text(l),
                            selected: details.filter[c]!.contains(l),
                            onSelected: (bool v) => details.setFilter(c, l, v),
                          ),
                      ],
                    ),
                  ],
                const SizedBox(height: 16),
                Text('Rating', style: theme.textTheme.labelLarge),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: <Widget>[
                    for (int r = 0; r <= 5; r++)
                      ChoiceChip(
                        label: Text(
                          r == 0
                              ? 'Any'
                              : r == 5
                              ? '5 stars'
                              : '$r+ stars',
                        ),
                        selected: details.minRating == r,
                        onSelected: (_) => details.setMinRating(r),
                      ),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    ),
    actions: <Widget>[
      TextButton(onPressed: details.clearFilter, child: const Text('Clear')),
      FilledButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Done'),
      ),
    ],
  ),
);
