# Seed — `bf_exit-status-not-propagated`

**Type:** `bf_` (bug fix)
**Filed:** 2026-09-08, by an agent working in the `intellikit` sidecar
**Status:** seed — not yet a packet
**Companion:** [`bf_pyhandler-gil.md`](bf_pyhandler-gil.md) — independent defect, found in the
same session. Neither depends on the other.

## One line

`omniprobe` always exits 0. When the instrumented target dies of SIGSEGV, `omniprobe` still
returns 0 — and because a returncode check is the **only** failure detection in the whole
IntelliKit → upstream-API → `omniprobe` chain, a crashed run is reported as a successful one.

## Root cause

`omniprobe/omniprobe`, `capture_subprocess_output()`. The function waits on the child, and the
code that would read its status is a comment:

```python
        # Loop until subprocess is terminated
        while process.poll() is None:
            ...

        # Get process return code          <-- says it; does not do it
        remaining = process.stdout.read()
        if remaining:
            ...
```

`process.returncode` is populated by then and never read. The function returns `None` implicitly.
`main()` calls it and discards the result:

```python
        capture_subprocess_output(parms.remaining[1:], new_env=setup_env(parms))
```

and then falls off the end, so the interpreter exits 0. There is no path by which a target's
failure can reach the caller.

Note the `KeyboardInterrupt` handler *does* `sys.exit(1)`, so Ctrl-C is reported correctly. It is
only ordinary child failure — including fatal signals — that is silently swallowed.

## Measured

On an MI350X (gfx950) node under ROCm 7.2.0, against `44547f9`, running the stock
`build/tests/test_kernels/simple_memory_analysis_test` under a handler that segfaults on the
`dh_comms` worker thread:

| Invocation | Reported | Actual |
|---|---|---|
| `omniprobe -i -a <handler> -- <target>` | **exit 0** | target died of SIGSEGV |
| target run directly, with the env from `omniprobe -e` | exit **139** | SIGSEGV (128+11) |

The crash was only discoverable by extracting the environment with `-e/--env-dump` and running
the target by hand. Through the CLI it is indistinguishable from success — the analysis output is
simply absent or short, and nothing says why.

## Why this matters beyond the CLI

This is the part that argues for fixing it rather than filing it. `omniprobe/api/omniprobe.py`
— the Python API that IntelliKit's `omniprobe_ik` wraps — has exactly one failure check:

```python
            result = subprocess.run(args, capture_output=True, text=True)

            if result.returncode != 0:
                raise RuntimeError(
                    f"omniprobe exited with code {result.returncode}: ..."
                )
```

That check is load-bearing and it is checking the value this bug makes constant. Worse, the very
next lines degrade quietly on the same path:

```python
            output_path = Path(tmp_path)
            if output_path.exists() and output_path.stat().st_size > 0:
                return output_path.read_text()

            return "[]"
```

So a crashed run yields `returncode == 0`, no exception, a missing output file, and `"[]"` — an
empty-but-well-formed result that flows into the parser and out to the caller as a successful
analysis of nothing.

**The realistic failure is partial, not empty.** IntelliKit's integration tests do assert
non-emptiness (`assert result.kernels, "analysis returned no kernels for a binary that launched
two"`), so a wholly-empty result is caught. What is not caught is a run that crashes *after* some
dispatches: the result is non-empty, every assertion passes, and the data is silently truncated.
Any conclusion drawn from it — a coalescing ratio, a cycle distribution, a regression comparison
— is computed over a fraction of the kernels and looks entirely normal.

## Suggested fix

Small. Return the status and exit with it:

```python
 def capture_subprocess_output(subprocess_args, handler=None, new_env=None):
     ...
         remaining = process.stdout.read()
         if remaining:
             ...
+    return process.returncode
```

and in `main()`:

```python
-        capture_subprocess_output(parms.remaining[1:], new_env=setup_env(parms))
+        rc = capture_subprocess_output(parms.remaining[1:], new_env=setup_env(parms))
         ...
+        if rc != 0:
+            sys.exit(128 - rc if rc < 0 else rc)
```

Three details worth deciding rather than assuming:

- **Signal deaths are negative.** `Popen.returncode` is `-11` for SIGSEGV, not `139`. Shell
  convention is `128 + signal`, hence the `128 - rc` for negative values. Whichever convention is
  chosen, upstream's `RuntimeError` message interpolates the number, so it should be one a reader
  recognises.
- **Ordering against `finalize_json_output`.** `main()` finalizes JSON output after the run. If
  the exit moves before that, a crashed run leaves malformed JSON; if after, the finalizer runs
  on partial data. Probably: finalize, then exit — but say so deliberately, and consider whether
  a truncated result should be marked as such in the JSON rather than silently closed.
- **Does a nonzero target status mean the analysis failed?** Not always — a target may exit
  nonzero for its own reasons while the analysis is complete and valid. Conflating "the workload
  failed" with "the measurement failed" would introduce the mirror-image bug. It may be worth
  distinguishing the two, at minimum in the message.

## Suggested acceptance criteria

1. A target that exits nonzero for its own reasons is reported with that status — assert on the
   number, not merely on nonzero.
2. **A target killed by a signal is reported as a failure**, and the reported value is
   recognisable (139 for SIGSEGV under the shell convention). This is the case that motivated
   the seed and no other criterion covers it.
3. A successful run still exits 0 — the regression guard, so the fix cannot be "always exit 1".
4. Driving it through `omniprobe/api/omniprobe.py` on a crashing target raises `RuntimeError`
   rather than returning `"[]"`. This is the criterion that shows the fix reaches the consumer
   that actually depends on it; a CLI-only test would pass without it.

A crashing target is easy to arrange without the GIL bug: any `-- /bin/sh -c 'kill -SEGV $$'`
style stub, or a HIP program that dereferences null on the host after its kernels launch.

## Reproducing

```sh
cd <omniprobe>
# any target that dies of a signal under instrumentation
./install/omniprobe/bin/omniprobe -i -a MemoryAnalysis -- <crashing-target>; echo "omniprobe: $?"

# compare against the target run directly with omniprobe's own environment
D=$(./install/omniprobe/bin/omniprobe -i -e -a MemoryAnalysis -- <crashing-target> | tail -1)
env $D <crashing-target>; echo "direct: $?"
```

The session that found this used the GIL bug in `bf_pyhandler-gil` as the crash source, but the
two defects are unrelated: this one reproduces with any target that dies of a signal.
