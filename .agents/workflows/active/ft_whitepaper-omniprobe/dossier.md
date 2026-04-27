# Dossier: ft_whitepaper-omniprobe

## Metadata

- Workflow ID: ft_whitepaper-omniprobe
- Workflow Type: feature
- Lifecycle State: active
- Owner / Current Executor: unassigned
- Intended Write Scope: ~/repos/whitepaper_omniprobe/
- Dependencies On Other Active Workflows: none

## Objective

Produce a polished, visually rich single-page HTML whitepaper that positions Omniprobe as the tool for source-level GPU memory access analysis, filling the gap between hardware-counter profilers and the per-instruction, per-source-location insight developers need to fix uncoalesced accesses and LDS bank conflicts.

## Background / Context

Omniprobe is a toolkit for instrumenting HIP/Triton GPU kernels to extract runtime information such as memory access patterns, cache line usage, and LDS bank conflicts. Existing AMD GPU profiling tools (rocprofv3, Omniperf, Omnitrace) provide hardware counter data and roofline analysis but do not offer per-instruction, per-source-location memory access pattern analysis. Omniprobe fills this gap through compile-time LLVM IR instrumentation, runtime HSA dispatch interception, device-host message streaming, and pluggable analysis handlers.

The whitepaper targets three audience tiers: (a) software developers and performance engineers, (b) technical team leads, (c) CIOs. It must be structured in balanced layers so each audience can consume the document at their appropriate depth.

The deliverable format is a self-contained HTML file styled after the example whitepapers in ~/repos/whitepaper_omniprobe/examples/ — featuring hero sections, sticky TOC, flow diagrams, card grids, step sequences, and professional visual design.

## Contract

The whitepaper content must be technically accurate per Omniprobe's PM units. Named tools (rocprofv3, Omniperf, Omnitrace) are framed as complementary — Omniprobe fills a gap they weren't designed to address. The document presents Omniprobe as v1.0-ready with a forward-looking roadmap.

## Acceptance Criteria

- **AC-1**: A single self-contained HTML file at `~/repos/whitepaper_omniprobe/omniprobe-whitepaper.html` that renders correctly in Chrome/Firefox with no external dependencies (all CSS inline).
- **AC-2**: Visual style matches the example whitepapers — hero section, sticky TOC sidebar, sectioned content panels with rounded corners/shadows, flow diagrams (CSS nodes+arrows), step sequences, card grids, table rows, callout notes, pill tags, responsive layout.
- **AC-3**: Content is structured in balanced layers: executive summary accessible to CIOs, architectural overview for team leads, deep technical sections for developers.
- **AC-4**: Named tools (rocprofv3, Omniperf, Omnitrace) appear in a factual capabilities comparison framed as complementary.
- **AC-5**: At least one concrete worked example showing a kernel with a memory access problem, Omniprobe's analysis output, and the fix — rendered as stylized HTML cards/tables.
- **AC-6**: Includes a roadmap section covering: v1.0 tagging, agent-first JSON output for all handlers, MCP layer for tool integration, LDS race condition detection handler, binary instrumentation support.
- **AC-7**: All technical claims are accurate per PM units.

## Failure Policy

- If the worked example cannot be made realistic enough, fall back to stylized/representative output with a note.
- If write access to `~/repos/whitepaper_omniprobe/` is blocked, write to `.untracked/` and report.

## Scope

- The HTML whitepaper file
- All inline CSS
- All content prose, stylized diagrams, and the worked example
- Write location: `~/repos/whitepaper_omniprobe/omniprobe-whitepaper.html`

## Non-Goals

- No JavaScript interactivity (pure HTML+CSS)
- No PDF generation step
- No modifications to the Omniprobe codebase
- No benchmark data collection or new test runs
- No build/install documentation beyond what's needed for context

## Constraints and Assumptions

- The worked example uses realistic but stylized output (not from a live run)
- Technical content accuracy verified against PM units
- The whitepaper is for external consumption — no references to internal infrastructure, agent workflows, or internal repo paths
- No external font, image, or script dependencies

## Dependencies

- PM units (read-only): architecture, interceptor, instrumentation, handler-pipeline, memory-analysis, dh_comms, kerneldb, omniprobe-cli, testing
- Example whitepapers in ~/repos/whitepaper_omniprobe/examples/ (read-only, for style reference)

## Plan Of Record

1. **Research and outline**: Read all PM units to extract accurate technical content. Build the section outline.
2. **Write the HTML structure and CSS**: Create the document skeleton with all visual components (hero, TOC, sections, diagrams) matching the example style.
3. **Write executive summary and problem statement**: CIO-accessible framing of the GPU memory analysis gap.
4. **Write architecture and subsystem sections**: Technical depth for developers. Include flow diagrams and card grids.
5. **Write the worked example**: Create a realistic kernel with uncoalesced accesses, show Omniprobe output, show the fix.
6. **Write the capabilities comparison**: Factual table comparing rocprofv3, Omniperf, Omnitrace, and Omniprobe.
7. **Write HIP/Triton workflow sections**: Two-path diagram.
8. **Write use cases, getting started, and roadmap sections**.
9. **Visual polish and responsive testing**: Ensure layout works at multiple breakpoints.
10. **Content verification**: Cross-check all technical claims against PM units.

## Verification Strategy

- **AC-1**: Open file in browser, verify no errors in console, verify no external requests.
- **AC-2**: Visual inspection against example whitepapers; check responsive behavior at mobile/tablet/desktop widths.
- **AC-3**: Read executive summary in isolation — it should be understandable without GPU expertise.
- **AC-4**: Verify the comparison table is factual and uses complementary framing.
- **AC-5**: Verify worked example includes problem kernel, output, and fix.
- **AC-6**: Verify roadmap section lists all five planned items.
- **AC-7**: Cross-reference technical claims against PM units.

## References

- Example whitepapers: ~/repos/whitepaper_omniprobe/examples/
- PM units: .agents/pm/units/ (all 10 units)
- Refined brief: produced by workflow-refine in the current session

## Open Questions

None — all clarified during workflow-refine.
