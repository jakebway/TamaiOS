# Transport replay finding and narrow repair

Automated expanded audit issue 4, commit 0a5cb40, reports 105 Swift policy checks and two IR context tests passing. Four of eight transport replay cases fail: truncated/oversized declared payload, short length header, acknowledged incomplete timeout. These reproduce actual answer-method behavior using synthetic replies, not a firmware failure trace.

The root tamaios_changes.patch is applied by the existing app build workflow and by the transport replay runner before method extraction. TamaLink.swift remains unmodified in the repository. The report records the patch hash. The patch rejects mismatched declared lengths and short control headers, preserving existing acknowledgment-only behavior. This does not establish command acceptance or exactly-once delivery.

The revised replay suite is not yet executed at commit creation. Local git-apply validation used a reconstructed method fixture, not a full app build. Full repository application and Swift compilation are checked in CI. No iOS build, device test, or firmware-protocol compatibility is claimed.

Remaining: command-specific completion criteria, monotonic/total timeouts, device/session ownership, duplicate delivery recovery, raw mode reconciliation and end-to-end firmware fixtures. The original stopped-timer snapshot mismatch remains separate.
