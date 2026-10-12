# 07 - Z-NPU (tensor / vector unit)

## 1. What it can honestly be

Roblox exposes no matrix hardware. The highest-throughput numeric primitive available is the
native Luau `vector` (3 x float32) with native arithmetic. The Z-NPU is therefore *defined* as a
unit whose only operations are the ones the host actually accelerates.

| Op | Meaning | Host operation |
| --- | --- | --- |
| VFMA vd, vs, vt | vd = vs * vt + vd | one fused multiply-add |
| VDP3 rd, vs, vt | dot(vs, vt) | one native dot product |
| VRED rd, vs | horizontal sum | three adds |
| VSCL vd, vs, s | scale by scalar | one multiply |
| VMIN / VMAX | component-wise min/max | native |
| VLEN / VNRM | magnitude / normalize | native |

## 2. The 3-lane constraint

Vectors are 3 x float32, so there are 3 lanes. There is no 4-wide mode in the host and no integer
lane packing. A GEMM therefore costs at minimum `ceil(N/3)` vector operations per output element.

That is the honest ceiling of this unit: it accelerates dot products and 3-wide fused
multiply-adds, and nothing else. Any claim beyond it would be false.

## 3. Reaching peak anyway

Peak comes from parallelism, not lane width:

1. Split GEMM output tiles across Actors, one tile per core.
2. Keep operands in structure-of-arrays float buffers and feed the unit with straight-line
   unrolled code, so the native backend can keep values resident.

Throughput becomes (native vector ops per second) x (busy cores), minus the compositing overhead
described in doc 06 section 4.

## 4. Int8 quantisation

Float32 vectors cannot pack int8 lanes, so quantised inference is *emulated*: unpack with a
multiply-add by a scale factor. It works, and it is slower than the float path. It is therefore
worth doing only when it reduces memory pressure - never because it is expected to be faster.
State that plainly rather than implying an INT8 tensor core exists.

## 5. What the NPU is for

Not general compute. It is sized for: geometry and transforms, normalisation, lighting
accumulation, soft-body and particle maths, small MLP inference, and audio DSP blocks. It is a
co-processor, and it is specified as one.

## 6. Command queue interface (`src/Zindex/Npu.luau`)

Implemented on page `0x0F007000`, fed with the same 48-byte command format as the GPU:

| Op | Meaning |
| --- | --- |
| `NOP` (0) | nothing |
| `DOT_BATCH` (1) | batch of `count` 3D dot products (`dst[i] = dot(src[i], matrix[i])`) |
| `FMA_BATCH` (2) | batch of `count` 3-lane fused multiply-adds (`mode=0` vector*vector+aux, `mode=1` vector*scalar+aux, optional ReLU) |
| `GEMM` (3) | 3-lane tiled `C[M x N] = A[M x K] * B[K x N] + bias` with optional ReLU (`flags` bit 0) |
| `NORM_BATCH` (4) | batch normalize `count` float3 vectors |
| `DEQUANT_INT8` (5) | unpack `count` signed int8 values to float32 via `q * scale + bias` |
| `DMA_COPY` (6) | bulk `buffer.copy` of `count` bytes from `src` to `dst` |
| `DMA_FILL` (7) | bulk `buffer.fill` of `count` bytes at `dst` with byte `src` |

