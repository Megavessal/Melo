# Melo 2.9.0 — Updates, Search, Accessibility

Melo 2.9.0 rebuilds the developer-update pipeline so a broken build can no longer
replace a working one, rewrites search relevance, and closes the accessibility
gaps that stopped VoiceOver and Full Keyboard Access from operating the app.

## Building

    ./Build\ Melo.command            # shipping build
    ./Build\ Melo.command --dev      # keeps the in-app developer-update tools

The expected output is `outputs/Melo.app`. The build now ends with a launch test:
a bundle that cannot start fails the build instead of failing on your desktop.

`--dev` sets the `MELO_DEV` compilation condition. Without it, the developer
update machinery is not merely hidden — it is not compiled in at all.
