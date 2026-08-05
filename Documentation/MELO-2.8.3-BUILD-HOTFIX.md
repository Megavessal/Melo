# Melo 2.8.3 — SwiftUI Composition Hotfix

The build-282 log showed that the previous key-handler extraction was not sufficient. Swift 6 still timed out while type-checking the complete `MenuBarPopupView.body` expression.

Build 283 restructures that view into smaller opaque layers:

- `popupContentLayer`
- `popupAppearanceLayer`
- `popupDeviceObservationLayer`
- `popupApplicationObservationLayer`
- `popupPeripheralObservationLayer`
- `popupWindowObservationLayer`
- `popupKeyboardLayer`

Initialization, device changes, guided-tour state, priority editing, and popup-window notifications now call named methods. Runtime behavior is preserved, but each generic SwiftUI expression is substantially smaller.

The update remains Apple-silicon-only and preserves all Melo 2.8.1 visual/tutorial refinements.
