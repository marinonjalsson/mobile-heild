import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/repository.dart';
import '../online/mon_client.dart';
import '../online/upload_payload.dart';
import 'auth_controller.dart';

/// Sends recordings to mon: every recording the sensor made that has not
/// been sent yet, oldest first, one request each, marked sent when mon says
/// it has it. Only when somebody is signed in; without that this does
/// nothing and nothing else in the app notices.
///
/// Separate from [SyncService] on purpose. That one talks to the sensor over
/// Bluetooth and must work with no network and no account; this one needs
/// both and is allowed to fail. It runs after each sensor sync, after a
/// sign-in, and from "Upload now".
///
/// "Sent" is what the phone's retention waits for: a recording older than
/// the retention period is deleted only once it is marked sent.
class OnlineSyncService extends ChangeNotifier {
  OnlineSyncService(this._repo, this._auth, this._mon);

  final Repository _repo;
  final AuthController _auth;
  final MonClient _mon;

  /// Called after a run that sent something (the table shows what is sent).
  VoidCallback? dataChanged;

  bool running = false;

  /// Progress of the current run.
  int done = 0;
  int total = 0;

  /// How the last run ended, for the Online tab. Null until one has.
  String? lastMessage;
  bool lastOk = true;
  DateTime? lastRunAt;

  bool _again = false;

  /// Recordings mon refused for good (HTTP 400), so they are not offered
  /// again on every run. Kept for the life of the process only: after a
  /// restart they are tried once more, which is how a fix on mon's side
  /// reaches them.
  final _rejected = <int>{};

  Future<void> run({String reason = 'manual'}) async {
    if (!_auth.isSignedIn) return;
    if (running) {
      _again = true;
      return;
    }
    running = true;
    done = 0;
    total = await _repo.unsentCount();
    notifyListeners();

    var sent = 0;
    var bytes = 0;
    var refused = 0;
    String? failure;
    try {
      batches:
      while (true) {
        final batch = await _repo.unsentRecordings(
          limit: 20,
          except: _rejected,
        );
        if (batch.isEmpty) break;
        for (final r in batch) {
          final outcome = await _send(r);
          switch (outcome) {
            case _Sent(:final bytes_):
              await _repo.markSent(r.id, true);
              sent++;
              bytes += bytes_;
              done++;
              notifyListeners();
            case _Refused(:final why):
              _rejected.add(r.id);
              refused++;
              await _repo.onlineLog(
                'push',
                'mon refused ${r.type.label} of '
                    '${DateTime.fromMillisecondsSinceEpoch(r.startMs)}: $why',
                ok: false,
              );
            case _Stopped(:final why):
              failure = why;
              break batches;
          }
        }
      }
    } catch (e) {
      failure = '$e';
    } finally {
      running = false;
      lastRunAt = DateTime.now();
      if (failure != null) {
        lastOk = false;
        lastMessage = sent == 0
            ? failure
            : 'sent $sent, then stopped: $failure';
      } else {
        lastOk = refused == 0;
        lastMessage = sent == 0 && refused == 0
            ? 'nothing to send'
            : 'sent $sent recordings (${_kb(bytes)})'
                  '${refused == 0 ? '' : ', $refused refused'}';
      }
      // One line of history per run that did or failed at something; a run
      // that found nothing to send is not history.
      if (sent > 0 || failure != null) {
        await _repo.onlineLog('push', lastMessage!, ok: failure == null);
        _auth.historyVersion++;
      }
      if (sent > 0) dataChanged?.call();
      notifyListeners();
    }
    if (_again) {
      _again = false;
      unawaited(run(reason: 'queued'));
    }
  }

  Future<_Outcome> _send(RecordingRow r) async {
    var token = await _auth.accessToken();
    if (token == null) return _Stopped(_noToken());
    final body = await buildUpload(_repo, r);
    for (var attempt = 0; ; attempt++) {
      try {
        return _Sent(await _mon.upload(token!, body));
      } on MonException catch (e) {
        if (e.isUnauthorized && attempt == 0) {
          // The access token ran out between the check and the request, or
          // was revoked. A fresh one settles which.
          token = await _auth.accessToken(forceRefresh: true);
          if (token == null) return _Stopped(_noToken());
          continue;
        }
        if (e.isRejected) return _Refused(e.message);
        if (e.isForbidden) {
          // Also what a sign-in from before the app asked for the `groups`
          // scope gets: mon cannot see the group in it.
          return _Stopped(
            '${e.message}. If you are in the group, sign out and sign in '
            'again.',
          );
        }
        return _Stopped('mon: ${e.message}');
      } on TimeoutException {
        return const _Stopped('mon did not answer');
      } catch (e) {
        return _Stopped('mon could not be reached ($e)');
      }
    }
  }

  String _noToken() => _auth.status == AuthStatus.expired
      ? 'sign in again'
      : 'the sign-in server could not be reached';

  static String _kb(int bytes) => bytes >= 1024 * 1024
      ? '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB'
      : '${(bytes / 1024).ceil()} kB';
}

sealed class _Outcome {
  const _Outcome();
}

class _Sent extends _Outcome {
  const _Sent(this.bytes_);
  final int bytes_;
}

/// mon will not take this recording; go on with the next.
class _Refused extends _Outcome {
  const _Refused(this.why);
  final String why;
}

/// Nothing more can be sent right now; the rest waits for the next run.
class _Stopped extends _Outcome {
  const _Stopped(this.why);
  final String why;
}
