---
title: "Testing interface contracts"
description: "Testing interface contracts"
date: 2026-04-26
draft: false
cover: /images/card-default-cover.png
tags:
- programming
- unit-testing
categories:
- programming
---

An interface is a promise. Any type that satisfies it must behave the same way from the caller's perspective. If that promise matters, the tests should enforce it on every implementation, not just the first one you wrote.

The pattern is simple and language-agnostic: write one test suite that takes a constructor, and run it against each implementation. The shape is the same whether you call them interfaces (Go, Java, C#), protocols (Swift, Python), traits (Rust), or abstract base classes. The examples here are in Go, but the idea carries over unchanged.

## The Setup

Here is a repository interface for a `collection` package. It has two planned implementations: an in-memory version for local development and dry-runs, and a persistent version backed by a database.

```go
type Repository interface {
    Create(name, description string) (Instance, error)
    List() ([]Instance, error)
    Rename(id, newName string) error
    Delete(id string) error
}
```

The invariants live in a doc comment on the interface:

- `Create` generates the ID. The returned `Instance` carries a non-empty ID.
- Names must be non-empty after trimming. Otherwise `ErrEmptyName`.
- Names are unique case-insensitively. Collisions return `ErrDuplicateName`.
- `Rename` and `Delete` return `ErrNotFound` for an unknown ID.

These rules are the contract. Every implementation has to honor them, or the interface is a lie.

## The Shared Contract Test

Instead of writing `TestMemoryRepository` and later duplicating it as `TestSQLRepository`, we extract one function that exercises the contract and takes a constructor:

```go
func TestMemoryRepository(t *testing.T) {
    testRepositoryContract(t, func() collection.Repository {
        return collection.NewMemory()
    })
}

// testRepositoryContract exercises the Repository interface contract. Any
// implementation (in-memory, persistent, etc.) is expected to pass it.
func testRepositoryContract(t *testing.T, newRepo func() collection.Repository) {
    t.Helper()

    t.Run("create then list returns the created collection", func(t *testing.T) {
        repo := newRepo()

        created, err := repo.Create("vim", "editor shortcuts")
        require.NoError(t, err)

        collections, err := repo.List()
        require.NoError(t, err)
        require.Len(t, collections, 1)
        require.Equal(t, created.ID, collections[0].ID)
        require.Equal(t, "vim", collections[0].Name)
        require.Equal(t, "editor shortcuts", collections[0].Description)
    })

    // ... more scenarios
}
```

When the SQL-backed repository lands, the only new test code is:

```go
func TestSQLRepository(t *testing.T) {
    testRepositoryContract(t, func() collection.Repository {
        return newSQLRepoForTest(t)
    })
}
```

One contract, many implementations, zero duplication.

## Why a Constructor, Not a Shared Instance

Each subtest calls `newRepo()` at the top. Fresh state, every time.

```go
t.Run("create then list returns the created collection", func(t *testing.T) {
    repo := newRepo()
    // ...
})

t.Run("list on an empty repository returns no collections", func(t *testing.T) {
    repo := newRepo()
    // ...
})
```

This matters for three reasons:

- **Independence:** no subtest can depend on state left behind by another. Go's `t.Run` doesn't guarantee ordering in all cases (`-run` flags, parallelism), and even if it did, depending on order would be fragile.
- **Parallel-friendly:** nothing blocks you from calling `t.Parallel()` later.
- **SQL-friendly:** when the persistent implementation shows up, the constructor can spin up a clean schema or a transaction per test without changing a single subtest.

A shared instance would force every scenario to clean up after itself, which is exactly the kind of bookkeeping that breeds order-dependent flakes.

## Scenarios Describe Behavior, Not Methods

The subtest names read as sentences about outcomes:

```go
t.Run("create then list returns the created collection", ...)
t.Run("creating a duplicate name returns ErrDuplicateName and does not add a second collection", ...)
t.Run("name uniqueness is case-insensitive", ...)
t.Run("renaming a collection to its own current name succeeds as a no-op", ...)
t.Run("renaming to an empty or whitespace-only name returns ErrEmptyName and leaves the collection unchanged", ...)
t.Run("after deleting a collection, its name becomes available for Create again", ...)
```

A few things to notice:

- Names describe what the caller observes, not which method was called.
- Each scenario has one reason to fail. "Returns the error AND does not mutate state" counts as one behavior: the rejection.
- Cross-operation scenarios (`after deleting, the name is free for Create`) test contracts that emerge from the interaction of two methods. These are exactly the bugs a single-method test misses.

Compare to what a mirror-style test would look like:

```go
// Bad: names the method, not the contract
t.Run("TestCreate_Success", ...)
t.Run("TestCreate_DuplicateReturnsError", ...)
t.Run("TestRename_Success", ...)
```

Those names describe the function under test. The good names describe what a caller can rely on.

## Assertions Use the Public API Only

Every assertion goes through the `Repository` interface:

```go
require.NoError(t, repo.Delete(a.ID))

collections, err := repo.List()
require.NoError(t, err)
require.Len(t, collections, 1)
require.Equal(t, b.ID, collections[0].ID)
```

No reaching into the in-memory map. No checking mutex state. No asserting on call counts. If the SQL implementation stores names in a wildly different shape, these tests still pass, because they only ever ask the interface what it promises to answer.

This is the refactor survival property: replace the implementation entirely, and the test suite still tells you whether the new one honors the contract.

## Testing Invariants, Not Implementations

Look at this scenario:

```go
t.Run("renaming to an existing collection's name returns ErrDuplicateName and leaves both unchanged", func(t *testing.T) {
    repo := newRepo()

    a, err := repo.Create("alpha", "a")
    require.NoError(t, err)
    b, err := repo.Create("beta", "b")
    require.NoError(t, err)

    err = repo.Rename(b.ID, "alpha")
    require.ErrorIs(t, err, collection.ErrDuplicateName)

    collections, err := repo.List()
    require.NoError(t, err)
    require.Len(t, collections, 2)

    byID := map[string]collection.Instance{}
    for _, c := range collections {
        byID[c.ID] = c
    }
    require.Equal(t, "alpha", byID[a.ID].Name)
    require.Equal(t, "beta", byID[b.ID].Name)
})
```

The assertion is not "the rename function returned an error." It is "after a failed rename, both collections are exactly as they were." That is an invariant: failed operations do not mutate state. An in-memory repo that uses a naive "delete then insert" rename could easily leak through a weaker test. This one catches it.

Same for case sensitivity:

```go
t.Run("name uniqueness is case-insensitive", func(t *testing.T) {
    repo := newRepo()
    _, err := repo.Create("vim", "")
    require.NoError(t, err)

    _, err = repo.Create("VIM", "")
    require.ErrorIs(t, err, collection.ErrDuplicateName)
    // ...
})
```

An SQL version using a case-sensitive column collation would pass all the other tests and silently violate this one. That is the point.

## Error Identity, Not Error Strings

The tests check error identity with `errors.Is`:

```go
require.ErrorIs(t, err, collection.ErrDuplicateName)
require.ErrorIs(t, err, collection.ErrNotFound)
require.ErrorIsf(t, err, collection.ErrEmptyName, "name=%q", name)
```

Not `err.Error() == "collection: duplicate name"`. Error messages are for humans and can change. Sentinel errors are part of the contract and can be wrapped with context by implementations without breaking the check.

This also means an SQL implementation that returns `fmt.Errorf("inserting row: %w", ErrDuplicateName)` still passes. The wrapping adds context without breaking callers.

## Table-Driven Variants Inside a Scenario

When the same behavior applies to multiple inputs, the loop stays inside the subtest:

```go
t.Run("creating with an empty or whitespace-only name returns ErrEmptyName and does not insert", func(t *testing.T) {
    for _, name := range []string{"", "   "} {
        repo := newRepo()

        _, err := repo.Create(name, "desc")
        require.ErrorIsf(t, err, collection.ErrEmptyName, "name=%q", name)

        collections, err := repo.List()
        require.NoError(t, err)
        require.Emptyf(t, collections, "after rejected Create(%q)", name)
    }
})
```

Fresh `repo` per iteration. The `f`-suffixed asserts (`ErrorIsf`, `Emptyf`) tag the failure with the offending input so a broken case is obvious without rerunning under a debugger.

## The Payoff

The immediate benefit is obvious: when the persistent repository lands, you get its test suite for free.

The subtler benefit is that the test suite has become a machine-checkable specification of the interface. A new implementation is not "done" when it compiles. It is done when `testRepositoryContract` passes. The invariants in the interface doc comment and the scenarios in the test suite are the same statement, written once for humans and once for the compiler.

That is what "interface contract" should mean in practice.
