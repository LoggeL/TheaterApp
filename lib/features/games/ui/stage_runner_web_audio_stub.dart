import 'stage_runner_sound.dart';

/// Only browsers have the Web Audio API; elsewhere [PluginRunnerSound] plays.
WebAudio openWebAudio() =>
    throw UnsupportedError('Web Audio is only available in browsers');
