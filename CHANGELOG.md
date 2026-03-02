# Changelog

All notable changes to TagBehaviorService will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0] - 2026-03-02

### Added

- Added `registerFolder(folder)` helper — auto-registers every descendant `ModuleScript` as a tag subscription. Modules can return a plain factory function (tag = module name) or a `BehaviorDefinition` table with optional `tag`, `className`, `predicate`, `defer` fields.

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
