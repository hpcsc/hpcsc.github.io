---
title: Building a Quality Pipeline for AI-Assisted Development
description: "Experimental multi-agent workflow that turns a feature request into reviewed, tested, committed code"
date: 2026-03-01
draft: false
cover: /images/card-default-cover.png
tags:
- programming
- ai
categories:
- ai
---

This is an experimental multi-agent workflow that turns a feature request into reviewed, tested, committed code. The pipeline has four stages: user story, task decomposition, implementation, and review. Each stage has approval gates. No code ships without passing all of them.

{{< figure src="images/full-workflow.png" >}}

Every arrow is a gate. Every gate requires either automated verification or human approval. The `write-user-story` skill runs separately. Everything after it, from task decomposition through commit, is orchestrated by a single `/implement` skill (`cd-implement`).

The gates are currently manual by design. As confidence in the automated reviewers grows, the human approval steps could be removed, letting the pipeline run end-to-end without intervention.

## Stage 1: User Stories

The `write-user-story` skill takes a raw feature request and turns it into structured user stories. It asks clarifying questions, then generates stories following the INVEST criteria (Independent, Negotiable, Valuable, Estimable, Small, Testable).

Each story uses the standard format: "As a [role], I want [capability], so that [benefit]." Each includes 3-7 acceptance criteria.

Two rules keep stories useful. First, no implementation details. Stories describe what the user needs, not how the code should work. Second, stories are sliced thin using the Elephant Carpaccio technique, each delivering a narrow vertical slice through the system.

The output is a markdown file saved to `user-stories/[feature-name].md`. This becomes the input for the next stage.

### What a story looks like

```
US-001: Parse a minimal .emod file

As a developer, I want to parse a minimal .emod file containing a
model name, one actor, one context with one aggregate, and one slice
with a command-event pair, so that I can validate the basic structure
of an event model.

Acceptance Criteria:
- `emod validate minimal.emod` exits with code 0 and prints no errors
  for a syntactically correct file
- The parser recognizes `model`, `actor`, `context`, `aggregate`, `slice`,
  `command`, `event`, and `fields` blocks
- Comments (lines starting with `#`) are ignored
- Quoted strings are parsed correctly
- Unrecognized keywords or unclosed braces produce an error message with
  file name, line number, and a description of what was expected
```

No mention of lexers, ASTs, or recursive descent. The story describes what the user sees when they run the tool.

## Stage 2: Task Decomposition

The `decompose-to-tasks` agent reads a user story and the actual codebase, then produces an ordered list of implementation tasks. Each task is independently committable and leaves the codebase green.

A task includes:

- **Imperative title:** what to do
- **Behavior:** the observable outcome
- **Acceptance criteria:** mapped back to the story
- **Affected files:** specific paths in the codebase
- **Patterns to follow:** file:line references to existing code (no paraphrasing, no pseudocode)
- **Testable:** yes or no
- **Dependencies:** which tasks must complete first

The agent explores the codebase before decomposing. It finds existing patterns, types, and conventions so tasks reference real code, not hypothetical structures.

**Gate:** The user reviews the task list before any implementation begins.

### What a task breakdown looks like

That single user story above decomposed into seven tasks:

1. Initialize Go module and directory structure
2. Define AST types for the emod model
3. Implement lexer for `.emod` tokens
4. Implement recursive-descent parser
5. Wire up CLI with root and validate subcommands
6. Produce structured parse errors with file, line, and description
7. Add sample `.emod` fixture and end-to-end validation test

Each task is marked as testable or not. Testable tasks (like "Implement lexer") go through the full test design cycle. Non-testable tasks (like "Initialize Go module and directory structure") are verified by compilation or a simple check instead.

Each task builds on the previous one. Task 4 (parser) depends on Task 3 (lexer) and Task 2 (AST types). Task 7 (integration test) depends on everything before it. The ordering is bottom-up: infrastructure first, integration last.

When tasks are independent, the decomposer marks them as parallelizable. A later story that added four pattern types (trigger, view, automation, translation) produced four independent parse tasks that could run concurrently.

## Stage 3: Implementation Cycles

Each task runs through a five-step cycle: test design, implementation, review, approval, and commit.

### Test Design

For testable tasks, the `test-case-designer` agent produces a test plan. It reads the affected code, designs test scenarios, then filters out anything that wouldn't catch real bugs.

Each scenario specifies what behavior it verifies, the expected outcome grounded in domain knowledge, and what code change would cause it to fail.

The agent explicitly filters out tests that verify compiler guarantees, duplicate existing coverage, test framework behavior, or would never catch a real bug.

**Gate:** The user approves the test plan before implementation begins.

#### What a test plan looks like

{{< figure src="images/test-plan.png" >}}

### Implementation

The implementation agent (language-specific, `go-implementer` for Go projects) receives the task description, acceptance criteria, affected files, patterns to follow, and the approved test plan.

For Go projects, the agent follows a test-first workflow: write all tests for the task upfront, confirm they fail, then write production code to make them pass. This is not traditional TDD where you write one test at a time. Writing a single test, implementing, then writing the next test is too slow for AI-assisted development. Instead, the approved test plan from the previous step becomes a batch of tests written together, and the implementation makes them all pass in one go. Tests use black-box testing from a `_test` package, calling only exported functions.

**Gate:** Tests must pass (or compilation must succeed for non-testable tasks) before moving to review.

### Review

This is where the pipeline gets aggressive. Four review agents run in parallel against the staged diff:

1. **Semantic reviewer:** logic correctness, edge cases, off-by-one errors, nil handling, error paths, intent alignment, and test quality
2. **Security reviewer:** injection patterns (SQL, command, XSS, template), authorization gaps, credential exposure, input validation at trust boundaries
3. **Performance reviewer:** missing timeouts, resource leaks, unbounded operations, graceful degradation gaps
4. **Concurrency reviewer:** shared state synchronization, non-atomic operations, race conditions, deadlock potential, idempotency

For Go projects, a fifth reviewer checks language-specific guidelines: naming conventions, interface design, package structure, and test patterns.

Each reviewer outputs a structured JSON verdict: `pass` or `block`, with findings that include file, line number, issue description, and explanation. If any reviewer returns `block`, the implementation agent receives the findings and revises. This can repeat up to three times before escalating to the user.

**Gate:** The user sees the implementation summary, review verdicts with per-reviewer breakdown, and test output. Nothing commits without explicit approval.

#### What a review output looks like

{{< figure src="images/review-output.png" >}}

### Commit

The `commit` agent stages changes and drafts a commit message following conventional rules: 50-character subject in imperative mood, body explaining what and why. It presents the message for approval before executing.

### Progress Tracking

After each commit, the task file updates its checkbox. The user sees remaining tasks and the cycle repeats for the next one.

## Language Awareness

The pipeline detects the project language from marker files (`go.mod`, `package.json`, `Gemfile`, etc.) and configures itself accordingly. Go projects get the `go-implementer` agent with its TDD workflow, the Go-specific semantic reviewer, and the guidelines reviewer. Other languages use the general-purpose implementation agent and the standard semantic reviewer.

## Why This Many Gates

Each gate catches a different class of problem:

- **Story approval** catches misunderstood requirements before any code exists
- **Task approval** catches poor decomposition before work begins
- **Test plan approval** catches missing scenarios and weak coverage before tests are written
- **Automated review** catches bugs, security holes, performance issues, and concurrency problems through specialized analysis
- **Human approval** catches anything the automated reviewers miss and validates that the change matches intent

The automated review layer runs four (or five) specialized reviewers rather than one general-purpose review. A security-focused reviewer that only looks for vulnerabilities will find issues that a general reviewer would miss. Same for performance, concurrency, and semantic correctness. Each reviewer has a narrow scope and deep checklist for that scope.
