# 00 - Overview

## 1. Why Zindex exists

Roblox's emulation scene fights the same walls every single time:

1. A fixed memory budget set by the platform, smaller on weak devices.
2. An interpreter-only CPU budget on the client (`--!native` is server-side today).
3. Only one displayed EditableImage can be updated per frame.
4. No shaders, no compute, no GPU access at all.
5. A watchdog that kills long non-yielding loops.

Every project rediscovers these alone, then ports a foreign ISA (6502, SM83, Z80) whose
assumptions actively fight the host: bit-packed encodings needing shift/mask per operand,
table-shaped memory, 64-bit arithmetic, status flags, and per-instruction bit twiddling.

Zindex inverts that. It is an instruction set architecture whose widths, encoding, register
layout, memory model and timing contract were all chosen because of what Luau is fast and slow
at. The guest pays for nothing the host cannot do well.

## 2. What this is and is not

It is a chip architecture: registers, an encoding, a memory map, an ABI, a device bus and a
timing contract.

It is not an emulator, not a clone of existing silicon, not a virtual machine for the Luau
language itself, and not a script sandbox. Where it resembles a clean RISC design, that is
because clean RISC encodings happen to be Luau-friendly, not because it is a port.

## 3. Luau is the substrate, so Luau's facts drive the design

| Luau fact | Architectural consequence |
| --- | --- |
| numbers are IEEE doubles; integers exact to 2^53 | word = 32 bits; addresses = 32 bits; no 64-bit ops |
| bitwise ops are the `bit32` *library* (function calls), not operators | byte-aligned encoding: decode needs no shifts or masks |
| shifts are function calls; multiply is not | strength-reduce `shl k` to `mul 2^k` |
| `buffer` = contiguous bytes with C-level read/write | registers and RAM live in buffers, never tables |
| a table number costs ~16-32 bytes and is GC-scanned | no machine state in tables |
| `vector` = 3 x float32 with native arithmetic | a real hardware float/vector unit (VFU) |
| `--!native` compiles typed Luau to machine code (server-side today) | cores stay pure, typed, engine-free: native-ready |
| Actors + SharedTable are the only extra cores | multi-core is designed in; sharing is explicit |
| one displayed EditableImage per frame | double-buffered framebuffer device |
| watchdog kills long non-yielding loops | cycle-budget scheduler is architectural |

## 4. Design principles

1. **32 bits everywhere.** Nothing in Zindex needs 64-bit integers.
2. **Byte-aligned, variable-length encoding.** Every operand starts on a byte boundary.
3. **Registers in a buffer.** 4 bytes per register, dense, invisible to the GC.
4. **Memory is one byte-addressed buffer.** Zero per-byte overhead.
5. **Flagless conditionals.** Branches compare two registers directly; there is no status
   register to serialize, rename, or mis-guess.
6. **A float/vector unit that *is* Luau's native vector math.** Not emulated.
7. **Determinism by construction.** The core reads no wall clock and no randomness. Time is a
   cycle counter.
8. **One explicit host boundary.** A single trap instruction leaves pure computation for host
   services, so the hot loop stays branch-light and native-compilable.
9. **Typed and native-ready from the first line.** No getfenv/setfenv, no variadics in hot
   paths, no engine API calls inside the core.
10. **Multi-core by design**, with the cost of sharing stated honestly instead of hidden.

## 5. Scope of this specification

Defines: ISA, ABI, memory map, device bus, timing contract, execution tiers.

Defers: any concrete device implementation, any guest toolchain, and any program image format
beyond the header sketch in doc 02.

## 6. Naming

`Zindex` is the repository's existing name and is used as the architecture name.
Short form: **Z32**.
