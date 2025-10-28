import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:path_provider/path_provider.dart';
import 'package:makos_timer/mobj.dart';
part 'database.g.dart';

const MobjID timerListID = '0afc1e39-9ed7-4174-8d72-e9319224d6e8';
const MobjID transientTimerListID = '0c02ee9a-6618-4231-a8c9-36f145970a4c';
const MobjID dbVersionID = '87012e13-974b-45f6-b0d7-ea8d1a3127ed';
const MobjID nextHueID = 'cd813df3-bb7b-4b69-a238-89b4971198ef';
const MobjID selectedAudioID = 'baa10d03-aa7f-4cc6-bd58-0c62bdaa9757';
// some spares
// 14513b04-3cbc-478b-b982-a2a17a7aaf29
// add21433-a63f-4eec-9786-d1d5959d0dc3
// f6ba1437-0300-4762-9848-827e71c16099
// b416f18f-ed48-4520-83ec-2145759f93ec
// cursor made this one lol
// 91012689-136a-4b23-9629-5a71657709a4

mixin UUIDd on Table {
  TextColumn get id => text()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

// we'll just store timers as kv entries
// class Timers extends Table with UUIDd {
//   /// the time when the timer was started or the duration it was paused at.
//   DateTimeColumn get startTime => dateTime()();

//   /// in seconds
//   RealColumn get duration => real()();

//   /// whether it's paused/playing
//   IntColumn get runningStatus => integer()();

//   /// the hue of the (pastel) color, in [0,1)
//   RealColumn get hue => real()();
// }

class KVs extends Table with UUIDd {
  // lol it turns out this all could have been done with UUIDV7, the first 48 bits are a unix timestamp, the next 12 bits are a sequence number.
  DateTimeColumn get timestamp => dateTime()();

  /// used when one process wants to override its previous value. Is subordinate to timestamp
  IntColumn get sequenceNumber => integer().withDefault(const Constant(0))();
  TextColumn get value => text()();
}

@DriftDatabase(tables: [
  KVs
], queries: {
  /// updates the value if it's lexicographically (includes chronologically) after the current value
  // todo, try removing the first listing of :id, :value, :timestamp, :sequence_number, I can't see a reason why they should need to be listed there.
  'insertIfMoreRecent': '''
WITH comparison AS (
  SELECT 
    :id,
    :value,
    :timestamp,
    :sequence_number,
    CASE 
      WHEN :timestamp > k_vs.timestamp THEN 1
      WHEN :timestamp = k_vs.timestamp AND :value > k_vs.value THEN 1
      WHEN :timestamp = k_vs.timestamp AND :value = k_vs.value AND :sequence_number > k_vs.sequence_number THEN 1
      ELSE 0
    END as should_update
  FROM k_vs
  WHERE id = :id
)
INSERT INTO k_vs (id, value, timestamp, sequence_number) 
VALUES (:id, :value, :timestamp, :sequence_number)
ON CONFLICT(id) DO UPDATE SET
  value = CASE WHEN (SELECT should_update FROM comparison) = 1
          THEN excluded.value ELSE k_vs.value END,
  timestamp = CASE WHEN (SELECT should_update FROM comparison) = 1
              THEN excluded.timestamp ELSE k_vs.timestamp END,
  sequence_number = CASE WHEN (SELECT should_update FROM comparison) = 1
                  THEN excluded.sequence_number ELSE k_vs.sequence_number END
'''
})
class TheDatabase extends _$TheDatabase {
  TheDatabase([QueryExecutor? executor]) : super(executor ?? _openConnection());
  @override
  int get schemaVersion => 1;
  static QueryExecutor _openConnection() {
    return driftDatabase(
      name: 'mako_timer_db',
      native: const DriftNativeOptions(
          databaseDirectory: getApplicationSupportDirectory,
          shareAcrossIsolates: true),
    );
  }
}
