# Handoff

## Current Status

Done 2026-11-08 (`093a6fe` phase 1; `2717c26`, `f296bba`, `03c12f6` phase 2). See run-log.

## Next Exact Step

None. Follow-up: real per-block timing via BBInterval, queued after `bf_faulted-dispatch-hang`.
Consumers (IntelliKit skill, Pennant scripts) must move from p50/cycles to wave_visits/active_lanes,
and rebuild binaries with the new BBStart plugin to get kernel-source lines.
