# Installed Skills

## Session Lifecycle
| Skill | When to Use |
|-------|-------------|
| session-init | Every session start — always run first |
| session-close | Every session end — bundles PM update, commits, and session capture |
| session-capture | Automatically run by session-close; or manually if not using session-close |
| session-review | When 5+ captures have accumulated since last review |

## Workflow Lifecycle
| Skill | When to Use |
|-------|-------------|
| workflow-refine | When the user provides a rough task description |
| workflow-create | After refining a brief into a complete specification |
| workflow-readiness-check | Before promoting any draft to active |
| workflow-resume | When executing/continuing a workflow — defaults to autonomous execution |
| workflow-complete | When all acceptance criteria are met (also called by session-close) |

## Project Memory
| Skill | When to Use |
|-------|-------------|
| pm-init | First session in a new project (run by amplify) |
| pm-load | At task start — load only relevant PM units |
| pm-update | At session end — persist durable knowledge |
| pm-validate | When PM index may be out of sync, or every ~10 sessions |
| pm-reflect | Periodically — assess whether PM structure fits project patterns |
| pm-restructure | After pm-reflect — execute approved structural changes (split, merge, archive, create) |

## State and Verification
| Skill | When to Use |
|-------|-------------|
| state-check | After a break >2 days, or when state feels inconsistent |
| feedback | When the user reports friction or a suggestion |
| lessons-forward | When a finding generalizes beyond this project |

## Workflow Type Helpers (code facet)
| Skill | When to Use |
|-------|-------------|
| pm-refactor | Creating a refactor workflow (rf_ prefix) |
| pm-feature | Creating a feature workflow (ft_ prefix) |
| pm-bugfix | Creating a bugfix workflow (bf_ prefix) |
| pm-investigation | Creating an investigation workflow (iv_ prefix) |
| pm-review | Creating a review workflow (rv_ prefix) |
| pm-performance | Creating a performance workflow (pf_ prefix) |

## Design Facet
| Skill | When to Use |
|-------|-------------|
| discussion-refine | Turning a rough design discussion into a clearer brief |
| decision-workflow | Creating a structured design decision document |
| docs-sync | After documentation changes — verify index consistency |
