# Release configuration

`release-config-v1.json` is the single input for artifact-resident release
identity. It defines the product and build versions, artifact channel, App
wording, runtime and firmware payload versions, firmware payload location, and
DMG file and volume names.

The build scripts validate the complete schema before invoking Xcode or a DMG
adapter. Missing, unknown, unsafe, or inconsistent values fail closed. The App
embeds the exact validated configuration used to build it.

`build-macos-app.sh` seals the completed App with an external build receipt.
`build-macos-dmg.sh` accepts only that App and receipt; it does not invoke the
App builder. The receipt is checked before staging, after copying, and after
the DMG adapter returns, so packaging cannot silently rebuild or mutate the
accepted App.

For an exact-byte final-RC-to-stable promotion, use the `stable` artifact
channel before building the final RC. That channel produces the release-neutral
DMG name and volume identity; whether the unchanged bytes are presented as a
GitHub Pre-release or stable Release remains publication metadata rather than
an artifact rebuild.
