/// Whether the engine's frame time stamps jitter around the display's rate
/// (see `FramePacing`): never outside a browser, where they are the vsync.
bool get frameClockJitters => false;
