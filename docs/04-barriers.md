# 04 - Barriers

Zindex is shaped around walls that cannot be removed. This document states them plainly so that
nobody builds on a false premise, and so the architecture's claims stay honest.

## 1. The walls, and the architectural response

| Wall | Architectural response | What stays impossible |
| --- | --- | --- |
| Fixed memory budget, smaller on weak devices | Density: 4 bytes per register, 1 byte per RAM byte, no GC-scanned machine state. A machine fits in roughly 20-30x less memory than a table-based design. | Total memory cannot be increased. There is no allocator API and there never will be. |
| `--!native` is server-side only today | Cores are pure, typed, engine-free functions, so they run interpreted on the client now, natively on the server today, and natively on the client later with one directive. | Client-side native speed is not available yet. |
| One displayed EditableImage per frame | Double-buffered framebuffer device, dirty rects, exactly one blit per frame. | More than one framebuffer present per frame is impossible. |
| No shaders, no compute, no GPU access | Rendering is out of scope for the ISA. The guest writes pixels to an MMIO framebuffer; the host chooses how to display them. | The GPU can never be used for guest computation. No shader path exists. |
| No shared mutable objects across Actors | Shared memory is an explicit SharedTable word region with its cost stated; hot state stays in private buffers. | Shared RAM can never be as fast as private RAM. |
| Watchdog kills long non-yielding loops | Cycle-budget scheduler with `run(budgetCycles)` and cooperative yields. | A core can never run unbounded between yields. |
| No client storage; server storage is small and rate-limited | Images are a single buffer; persistence is explicitly a host concern. | Zindex cannot give a guest a disk. |
| No sample-accurate audio API | AUDIO is a ring buffer descriptor; the host decides how to voice it. | Bit-exact PCM output is not achievable. |

## 2. What Zindex does not claim

- It does not provide more RAM. Nothing does.
- It does not unlock GPU compute. Nothing does.
- It does not make the client run native code today.
- It does not remove the one-image-per-frame rule.
- It does not make emulation of existing hardware fast by itself. It provides a substrate designed
  so a compiler can target it efficiently, which is a different and narrower claim.

## 3. What Zindex does claim

- An ISA whose encoding costs no shift/mask work per instruction in Luau.
- Machine state at 1 byte per RAM byte and 4 bytes per register, with no GC pressure.
- A hardware float/vector unit that is literally Luau's native vector math.
- Deterministic execution: exact save states, exact replay, rollback.
- A scheduler that cannot trip the watchdog.
- Multi-core with the cost of sharing stated rather than hidden.
- Typed and native-ready from line one, so the client-native speedup is one directive away.

## 4. Why this is not an emulator

An emulator pays a permanent translation tax: it must reproduce foreign hardware exactly,
including the parts the host is worst at. Zindex has no foreign hardware to reproduce. It is a
machine designed for its substrate, so every instruction is cheap on the host by construction,
and any guest is compiled *to* it rather than translated *through* it.

That inversion is the entire point, and it is also the honest limit: Zindex does not make old
hardware faster. It makes a new machine possible.

## 5. Heterogeneous non-claims

Adding a raster unit and a tensor unit does not change the walls. Specifically:

- The GPU unit is a **software rasteriser**. It is not GPU hardware and it never will be; every
  pixel is host work (doc 06 section 5).
- The NPU unit is **3-lane float32 vector maths** fanned across Actors. It is not matrix hardware,
  and there is no INT8 tensor core (doc 07 sections 2 and 4).
- Adding units does not add memory. All units draw from the same fixed client budget.
- More units does not mean more throughput than the host can supply. Throughput is bounded by
  interpreted instruction rate times busy cores (doc 08 section 2).
