# 09 - Implementation status

What exists in `src/Zindex`, what it has been tested against, and what it does
not do yet. Written so that nobody has to guess.

## 1. What exists

| Module | Role |
| --- | --- |
| `Opcodes.luau` | the instruction set as data: opcode, name, encoding form, size |
| `Memory.luau` | the address space: RAM buffer, device window, trap page, per-access cycle cost |
| `Devices.luau` | the standard device set: DEV, TIMER, INPUT, AUDIO, IPC, FB |
| `Core.luau` | a CPU core: registers, decode, execute, cycle accounting, disassembler |
| `Assembler.luau` | two-pass assembler: labels, expressions, directives, listing |
| `Image.luau` | program image pack and unpack |
| `init.luau` | the public API: build, load, run, snapshot, restore, host calls |
| `RobloxView.luau` | the only file that touches a Roblox API: EditableImage presentation |

Every opcode in doc 01 is implemented, including the whole vector unit. The core
is Tier 0 (the dispatch loop) from doc 03.

## 2. How it is tested

```
python3 Tests/bundle.py && luau Tests/combined.luau
```

`Tests/bundle.py` rewrites `require(script.Parent.X)` into a module table so the
library runs unchanged outside Roblox, then appends `Tests/suite.luau`. The
suite drives the real core through the real assembler; nothing is mocked.

Covered: arithmetic wrapping and 32-bit multiply exactness, shifts including the
32-or-more rule, signed and unsigned comparison, byte/half/word load and store
with sign extension, loops and branches, call and return, the vector unit
end to end, device reads and writes through MMIO, host calls, assembler
directives and label expressions, image round trip, illegal opcode handling,
and save state replay being byte-exact.

The save state test is the important one: it runs a program, snapshots, runs on,
restores, and re-runs, then requires the RAM and the cycle count to match
exactly. That is the determinism claim from doc 03 actually being checked.

## 3. What is not implemented yet

Stated plainly, in the order it would matter:

1. **Tier 1 and Tier 2 execution** (doc 03 sections 1). The core is the dispatch
   loop only. `--!native` is declared on `Core.luau` and is honoured on the
   server, but the block compiler does not exist.
2. **Multi-core.** The IPC device exposes a shared-region descriptor, and `SYNC`
   executes, but no Actor fan-out and no `SharedTable` region exist. One core is
   the only configuration today.
3. **Interrupts.** `Core.onInterrupt` and `Core.irqEnabled` exist and are polled
   every 256 instructions, but no device raises an interrupt yet.
4. **Audio.** The AUDIO page is addressable and inert.
5. **The Avalon raster unit** (doc 06) is specified but not wired in. There is no
   GPU command queue in `Devices` yet, so a guest cannot issue `DRAW_MESH`.
6. **Assembler conveniences**: no macros, no `.equ`, no floating point exponents
   in expressions (a `-` inside `1e-3` would parse as a subtraction).

## 4. Two bugs the tests caught, as evidence they are worth running

- `not` is form F2, which has three operand slots, but it only needs two. The
  assembler demanded all three until the suite failed on `not r9, r0`.
- `Memory` had both a field `ram` and a method `ram`. Because the field exists on
  the instance, `self.memory:ram()` resolved to the buffer and tried to call it.
  The accessor is now `getRam()`.

Both were found by running the suite, not by reading the code.
