# Parallel Work

Multiple agents can work in parallel in this repository when their workflow packets are separate and their intended write scopes do not silently collide.

## The Coordination Files

- `.agents/state/current-focus.md`: project-wide summary
- `.agents/state/active-workflows.md`: concurrent workflow index
- each workflow `handoff.md`: exact local resume state

## Safe Parallel Work

Usually safe:

- different features in clearly separate areas
- a review workflow that inspects code while another workflow changes a different subsystem
- a performance investigation that only measures and reports while another workflow edits unrelated files

Usually not safe without explicit coordination:

- two workflows editing the same core module
- a refactor that changes shared interfaces while a feature workflow depends on those interfaces
- overlapping migrations of tests or build scripts

## What Users Should Do

Before asking two agents to work at once:

1. make sure each work item has its own workflow packet
2. confirm each packet states its intended write scope
3. check `.agents/state/active-workflows.md` for overlap
4. if overlap is real, sequence the work or explicitly coordinate it
