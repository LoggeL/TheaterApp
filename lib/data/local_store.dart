import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/models.dart';

/// Account namespaces include both server origin and user ID.
abstract class LocalStore {
  Future<void> initialize();
  Future<JsonMap?> read(String account, String key);
  Future<void> write(String account, String key, JsonMap value);
  Future<void> remove(String account, String key);
  Future<void> clearAccount(String account);
  Future<void> close();
}

class SqliteLocalStore implements LocalStore {
  Database? _database;
  @override
  Future<void> initialize() async {
    _database ??= await openDatabase(
      p.join(await getDatabasesPath(), 'theater_v1.sqlite'),
      version: 1,
      onCreate: (db, version) => db.execute('''
        CREATE TABLE account_cache (
          account TEXT NOT NULL, cache_key TEXT NOT NULL, value TEXT NOT NULL,
          PRIMARY KEY (account, cache_key)
        )
      '''),
    );
  }

  @override
  Future<JsonMap?> read(String account, String key) async {
    final rows = await _database!.query(
      'account_cache',
      columns: ['value'],
      where: 'account = ? AND cache_key = ?',
      whereArgs: [account, key],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return jsonMap(jsonDecode(rows.single['value'] as String));
  }

  @override
  Future<void> write(String account, String key, JsonMap value) async {
    await _database!.insert('account_cache', {
      'account': account,
      'cache_key': key,
      'value': jsonEncode(value),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  @override
  Future<void> remove(String account, String key) async {
    await _database!.delete(
      'account_cache',
      where: 'account = ? AND cache_key = ?',
      whereArgs: [account, key],
    );
  }

  @override
  Future<void> clearAccount(String account) async {
    await _database!.delete(
      'account_cache',
      where: 'account = ?',
      whereArgs: [account],
    );
  }

  @override
  Future<void> close() async => _database?.close();
}

/// No platform channels: use this store in deterministic offline/session tests.
class MemoryLocalStore implements LocalStore {
  final Map<String, Map<String, JsonMap>> _accounts = {};
  @override
  Future<void> initialize() async {}
  @override
  Future<JsonMap?> read(String account, String key) async {
    final value = _accounts[account]?[key];
    return value == null ? null : cloneJson(value);
  }

  @override
  Future<void> write(String account, String key, JsonMap value) async {
    (_accounts[account] ??= {})[key] = cloneJson(value);
  }

  @override
  Future<void> remove(String account, String key) async =>
      _accounts[account]?.remove(key);
  @override
  Future<void> clearAccount(String account) async => _accounts.remove(account);
  @override
  Future<void> close() async {}
}

abstract class CredentialStore {
  Future<JsonMap?> read();
  Future<void> write(JsonMap value);
  Future<void> clear();
}

class SecureCredentialStore implements CredentialStore {
  SecureCredentialStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();
  final FlutterSecureStorage _storage;
  static const _key = 'theater.mobile.session.v1';
  @override
  Future<JsonMap?> read() async {
    final value = await _storage.read(key: _key);
    return value == null ? null : jsonMap(jsonDecode(value));
  }

  @override
  Future<void> write(JsonMap value) =>
      _storage.write(key: _key, value: jsonEncode(value));
  @override
  Future<void> clear() => _storage.delete(key: _key);
}

class MemoryCredentialStore implements CredentialStore {
  JsonMap? value;
  @override
  Future<JsonMap?> read() async => value == null ? null : cloneJson(value!);
  @override
  Future<void> write(JsonMap next) async => value = cloneJson(next);
  @override
  Future<void> clear() async => value = null;
}

/// Persistent Flutter-web storage. Sessions contain a Firebase UID marker only;
/// Firebase manages its own authentication tokens and refresh lifecycle.
class PreferencesLocalStore implements LocalStore {
  SharedPreferences? _preferences;
  String _prefix(String account) =>
      'theater.cache.${Uri.encodeComponent(account)}.';
  @override
  Future<void> initialize() async =>
      _preferences ??= await SharedPreferences.getInstance();
  @override
  Future<JsonMap?> read(String account, String key) async {
    final value = _preferences!.getString('${_prefix(account)}$key');
    return value == null ? null : jsonMap(jsonDecode(value));
  }

  @override
  Future<void> write(String account, String key, JsonMap value) async {
    if (!await _preferences!.setString(
      '${_prefix(account)}$key',
      jsonEncode(value),
    )) {
      throw StateError('Speichern fehlgeschlagen');
    }
  }

  @override
  Future<void> remove(String account, String key) async =>
      _preferences!.remove('${_prefix(account)}$key');
  @override
  Future<void> clearAccount(String account) async {
    for (final key in _preferences!.getKeys().where(
      (k) => k.startsWith(_prefix(account)),
    )) {
      await _preferences!.remove(key);
    }
  }

  @override
  Future<void> close() async {}
}

class PreferencesCredentialStore implements CredentialStore {
  static const _key = 'theater.session';
  @override
  Future<JsonMap?> read() async {
    final value = (await SharedPreferences.getInstance()).getString(_key);
    return value == null ? null : jsonMap(jsonDecode(value));
  }

  @override
  Future<void> write(JsonMap value) async {
    await (await SharedPreferences.getInstance()).setString(
      _key,
      jsonEncode(value),
    );
  }

  @override
  Future<void> clear() async {
    await (await SharedPreferences.getInstance()).remove(_key);
  }
}
