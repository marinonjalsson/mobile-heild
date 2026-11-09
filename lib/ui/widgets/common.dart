import 'package:flutter/material.dart';

import '../../polar/polar_errors.dart';

/// Runs [action], then shows [success] or the error in a snackbar.
/// Returns true when the action completed without throwing.
Future<bool> runAction(
  BuildContext context,
  Future<void> Function() action, {
  String? success,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  final errorColor = Theme.of(context).colorScheme.error;
  try {
    await action();
    if (success != null) {
      messenger.showSnackBar(SnackBar(content: Text(success)));
    }
    return true;
  } on PolarException catch (e) {
    messenger.showSnackBar(
      SnackBar(content: Text(e.toString()), backgroundColor: errorColor),
    );
    return false;
  } catch (e) {
    messenger.showSnackBar(
      SnackBar(content: Text('$e'), backgroundColor: errorColor),
    );
    return false;
  }
}

/// Confirmation for an irreversible operation. The user must type [word].
Future<bool> confirmTyped(
  BuildContext context, {
  required String title,
  required String body,
  required String word,
}) async {
  final ctrl = TextEditingController();
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(body),
            const SizedBox(height: 16),
            Text('Type $word to confirm:'),
            TextField(
              controller: ctrl,
              autofocus: true,
              autocorrect: false,
              onChanged: (_) => setState(() {}),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            onPressed: ctrl.text.trim() == word
                ? () => Navigator.pop(ctx, true)
                : null,
            child: const Text('Confirm'),
          ),
        ],
      ),
    ),
  );
  ctrl.dispose();
  return ok ?? false;
}

/// Simple yes/no confirmation.
Future<bool> confirmSimple(
  BuildContext context, {
  required String title,
  required String body,
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('OK'),
        ),
      ],
    ),
  );
  return ok ?? false;
}

/// Shows [text] in a scrollable dialog.
Future<void> showTextDialog(BuildContext context, String title, String text) =>
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(child: SelectableText(text)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );

/// Asks for one line of text.
Future<String?> promptText(
  BuildContext context, {
  required String title,
  String? hint,
  String initial = '',
}) async {
  final ctrl = TextEditingController(text: initial);
  final value = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: ctrl,
        autofocus: true,
        decoration: InputDecoration(hintText: hint),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, ctrl.text),
          child: const Text('OK'),
        ),
      ],
    ),
  );
  ctrl.dispose();
  return value;
}

/// A card with a title and children, used for every section of the tabs.
class Section extends StatelessWidget {
  const Section({
    super.key,
    required this.title,
    required this.children,
    this.trailing,
  });

  final String title;
  final List<Widget> children;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                ?trailing,
              ],
            ),
            const SizedBox(height: 8),
            ...children,
          ],
        ),
      ),
    );
  }
}

/// Two-column key/value rows.
class KeyValueList extends StatelessWidget {
  const KeyValueList(this.entries, {super.key});

  final Map<String, String?> entries;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodyMedium;
    return Column(
      children: [
        for (final e in entries.entries)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 150,
                  child: Text(
                    e.key,
                    style: style?.copyWith(color: Theme.of(context).hintColor),
                  ),
                ),
                Expanded(child: SelectableText(e.value ?? '—', style: style)),
              ],
            ),
          ),
      ],
    );
  }
}

/// Wrap of buttons with consistent spacing.
class ButtonRow extends StatelessWidget {
  const ButtonRow(this.children, {super.key});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) =>
      Wrap(spacing: 8, runSpacing: 4, children: children);
}

String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} kB';
  return '${(bytes / 1024 / 1024).toStringAsFixed(2)} MB';
}
