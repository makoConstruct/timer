import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:makos_timer/database.dart';
import 'package:signals/signals_flutter.dart';

import 'main.dart';

/// The TypeHelp class is extended type information that's used to convert to and from json in the database, as well as to encode the type information.
/// type description has to be taken from the top level TypeHelp rather than from each individual object (heterogenously) because we want the top level dart runtime types to be correct too
/// TypeHelp type descriptions are stored with the values in the db to allow fully pre-parsing the objects up front

abstract class TypeHelp<T> {
  final Object typeDescription;

  const TypeHelp(this.typeDescription);

  T fromJson(Object? json) {
    return fromJsonValue(json);
  }

  Object? toJson(T object) {
    return toJsonValue(object);
  }

  T fromJsonValue(Object? json);
  Object? toJsonValue(T object);
}

class IntType extends TypeHelp<int> {
  const IntType() : super('int');

  @override
  int fromJsonValue(Object? json) {
    if (json is int) return json;
    if (json is String) return int.parse(json);
    throw ArgumentError('Cannot convert $json to int');
  }

  @override
  Object? toJsonValue(int object) => object;
}

class DoubleType extends TypeHelp<double> {
  const DoubleType() : super('double');

  @override
  double fromJsonValue(Object? json) {
    if (json is double) return json;
    if (json is int) return json.toDouble();
    if (json is String) return double.parse(json);
    throw ArgumentError('Cannot convert $json to double');
  }

  @override
  Object? toJsonValue(double object) => object;
}

class BoolType extends TypeHelp<bool> {
  const BoolType() : super('bool');

  @override
  bool fromJsonValue(Object? json) {
    if (json is bool) return json;
    throw ArgumentError('Cannot convert $json to bool');
  }

  @override
  Object? toJsonValue(bool object) => object;
}

class StringType extends TypeHelp<String> {
  const StringType() : super('string');

  @override
  String fromJsonValue(Object? json) {
    if (json is String) return json;
    throw ArgumentError('Cannot convert null to String');
  }

  @override
  Object? toJsonValue(String object) => object;
}

class Nullable<T> extends TypeHelp<T?> {
  final TypeHelp<T> innerType;

  Nullable(this.innerType) : super(['nullable', innerType.typeDescription]);

  @override
  T? fromJsonValue(Object? json) {
    if (json == null) return null;
    return innerType.fromJson(json);
  }

  @override
  Object? toJsonValue(T? object) {
    if (object == null) return null;
    return innerType.toJson(object);
  }
}

class ListType<T> extends TypeHelp<List<T>> {
  final TypeHelp<T> itemConverter;

  ListType(this.itemConverter) : super(['list', itemConverter.typeDescription]);

  @override
  List<T> fromJsonValue(Object? json) {
    if (json is List) {
      return json.map((item) => itemConverter.fromJson(item)).toList();
    }
    throw ArgumentError('Cannot convert $json to List');
  }

  @override
  Object? toJsonValue(List<T> object) {
    return object.map((item) => itemConverter.toJson(item)).toList();
  }
}

class MapType<K, V> extends TypeHelp<Map<K, V>> {
  final TypeHelp<K> keyConverter;
  final TypeHelp<V> valueConverter;

  MapType(this.keyConverter, this.valueConverter)
      : super([
          'map',
          keyConverter.typeDescription,
          valueConverter.typeDescription
        ]);

  @override
  Map<K, V> fromJsonValue(Object? json) {
    if (json is Map<String, dynamic>) {
      return json.map((key, value) => MapEntry(
            keyConverter.fromJson(key),
            valueConverter.fromJson(value),
          ));
    }
    throw ArgumentError('Cannot convert $json to Map');
  }

  @override
  Object? toJsonValue(Map<K, V> object) {
    return object.map((key, value) => MapEntry(
          keyConverter.toJson(key),
          valueConverter.toJson(value),
        ));
  }
}

class DateTimeType extends TypeHelp<DateTime> {
  const DateTimeType() : super('datetime');

  @override
  DateTime fromJsonValue(Object? json) {
    if (json is String) {
      return DateTime.parse(json);
    }
    if (json is int) {
      return DateTime.fromMillisecondsSinceEpoch(json);
    }
    throw ArgumentError('Cannot convert $json to DateTime');
  }

  @override
  Object? toJsonValue(DateTime object) {
    return object.toIso8601String();
  }
}

class TimerDataType extends TypeHelp<TimerData> {
  const TimerDataType() : super('TimerData');

  @override
  TimerData fromJsonValue(Object? json) {
    if (json is Map<String, dynamic>) {
      return TimerData(
        startTime: Nullable(const DateTimeType()).fromJson(json['startTime']),
        runningState: const IntType().fromJson(json['runningState']),
        hue: const DoubleType().fromJson(json['hue']),
        selected: const BoolType().fromJson(json['selected']),
        digits: ListType(const IntType()).fromJson(json['digits']),
        ranTime: const DoubleType().fromJson(json['ranTime']),
        isGoingOff: const BoolType().fromJson(json['isGoingOff']),
      );
    }
    throw ArgumentError('Cannot convert $json to TimerData');
  }

  @override
  Object? toJsonValue(TimerData object) {
    return {
      'startTime': Nullable(const DateTimeType()).toJson(object.startTime),
      'runningState': const IntType().toJson(object.runningState),
      'hue': const DoubleType().toJson(object.hue),
      'selected': const BoolType().toJson(object.selected),
      'digits': ListType(const IntType()).toJson(object.digits),
      'ranTime': const DoubleType().toJson(object.ranTime),
      'isGoingOff': const BoolType().toJson(object.isGoingOff),
    };
  }
}

TimerData cloneTimerDataWithChanges(
  TimerData old, {
  DateTime? startTime,
  int? runningState,
  double? hue,
  bool? selected,
  List<int>? digits,
  double? ranTime,
  bool? isGoingOff,
}) {
  return TimerData(
    startTime: startTime ?? old.startTime,
    runningState: runningState ?? old.runningState,
    hue: hue ?? old.hue,
    selected: selected ?? old.selected,
    digits: digits ?? old.digits,
    ranTime: ranTime ?? old.ranTime,
    isGoingOff: isGoingOff ?? old.isGoingOff,
  );
}

typedef ObjID<T> = String;

class MobjRegistry {
  static bool isInitialized = false;
  static late TheDatabase db;

  // an object should always be removed from its previous caching levels when being moved to the next. _loadedMobjs is the final level atop _loading an _preloaded
  static final Map<ObjID, Mobj> _loadedMobjs = {};
  static final Map<ObjID, Future<Mobj>> _loadingMobjs = {};
  static final Map<ObjID, String> _preloadedMobjEncodings = {};

  // remember to await the future to make sure the root objects will be ready before other stuff happens
  // none of these ever deload/they're made root objects, they're essentially leaked here once
  static Future<void> initialize(TheDatabase db) {
    if (isInitialized) {
      throw StateError("PersistedSignalRegistry already initialized");
    }
    isInitialized = true;
    MobjRegistry.db = db;
    // tombstone: we initially tried to use type information to preload every object fully as a Mobj. This wasn't possible, because it would have required dependent types. So we ended up pre-loading generic types as, EG, List<Object?>, which then broke at runtime
    return db.kVs.all().get().then((v) {
      for (final KV kv in v) {
        _preloadedMobjEncodings[kv.id] = kv.value;
      }
    });
  }

  static Mobj<T>? seek<T>(ObjID<T> id) {
    return _loadedMobjs[id] as Mobj<T>?;
  }

  static void unregister(ObjID id) {
    _loadedMobjs.remove(id);
    _loadingMobjs.remove(id);
    _preloadedMobjEncodings.remove(id);
  }
}

/// The Mobj system is a little reactive KV database that uses Signals for reactivity (which are better than streams) and sqlite for persistence.
/// It was made just for this app, because the author couldn't find anything else that would do, and because the author intends to contribute to the development of a much more serious dynamic persistence system soon.

/// Modular Object, but not actually Modular, this is a crappy approximation. Can be subscribed, and is automatically persisted to disk.
class Mobj<T> extends Signal<T?> {
  final ObjID _id;
  ObjID get id => _id;
  final TypeHelp<T> _type;
  int _refCount = 1;
  bool _currentlyReadingFromDb = false;

  Future<void> writeBack() {
    final v = peek();
    if (v != null) {
      return MobjRegistry.db.kVs.insertOnConflictUpdate(
          KV(id: _id, value: jsonEncode(_type.toJson(v))));
    } else {
      MobjRegistry.db.kVs.delete().where((t) => t.id.equals(_id));
      return Future.value();
    }
  }

  Mobj._createAndRegister(
    this._id,
    this._type, {
    T? initial,
    String? debugLabel,
    // on reflection I'm not sure we can support autodispose, because of the refcounting stuff
    bool autoDispose = false,
  }) : super(initial, debugLabel: debugLabel, autoDispose: autoDispose) {
    MobjRegistry._loadedMobjs[_id] = this;
    // a Mobj writes back to db whenever it changes
    subscribe((v) {
      if (_currentlyReadingFromDb) {
        return;
      }
      writeBack();
    });
  }

  factory Mobj.fromEncoding(ObjID id, String encoding, TypeHelp<T> type) {
    final v = type.fromJson(jsonDecode(encoding));
    return Mobj._createAndRegister(id, type,
        initial: v, debugLabel: id, autoDispose: false);
  }

  /// only returns non-null if the mobj has already been loaded from the db
  /// type is needed in case the object is in the _loadedMobjEncodings stage
  static Mobj<T>? seekAlreadyLoaded<T>(ObjID id, TypeHelp<T> type) {
    final pr = MobjRegistry._preloadedMobjEncodings[id];
    if (pr != null) {
      final p = Mobj.fromEncoding(id, pr, type);
      MobjRegistry._preloadedMobjEncodings.remove(id);
      return p;
    } else {
      final lm = MobjRegistry._loadingMobjs[id];
      if (lm != null) {
        throw StateError(
            "Mobj.get(id) should only be called if you're sure the mobj has already finished loading. In this case, id=$id, it's still loading");
      }
      return MobjRegistry._loadedMobjs[id] as Mobj<T>?;
    }
  }

  /// assumes the mobj has already been loaded from the db
  /// type is needed in case the object is in the _loadedMobjEncodings stage
  factory Mobj.getAlreadyLoaded(ObjID id, TypeHelp<T> type) {
    final m = seekAlreadyLoaded(id, type);
    if (m == null) {
      throw StateError(
          "Mobj.get(id) was called for an id that isn't loaded, id=$id");
    }
    return m;
  }

  /// unsafe, *may or may not* overwrite a value that's in the db, but gets you a mobj instantly without a Future, so you may choose to do it when you know the mobj hasn't been created before.
  factory Mobj.clobberCreate(
    ObjID id, {
    required TypeHelp<T> type,
    T Function()? initial,
    String? debugLabel,
    bool autoDispose = false,
  }) {
    // Check if signal already exists
    final existing = Mobj.seekAlreadyLoaded<T>(id, type);
    if (existing != null) {
      if (initial != null) {
        existing.value = initial();
      }
      return existing;
    } else {
      final m = Mobj<T>._createAndRegister(
        id,
        type,
        initial: initial?.call(),
        debugLabel: debugLabel,
        autoDispose: autoDispose,
      );
      m.writeBack();
      return m;
    }
  }

  /// like createIfNotLoaded but delayed because it checks the db
  static Future<Mobj<T>> getOrCreate<T>(ObjID id,
      {required T Function() initial,
      required TypeHelp<T> type,
      String? debugLabel,
      bool autoDispose = false}) async {
    Mobj<T>? s = Mobj.seekAlreadyLoaded(id, type);
    if (s != null) {
      return s;
    } else {
      final pf = MobjRegistry._loadingMobjs[id];
      if (pf != null) {
        return (await pf) as Mobj<T>;
      } else {
        final T iv = initial();
        final valueEncoding = jsonEncode(type.toJson(iv));
        final ret = MobjRegistry.db.kVs
            .insertReturning(KV(id: id, value: valueEncoding),
                onConflict: DoUpdate((old) => KVsCompanion(
                      id: Value(id), // Keep the same id
                      value: Value.absent(), // Don't change the value
                    )))
            .then(
          (v) {
            // [critical] there's an error here, you needed to reparse if there was a conflict
            MobjRegistry._loadingMobjs.remove(id);
            return Mobj._createAndRegister(id, type,
                initial: v.value == valueEncoding
                    ? iv
                    : type.fromJson(jsonDecode(v.value)),
                debugLabel: debugLabel,
                autoDispose: autoDispose);
          },
        );
        MobjRegistry._loadingMobjs[id] = ret;
        return await ret;
      }
    }
  }

  static Future<Mobj<T>> fetch<T>(ObjID id,
      {required TypeHelp<T> type,
      String? debugLabel,
      bool autoDispose = false}) {
    Mobj? s = MobjRegistry.seek(id);
    if (s != null) {
      try {
        return Future.value(s as Mobj<T>);
      } catch (e) {
        return Future.error(e);
      }
    } else {
      return (MobjRegistry.db.kVs.select()..where((t) => t.id.equals(id)))
          .getSingleOrNull()
          .then((s) {
        if (s != null) {
          return Mobj._createAndRegister(id, type,
              initial: type.fromJson(jsonDecode(s.value)),
              debugLabel: debugLabel,
              autoDispose: autoDispose);
        } else {
          throw StateError(
              "requested Mobj $id, no such Mobj resides in the database");
        }
      });
    }
  }

  void addRef() {
    _refCount++;
  }

  void removeRef() {
    _refCount--;
    if (_refCount == 0) {
      // this deletes from the store
      set(null);
      MobjRegistry.unregister(_id);
    }
  }

  // this currently functions as deletion because it removes the original bonus refcount that root objects get for free. This is a slightly janky way to implement this and could eventually be replaced with something that does proper error reporting.
  void deleteRoot() {
    removeRef();
  }

  @override
  void dispose() {
    removeRef();
    super.dispose();
  }
}
