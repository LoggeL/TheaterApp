import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:theater_app/features/games/data/runner_motion_preferences.dart';

const _key = 'stageRunner.sceneryMotion';

class _Preferences implements SharedPreferences {
  _Preferences({this.stored, this.save});

  bool? stored;
  Future<bool> Function(bool value)? save;
  final writes = <bool>[];

  @override
  bool? getBool(String key) {
    expect(key, _key);
    return stored;
  }

  @override
  Future<bool> setBool(String key, bool value) async {
    expect(key, _key);
    writes.add(value);
    final success = await (save?.call(value) ?? Future.value(true));
    if (success) stored = value;
    return success;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the device remembers the choice across screen instances', () async {
    SharedPreferences.setMockInitialValues({});
    final first = RunnerMotionPreferences();
    expect(first.ready, isFalse);
    expect(first.sceneryMotion, isTrue);
    await first.loaded;
    expect(first.ready, isTrue);
    await first.setSceneryMotion(false);
    first.dispose();

    final next = RunnerMotionPreferences();
    await next.loaded;
    expect(next.sceneryMotion, isFalse);
    await next.setSceneryMotion(true);
    expect((await SharedPreferences.getInstance()).getBool(_key), isTrue);
    next.dispose();
  });

  test('a late stored value cannot overwrite a new choice', () async {
    final load = Completer<SharedPreferences>();
    final storage = _Preferences(stored: false);
    final preferences = RunnerMotionPreferences(
      loadPreferences: () => load.future,
    );
    // Even selecting the current default is an explicit choice.
    final save = preferences.setSceneryMotion(true);
    load.complete(storage);
    await preferences.loaded;
    await save;
    expect(preferences.sceneryMotion, isTrue);
    expect(storage.stored, isTrue);
    preferences.dispose();
  });

  test('rapid changes save in order and retain the last choice', () async {
    final firstSave = Completer<bool>();
    final secondSave = Completer<bool>();
    final storage = _Preferences(
      save: (value) => value ? secondSave.future : firstSave.future,
    );
    final preferences = RunnerMotionPreferences(
      loadPreferences: () async => storage,
    );
    await preferences.loaded;
    final first = preferences.setSceneryMotion(false);
    final second = preferences.setSceneryMotion(true);
    expect(preferences.sceneryMotion, isTrue);
    await pumpEventQueue();
    expect(storage.writes, [false]);
    firstSave.complete(true);
    await first;
    await pumpEventQueue();
    expect(storage.writes, [false, true]);
    secondSave.complete(true);
    await second;
    expect(storage.stored, isTrue);
    preferences.dispose();
  });

  test('a reopened screen waits for the pending save', () async {
    final pending = Completer<bool>();
    final storage = _Preferences(stored: true, save: (_) => pending.future);
    final first = RunnerMotionPreferences(loadPreferences: () async => storage);
    await first.loaded;
    final save = first.setSceneryMotion(false);
    first.dispose();
    final next = RunnerMotionPreferences(loadPreferences: () async => storage);
    await pumpEventQueue();
    expect(next.ready, isFalse);
    pending.complete(true);
    await save;
    await next.loaded;
    expect(next.sceneryMotion, isFalse);
    next.dispose();
  });

  test(
    'a failed save is reported without losing the choice or next save',
    () async {
      final storage = _Preferences(stored: true, save: (_) async => false);
      final preferences = RunnerMotionPreferences(
        loadPreferences: () async => storage,
      );
      await preferences.loaded;
      await expectLater(preferences.setSceneryMotion(false), throwsStateError);
      expect(preferences.sceneryMotion, isFalse);
      expect(storage.stored, isTrue);
      storage.save = null;
      await preferences.setSceneryMotion(false);
      expect(storage.stored, isFalse);
      preferences.dispose();
    },
  );

  test('failed loading still becomes ready and saving can retry', () async {
    final storage = _Preferences();
    var loads = 0;
    final preferences = RunnerMotionPreferences(
      loadPreferences: () async {
        if (loads++ == 0) throw StateError('storage unavailable');
        return storage;
      },
    );
    await preferences.loaded;
    expect(preferences.ready, isTrue);
    expect(preferences.sceneryMotion, isTrue);
    await preferences.setSceneryMotion(false);
    expect(storage.stored, isFalse);
    preferences.dispose();
  });

  test(
    'late loading after dispose does not notify or change the choice',
    () async {
      final load = Completer<SharedPreferences>();
      final preferences = RunnerMotionPreferences(
        loadPreferences: () => load.future,
      );
      var notifications = 0;
      preferences.addListener(() => notifications++);
      preferences.dispose();
      load.complete(_Preferences(stored: false));
      await preferences.loaded;
      await preferences.setSceneryMotion(false);
      expect(notifications, 0);
      expect(preferences.sceneryMotion, isTrue);
    },
  );
}
