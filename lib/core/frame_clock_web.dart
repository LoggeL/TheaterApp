import 'dart:js_interop';

@JS('navigator.vendor')
external JSString? get _vendor;

@JS('location.search')
external JSString? get _query;

/// Whether the engine's frame time stamps jitter around the display's rate
/// (see `FramePacing`): in WebKit, which stamps a frame with the moment the
/// main thread got to it, rounded to a millisecond. That is Safari and every
/// browser on iOS and iPadOS (all of them name Apple as their vendor);
/// Chromium and Firefox stamp frames with their vsync.
///
/// `?pace=off` in the address leaves the stamps as they are, to compare both
/// on one device.
bool get frameClockJitters =>
    _vendor?.toDart == 'Apple Computer, Inc.' &&
    !(_query?.toDart ?? '').contains('pace=off');
