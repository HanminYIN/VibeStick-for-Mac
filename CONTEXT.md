# VibeStick for Mac

VibeStick for Mac is a local-first macOS control center and StickS3 firmware pair for observing coding-agent status, performing explicit USB maintenance, and preserving the existing Bridge/HUD/Paste runtime.

## Language

**Device Network Snapshot**:
A bounded, read-only view of the StickS3 network state, returned only after an explicit USB diagnostic read. It contains no credentials, pairing identifiers, background polling, or network side effects.
_Avoid_: Diagnostic bundle, live probe

**Current Bridge Target**:
The local Bridge address the firmware is prepared to use for its next request, including whether it came from Bonjour or the configured fallback.
_Avoid_: Active endpoint, last endpoint

**Last Bridge Attempt**:
The target and numeric result belonging to the most recent completed Bridge request. Its target remains historical even when the Current Bridge Target changes afterward.
_Avoid_: Current target, latest host

**Bridge Reachability Finding**:
The user-facing classification derived from the Device Network Snapshot: Wi-Fi disconnected, unpaired, polling not observed, transport failure, authentication rejection, HTTP response failure, or Bridge reached. A valid HTTP status outranks the transport error field; transport failure means no HTTP status was received.
_Avoid_: Network error, offline reason

**USB Diagnostic Read**:
The explicit Mac action that requests one existing Device Network Snapshot over the detected StickS3 serial connection. Lack of a response is reported as device not responding, not proof of unsupported firmware.
_Avoid_: USB scan, automatic diagnosis
