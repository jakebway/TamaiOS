# Firmware-grounded validation audit

## Baseline

App baseline: e5ab6b2406abee7f8e9132c4ab04ee2a937e0552.
Core: oreo-fox/tg18-emu at 41204c92e98a8882d5c90a9876d8990f3b63e285, with radio.patch and ir_partner.patch.
User-supplied initial summary reports Limit, exit 0, smoke-passed for Fairy EN v057, Magic EN v058 and Wonder Garden EN v063. This is not gameplay or connection verification.

## Current harness

The manually dispatched headless-audit workflow runs tools/headless_audit.py on the selected branch. Select audit/firmware-grounded-validation when testing this revision.
Each firmware gets disposable files and separate CLI processes. No player saves are used. Artifacts contain metrics, hashes and differing chunk names, not snapshot contents.

Checks: fresh execution progress; zero-instruction snapshot restore/recapture; independent one-second continuations from the same snapshot; input snapshot immutability. Only the capture timestamp and extra-page serialization order are normalized. Other differences fail and require investigation, including potentially intentional restore normalization. Do not widen exclusions simply to make tests pass.

This checks snapshot-visible state, not all transient hardware state. It does not prove simultaneous in-process instance isolation, equivalence with uninterrupted execution, the iOS FFI save/load path, valid lifecycle mappings, notification delivery, Bluetooth or IR behavior. Fresh-boot fixtures may still be on setup screens.

## Source observations requiring investigation

- snapshot.rs capture includes host Unix time in info; full file hashes are not a round-trip equality criterion.
- restore resynchronizes timers and changes transient sound/stop/flash state; measure before deciding what is expected.
- AppLink.start branches on saved away before mode discovery in that branch.
- IRLink uses raw readiness checks but also scripted menu navigation and fallback mode values.
- AppModel entry points use different connection guards; trace lower-level protections before declaring a race.

## Next gates

1. Run this revision; investigate actual round-trip differences and any progress failure.
2. Audit patched snapshot coverage, including radio and IR state; add uninterrupted-versus-restored continuation comparison.
3. Implement simultaneous two-core isolation checks and paired IR traces.
4. Build named lifecycle fixtures; validate firmware-specific raw-state meanings.
5. Trace FFI and iOS lifecycle ownership, town transactions, notifications, settings and device switching.

No gameplay fixes or runtime passes are claimed by adding this harness. Preserve existing user requirements and record executed evidence before marking findings verified.
