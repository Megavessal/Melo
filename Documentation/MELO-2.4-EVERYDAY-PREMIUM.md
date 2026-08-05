# Melo 2.4 — Everyday Premium design

Melo 2.4 does not replace the advanced audio engine. It adds a simpler layer
that lets a normal Mac user benefit from it without understanding routing,
process taps, Audio Units, sample rates, latency, or loudness terminology.

## Consumer features

### Scenes

A Scene saves the complete current setup: app volume and mute state, boost,
routing, multi-output choices, EQ, balance, default and system-sound outputs,
device volume/mute, AutoEQ, Smart Sound settings, privacy processing, and Audio
Unit effect chains. Scene cards use familiar names and one clear “Use This
Scene” action.

### Automations

The editor offers only three triggers:

- when an app opens
- when speakers or headphones connect
- at a chosen time each day

Each trigger applies one Scene. Existing open apps and connected devices are
used as the startup baseline so rules do not unexpectedly fire at launch.

### Find an Action

The menu-bar popup includes search for Scenes, output devices, Smart Sound,
Undo, Fix Audio, and Settings. The wording describes outcomes rather than
internal audio operations. Command-K opens it while the popup is active.

### Recent Changes

Melo keeps up to twelve private, in-memory snapshots. Repeated slider/key
changes are combined into a single undo step. The history covers per-app and
output-device volume, mute, EQ, balance, routing, global sound options, output
selection, Scene application, and repair.

### Fix Audio

Fix Audio snapshots the current setup, safely invalidates Melo's active routes,
cleans up leftovers, refreshes devices, reapplies saved settings, rebuilds only
needed routes, and rescans effects. It does not erase settings. Technical facts
remain in an optional “Show Details” disclosure.

### Compare and sharing

The Everyday tab can switch between two Scenes for a simple A/B comparison.
Scenes export as readable `.melo-scene.json` files and can be imported on
another Melo installation. Missing third-party effects remain safely bypassed
by the existing effect host.

### Menu bar and devices

The menu bar can remain icon-only or show volume, current device, or a small
live level. Device details lead with Connection, Sound, Quality, and Response;
sample rate, format, latency, clock source, and device ID stay under Technical
details.
