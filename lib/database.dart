import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:path_provider/path_provider.dart';
part 'database.g.dart';

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
  TextColumn get value => text()();
}

@DriftDatabase(tables: [KVs])
class TheDatabase extends _$TheDatabase {
  TheDatabase([QueryExecutor? executor]) : super(executor ?? _openConnection());
  @override
  int get schemaVersion => 1;
  static QueryExecutor _openConnection() {
    return driftDatabase(
      name: 'mako_timer_db',
      native: const DriftNativeOptions(
          databaseDirectory: getApplicationSupportDirectory),
    );
  }
}
