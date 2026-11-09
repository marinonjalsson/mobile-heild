import 'package:sqflite/sqflite.dart';

/// The app database: recordings pulled from the sensor plus per-minute
/// aggregates for graphs. Opened once by the app controller; tests open it on
/// the host through `sqflite_common_ffi` with an in-memory path.
class HeildDb {
  HeildDb._(this.db, this.path);

  final Database db;
  final String path;

  static const version = 2;

  /// Settings key set by a schema upgrade when `minute_stats` must be rebuilt
  /// from the raw rows (the app controller does it at start-up).
  static const statsRebuildKey = 'stats_rebuild';

  static Future<HeildDb> open({DatabaseFactory? factory, String? path}) async {
    final f = factory ?? databaseFactory;
    final p = path ?? '${await f.getDatabasesPath()}/heild.db';
    final db = await f.openDatabase(
      p,
      options: OpenDatabaseOptions(
        version: version,
        onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
        onCreate: (db, _) async {
          for (final s in _schema) {
            await db.execute(s);
          }
        },
        onUpgrade: (db, oldVersion, _) async {
          if (oldVersion < 2) {
            // v2: minute stats became a pure function of the raw rows
            // (pooled merges, RMSSD breaks at blockers). Recompute them.
            await db.insert('settings', {
              'key': statsRebuildKey,
              'value': '1',
            }, conflictAlgorithm: ConflictAlgorithm.replace);
          }
        },
      ),
    );
    if (p != inMemoryDatabasePath) {
      try {
        await db.rawQuery('PRAGMA journal_mode = WAL');
      } catch (_) {
        // Not all platforms allow switching; the default journal is fine.
      }
    }
    return HeildDb._(db, p);
  }

  Future<void> close() => db.close();

  static const _schema = [
    '''
    CREATE TABLE settings (
      key TEXT PRIMARY KEY,
      value TEXT NOT NULL
    )''',
    '''
    CREATE TABLE recordings (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      device_id TEXT NOT NULL,
      type TEXT NOT NULL,
      start_ms INTEGER NOT NULL,
      end_ms INTEGER NOT NULL,
      sample_count INTEGER NOT NULL,
      rate_hz INTEGER,
      range INTEGER,
      settings_json TEXT,
      source TEXT NOT NULL,
      path TEXT,
      fetched_ms INTEGER NOT NULL,
      sent_ms INTEGER,
      UNIQUE(device_id, type, start_ms)
    )''',
    'CREATE INDEX recordings_type_start ON recordings(type, start_ms)',
    '''
    CREATE TABLE hr_samples (
      recording_id INTEGER NOT NULL REFERENCES recordings(id) ON DELETE CASCADE,
      ts_ms INTEGER NOT NULL,
      hr INTEGER NOT NULL,
      contact INTEGER NOT NULL,
      PRIMARY KEY (recording_id, ts_ms)
    ) WITHOUT ROWID''',
    '''
    CREATE TABLE ppi_samples (
      recording_id INTEGER NOT NULL REFERENCES recordings(id) ON DELETE CASCADE,
      ts_ms INTEGER NOT NULL,
      ppi INTEGER NOT NULL,
      error_estimate INTEGER NOT NULL,
      hr INTEGER NOT NULL,
      blocker INTEGER NOT NULL,
      skin_contact INTEGER NOT NULL,
      PRIMARY KEY (recording_id, ts_ms)
    ) WITHOUT ROWID''',
    '''
    CREATE TABLE acc_chunks (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      recording_id INTEGER NOT NULL REFERENCES recordings(id) ON DELETE CASCADE,
      start_ms INTEGER NOT NULL,
      end_ms INTEGER NOT NULL,
      sample_count INTEGER NOT NULL,
      rate_hz INTEGER NOT NULL,
      data BLOB NOT NULL
    )''',
    'CREATE INDEX acc_chunks_rec ON acc_chunks(recording_id, start_ms)',
    '''
    CREATE TABLE minute_stats (
      type TEXT NOT NULL,
      minute_ms INTEGER NOT NULL,
      n INTEGER NOT NULL,
      mean REAL NOT NULL,
      min REAL NOT NULL,
      max REAL NOT NULL,
      extra REAL,
      PRIMARY KEY (type, minute_ms)
    ) WITHOUT ROWID''',
    '''
    CREATE TABLE sync_log (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      ts_ms INTEGER NOT NULL,
      level TEXT NOT NULL,
      message TEXT NOT NULL
    )''',
  ];
}
