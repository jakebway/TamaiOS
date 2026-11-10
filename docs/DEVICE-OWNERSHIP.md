# Device-operation guard batch

Expanded audit issue 6 confirms all 12 transport replays, 105 notification policy checks and two IR-context tests passed at 270c980. The separate strict snapshot check retains the stopped-timer difference.

This cumulative build patch retains the transport fix and adds Emulator.canReplaceDevice. It blocks replacement while loading, changing clocks, IR setup/exchange/quiet time, app exchange, download session, app waiting or app hold is active. AppModel play checks before changing currentToy. AppModel remove, restore and reset paths share the guard. Emulator.load routes off-main requests to main and sets loading synchronously before unloading, reducing overlapping boot requests. Daytime Mode uses the same conservative gate.

No raw firmware state meaning is added. Blocked operations are rejected rather than queued; finish or cancel the connection first. This is not a complete session-token or concurrency solution. Direct console/Emulator restore paths, termination during boot, background-reader save ownership and session-bound callbacks still require review.

CI applies the cumulative patch, replays transport cases, executes the actual ownership predicate for all 256 Boolean combinations, and checks guard placement in source. Predicate/source checks do not compile the full iOS app or reproduce UIKit races. Full app compilation and phone lifecycle tests remain required. Source files remain unmodified until the build/test patch is applied. Local hunk checks used reconstructed fixtures; repository application is checked in CI.
