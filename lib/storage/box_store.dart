import 'package:hive_flutter/hive_flutter.dart';

abstract class BoxStore {
  int get length;
  Iterable<dynamic> get keys;
  dynamic get(dynamic key);
  Future<void> put(dynamic key, dynamic value);
  Future<int> add(dynamic value);
  Future<void> delete(dynamic key);
  Future<void> clear();
}

class HiveBoxStore implements BoxStore {
  final Box _box;
  HiveBoxStore(this._box);

  @override
  int get length => _box.length;

  @override
  Iterable<dynamic> get keys => _box.keys;

  @override
  dynamic get(dynamic key) => _box.get(key);

  @override
  Future<void> put(dynamic key, dynamic value) => _box.put(key, value);

  @override
  Future<int> add(dynamic value) => _box.add(value);

  @override
  Future<void> delete(dynamic key) => _box.delete(key);

  @override
  Future<void> clear() async => _box.clear();
}

class MemoryBoxStore implements BoxStore {
  final Map<dynamic, dynamic> _data = {};
  int _autoKey = 0;

  @override
  int get length => _data.length;

  @override
  Iterable<dynamic> get keys => _data.keys;

  @override
  dynamic get(dynamic key) => _data[key];

  @override
  Future<void> put(dynamic key, dynamic value) async => _data[key] = value;

  @override
  Future<int> add(dynamic value) async {
    final k = _autoKey++;
    _data[k] = value;
    return k;
  }

  @override
  Future<void> delete(dynamic key) async => _data.remove(key);

  @override
  Future<void> clear() async => _data.clear();
}
