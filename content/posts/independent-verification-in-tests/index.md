---
title: Independent Verification in Tests
description:  "Different degrees of independence when writing tests"
date: 2026-02-17
draft: false
cover: /images/card-default-cover.png
tags:
- programming
- golang
- unit-testing
categories:
- programming
---

## What's independent verification in tests

A test provides independent verification when its expected values come from **outside the implementation**, from business requirements, specifications, or domain knowledge, rather than restating what the code does.

The key question: **if the implementation breaks, will this test catch it?**

## Degrees of Independence

| Degree | Expected value source | Can it fail on a bug? | Value |
|---|---|---|---|
| Strong | Domain knowledge / spec | Yes, and failure is self-evidently wrong | High |
| Moderate | Externally verified lookup | Yes, but correctness requires checking an external source | Medium |
| Weak | Copied from production code | Yes, but correctness requires checking production intent | Low (change detector) |
| None (tautology) | Computed from production code | No | Zero |

Consider a currency conversion module.

### Strong: test encodes domain knowledge the implementation must satisfy

```go
func TestConvertUSDToCents(t *testing.T) {
    require.Equal(t, int64(1050), ConvertToCents(10.50, "USD"))
}
```

The test knows that $10.50 equals 1050 cents. This is a mathematical fact independent of how `ConvertToCents` is implemented. If someone introduces a floating-point rounding bug, the test catches it because **the test and the implementation arrive at the same answer from different directions**.

### Moderate: test duplicates a lookup table from production code

```go
func TestCurrencySymbol(t *testing.T) {
    require.Equal(t, "$", CurrencySymbol("USD"))
    require.Equal(t, "A$", CurrencySymbol("AUD"))
}
```

The expected values are correct because someone verified them against real-world currency conventions. But the test is essentially a second copy of the same mapping that exists in production. The "independence" rests entirely on the assumption that the person who wrote the test verified the values against an external source.

### Weak: test restates a hardcoded constant

```go
func TestDefaultDecimalPlaces(t *testing.T) {
    require.Equal(t, 2, DefaultDecimalPlaces("USD"))
}
```

Where does `2` come from? From looking at the production code and writing down what it returns. If someone changes it to `3`, the test fails, but it cannot tell you whether `3` is wrong. A developer would look at the failing test, see `2`, look at the new code, see `3`, and update the test to match.

A particularly bad variant is duplicating the production formula in the test:

```go
func TestDiscount(t *testing.T) {
    price := 100.0
    discount := 0.2
    expected := price - (price * discount) // same formula as production code
    require.Equal(t, expected, ApplyDiscount(price, discount))
}
```

This can still fail. The formula is a static copy, so changing production breaks the test. But when it fails, the developer sees two competing formulas and has no way to know which is correct without consulting an external source. It detects the change while providing no guidance on correctness.

### None (tautology): test derives expected values from the code under test

```go
func TestDiscount(t *testing.T) {
    expected := ApplyDiscount(100.0, 0.2)
    require.Equal(t, expected, ApplyDiscount(100.0, 0.2))
}
```

The expected value is produced by calling the function under test itself. No matter what `ApplyDiscount` does (returns zero, panics and recovers, applies the wrong formula), the test passes because both sides evaluate the same code path. Unlike a weak test, which at least **detects** a change and forces a pause, a tautology test **cannot fail**. It is true by construction.

Other common forms:
- Asserting a mock returns what you told it to return (`mock.On("Get", id).Return(user, nil)` then asserting `result == user`)
- Using a shared helper that computes both the expected and actual values from the same source

The boundary between weak and none is whether the expected value is **static** (hardcoded at test-write time) or **dynamic** (computed from the code under test at test-run time).

## Prefer Higher-Level Behavioral Tests

A test with strong independence acts as a **second opinion**: it can tell you the result is wrong on its own merits. A test with weak independence acts as a **change detector**: it can only tell you something changed.

A higher-level test that exercises a value through real behavior naturally provides stronger independence:

```go
// Change detector: weak independence
func TestDefaultDecimalPlaces(t *testing.T) {
    require.Equal(t, 2, DefaultDecimalPlaces("USD"))
}

// Higher-level: strong independence
func TestFormatUSDAmount(t *testing.T) {
    require.Equal(t, "$10.50", FormatAmount(10.5, "USD"))
}
```

If someone changes `DefaultDecimalPlaces("USD")` to `3`, both tests fail. But the formatting test fails with `"$10.500" != "$10.50"`, self-evidently wrong without checking production code. The change detector only tells you the value changed from `2` to `3`, leaving you to decide if that's correct.

When you notice a change-detector test, check whether a behavioral test already covers it. If so, the change detector is redundant. If not, consider writing the behavioral test first, then removing the change detector.

## The Limited Value of Change Detectors

Change detectors force a **conscious acknowledgment** of a change. Without the test, someone changes `DefaultDecimalPlaces` from `2` to `3` and nothing in the pipeline flags it. With the test, the pipeline breaks and a developer must look at the failure, understand what changed, and deliberately update the test. That pause ("this test expects `2`, my code returns `3`, is that correct?") is the entire value.

This matters most in two scenarios:

- **Accidental edits:** a merge conflict resolution, a stray keystroke, a refactor that inadvertently changes a value. The developer didn't intend to change the behavior, so the failing test surfaces something they'd otherwise miss.
- **Blast radius awareness:** changing a shared constant and seeing 15 tests fail tells you the change affects 15 behaviors. Even if you update all 15, the act of reviewing each one forces you to consider the impact.

The value disappears when the person updating the test treats it mechanically: sees the failure, copies the new value into the assertion, moves on without thinking. At that point the test is pure overhead: it costs time to maintain and catches nothing.

A tautology test doesn't even offer this. It occupies CI time and gives the false appearance of coverage while catching nothing.

## Identifying the Degree

Two questions, applied in order:

1. **Can the test fail at all?** If the expected value is derived from the code under test at runtime, it cannot fail. It's a tautology (no independence). Remove it or replace it with a hardcoded expected value.
2. **If it fails, is the failure self-evidently wrong?** If yes (e.g., asserting $10.50 = 1060 cents), the test has strong independence. If you'd just update the test to match the new production value, it has weak independence.
