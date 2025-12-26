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
const MobjID isRightHandedID = '14513b04-3cbc-478b-b982-a2a17a7aaf29';
const MobjID padVerticallyAscendingID = 'add21433-a63f-4eec-9786-d1d5959d0dc3';

/// gets set when they set the app up
const MobjID timeFirstUsedApp = 'f6ba1437-0300-4762-9848-827e71c16099';

/// gets set when they create their first timer
const MobjID hasCreatedTimerID = '2d4b1cab-dd74-4888-bc32-2ebc08ece52f';

const MobjID exitedSetupID = 'b416f18f-ed48-4520-83ec-2145759f93ec';
const MobjID completedSetupID = 'ac869383-78d9-4013-b234-1e061e742b24';

/// the span of the buttons in the control pad, in logical pixels
const MobjID buttonSpanID = '1a6d9d41-3002-48b3-a2a7-7117bfcd67b2';

const MobjID buttonScaleDialOnID = '59a00948-75e1-4a87-8f57-42208b03c3a2';
const MobjID crankGameWinMessageIndexID =
    '71874fd9-f83b-4bc3-a2a4-327298746577';
const MobjID usedDragActionRecordID = '1cf75159-85e7-46eb-aa21-5b06a164b01b';

// some spares
// 1cd38324-8199-4c92-88f1-a6becbe9ec55
// fb66e93f-84d1-4809-a997-293218a83ddc
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
  /// updates the value if it's lexicographically (includes chronologically) after the current value (drift_dev will produce warnings about the comparison of string-formatted timestamps, but iso8601 is lexicographically ordered in this situation)
  // the select used to list :id, :value, :timestamp, :sequence_number, but I couldn't see what they were doing, so I removed them. I think claude might have just put them there to control the order the parameters would be in in the generated code. We turned on named parameters so that doesn't matter now.
  'insertIfMoreRecent': '''
WITH comparison AS (
  SELECT 
    CASE 
      WHEN :timestamp > k_vs.timestamp THEN 1
      WHEN :timestamp = k_vs.timestamp AND :sequence_number > k_vs.sequence_number THEN 1
      WHEN :timestamp = k_vs.timestamp AND :sequence_number = k_vs.sequence_number AND :value > k_vs.value THEN 1
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
''',

  /// inserts a row if it doesn't exist, returns the final value and whether an insert occurred
  'insertIfNotExistsAndReturn': '''
  INSERT INTO k_vs (id, value, timestamp, sequence_number)
  VALUES (:id, :value, :timestamp, :sequence_number)
  ON CONFLICT(id) DO NOTHING
  RETURNING
    (SELECT COUNT(*) FROM k_vs WHERE id = :id AND timestamp = :timestamp) as was_inserted,
    (SELECT id FROM k_vs WHERE id = :id) as id,
    (SELECT value FROM k_vs WHERE id = :id) as value,
    (SELECT timestamp FROM k_vs WHERE id = :id) as timestamp,
    (SELECT sequence_number FROM k_vs WHERE id = :id) as sequence_number
'''
})
class TheDatabase extends _$TheDatabase {
  TheDatabase([QueryExecutor? executor]) : super(executor ?? _openConnection());
  @override
  int get schemaVersion => 1;

  /// Inserts a row if it doesn't exist, returns the final value and whether an insert occurred
  // Future<({KV row, bool wasInserted})> insertIfNotExistsAndReturn({
  //   required String id,
  //   required String value,
  //   required DateTime timestamp,
  //   required int sequenceNumber,
  // }) async {
  //   final existsBefore =
  //       await (select(kVs)..where((t) => t.id.equals(id))).getSingleOrNull();

  //   if (existsBefore == null) {
  //     await into(kVs).insert(KVsCompanion.insert(
  //       id: id,
  //       value: value,
  //       timestamp: timestamp,
  //       sequenceNumber: Value(sequenceNumber),
  //     ));
  //     final row =
  //         await (select(kVs)..where((t) => t.id.equals(id))).getSingle();
  //     return (row: row, wasInserted: true);
  //   } else {
  //     return (row: existsBefore, wasInserted: false);
  //   }
  // }

  static QueryExecutor _openConnection() {
    return driftDatabase(
      name: 'mako_timer_db',
      native: const DriftNativeOptions(
          databaseDirectory: getApplicationSupportDirectory,
          shareAcrossIsolates: true),
    );
  }
}
