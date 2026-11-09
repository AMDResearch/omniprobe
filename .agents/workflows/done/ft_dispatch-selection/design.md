# Dispatch selection: design note (2026-11-09)

Status: **proposal, awaiting the supervisor's ruling.** No code has been changed.
Source of the request: Rene, `rene-response-2026-11-09.md` § Omniprobe and § Deferred decisions:
remove `-d random`; select dispatches by kernel-name regex and by dispatch number (lists, ranges,
repeat shorthands); a dispatch number counts **per kernel that matches the regex**.

Evidence tags: `[read]` read in the tree at `5d23a84`, `[meas]` measured here (how is stated),
`[inf]` inference, `[ext]` external documentation.

---

## 1. What exists today

### 1.1 Path from the command line to the runtime

| Step | Where | What |
|---|---|---|
| `-d/--dispatches` | `omniprobe/omniprobe:711-720` | `type=str`, default `"all"`, help says `[all, random, 1]`. **No `choices=` and no validation**: `-d 5` or `-d foo` is accepted. [read] |
| env | `omniprobe/omniprobe:464-466` | Always exported as `LOGDUR_DISPATCHES` (the default `all` is non-empty). [read] |
| `-k/--kernels` | `omniprobe/omniprobe:699-708`, `:487-492` | Exported as `LOGDUR_FILTER`, only with `-i`; otherwise "will be ignored". [read] |
| config read | `src/utils.cc:875-905` | `getLogDurConfig` copies both env vars into the config map. [read] |
| `-d` parse | `src/utils.cc:1342-1370` | `dispatchController` ctor: `random` / `all` / `1`. **Any other value sets none of `bAllDispatch_`, `bRandomDispatch_`, `bOneDispatch_`**, which have no initialisers (`inc/utils.h:274-276`); `canDispatch` then reads indeterminate bools. A latent defect, removed by this redesign. [read] |
| `-k` compile | `src/interceptor.cc:200-215` | `std::regex(strFilter, ECMAScript)` once at startup; `-k` also goes to `kernel_cache_.setLocation`/`addFile` (`:226`, `:395`), which use it to choose which Triton-cache files to index. [read] |
| `-k` match | `src/interceptor.cc:1138-1143` | `runKernelInstrumented`: `std::regex_search` (substring match) on the **demangled** kernel name (`kernel_objects_[..].name_`, set by `demangleKernelName`, `:1153-1156`). [read] |

### 1.2 The per-dispatch decision

`hsaInterceptor::doPackets` (`src/interceptor.cc:1037-1066`) handles every packet on every
intercepted queue. For each kernel-dispatch packet it takes `id = ++dispatch_count_` (`:1045`), then
calls `fixupPacket(packet, queue, id)` (`:863`). Inside, under `mutex_`:

1. `kernel_cache_.hasKernels(agent)` and the kernel object is known (`:885-888`);
2. with `-i`, look up the instrumented clone: `findInstrumentedAlternative` (`:895`);
3. **only if a clone exists** (`:921`): `filter_allows = runKernelInstrumented(name)` (`:927`),
   `eligible = run_instrumented_ && filter_allows` (`:941`),
   `capture = eligible && dispatcher_.canDispatch(alt_kernel_object)` (`:942`);
4. `capture` → rewrite the packet to the clone, allocate kernargs, check out a `dh_comms` object
   with `dispatch_id = id` (`:983`); otherwise run the original kernel object.

### 1.3 What `-d` does today

- `all`: `canDispatch` returns true.
- `1`: true the first time `canDispatch` sees a given **`alt_kernel_object`** (the clone's kernel
  object), false afterwards (`src/utils.cc:1377-1388`). The map is touched only when
  `eligible` (short-circuit at `:942`), so `-d 1` means *the first dispatch that passes `-k`*, per
  clone kernel object. [read]
- `random`: each eligible dispatch independently with probability 1/`RANDOM_DISPATCH_DISTRIBUTION`
  = 1/100 (`src/interceptor.cc:324-341`, `utils.cc:1337-1340`); an end-of-run warning lists the
  kernels it captured nothing of (`interceptor.cc:322-341`, added 2026-11-08).

### 1.4 What a "dispatch number" is today

| Question | Answer |
|---|---|
| Reported `dispatch_id` (every handler, JSON/CSV) | `dispatch_count_`, a per-process `std::atomic<uint64_t>` (`inc/interceptor.h:194`), C++20 so value-initialised to 0, pre-incremented, so **1-based** (`:1045`). [read] |
| Global or per kernel? | **Global**: one counter for all kernels, all queues, all agents in the process. [read] |
| Before or after `-k`? | **Before**: it counts every kernel-dispatch packet, including HIP runtime blit kernels (`__amd_rocclr_*`) and kernels without a clone or excluded by `-k`. [read] |
| `-d 1`'s notion of "first" | **Per clone kernel object, after `-k`** — a different counter from the reported id. [read] |
| Shared across streams? | Yes within a process: all intercepted queues share the counter. [read] |
| Across devices? | The counter yes. `-d 1` no: clone kernel objects are per agent, so `-d 1` captures the first dispatch **on each GPU** [inf: kernel objects are per loaded executable per agent]. |
| Across processes (MPI ranks)? | No. Each process has its own interceptor singleton (`interceptor.cc:92-99`), so each rank counts from 1 independently. [read] |
| Concurrent submitters | `++dispatch_count_` is taken in `doPackets`, outside `mutex_`. The order between two threads submitting at the same time is whichever wins; the ids are unique but not reproducible run to run [inf]. |

Consequence for the redesign: **the numbers users see in output (global ids) are not the numbers
the new `-d` will take (per-kernel ordinals).** See § 5, Q6.

### 1.5 Users of `-d random` (and of `-d` generally)

In this repo (`command grep -rn`, tracked tree plus `tests/test_output/`):

- `tests/test_dispatch_random.sh` (whole file), `tests/run_all_tests.sh:181` (suite 27);
  `tests/test_output/dispatch_random/*.log` (output, untracked or regenerated).
- `src/utils.cc:1332-1370`, `inc/utils.h:257-279` (`randomDispatcher`, `RANDOM_DISPATCH_DISTRIBUTION`),
  `src/interceptor.cc:322-341, 943-950`, `inc/interceptor.h:182` (`random_draws_`).
- `omniprobe/omniprobe:719` (help), `omniprobe/api/omniprobe.py:104-106` (docstring), `:313` (passes `-d`).
- Docs: `docs/usage.md:250-278` (section "Selecting dispatches"), `:629`; `docs/triton-instrumentation.md:325`;
  `README.md:85`.

In IntelliKit (`~/repos/intellikit`, read-only peek; **owned by `ikl`**):

- `omniprobe/src/omniprobe_ik/cli/main.py:141-149` — `choices=["all", "random", "1"]` (would
  reject every new spec).
- `omniprobe/src/omniprobe_ik/api.py:590-625` — `random_dispatch_missed()` and its hint text.
- `omniprobe/src/omniprobe_ik/mcp/server.py:54-56` — tool docstring lists `'all', 'random', or '1'`.
- `omniprobe/src/omniprobe_ik/raw.py:147` — passes `-d <dispatches>` through (works unchanged).
- `omniprobe/skill/SKILL.md:53, 57, 190`; `docs/tools/omniprobe.md:263-264, 337`.
- `omniprobe/build/lib/...` — stale build copies, ignore.

---

## 2. Semantics (common to every syntax option)

### 2.1 Selection rule

A dispatch of kernel *K* is instrumented iff

1. `-i` is given, *K* has an instrumented clone, and
2. *K*'s demangled name matches `-k` (or no `-k`), and
3. *K*'s **per-kernel ordinal** *n* is in the dispatch set *S* given by `-d`.

The per-kernel ordinal *n* of a dispatch is 1 + the number of earlier dispatches of the same kernel
in this process. This is Rene's rule: with `-k 'A|B' -d 2,5`, the 2nd and 5th dispatch of A and of
B are instrumented. Without `-k`, the same rule applies to every kernel.

**What counts as an earlier dispatch** (recommendation): *every* dispatch of *K* the interceptor
sees, whether or not it was instrumented or *K* had a clone yet. Reason: "the 5th dispatch of A"
should mean the application's 5th launch of A, independent of omniprobe's state. Today's `-d 1`
counts only eligible dispatches, and with a Triton cache a clone can appear after the first
launches, so "first" would drift. Since `-k` is per kernel (all of *K*'s dispatches match or none
do), counting before or after `-k` differs only through clone timing, and that case favours
counting all. Implementation note: the count must move out of the `if (alt_kernel_object)` block
(`interceptor.cc:921`) and be keyed by name.

### 2.2 Identity of "a kernel"

Recommendation: the **demangled name** — the string `-k` matches and output reports. Alternatives:
clone kernel object (today's `-d 1`; splits by GPU and by duplicate code-object loads), or
(name, agent). See Q5.

### 2.3 The dispatch set *S*

Built from a **pattern** (a list of items; an item is `n` or an inclusive range `a-b`) and an
optional **repeat** (count *c*, stride *s*):

- pattern *P* = union of the items; `min(P)` = smallest, `max(P)` = largest member;
- default stride *s* = `max(P) - min(P) + 1` (the "continue with the dispatch after the last one");
- *S* = { *p* + *k*·*s* : *p* ∈ *P*, 0 ≤ *k* < *c* }; *c* = ∞ when unbounded;
- no repeat given = *c* = 1 (just the pattern).
- *c* counts **copies of the pattern including the first**, not additional repetitions.

### 2.4 Rene's examples checked against the rule

| Rene | Rule | Expansion | Rene's expansion | |
|---|---|---|---|---|
| `[1,3,4]` | P={1,3,4}, c=1 | 1,3,4 | 1,3,4 | ✓ |
| `[1,3,4:3]` | s = 4−1+1 = 4, c=3 | 1,3,4, 5,7,8, 9,11,12 | 1,3,4,5,7,8,9,11 12 | ✓ (his text lacks one comma) |
| `[1,3,4:3:100]` | s=100, c=3 | 1,3,4, 101,103,104, 201,203,204 | same | ✓ |
| `[1,3,4::100]` | s=100, c=∞ | 1,3,4, 101,103,104, 201,… | "keep repeating until the last dispatch" | ✓ |
| `[1-10]` | P={1..10} | 1..10 | ranges | ✓ (inclusive reading) |

All five are consistent with one rule. Two readings were checked and rejected:
*"repeat three times" = 3 additional copies* gives 12 numbers for `[1,3,4:3]`, but Rene lists 9;
*period = span* (`max-min` = 3) gives 1,3,4,4,6,7,…, not his list. "Skip relative from first item"
is the stride measured from `min(P)`, which is the same as adding *k*·*s* to every member.

### 2.5 Edge cases

| Case | Behaviour proposed |
|---|---|
| duplicates / overlapping items (`1,1-3`) | set semantics; no warning |
| stride < span (`1-10:3:5`) | allowed; copies overlap; set semantics. Warn? No — it is well defined. |
| stride with c=1 (`1,3:1:100`) | allowed, stride irrelevant (no warning; scripts generate such specs) |
| 0, negative, `b < a` in `a-b` | error (see § 4) |
| *c* = 0 | error ("repeat count must be ≥ 1; leave it empty for unbounded") |
| huge numbers | accepted up to 2^63−1; ranges are never expanded into lists (membership test is arithmetic: (n − min) mod s, then interval test) |
| `all` | keyword, = every dispatch (default) |
| `1` | unchanged meaning: first dispatch of each kernel (now per name, see Q5) |
| `random` | removed: error naming a replacement — deterministic sampling `-d 1::100` (every 100th dispatch of each kernel) |

### 2.6 Processes and devices

- **Multi-process (MPI, `fork`/`exec` children inheriting `LD_PRELOAD`)**: each process counts its
  own dispatches from 1; the same spec applies in every rank. A cross-process shared counter (shm)
  is not proposed: rank-local counting is what users of per-rank tools expect, and different
  ranks running the same kernel would otherwise race for "the 2nd dispatch". Selecting *ranks* is
  out of scope (a wrapper that sets `-d` per rank does it today). Documented, not implemented.
- **Multi-GPU in one process**: by name (recommended), a kernel's dispatches on all GPUs share one
  ordinal sequence, in interception order. With concurrent submitting threads that order is not
  reproducible; documented. Per-(name, GPU) counting is Q5's alternative.
- **Streams**: irrelevant to the count (all queues in a process feed one per-kernel counter).

---

## 3. Syntax options

Shell facts used below:

- `[ ... ]` is a glob bracket expression in bash and zsh. **[meas] bash 5 on this node:**
  `bash -c 'echo [1,3,4]'` prints `[1,3,4]` in an empty directory, but after `touch 1` it prints
  **`1`** — the spec silently becomes "first dispatch". zsh (not installed here) errors with
  `no matches found: [1,3,4]` under its default `NOMATCH` option [ext: zsh manual, `NOMATCH`].
  So brackets are safe only when quoted.
- `(` `)` `;` `<` `>` `|` `&` are shell metacharacters. **[meas]** `bash -c 'echo [0,10)'` →
  `syntax error near unexpected token ')'`.
- `,` `-` `:` `.` `+` `/` `=` `%` `@` digits and letters are inert in bash and zsh in argument
  position (`,` only matters inside `{}`; `:` only in zsh history/parameter modifiers after `!`/`$`).
  **[meas]** `1,3,4:3:100`, `1-10`, `1,3,4::100` pass through bash unchanged.
- `!` triggers history expansion in interactive bash/zsh; `^` is a glob operator in zsh with
  `EXTENDED_GLOB`; `*`/`?` glob; `~` expands at word start. None is used by any option.

### Option A — Rene's notation, brackets optional (recommended)

```
spec    := "all" | pattern [ ":" [count] [ ":" stride ] ]
           (optionally wrapped in "[" "]")
pattern := item { "," item }
item    := N | N "-" N              (inclusive; N ≥ 1)
count   := N                         (empty = unbounded)
stride  := N
```

| Rene | Option A, unquoted | Also accepted (must be quoted) |
|---|---|---|
| `[1,3,4]` | `-d 1,3,4` | `-d '[1,3,4]'` |
| `[1,3,4:3]` | `-d 1,3,4:3` | `-d '[1,3,4:3]'` |
| `[1,3,4:3:100]` | `-d 1,3,4:3:100` | |
| `[1,3,4::100]` | `-d 1,3,4::100` | |
| `[1-10]` | `-d 1-10` | |
| `-k 'A\|B'` + `[2,5]` | `-k 'A\|B' -d 2,5` | |

Other forms: `-d 1::100` (every 100th dispatch of each kernel: 1, 101, 201, …; replaces `random`);
`-d 1::2` (odd dispatches); `-d 1,3:` (unbounded, default stride 3: 1,3, 4,6, 7,9, …);
`-d 10-` is an error unless Q4's open-range extension is accepted.

Shell: unquoted form needs no quoting in bash or zsh. Docs show only the unquoted form; brackets
accepted for anyone copying Rene's notation, and if a glob ate them the launcher sees `1` and
cannot tell — so the docs say *don't use brackets unquoted*.
Pro: exactly Rene's mental model, shortest, one token, one env var. Con: the two positional
`:` fields (`1,3,4:3` vs `1,3,4::3`) are easy to confuse — `:3` is a count, `::3` a stride.

### Option B — list/range in `-d`, repeat as separate flags

```
-d all | pattern                 (pattern as in A, no ":")
--dispatch-repeat N | inf        (default 1)
--dispatch-stride N              (default max-min+1)
```

`[1,3,4:3:100]` → `-d 1,3,4 --dispatch-repeat 3 --dispatch-stride 100`;
`[1,3,4::100]` → `-d 1,3,4 --dispatch-repeat inf --dispatch-stride 100`.
Shell: no issues. Pro: self-documenting, no positional ambiguity. Con: three flags for one concept;
the Python API and IntelliKit (CLI, MCP tool, skill) each grow two parameters; long.

### Option C — named fields in one token

```
spec := "all" | pattern { ":" key "=" N }      key ∈ { count, every }   (count may be "inf")
```

`[1,3,4:3]` → `-d 1,3,4:count=3`; `[1,3,4:3:100]` → `-d 1,3,4:count=3:every=100`;
`[1,3,4::100]` → `-d 1,3,4:every=100` (stride given without count = unbounded).
Shell: no issues (`=` is inert in argument position). Pro: one token, readable, extensible
(e.g. `:gpu=0` later). Con: longer; departs from Rene's notation; "every alone means unbounded"
is a rule to learn.

### Option D — Python-slice style, 0-based, half-open (for comparison; not recommended)

`-d 0:10` = dispatches 0..9; lists of slices `0,2:4`; stride as third slice field `0:1000:100`.
Rene's `[1,3,4::100]` has no direct form (a list repeated with a stride is not a slice); it needs
an extra operator such as `0,2,3%100`. Half-open `[0,10)` in mathematical notation is ruled out
by the measured bash syntax error unless quoted. Pro: familiar to Python users. Con: `0`-based
clashes with the 1-based ids in all existing output; `:` means range here and repeat in Rene's
notation; does not express Rene's main example.

---

## 4. Validation and errors

Validated **in the launcher** before the application starts (exit status 2, argparse-style);
the launcher writes a canonical form to the environment, and the runtime parses only that form and
treats a malformed value as fatal for instrumentation (prints `omniprobe: ERROR: LOGDUR_DISPATCHES=…`
and instruments nothing, plus a line in the exit summary) — never the indeterminate-bool fallback
of today. One shared grammar test table drives both parsers (Python unit test + a C++ test binary,
or the runtime parser exposed through a `--check` path).

Canonical env form (recommended): `LOGDUR_DISPATCHES` = `all` or
`<a>-<b>[,<a>-<b>…];count=<c|inf>;stride=<s>` — intervals, explicit count and stride, never
expanded. The variable name stays `LOGDUR_*` (renaming is `rf_rename-logduration-to-omniprobe`).

Messages (Option A wording; B/C analogous), each echoing the input with a caret:

| Input | Message |
|---|---|
| `random` | `-d random was removed; for sampling use e.g. -d 1::100 (every 100th dispatch of each kernel)` |
| `0` / `0-5` | `dispatch numbers start at 1 (the first dispatch of a kernel is 1)` |
| `5-2` | `range 5-2 is empty: the end must be ≥ the start` |
| `1,,3`, `1,`, `,3` | `empty item in dispatch list` |
| `1,3:0` | `repeat count must be ≥ 1 (leave it empty, '1,3::S', for unbounded)` |
| `1,3:2:0` | `stride must be ≥ 1` |
| `1:2:3:4`, `1,x` | `expected a number, a range a-b, or ':' count ':' stride` |
| `[1,3` | `unbalanced '['` |
| unquoted `[1,3,4]` globbed to `1` by the shell | undetectable by omniprobe — the docs never show unquoted brackets |
| `-d` without `-i` | warning, as `-k` does today (`omniprobe:487-489`) |

---

## 5. Sub-questions and recommendations

| # | Question | Recommendation | Why |
|---|---|---|---|
| Q1 | Syntax | **Option A** (brackets optional, documented unquoted) | Rene's notation; one token; shell-safe without brackets; maps 1:1 to the canonical env form. |
| Q2 | 0- or 1-based | **1-based** | Reported `dispatch_id` is already 1-based; `-d 1` already means "first" and keeps working; Rene's examples start at 1. |
| Q3 | Ranges | **Inclusive `a-b`**; no half-open notation | `1-10` = ten dispatches reads naturally with 1-based counting; `[0,10)` needs quoting (measured syntax error) and mixes notations. |
| Q4 | Open-ended ranges (`10-`)? | **Yes, add `a-`** ("from the a-th on") | Cheap, shell-safe, otherwise users write `10-999999999`. Optional; drop if the ruling wants minimal. |
| Q5 | Kernel identity for counting | **Demangled name, per process** (all GPUs share one sequence) | What `-k` matches and output shows. Changes `-d 1` on multi-GPU from "first per GPU" to "first overall" — note in docs. Alternative: (name, GPU). |
| Q6 | Users see global ids, `-d` takes per-kernel ordinals | **Add the per-kernel ordinal to output** (`kernel_dispatch` field in JSON/CSV and on the "Found instrumented alternative" stderr line) | Otherwise nobody can pick "the 5th dispatch of A" from a first run's output. Touches handler output in `src/` only; the dh_comms LDS code is not involved. If the ruling wants this out of scope, a follow-up packet. |
| Q7 | What counts toward the ordinal | **Every dispatch of the kernel**, instrumented or not, clone present or not | Stable meaning ("the app's 5th launch of A"); immune to clone-arrival timing. |
| Q8 | Repeat count meaning | **Total copies including the first** | Matches Rene's 9-number expansion of `[1,3,4:3]`. |
| Q9 | `random` | **Remove**; launcher error points to `-d 1::100` | Rene's instruction; deterministic sampling covers the use. |
| Q10 | Python API / IntelliKit | `dispatches=` stays a string, passes through; IntelliKit's `choices=` list, `random_dispatch_missed()` and docs must change (`ikl`'s repo) | No new API surface under Option A. |
