# AGENTS.md

Guidance for AI agents (Claude Code and others) working in this repo. Human
contributors: see `CONTRIBUTING.md` — this file does not replace it, it sharpens
the parts agents get wrong.

## What Hyper is

A distributed orchestrator for Firecracker microVMs, written on the BEAM
(Elixir `~> 1.20`, OTP 28+). A small privileged Rust setuid helper
(`native/suidhelper/`, crate `hyper_suidhelper`) performs the Linux operations
the BEAM cannot do safely (losetup, dmsetup, chroot jails, device nodes).
Postgres is the only external runtime dependency (the image database).

## Commands

```sh
mix check        # THE gate. Must pass before any PR. Runs, in order:
                 #   format --check-formatted   (formatting is not optional)
                 #   compile --warnings-as-errors --force
                 #   credo --strict
                 #   test --warnings-as-errors
                 #   dialyzer                    (strict; @specs required)
mix test                              # Elixir suite (needs Postgres for DB tests)
mix test test/unit test/controls      # pure tests, no Postgres/Firecracker needed
cargo nextest run                     # Rust suite (run inside native/suidhelper/)
```

Pure tests under `test/unit` and `test/controls` need neither Postgres nor
Firecracker. DB-backed tests need `mix ecto.create && mix ecto.migrate` first.

## Layout

- `lib/` — Elixir source. Tests in `test/` mirror this tree.
- `lib/unit/`, `lib/controls/`, `lib/sys/linux/proc/`, `lib/hyper/redist/` —
  **pure cores**: units algebra, EWMA/rate controls, `/proc` parsers, hashing.
  No processes, no I/O. These are where property tests pay off most.
- `native/suidhelper/` — the privileged Rust helper. Source in `src/`, tests in
  `tests/` (see Rust rules below).
- Generated, do not hand-edit: `lib/hyper/firecracker/api/{operations,schemas}`
  (regen `mix firecracker.gen`) and `lib/hyper/grpc/v0/hyper.pb.ex`
  (regen `mix grpc.gen`). Both are gitignored and rebuilt by a Mix compiler.

## Testing philosophy — read this before writing any test

**A good test proves the spec, not that the code ran.** Writing a passing test
is not the goal; writing a test that would *fail if the behavior were wrong* is.
Before adding a test, ask: "what does this module promise, and what input could
break that promise?" If a test cannot fail for any realistic implementation bug,
it proves nothing — delete it.

### Prefer property-based tests. Find the invariants.

StreamData (Elixir) and proptest (Rust) are already wired in. For any pure
function — parsers, codecs, algebra, validators, hashing, scheduling math —
**reach for a property test first**. The work is identifying the invariant. Hunt
for these families (the existing suites are worked examples of each):

- **Round-trip / inverse** — `parse(render(x)) == x`, `decode(encode(x)) == x`,
  `with_value(value(q)) == q`. See `test/unit/quantity_properties_test.exs`,
  `test/sys/linux/proc/stat_properties_test.exs`,
  `native/suidhelper/tests/util/safe_path.rs` (`relative_to` reconstructs).
- **Algebraic laws** — commutativity, associativity, identity, inverse, total
  order. See the additive-group laws in `quantity_properties_test.exs`.
- **Oracle / model** — the result equals an independent reference computation
  (`CpuTimes.total == Enum.sum(cols)`).
- **Invariant preserved** — a property that holds for *every* output regardless
  of input (a confined path never contains `..`; a refcount is never negative).
- **Idempotence / metamorphic** — `f(f(x)) == f(x)`; or a known input change
  produces a known output change.
- **Error & refusal contracts** — invalid input *always* raises/returns the
  specific error, and is never silently accepted. This is a property too: see
  "mixing two dimensions always raises" and `rejects_any_loose_component`.
  For security-sensitive code (the setuid helper, path confinement) the refusal
  property is the *most* important test in the file.

State the laws under test in the module's `@moduledoc` (or a Rust `//!` doc),
the way the existing property suites do — it forces you to name the contract.

### When an example test is the right tool

Property tests are not a religion. Use a plain example/smoke test when:

- the behavior has no meaningful input space to generate over (a specific
  parse of one real `/proc/meminfo` fixture, one gRPC round-trip);
- you are pinning one concrete edge case or regression;
- generating valid inputs would be more code (and more bugs) than the thing
  under test.

A few good examples that exercise real logic beat a generator that only ever
hits the happy path. Pair them: properties for the laws, examples for the
representative cases and the nasty edges.

### Do not write slop

These will be asked to be removed (per `CONTRIBUTING.md`):

- one-assertion-per-getter / setter tests that restate the struct definition;
- tests asserting on mocks you set up in the same test (proves the mock, not
  the code);
- tautologies — `assert f(x) == f(x)`, or recomputing the implementation inside
  the assertion;
- snapshot/coverage-padding tests with no invariant behind them;
- a `property` block whose generator is so narrow it only emits one value.

Coverage is a side effect of good tests, never the target.

### Elixir specifics

- `use ExUnit.Case, async: true` and `use ExUnitProperties` for property suites.
- Naming convention already in the tree: `*_properties_test.exs` for the
  property suite of a module, `*_test.exs` for its example tests (often both
  exist side by side, e.g. `sha256_test.exs` + `sha256_properties_test.exs`).
- Build generators by composing the module's own constructors (see how
  `quantity/0` maps scalars through `Information.bytes/1` etc.) — generate valid
  inputs by construction rather than generating-then-filtering.
- **`StreamData` gotcha:** an empty `integer(a..b)` range (when `a > b`) raises
  at generation time and aborts the whole `check all`, it does not re-generate.
  Bound the parent generator so the range is always non-empty.

### Rust specifics (`native/suidhelper/`)

- **Tests live in `tests/`, never inline `#[cfg(test)]` in `src/`.** The crate
  is split into a lib (`src/lib.rs`, crate `hyper_suidhelper`) and a thin bin
  (`src/main.rs`) precisely so integration tests can reach the internals.
- Each test file must be registered as a `[[test]]` target in `Cargo.toml`
  (`tests/` subdirectories are not auto-discovered) — copy an existing
  `[[test]]` block when adding one.
- `proptest` is the dev-dependency; use `proptest!{ #[test] fn ... }` with
  `prop_assert!`. CI runs `cargo nextest run --profile ci` (one retry to damp
  flakes — do not write tests that *rely* on the retry).

## Other conventions

- **NEVER write section-divider banners** — comments like `// --- foo ---`,
  `# === bar ===`, `// ---- Tests ----`, or any comment whose job is to label a
  region of a file. They are a code smell: reaching for one is a signal that
  the file is doing too many things at once. When you feel the urge, do NOT
  write the banner — make the underlying decision instead:
    1. **Split it out.** If the regions are genuinely distinct
       responsibilities, they belong in separate modules/files (or, for tests,
       separate test files or submodules). Extract them.
    2. **Or drop the comment entirely.** If the code is already cohesive, the
       banner adds nothing a reader can't see from the names — delete it. A
       blank line is sufficient separation.
  There is no third option where the banner stays.
- **Comments earn their place.** No comment that just restates what the next
  line does. A comment explains a non-obvious *why* a reader cannot recover
  from the code — a workaround, an invariant, a deliberate trade-off. Prefer
  self-documenting code: a named function, a `Unit.*` quantity instead of a
  bare `1024 * 1024`, a descriptive variable — over a comment narrating the
  mechanics. If you reach for a comment to explain *what*, rename the thing
  instead.
- Don't hand-roll magic numbers for sizes/durations/bandwidth: use the
  `Unit.*` types (`Unit.Information.mib(8)`, not `8 * 1024 * 1024`) and
  `use Unit.Operators` for unit-aware arithmetic.
- Add `@spec` to public functions. Dialyzer runs with `:unmatched_returns`,
  `:extra_return`, `:missing_return` and will fail the gate on a missing/wrong
  spec.
- Zero compiler warnings — `--warnings-as-errors` is enforced.
- Conventional Commits, scoped to subsystem: `feat(fire_vmm): ...`,
  `fix(redist): ...`, `test(unit): ...`, `docs: ...`.
- Do not commit generated bindings or hand-edit them; commit the source
  artifact (the `.proto` / OpenAPI spec), not the output.
