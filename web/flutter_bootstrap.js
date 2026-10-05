{{flutter_js}}
{{flutter_build_config}}

// Serve the renderer with the app so the offline cache includes it.
_flutter.loader.load({config: {assetBase: './', canvasKitBaseUrl: 'canvaskit/'}});
