import 'package:flutter/material.dart';

import '../../data/repository.dart';
import '../../main.dart';
import '../../state/auth_controller.dart';
import '../viewer/format.dart';
import '../widgets/common.dart';

/// The Online tab: the Loria sign-in and, once signed in, who is signed in
/// and what has been sent. Signing in is optional; only online sync needs it.
class OnlinePage extends StatelessWidget {
  const OnlinePage({super.key});

  @override
  Widget build(BuildContext context) {
    final auth = appController.auth;
    return Scaffold(
      appBar: AppBar(title: const Text('Online')),
      body: ListenableBuilder(
        listenable: Listenable.merge([auth, appController]),
        builder: (context, _) => ListView(
          padding: const EdgeInsets.only(bottom: 24),
          children: [
            switch (auth.status) {
              AuthStatus.signedIn => _Account(auth),
              AuthStatus.expired => _SignIn(auth, again: true),
              AuthStatus.signedOut => _SignIn(auth),
            },
            if (auth.status != AuthStatus.signedOut) _OnlineSync(auth),
            _History(auth),
          ],
        ),
      ),
    );
  }
}

class _SignIn extends StatelessWidget {
  const _SignIn(this.auth, {this.again = false});
  final AuthController auth;
  final bool again;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Section(
      title: again ? 'Sign in again' : 'Sign in',
      children: [
        Text(
          again
              ? 'The sign-in for ${auth.username} is no longer valid. '
                    'Nothing is sent until you sign in again; everything else '
                    'in the app keeps working.'
              : 'Sign in with your Loria account to send your data online. '
                    'The app works without it: recordings stay on this phone.',
          style: theme.textTheme.bodyMedium,
        ),
        const SizedBox(height: 12),
        _Error(auth),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.icon(
            onPressed: auth.busy ? null : auth.signIn,
            icon: auth.busy
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.login),
            label: const Text('Sign in'),
          ),
        ),
        if (auth.signingIn)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: auth.cancelSignIn,
              child: const Text('Cancel'),
            ),
          ),
        if (again && !auth.signingIn)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: auth.busy ? null : auth.signOut,
              child: const Text('Forget this account'),
            ),
          ),
        const SizedBox(height: 4),
        Text(
          'Opens auth.loria.is in your browser.',
          style: theme.textTheme.bodySmall,
        ),
      ],
    );
  }
}

class _Account extends StatelessWidget {
  const _Account(this.auth);
  final AuthController auth;

  @override
  Widget build(BuildContext context) {
    final at = auth.signedInAt;
    return Section(
      title: 'Signed in',
      children: [
        KeyValueList({
          'Username': auth.username,
          if (auth.displayName != null) 'Name': auth.displayName,
          if (auth.email != null) 'Email': auth.email,
          if (at != null) 'Since': fmtDateTime.format(at),
          'Account': 'auth.loria.is',
        }),
        const SizedBox(height: 8),
        _Error(auth),
        Wrap(
          spacing: 8,
          children: [
            OutlinedButton.icon(
              onPressed: auth.busy
                  ? null
                  : () async {
                      final ok = await auth.check();
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            ok
                                ? 'Sign-in works'
                                : auth.status == AuthStatus.expired
                                ? 'Sign in again'
                                : 'Could not reach the sign-in server',
                          ),
                        ),
                      );
                    },
              icon: const Icon(Icons.verified_user_outlined),
              label: const Text('Check sign-in'),
            ),
            TextButton.icon(
              onPressed: auth.busy ? null : () => _confirmSignOut(context),
              icon: const Icon(Icons.logout),
              label: const Text('Sign out'),
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _confirmSignOut(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Sign out?'),
        content: const Text(
          'Online sync stops until you sign in again. '
          'Recordings on this phone are kept.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Sign out'),
          ),
        ],
      ),
    );
    if (ok == true) await auth.signOut();
  }
}

class _Error extends StatelessWidget {
  const _Error(this.auth);
  final AuthController auth;

  @override
  Widget build(BuildContext context) {
    final e = auth.lastError;
    if (e == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        e,
        style: TextStyle(color: Theme.of(context).colorScheme.error),
      ),
    );
  }
}

/// What online sync is doing: how much is waiting, how the last run went,
/// and a button to run it now.
class _OnlineSync extends StatelessWidget {
  const _OnlineSync(this.auth);
  final AuthController auth;

  @override
  Widget build(BuildContext context) {
    final online = appController.online;
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: online,
      builder: (context, _) => _Loaded<int>(
        // Re-read when a sensor sync or a live flush changed the data, and
        // as an upload works through the queue.
        version: (appController.sync.dataVersion, online.done, online.running),
        load: appController.repo.unsentCount,
        builder: (context, snap) {
          final at = online.lastRunAt;
          return Section(
            title: 'Online sync',
            children: [
              KeyValueList({
                'Status': !auth.isSignedIn
                    ? 'stopped: sign in again'
                    : online.running
                    ? 'sending ${online.done} of ${online.total}…'
                    : 'sends after each sensor sync',
                'Waiting on this phone': snap.hasData
                    ? '${snap.data} recordings'
                    : '…',
                if (at != null) 'Last run': fmtAgo(at),
                'Goes to': 'mon.loria.is/heild',
              }),
              if (online.running) ...[
                const SizedBox(height: 8),
                LinearProgressIndicator(
                  value: online.total == 0 ? null : online.done / online.total,
                ),
              ],
              if (online.lastMessage != null && !online.running)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    online.lastMessage!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: online.lastOk ? null : theme.colorScheme.error,
                    ),
                  ),
                ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  onPressed: online.running || !auth.isSignedIn
                      ? null
                      : () => online.run(reason: 'manual'),
                  icon: const Icon(Icons.cloud_upload_outlined),
                  label: const Text('Upload now'),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// A FutureBuilder that queries again only when [version] changes. The page
/// rebuilds on every app notification (there are many during a sensor sync)
/// and must not hit the database each time.
class _Loaded<T> extends StatefulWidget {
  const _Loaded({
    required this.version,
    required this.load,
    required this.builder,
  });

  final Object version;
  final Future<T> Function() load;
  final AsyncWidgetBuilder<T> builder;

  @override
  State<_Loaded<T>> createState() => _LoadedState<T>();
}

class _LoadedState<T> extends State<_Loaded<T>> {
  late Future<T> _future = widget.load();

  @override
  void didUpdateWidget(_Loaded<T> old) {
    super.didUpdateWidget(old);
    if (old.version != widget.version) _future = widget.load();
  }

  @override
  Widget build(BuildContext context) =>
      FutureBuilder<T>(future: _future, builder: widget.builder);
}

class _History extends StatelessWidget {
  const _History(this.auth);
  final AuthController auth;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return _Loaded<List<OnlineLogRow>>(
      version: auth.historyVersion,
      load: appController.repo.onlineHistory,
      builder: (context, snap) {
        final rows = snap.data ?? const <OnlineLogRow>[];
        return Section(
          title: 'History',
          children: [
            if (rows.isEmpty)
              Text(
                snap.hasData ? 'Nothing yet.' : '…',
                style: theme.textTheme.bodySmall,
              ),
            for (final r in rows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      r.kind == 'push'
                          ? (r.ok ? Icons.cloud_done_outlined : Icons.cloud_off)
                          : (r.ok ? Icons.person_outline : Icons.error_outline),
                      size: 18,
                      color: r.ok
                          ? theme.colorScheme.onSurfaceVariant
                          : theme.colorScheme.error,
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 92,
                      child: Text(
                        fmtMs(r.tsMs),
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                    Expanded(
                      child: Text(r.message, style: theme.textTheme.bodySmall),
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}
