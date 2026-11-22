import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/repository.dart';
import '../online/upload_client.dart';
import '../online/upload_payload.dart';
import '../online/walk_payload.dart';
import '../walk/models.dart';
import 'auth_controller.dart';
import 'features.dart';

/// Sends recordings to the server: every recording the sensor made that has not
/// been sent yet, oldest first, one request each, marked sent when the server says
/// it has it. Only when somebody is signed in; without that this does
/// nothing and nothing else in the app notices.
///
/// Separate from [SyncService] on purpose. That one talks to the sensor over
/// Bluetooth and must work with no network and no account; this one needs
/// both and is allowed to fail. It runs after each sensor sync, once the
/// sensor is disconnected, after a sign-in, and from "Upload now"; never
/// while the phone is talking to the sensor ([sensorBusy]).
///
/// "Sent" is what the phone's retention waits for: a recording older than
/// the retention period is deleted only once it is marked sent.
class OnlineSyncService extends ChangeNotifier {
  OnlineSyncService(
    this._repo,
    this._auth,
    this._uploads, {
    this.walks = walkUploadEnabled,
  });

  final Repository _repo;
  final AuthController _auth;
  final UploadClient _uploads;

  /// Finished walks are sent too, after the recordings.
  final bool walks;

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

  /// The sensor sync is connected or about to be. Uploads wait for it: the
  /// phone finishes with the sensor first, and the sync starts a run itself
  /// once it has disconnected.
  bool Function() sensorBusy = () => false;

  /// Recordings the server refused for good (HTTP 400), so they are not offered
  /// again on every run. Kept for the life of the process only: after a
  /// restart they are tried once more, which is how a fix on the server's side
  /// reaches them.
  final _rejected = <int>{};
  final _rejectedWalks = <int>{};

  Future<void> run({String reason = 'manual'}) async {
    if (!_auth.isSignedIn) return;
    if (sensorBusy()) {
      lastMessage = 'waiting for the sensor sync to finish';
      lastOk = true;
      notifyListeners();
      return;
    }
    if (running) {
      _again = true;
      return;
    }
    running = true;
    done = 0;
    total =
        await _repo.unsentCount() + (walks ? await _repo.unsentWalkCount() : 0);
    notifyListeners();

    var sent = 0;
    var walksSent = 0;
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
          final outcome = await _send(
            await buildUpload(_repo, r),
            _uploads.upload,
          );
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
                'The server refused ${r.type.label} of '
                    '${DateTime.fromMillisecondsSinceEpoch(r.startMs)}: $why',
                ok: false,
              );
            case _Stopped(:final why):
              failure = why;
              break batches;
          }
        }
      }
      walkBatches:
      while (walks && failure == null) {
        final batch = await _repo.unsentWalks(
          limit: 20,
          except: _rejectedWalks,
        );
        if (batch.isEmpty) break;
        for (final WalkRow w in batch) {
          final outcome = await _send(
            await buildWalkUpload(_repo, w),
            _uploads.uploadWalk,
          );
          switch (outcome) {
            case _Sent(:final bytes_):
              await _repo.markWalkSent(w.id);
              walksSent++;
              bytes += bytes_;
              done++;
              notifyListeners();
            case _Refused(:final why):
              _rejectedWalks.add(w.id);
              refused++;
              await _repo.onlineLog(
                'push',
                'The server refused the walk of '
                    '${DateTime.fromMillisecondsSinceEpoch(w.startMs)}: $why',
                ok: false,
              );
            case _Stopped(:final why):
              failure = why;
              break walkBatches;
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
        lastMessage = sent + walksSent == 0
            ? failure
            : 'sent ${sent + walksSent}, then stopped: $failure';
      } else {
        lastOk = refused == 0;
        lastMessage = sent + walksSent == 0 && refused == 0
            ? 'nothing to send'
            : 'sent ${_what(sent, walksSent)} (${_kb(bytes)})'
                  '${refused == 0 ? '' : ', $refused refused'}';
      }
      // One line of history per run that did or failed at something; a run
      // that found nothing to send is not history.
      if (sent + walksSent > 0 || failure != null) {
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

  /// "3 recordings", "1 walk", "3 recordings and 1 walk".
  static String _what(int recordings, int walks) => [
    if (recordings > 0 || walks == 0) '$recordings recordings',
    if (walks > 0) walks == 1 ? '1 walk' : '$walks walks',
  ].join(' and ');

  /// Posts one [body] with [post] (a recording or a walk).
  Future<_Outcome> _send(
    Map<String, Object?> body,
    Future<int> Function(String token, Map<String, Object?> body) post,
  ) async {
    var token = await _auth.accessToken();
    if (token == null) return _Stopped(_noToken());
    for (var attempt = 0; ; attempt++) {
      try {
        return _Sent(await post(token!, body));
      } on UploadException catch (e) {
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
          // scope gets: the server cannot see the group in it.
          return _Stopped(
            '${e.message}. If you are in the group, sign out and sign in '
            'again.',
          );
        }
        return _Stopped('Server: ${e.message}');
      } on TimeoutException {
        return const _Stopped('The server did not answer');
      } catch (e) {
        return _Stopped('The server could not be reached ($e)');
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

/// The server will not take this recording; go on with the next.
class _Refused extends _Outcome {
  const _Refused(this.why);
  final String why;
}

/// Nothing more can be sent right now; the rest waits for the next run.
class _Stopped extends _Outcome {
  const _Stopped(this.why);
  final String why;
}
