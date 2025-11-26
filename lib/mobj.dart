import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:makos_timer/database.dart';
import 'package:signals/signals_flutter.dart';

/// these are just parser combinators. They used to be self-describing so that we could put type descriptions in the DB and use those to pre-parse any root objects, but it turned out that's impossible in dart (you can't construct a new generic type at runtime, which, since dart has runtime type information, means you also can't construct values of that type), and would only be elegant with dependent types.
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

typedef MobjID<T> = String;

class MobjRegistry {
  static bool isInitialized = false;
  static late TheDatabase db;

  // an object should always be removed from its previous caching levels when being moved to the next. _loadedMobjs is the final level atop _loading an _preloaded
  static final Map<MobjID, Mobj> _loadedMobjs = {};
  static final Map<MobjID, Future<Mobj>> _loadingMobjs = {};
  static final Map<MobjID, String> _preloadedMobjEncodings = {};

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

  static Mobj<T>? seek<T>(MobjID<T> id) {
    return _loadedMobjs[id] as Mobj<T>?;
  }

  static void unregister(MobjID id) {
    _loadedMobjs.remove(id);
    _loadingMobjs.remove(id);
    _preloadedMobjEncodings.remove(id);
  }
}

/// Modular Object, but not actually belonging to the Modular Web protocol, this is a crappy approximation. Can be subscribed, and is automatically persisted to disk.
/// The Mobj system is a little reactive KV database that uses Signals for reactivity (which are better than streams) and sqlite for persistence.
/// It was made just for this app, because the author couldn't find anything else that would do, and because the author intends to contribute to the development of a much more serious dynamic persistence system soon, so they need to get interested in making their own.
/// This is currently quite bad, for a couple of reasons, but mainly because drift's streaming queries will update whenever any of their values update. This will presumably be a performance problem if you have a lot of active mobjs. It wont come through in the behavior of the mobjs (we don't notify on redundant updates) though.
/// Doesn't support transactions right now, though note that both Signal and Drift do support transactions, so it should be possible?
/// streaming_shared_preferences seems to be the same as this, but using shared_preferences for storage instead of drift.
/// I think I need this to work across isolates now.
/// setting it to null causes a deletion. After deletion, undeletion isn't permitted.
class Mobj<T> extends Signal<T?> {
  final MobjID _id;

  MobjID get id => _id;
  final TypeHelp<T> _type;
  int _refCount = 1;
  DateTime _lastTimestamp = DateTime.fromMillisecondsSinceEpoch(0);
  int _lastSequenceNumber = 0;
  String _valueEncoded = "";
  StreamSubscription<KV?>? _dbSubscription;
  // prevents updates from the db from triggering a write back to the db
  bool _currentlyTakingFromDb = false;
  bool _blockInitialWriteBack = false;
  bool _unloaded = true;

  /// only actually writes back if the new value has a newer timestamp than the value in the db, this is important for situations where more than one process is doing writes and we want to make sure they all end up agreeing.
  Future<void> writeBack() async {
    final v = peek();
    print(
        "writeBack: id=${_id}, value=${v}, _valueEncoded=${_valueEncoded}, _lastTimestamp=${_lastTimestamp}, _lastSequenceNumber=${_lastSequenceNumber}");
    if (v != null) {
      _valueEncoded = jsonEncode(_type.toJson(v));
      final nextTimestamp = DateTime.now();
      if (nextTimestamp.isAtSameMomentAs(_lastTimestamp)) {
        _lastSequenceNumber++;
      } else {
        // we don't really have to reset, but we may as well.
        _lastSequenceNumber = 0;
      }
      _lastTimestamp = nextTimestamp;
      // compares with the current previous value lexicographically before finalizing the insert
      await MobjRegistry.db.insertIfMoreRecent(
        _id,
        _valueEncoded,
        _lastTimestamp,
        _lastSequenceNumber,
      );
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
    DateTime? timestamp,
    int? sequenceNumber,
    required bool initialWriteBack,
    // on reflection I'm not sure we can support autodispose, because of the refcounting stuff
    // bool autoDispose = false,
  }) : super(initial, debugLabel: debugLabel, autoDispose: false) {
    MobjRegistry._loadedMobjs[_id] = this;
    _blockInitialWriteBack = !initialWriteBack;
    if (initial != null) {
      _unloaded = false;
    }

    if (timestamp != null) {
      _lastTimestamp = timestamp;
    }
    if (sequenceNumber != null) {
      _lastSequenceNumber = sequenceNumber;
    }

    // a Mobj writes back to db whenever it changes
    subscribe((v) {
      if (_currentlyTakingFromDb) {
        return;
      }
      if (_blockInitialWriteBack) {
        _blockInitialWriteBack = false;
        return;
      }
      writeBack();
    });

    // Stream database changes for this id
    _dbSubscription = (MobjRegistry.db.kVs.select()
          ..where((t) => t.id.equals(_id)))
        .watchSingleOrNull()
        .listen((kv) {
      if (kv == null) {
        // Entry was deleted from DB
        if (internalValue != null) {
          _currentlyTakingFromDb = true;
          set(null);
          _currentlyTakingFromDb = false;
        }
      } else {
        print(
            "readBack: id=${_id}, kv.timestamp=${kv.timestamp}, _lastTimestamp=${_lastTimestamp}, kv.sequenceNumber=${kv.sequenceNumber}, _lastSequenceNumber=${_lastSequenceNumber}, kv.value=${kv.value}, _valueEncoded=${_valueEncoded}");
        if (kv.timestamp.isAfter(_lastTimestamp) ||
            (kv.timestamp.isAtSameMomentAs(_lastTimestamp) &&
                kv.sequenceNumber > _lastSequenceNumber) ||
            (kv.timestamp.isAtSameMomentAs(_lastTimestamp) &&
                kv.sequenceNumber == _lastSequenceNumber &&
                kv.value.compareTo(_valueEncoded) > 0)) {
          // DB has newer data, update local value
          _currentlyTakingFromDb = true;
          _lastTimestamp = kv.timestamp;
          _lastSequenceNumber = kv.sequenceNumber;
          set(_type.fromJson(jsonDecode(kv.value)));
          _currentlyTakingFromDb = false;
        }
      }
    });
  }

  /// only returns non-null if the mobj has already been loaded from the db
  /// type is needed in case the object is in the _loadedMobjEncodings stage
  static Mobj<T>? seekAlreadyLoaded<T>(MobjID id, TypeHelp<T> type) {
    final pr = MobjRegistry._preloadedMobjEncodings[id];
    if (pr != null) {
      final p = Mobj._createAndRegister(id, type,
          initial: type.fromJson(jsonDecode(pr)),
          debugLabel: id,
          initialWriteBack: false);
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
  factory Mobj.getAlreadyLoaded(MobjID id, TypeHelp<T> type) {
    final m = seekAlreadyLoaded(id, type);
    if (m == null) {
      throw StateError(
          "Mobj.get(id) was called for an id that isn't loaded, id=$id");
    }
    return m;
  }

  /// unsafe, may overwrite a value that's in the db, but gets you a mobj instantly without an async delay, so you may choose to do it when you know the mobj hasn't been created before and you want it right away
  factory Mobj.clobberCreate(
    MobjID id, {
    required TypeHelp<T> type,
    required T initial,
    String? debugLabel,
  }) {
    // Check if signal already exists
    final existing = Mobj.seekAlreadyLoaded<T>(id, type);
    if (existing != null) {
      existing.value = initial;
      return existing;
    } else {
      final m = Mobj<T>._createAndRegister(
        id,
        type,
        initial: initial,
        debugLabel: debugLabel,
        initialWriteBack: true,
      );
      m.writeBack();
      return m;
    }
  }

  /// like createIfNotLoaded but delayed because it checks the db
  static Future<Mobj<T>> getOrCreate<T>(
    MobjID id, {
    required T Function() initial,
    required TypeHelp<T> type,
    String? debugLabel,
  }) async {
    Mobj<T>? s = Mobj.seekAlreadyLoaded(id, type);
    if (s != null) {
      return s;
    } else {
      // I think this implementation is kinda nonsense, this never could have done what you'd wanted
      final pf = MobjRegistry._loadingMobjs[id];
      if (pf != null) {
        return (await pf) as Mobj<T>;
      } else {
        final T iv = initial();
        final valueEncoding = jsonEncode(type.toJson(iv));
        final ret = MobjRegistry.db
            .insertIfNotExistsAndReturn(id, valueEncoding, DateTime.now(), 0)
            .then(
          (v) {
            MobjRegistry._loadingMobjs.remove(id);
            print(v);
            assert(v.length == 1);
            final vv = v.first;
            if (vv.wasInserted == 0) {
              return Mobj._createAndRegister(
                id,
                type,
                initial: iv,
                debugLabel: debugLabel,
                initialWriteBack: true,
              );
            } else {
              return Mobj._createAndRegister(
                id,
                type,
                initial: type.fromJson(jsonDecode(vv.value!)),
                debugLabel: debugLabel,
                initialWriteBack: false,
                timestamp: vv.timestamp!,
                sequenceNumber: vv.sequenceNumber!,
              );
            }
          },
        );
        MobjRegistry._loadingMobjs[id] = ret;
        return await ret;
      }
    }
  }

  /// Reads the current value from the database without creating or loading a Mobj
  static Future<T> readCurrentValue<T>(
    MobjID id, {
    required TypeHelp<T> type,
  }) async {
    final kv = await (MobjRegistry.db.kVs.select()
          ..where((t) => t.id.equals(id)))
        .getSingleOrNull();

    if (kv == null) {
      throw StateError("Mobj $id does not exist in the database");
    }

    return type.fromJson(jsonDecode(kv.value));
  }

  /// (can't be called "get" because Signal already has a method of that name)
  static Future<Mobj<T>> fetch<T>(
    MobjID id, {
    required TypeHelp<T> type,
    String? debugLabel,
  }) async {
    Mobj? s = MobjRegistry.seek(id);
    if (s != null) {
      return s as Mobj<T>;
    } else {
      return (MobjRegistry.db.kVs.select()..where((t) => t.id.equals(id)))
          .getSingleOrNull()
          .then((s) {
        if (s != null) {
          return Mobj._createAndRegister(
            id,
            type,
            initial: type.fromJson(jsonDecode(s.value)),
            debugLabel: debugLabel,
            initialWriteBack: false,
          );
        } else {
          // hmm why not just initialize as null
          throw StateError(
              "requested Mobj $id, no such Mobj resides in the database");
        }
      });
    }
  }

  void addRef() {
    _refCount++;
  }

  // ah, problem, there's no way to remove from the store without deleting from the db. That also means there's no way to clean up the callbacks?..
  void removeRef() {
    _refCount--;
    if (_refCount == 0) {
      // this deletes from the store
      set(null);
      MobjRegistry.unregister(_id);
    }
  }

  /// this currently functions as deletion because it removes the original bonus refcount that root objects get for free. This is a slightly janky way to implement this and could eventually be replaced with something that does proper error reporting.
  void deleteRoot() {
    removeRef();
  }

  @override
  void dispose() {
    _dbSubscription?.cancel();
    _dbSubscription = null;
    super.dispose();
  }
}
