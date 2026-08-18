import 'dart:async';
import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:drift/drift.dart';
import 'package:makos_timer/boring.dart';
import 'package:makos_timer/database.dart';
import 'package:signals/signals_flutter.dart';

bool _typeHelpDescriptionDeepEquals(Object a, Object b) {
  if (identical(a, b)) return true;
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_typeHelpDescriptionDeepEquals(a[i] as Object, b[i] as Object)) {
        return false;
      }
    }
    return true;
  }
  return a == b;
}

int _typeHelpDescriptionDeepHash(Object o) {
  if (o is List) {
    return Object.hashAll(
      o.map((e) => _typeHelpDescriptionDeepHash(e as Object)),
    );
  }
  return o.hashCode;
}

/// these are just parser combinators. They used to be self-describing so that we could put type descriptions in the DB and use those to pre-parse any root objects, but it turned out that's impossible in dart (you can't construct a new generic type at runtime, which, since dart has runtime type information, means you also can't construct values of that type), and would only be elegant with dependent types.
/// couldn't be const because of the late final _hashCode cached value
abstract class TypeHelp<T>(final Object typeDescription) {
  late final int _hashCode;

  this {
    _hashCode = _typeHelpDescriptionDeepHash(typeDescription);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is TypeHelp &&
          runtimeType == other.runtimeType &&
          _typeHelpDescriptionDeepEquals(
            typeDescription,
            other.typeDescription,
          ));

  @override
  int get hashCode => _hashCode;

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
  IntType._() : super('int');
  static final IntType _instance = IntType._();
  factory IntType() => _instance;

  @override
  bool operator ==(Object other) => identical(this, other);

  @override
  int get hashCode => identityHashCode(this);

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
  DoubleType._() : super('double');
  static final DoubleType _instance = DoubleType._();
  factory DoubleType() => _instance;

  @override
  bool operator ==(Object other) => identical(this, other);

  @override
  int get hashCode => identityHashCode(this);

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
  BoolType._() : super('bool');
  static final BoolType _instance = BoolType._();
  factory BoolType() => _instance;

  @override
  bool operator ==(Object other) => identical(this, other);

  @override
  int get hashCode => identityHashCode(this);

  @override
  bool fromJsonValue(Object? json) {
    if (json is bool) return json;
    throw ArgumentError('Cannot convert $json to bool');
  }

  @override
  Object? toJsonValue(bool object) => object;
}

class StringType extends TypeHelp<String> {
  StringType._() : super('string');
  static final StringType _instance = StringType._();
  factory StringType() => _instance;

  @override
  bool operator ==(Object other) => identical(this, other);

  @override
  int get hashCode => identityHashCode(this);

  @override
  String fromJsonValue(Object? json) {
    if (json is String) return json;
    throw ArgumentError('Cannot convert null to String');
  }

  @override
  Object? toJsonValue(String object) => object;
}

class Nullable<T>(final TypeHelp<T> innerType) extends TypeHelp<T?> {
  this : super(['nullable', innerType.typeDescription]);

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

class ListType<T>(final TypeHelp<T> itemConverter) extends TypeHelp<List<T>> {
  this : super(['list', itemConverter.typeDescription]);

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

class MapType<K, V>(final TypeHelp<K> keyConverter, final TypeHelp<V> valueConverter)
    extends TypeHelp<Map<K, V>> {
  this
      : super([
          'map',
          keyConverter.typeDescription,
          valueConverter.typeDescription,
        ]);

  @override
  Map<K, V> fromJsonValue(Object? json) {
    if (json is Map<String, dynamic>) {
      return json.map(
        (key, value) => MapEntry(
          keyConverter.fromJson(key),
          valueConverter.fromJson(value),
        ),
      );
    }
    throw ArgumentError('Cannot convert $json to Map');
  }

  @override
  Object? toJsonValue(Map<K, V> object) {
    return object.map(
      (key, value) =>
          MapEntry(keyConverter.toJson(key), valueConverter.toJson(value)),
    );
  }
}

class DateTimeType extends TypeHelp<DateTime> {
  DateTimeType._() : super('datetime');
  static final DateTimeType _instance = DateTimeType._();
  factory DateTimeType() => _instance;

  @override
  bool operator ==(Object other) => identical(this, other);

  @override
  int get hashCode => identityHashCode(this);

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
  static final Map<MobjID, Mobj> loadedMobjs = {};
  static final Map<MobjID, Future<Mobj>> _loadingMobjs = {};
  static final Map<MobjID, String> _preloadedMobjEncodings = {};
  static final Map<TypeHelp, List<QuerySet>> _querySets = {};

  // remember to await the future to make sure the root objects will be ready before other stuff happens
  // none of these ever deload/they're made root objects, they're essentially leaked here once
  static Future<void> initialize(TheDatabase db, {bool preload = true}) {
    if (isInitialized) {
      throw StateError("PersistedSignalRegistry already initialized");
    }
    isInitialized = true;
    MobjRegistry.db = db;
    // tombstone: we initially tried to use type information to preload every object fully as a Mobj. This wasn't possible, because it would have required dependent types. So we ended up pre-loading generic types as, EG, List<Object?>, which then broke at runtime
    if (preload) {
      return reloadPreload();
    } else {
      return Future.value();
    }
  }

  static Mobj<T>? seek<T>(MobjID<T> id, TypeHelp<T> type) {
    return Mobj.seekAlreadyLoaded(id, type);
  }

  static Future<void> reloadPreload() {
    return db.fetchActive().get().then((v) {
      for (final kv in v) {
        _preloadedMobjEncodings[kv.id] = kv.value;
      }
    });
  }

  static void unregister(MobjID id) {
    loadedMobjs.remove(id);
    _loadingMobjs.remove(id);
    _preloadedMobjEncodings.remove(id);
  }

  static QuerySet<T> createQuerySet<T>(
    TypeHelp<T> type, {
    bool Function(T)? predicate,
  }) {
    predicate = predicate ?? alwaysTrue;
    final qs = QuerySet<T>(type, predicate);
    multimapAdd(_querySets, type, qs);
    // if you create any querysets, we have to attempt to parse all preloaded mobjs against it, we can't just select the ones with the right type
    for (final e in _preloadedMobjEncodings.entries.toList()) {
      Mobj<T>? mobj;
      // wait, conceptual problem, I don't think anything actually has its type stored?.. so duck types would trip this up?
      try {
        // Only create and add if decode successful
        mobj = Mobj.seekAlreadyLoaded<T>(e.key, type)!;
      } on MobjTypeMismatchError catch (_) {
        // type mismatches are expected here.
      }
      if (mobj != null) {
        loadedMobjs[e.key] = mobj;
        _preloadedMobjEncodings.remove(e.key);
        final val = mobj.peek();
        if (val != null && predicate(val)) {
          qs.add(mobj);
        }
      }
    }
    // also check already-loaded Mobj instances (e.g. fetched before this QuerySet existed)
    for (final mobj in loadedMobjs.values.toList()) {
      if (mobj._type == type) {
        final val = (mobj as Mobj<T>).peek();
        if (val != null && predicate(val)) {
          qs.add(mobj);
        }
      }
    }
    return qs;
  }

  static Mobj<T>? seekTyped<T>(MobjID id, TypeHelp<T> type) {
    Mobj<T>? mobj;
    try {
      mobj = Mobj.seekAlreadyLoaded<T>(id, type);
    } on MobjTypeMismatchError catch (_) {
      // type mismatches are expected here.
    }
    return mobj;
  }

  static Mobj? seekTypeds(MobjID id, List<TypeHelp> types) {
    for (final type in types) {
      final mobj = seekTyped(id, type);
      if (mobj != null) {
        return mobj;
      }
    }
    return null;
  }

  // deletes all Mobjs regardless of refCount. Sometimes necessary because it's really important that the background thread completely forgets all cached values for its mobjs after handing control back to the app thread, and because we haven't really encountered a practical need for refCounts so aren't using them.
  static void relinquishAll() {
    for (final mobj in loadedMobjs.values) {
      mobj.dispose();
    }
    loadedMobjs.clear();
    for (final mobj in _loadingMobjs.values) {
      mobj.then((m) {
        m.dispose();
      });
    }
    _loadingMobjs.clear();
    _preloadedMobjEncodings.clear();
  }
}

class QueryTrack<T>(final Mobj<T> m, final Function() unsubscribe);

bool alwaysTrue(dynamic v) {
  return true;
}

class QuerySet<T>(final TypeHelp<T> requiredType, [final bool Function(T) predicate = alwaysTrue]) {
  final Map<MobjID, QueryTrack<T>> inSet = {};
  late final StreamController<Mobj<T>> _onAdded =
      StreamController<Mobj<T>>.broadcast();
  Stream<Mobj<T>> get onAdded => _onAdded.stream;
  late final StreamController<Mobj<T>> _onRemoved =
      StreamController<Mobj<T>>.broadcast();
  Stream<Mobj<T>> get onRemoved => _onRemoved.stream;

  void add(Mobj<T> mobj) {
    if (!inSet.containsKey(mobj.id)) {
      inSet[mobj.id] = QueryTrack(
        mobj,
        mobj.subscribe((v) {
          if (v == null || !predicate(v)) {
            remove(mobj);
          }
        }),
      );
      _onAdded.add(mobj);
    }
  }

  void remove(Mobj<T> mobj) {
    final qt = inSet.remove(mobj.id);
    if (qt != null) {
      qt.unsubscribe();
      _onRemoved.add(mobj);
    }
  }

  StreamSubscription<Mobj<T>> forAll(Function(Mobj<T>) callback) {
    for (final mobj in inSet.values) {
      callback(mobj.m);
    }
    return onAdded.listen(callback);
  }

  void dispose() {
    MobjRegistry._querySets[requiredType]?.remove(this);
    for (final qt in inSet.values) {
      qt.unsubscribe();
    }
    inSet.clear();
    _onAdded.close();
    _onRemoved.close();
  }
}

class MobjTypeMismatchError(final String message) extends Error;

/// Modular Object, but not actually belonging to the Modular Web protocol, this is a crappy approximation. Can be subscribed, and is automatically persisted to disk.
/// The Mobj system is a little reactive KV database that uses Signals for reactivity (which are better than streams) and sqlite for persistence.
/// Reactivity is purely in-memory via Signals; changes write through to the DB but the DB doesn't push changes back. Single-isolate only.
/// Doesn't support transactions right now, though note that both Signal and Drift do support transactions, so it should be possible?
/// Setting it to null causes a deletion. After deletion, undeletion isn't permitted.
class Mobj<T> extends Signal<T?> {
  final MobjID _id;

  MobjID get id => _id;
  final TypeHelp<T> _type;
  TypeHelp<T> get type => _type;
  // currently not really used [todo] stop leaking into the db maybe (but don't worry about leaking signals into memory..)
  int _refCount = 1;
  bool _isActive;

  /// whether the mobj is preloaded on MobjRegistry initialization.
  bool get isActive => _isActive;
  set isActive(bool value) {
    if (value == _isActive) return;
    _isActive = value;
    writeBack();
  }

  DateTime _lastTimestamp = DateTime.fromMillisecondsSinceEpoch(0);

  /// the timestamp of this Mobj's most recent write-back. For binned (deleted)
  /// timers this doubles as the time of deletion, since they aren't written to
  /// again while shelved — see the trash bin pruning logic.
  DateTime get lastTimestamp => _lastTimestamp;
  int _lastSequenceNumber = 0;
  String _valueEncoded = "";
  late final Function() _systemSubscription;
  bool _blockInitialWriteBack = false;

  /// only actually writes back if the new value has a newer timestamp than the value in the db, this is important for situations where more than one process is doing writes and we want to make sure they all end up agreeing.
  Future<void> writeBack() async {
    final v = peek();
    if (v != null) {
      _valueEncoded = Mobj.serialize(v, _type);
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
        id: _id,
        timestamp: _lastTimestamp,
        sequenceNumber: _lastSequenceNumber,
        value: _valueEncoded,
        isActive: _isActive,
      );
    } else {
      (MobjRegistry.db.kVs.delete()..where((t) => t.id.equals(_id))).go();
      _systemSubscription();
      return Future.value();
    }
  }

  static String serialize<T>(T v, TypeHelp<T> type) =>
      jsonEncode({'type': type.typeDescription, 'value': type.toJson(v)});
  static T deserialize<T>(String s, TypeHelp<T> type) {
    var dec = jsonDecode(s);
    if (!const DeepCollectionEquality().equals(
      dec['type'],
      type.typeDescription,
    )) {
      throw MobjTypeMismatchError(
        'Mobj.deserialize: type mismatch, expected ${type.typeDescription} but got ${dec['type']}',
      );
    }
    return type.fromJson(dec['value']);
  }

  /// every new mobj is created this way
  Mobj._createAndRegister(
    this._id,
    this._type, {
    T? initial,
    String? debugLabel,
    DateTime? timestamp,
    int? sequenceNumber,
    bool? isActive,
    required bool initialWriteBack,
    // on reflection I'm not sure we can support autodispose, because of the refcounting stuff
    // bool autoDispose = false,
  }) : _isActive = isActive ?? true,
       super(
         initial,
         options: SignalOptions(name: debugLabel, autoDispose: false),
       ) {
    if (T == dynamic) {
      throw StateError(
        "dynamic mobj type. It's very unlikely that this is what you intended, we're not sure how it could be. In most cases, this is an accident that will prevent you from being able to cast your Mobjs to the actual intended type.",
      );
    }
    MobjRegistry.loadedMobjs[_id] = this;
    MobjRegistry._preloadedMobjEncodings.remove(_id);
    _blockInitialWriteBack = !initialWriteBack;

    if (timestamp != null) {
      _lastTimestamp = timestamp;
    }
    if (sequenceNumber != null) {
      _lastSequenceNumber = sequenceNumber;
    }

    // why do this in a subscription instead of in the value setter?
    _systemSubscription = subscribe((v) {
      // update query sets
      for (QuerySet qs in MobjRegistry._querySets[_type] ?? []) {
        if (qs.predicate(v)) {
          qs.add(this);
        } else {
          qs.remove(this);
        }
      }
      // a Mobj writes back to db whenever it changes
      if (_blockInitialWriteBack) {
        _blockInitialWriteBack = false;
      } else {
        writeBack();
      }
    });
  }

  static Mobj? seekTypedsAlreadyLoaded(MobjID id, List<TypeHelp> types) {
    return MobjRegistry.seekTypeds(id, types);
  }

  static Mobj<T>? seekTypedAlreadyLoaded<T>(MobjID id, TypeHelp<T> type) {
    return MobjRegistry.seekTyped(id, type);
  }

  /// only returns non-null if the mobj has already been loaded from the db
  /// type is needed in case the object is in the _loadedMobjEncodings stage
  static Mobj<T>? seekAlreadyLoaded<T>(MobjID id, TypeHelp<T> type) {
    final Mobj? loaded = MobjRegistry.loadedMobjs[id];
    if (loaded != null) {
      if (loaded.type != type) {
        throw MobjTypeMismatchError(
          'Mobj.seekAlreadyLoaded: type mismatch, expected ${type.typeDescription} but got ${loaded.type.typeDescription}',
        );
      }
      return loaded as Mobj<T>;
    }
    final pr = MobjRegistry._preloadedMobjEncodings[id];
    if (pr != null) {
      final p = Mobj<T>._createAndRegister(
        id,
        type,
        initial: Mobj.deserialize(pr, type),
        debugLabel: id,
        initialWriteBack: false,
      );
      MobjRegistry._preloadedMobjEncodings.remove(id);
      return p;
    }
    return null;
  }

  /// assumes the mobj has already been loaded from the db
  /// type is needed in case the object is in the _loadedMobjEncodings stage
  factory Mobj.getAlreadyLoaded(MobjID id, TypeHelp<T> type) {
    final m = seekAlreadyLoaded(id, type);
    if (m == null) {
      throw StateError(
        "Mobj.get(id) was called for an id that isn't loaded, id=$id",
      );
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
    final existing = Mobj.write(id, initial, type, isActive: true);
    if (existing != null) return existing;
    // The value is already in the db, so the new mobj doesn't write it again —
    // it takes over the stamp that write just used, so that its next write
    // back is recognisably more recent than what's sitting there even if it
    // lands in the same millisecond.
    final stamp = _writeStamps[id];
    return Mobj<T>._createAndRegister(
      id,
      type,
      initial: initial,
      debugLabel: debugLabel,
      initialWriteBack: false,
      timestamp: stamp?.$1,
      sequenceNumber: stamp?.$2,
    );
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
    }
    final pf = MobjRegistry._loadingMobjs[id];
    if (pf != null) {
      return (await pf) as Mobj<T>;
    }
    final T iv = initial();
    final valueEncoding = Mobj.serialize(iv, type);
    final ret = MobjRegistry.db
        .insertIfNotExistsAndReturn(
          id: id,
          value: valueEncoding,
          timestamp: DateTime.now(),
          sequenceNumber: 0,
          isActive: true,
        )
        .then((v) {
          MobjRegistry._loadingMobjs.remove(id);
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
              initial: Mobj.deserialize(vv.value!, type),
              debugLabel: debugLabel,
              initialWriteBack: false,
              isActive: vv.isActive!,
              timestamp: vv.timestamp!,
              sequenceNumber: vv.sequenceNumber!,
            );
          }
        });
    MobjRegistry._loadingMobjs[id] = ret;
    return ret;
  }

  /// the timestamps [write] has stamped this session, so that two writes
  /// landing in the same millisecond don't have the second one dropped for
  /// being no more recent than the first
  static final Map<MobjID, (DateTime, int)> _writeStamps = {};

  /// Writes a value to the db under [id], and returns the Mobj it went
  /// through, if there was one.
  ///
  /// If [id] is already loaded, this is that Mobj being set: it writes itself
  /// back, everything subscribed to it hears about the change, and it's what
  /// comes back from here. If it isn't loaded, the row is written directly and
  /// null comes back — a value that mutates in place has nothing for a signal
  /// to notify anyone about, so there's no reason to mint one just to write.
  /// The counterpart is [read].
  ///
  /// [isActive] only applies to rows written directly; a loaded Mobj carries
  /// its own. Directly written rows default to inactive: nothing preloads
  /// them at startup, so whatever wants one asks for it when it wants it.
  static Mobj<T>? write<T>(
    MobjID id,
    T value,
    TypeHelp<T> type, {
    bool isActive = false,
  }) {
    // deliberately not seekAlreadyLoaded: a preloaded encoding is a value
    // that's about to be replaced, and parsing it (or failing to) on the way
    // to overwriting it would be work at best and a thrown error at worst
    final loaded = MobjRegistry.loadedMobjs[id];
    if (loaded != null) {
      if (loaded.type != type) {
        throw MobjTypeMismatchError(
          'Mobj.write: type mismatch, expected ${type.typeDescription} but got ${loaded.type.typeDescription}',
        );
      }
      // forced, since the value may be the same instance it was, mutated
      (loaded as Mobj<T>).set(value, force: true);
      return loaded;
    }
    final encoded = Mobj.serialize(value, type);
    // whatever was preloaded under this id is now stale, and leaving it there
    // would have the next seek materialize the old value
    if (MobjRegistry._preloadedMobjEncodings.containsKey(id)) {
      MobjRegistry._preloadedMobjEncodings[id] = encoded;
    }
    final previous = _writeStamps[id];
    var timestamp = DateTime.now();
    var sequenceNumber = 0;
    if (previous != null && !timestamp.isAfter(previous.$1)) {
      timestamp = previous.$1;
      sequenceNumber = previous.$2 + 1;
    }
    _writeStamps[id] = (timestamp, sequenceNumber);
    MobjRegistry.db.insertIfMoreRecent(
      id: id,
      timestamp: timestamp,
      sequenceNumber: sequenceNumber,
      value: encoded,
      isActive: isActive,
    );
    return null;
  }

  /// Reads back what [write] wrote (or what a Mobj of the same type left
  /// there), without creating or loading a Mobj. Null if there's no such row;
  /// throws [MobjTypeMismatchError] if there is one and it's something else.
  static Future<T?> read<T>(MobjID id, TypeHelp<T> type) async {
    final kv =
        await (MobjRegistry.db.kVs.select()..where((t) => t.id.equals(id)))
            .getSingleOrNull();
    if (kv == null) return null;
    return Mobj.deserialize(kv.value, type);
  }

  /// Reads the current value from the database without creating or loading a Mobj
  static Future<T> readCurrentValue<T>(
    MobjID id, {
    required TypeHelp<T> type,
  }) async {
    final v = await read(id, type);
    if (v == null) {
      throw StateError("Mobj $id does not exist in the database");
    }
    return v;
  }

  /// (can't be called "get" because Signal already has a method of that name)
  static Future<Mobj<T>> fetch<T>(
    MobjID id, {
    required TypeHelp<T> type,
    String? debugLabel,
  }) async {
    Mobj<T>? s = Mobj.seekAlreadyLoaded<T>(id, type);
    if (s != null) {
      return s;
    } else {
      final Future<Mobj<T>> r =
          (MobjRegistry.db.kVs.select()..where((t) => t.id.equals(id)))
              .getSingleOrNull()
              .then((s) {
                if (s != null) {
                  MobjRegistry._loadingMobjs.remove(id);
                  return Mobj<T>._createAndRegister(
                    id,
                    type,
                    initial: Mobj.deserialize(s.value, type),
                    debugLabel: debugLabel,
                    initialWriteBack: false,
                  );
                } else {
                  // hmm why not just initialize as null
                  throw StateError(
                    "requested Mobj $id, no such Mobj resides in the database",
                  );
                }
              });
      MobjRegistry._loadingMobjs[id] = r;
      return r;
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
}
