// Enforce WebRTC framework presence at build time.
#if !canImport(WebRTC)
#error("WebRTC framework is required to build this target. Please add the WebRTC dependency and ensure it links correctly.")
#endif

