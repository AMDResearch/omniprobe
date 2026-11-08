# Dossier — ft_pythonhandler-wave-fields

## Metadata

- Workflow ID: ft_pythonhandler-wave-fields
- Workflow Type: feature
- Lifecycle State: done
- Owner / Current Executor: opimpl worker (supervised run, 2026-11-08)
- Base Commit: 103ccd1
- Request: ikimpl (IntelliKit) spec, relayed by the supervisor 2026-11-08

```write-scope
src/pyHandler.cc
inc/pyHandler.h
plugins/python_bridge_plugin.cc
plugins/CMakeLists.txt
omniprobe/config/analytics.py
tests/test_python_handler.sh
tests/python_handler/
docs/usage.md
```

## Objective

A Python handler gets, per wave, what AddressLogger records: lane addresses, lane ids and exec
mask, source file/line/column, access type, memory space, access size, block index, wave and
CU/SE/XCC ids, timestamp; and time-interval messages carry their source location and wave ids.

## Decisions

- Versioned by function name: new `handleAddressWave(dict)`, once per wave. The per-lane
  `handleAddressMessage(dict)` is unchanged (only `address`, plus `kernel`/`dispatch_id`), so
  existing modules work. If both are defined, both are called.
- All handler functions are optional; at least one of handleAddressWave / handleAddressMessage /
  handleTimeMessage is required (before: handleAddressMessage AND handleTimeMessage were).
- `handleTimeMessage` gains keys additively: start, stop, block_id, and the wave keys.
- `lanes` are the set bits of `exec`, matching AddressLogger's "one address per active lane in
  increasing lane order"; if their count disagrees with the addresses, `lanes` is left empty
  rather than guessed.
- `source_file` is resolved as AddressLogger does (the adapter is a `kdb_message_handler_base`).

## Acceptance Criteria

- **AC-1**: suite 19 `waves: fields_per_wave`: 2 dispatches x 32 wave messages, at the load and
  store lines, 64 distinct addresses and lanes 0..63 each, all fields as expected.
- **AC-2**: `waves: lanes_match_partial_exec`: waves with exec = odd lanes give 32 addresses and
  the odd lane ids.
- **AC-3**: `intervals: time_message_fields`: 12 intervals (BBInterval loop, 10 iterations) with
  start/stop/elapsed_time/block_id/source location.
- AC-1..3 FAIL on the previous PythonHandler (module rejected: no handleAddressMessage).
- **AC-4**: full suite passes.
