# 03 - Execution Model

## 1. Three tiers, one ISA

**Tier 0 - dispatch loop.** A switch on the opcode byte, reading operands from the code buffer,
registers in a buffer, PC in a local. This is the baseline and the reference semantics.

**Tier 1 - block compiler.** Decode each basic block once into a flat sequence or a Luau closure,
cache it by PC, and run it repeatedly. This amortizes decode, which is a large share of Tier 0
cost. Invalidate on any write into the code region.

**Tier 2 - native.** Mark core functions `@native`. The ISA's byte-aligned encoding and
buffer-based state are exactly what the native backend handles best. Tier 0 and Tier 1 are the
same source; Tier 2 is a directive, not a rewrite.

The design constraint that makes Tier 2 possible at all: the core is a pure function of machine
state. It calls no engine APIs, allocates nothing per instruction, and keeps no closures in the
hot path. That is what lets the same code run interpreted on the client today, natively on the
server now, and natively on the client when that becomes available.

## 2. Timing contract

- The cycle counter is core state. Monotonic, never wall-clock derived.
- Base cost: 1 cycle per instruction.
- Memory access: +1 cycle, +2 on a region crossing.
- VFU operation: +2 cycles.
- Device register access: +4 cycles.
- The guest reads the counter through the TIMER device.

A stable, defined cost model is what makes timing-sensitive guests possible at all. Wall-clock
time must never enter the core, or determinism dies and every guarantee in section 4 with it.

## 3. Scheduler

The host drives the chip, not the other way around:

```
chip:run(budgetCycles) -> cyclesUsed
```

The host computes a budget per frame from measured frame time, calls `run`, and returns. The core
yields at the end of the budget or earlier on YIELD, so the watchdog is never tripped: there is
no long non-yielding loop for it to kill. This is architectural, not a workaround.

Supported modes: catch-up (extra budget after a hitch), fast-forward (larger budget), single-step
(budget of one instruction), and pause. Because execution is deterministic, a fixed budget yields
a byte-identical machine state every time.

## 4. Save states, replay, rollback

`chip:snapshot()` captures every core's registers and control state, private RAM, device register
files, shared memory, GPU/NPU queues and counters, and host-visible present count. `chip:restore(state)`
requires a compatible chip with the same RAM size, core count, shared-memory shape, and optional-GPU
presence; it restores those values and invalidates compiled blocks so they are rebuilt from RAM.
The snapshot is an in-memory Lua table containing cloned buffers; applications that need
persistence must serialize that table using their chosen storage format. Take snapshots at a
scheduler safe point with all cores quiescent so shared memory is consistent.

Host callbacks and compiled code caches are intentionally not serialized. With deterministic
execution and the same callback behavior, replay is exact. This enables rewind and rollback: keep
the last N states and re-simulate forward.

## 5. Native-readiness rules

These are ISA-level rules, because violating one silently drops the core back to the interpreter
and takes the architecture's entire performance claim with it.

- No getfenv/setfenv anywhere in the core.
- Every function fully typed; no untyped parameters, no type violations at call sites.
- No variadics in hot paths.
- No table indexing, no string operations, no allocations per instruction.
- Machine state lives in buffers, never tables.
- Strength-reduce constant shifts to multiply/divide.
- Respect the code-size limits: 64K instructions per block, 32K blocks per function, 1M
  instructions per module, plus a per-game native code memory budget. Split cores across modules
  rather than blowing the module limit.
- Measure with the Script Profiler. A function that is not running natively is a bug.

## 6. Multi-core execution

A chip is a group of N cores. Each core is an Actor running its own `run` loop with its own cycle
budget. Private RAM per core, shared region per doc 02, SYNC as the barrier.

Cores must be designed so that a single-core configuration is a legal configuration: the same
image runs on 1 or N cores, and a compiler can target both without a second code path.
