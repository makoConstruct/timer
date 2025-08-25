import 'package:makos_timer/boring.dart';

import 'main.dart';

/// this is extended type information that's used to convert to and from json in the database, as well as to encode the type information.
/// type description has to be taken from the top level TypeHelp rather than from each individual object (heterogenously) because we want the top level dart runtime types to be correct too
/// TypeHelp type descriptions are stored with the values in the db to allow fully pre-parsing the objects up front

abstract class TypeHelp<T> {
  final Object typeDescription;

  const TypeHelp(this.typeDescription);

  T fromJson(Object? json) {
    if (json is Map<String, dynamic>) {
      final type = json['type'];
      final value = json['value'];
      if (type == typeDescription) {
        return fromJsonValue(value);
      }
      throw ArgumentError(
          'Type mismatch: expected $typeDescription, got $type');
    }
    throw ArgumentError('Expected JSON object with type and value fields');
  }

  Object? toJson(T object) {
    return {
      'type': typeDescription,
      'value': toJsonValue(object),
    };
  }

  T fromJsonValue(Object? json);
  Object? toJsonValue(T object);
}

class TypeRegistry {
  static final Map<String, TypeHelp> _registry = {};

  static void _initializeRegistry() {
    if (_registry.isNotEmpty) return;

    // Register primitive types
    const intConverter = IntType();
    const doubleConverter = DoubleType();
    const boolConverter = BoolType();
    const stringConverter = StringType();
    const dateTimeConverter = DateTimeType();
    const timerDataConverter = TimerDataType();

    _registry[intConverter.typeDescription as String] = intConverter;
    _registry[doubleConverter.typeDescription as String] = doubleConverter;
    _registry[boolConverter.typeDescription as String] = boolConverter;
    _registry[stringConverter.typeDescription as String] = stringConverter;
    _registry[dateTimeConverter.typeDescription as String] = dateTimeConverter;
    _registry[timerDataConverter.typeDescription as String] =
        timerDataConverter;
  }

  static TypeHelp<T> getTypeHelp<T>(Object typeDescription) {
    _initializeRegistry();

    TypeHelp<T> typeCheck(TypeHelp v) => v is TypeHelp<T>
        ? v
        : throw ArgumentError("typeDescription doesn't match type T");

    // Handle primitive types
    if (_registry.containsKey(typeDescription)) {
      return typeCheck(_registry[typeDescription]!);
    }

    // Handle complex types (lists)
    if (typeDescription is List && typeDescription.isNotEmpty) {
      final typeConstructor = typeDescription[0];

      switch (typeConstructor) {
        case 'nullable':
          if (typeDescription.length == 2) {
            final innerTypeHelp = getTypeHelp(typeDescription[1]);
            return typeCheck(Nullable(innerTypeHelp));
          } else {
            throw ArgumentError("nullable type should have one parameter");
          }

        case 'list':
          if (typeDescription.length == 2) {
            final elementTypeHelp = getTypeHelp(typeDescription[1]);
            return typeCheck(ListType(elementTypeHelp));
          } else {
            throw ArgumentError("list type should have one parameter");
          }

        case 'map':
          if (typeDescription.length == 3) {
            final keyTypeHelp = getTypeHelp(typeDescription[1]);
            final valueTypeHelp = getTypeHelp(typeDescription[2]);
            return typeCheck(MapType(keyTypeHelp, valueTypeHelp));
          } else {
            throw ArgumentError("map type should have two parameters");
          }
        case _:
          throw ArgumentError(
              "unknown term in type constructor \"$typeConstructor\"");
      }
    }

    throw ArgumentError("wasn't able to resolve type $typeDescription");
  }

  static void registerCustomType(Object typeDescription, TypeHelp typeHelp) {
    _initializeRegistry();
    String ds = typeDescription is String
        ? typeDescription
        : throw ArgumentError(
            "complex types can't be registered, TypeHelp is a dirt go level typesystem");
    _registry[ds] = typeHelp;
  }
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
    if (json is String) {
      if (json.toLowerCase() == 'true') return true;
      if (json.toLowerCase() == 'false') return false;
    }
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
    if (json != null) return json.toString();
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
    throw ArgumentError('Cannot convert $json to List<$T>');
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
    throw ArgumentError('Cannot convert $json to Map<$K, $V>');
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
  Object? toJsonValue(DateTime object) => object.toIso8601String();
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
        digits: ListType(IntType()).fromJson(json['digits']),
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
      'digits': ListType(IntType()).toJson(object.digits),
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
