# Changelog

All notable changes to TagBehaviorService will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.3.0] - 2026-03-02

### Changed

- **Breaking:** `subscribe(tag, factory, opts?)` is now `subscribe(tag, factory, predicate?)`. The options table is replaced by a single optional predicate function.
- `BehaviorDefinition` simplified — `className` and `defer` fields removed, only `tag?`, `factory`, and `predicate?` remain.
- `getContext()` removed — use `isActive()` instead.

### Removed

- `SubscribeOptions` type — no longer needed.
- `ContextInfo` type — no longer needed.
- `defer` option and all deferred attach/cancellation logic.
- `className` option — use a predicate with `instance:IsA()` instead.

## [0.2.0] - 2026-03-02

### Added

- `registerFolder(folder)` helper — auto-registers every descendant `ModuleScript` as a tag subscription.

## [0.1.0] - 2026-03-02

### Added

- Singleton `TagBehaviorService` module — `require` and use, no `.new()` needed.
- `subscribe(tag, factory, opts?)` with `className`, `predicate`, and `defer` options.
- `start()` to activate all subscriptions.
- `isStarted()`, `getContext()`, `isActive()`, `getActiveCount()` introspection helpers.
- Idempotent unsubscribe functions returned from `subscribe`.
- `pcall`-wrapped error isolation for factory, cleanup, and predicate callbacks with `warn` logging.
- At-most-once cleanup guarantee per activation.
- Race-safe handling for rapid add/remove/add, unsubscribe-while-pending, and deferred cancellation.
- `Instance.Destroying` listener for cleanup on instance destruction without explicit untag.
- `.new()` available via metatable for test isolation and multi-scope use.
- Comprehensive test suite covering all public API and edge cases.
- README with quickstart, full API reference, lifecycle diagram, and usage examples.
