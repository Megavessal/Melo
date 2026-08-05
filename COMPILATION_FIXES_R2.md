# Melo 2.6.0 compilation fixes — R2

This revision addresses the native Xcode failures reported on August 3, 2026:

- Changed AppEntity metadata/query declarations from mutable static properties to immutable `static let` values for Swift 6 strict-concurrency safety.
- Reworked the Smart Auto EQ preview fixture to initialize `AdaptiveAudioSettings` through its supported zero-argument initializer before assigning preview values.

No runtime audio behavior or saved settings were changed.
