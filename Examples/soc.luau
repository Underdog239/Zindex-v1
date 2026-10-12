--[[
	Zindex example: full heterogeneous SoC & Tier 0 / Tier 1 / Tier 2 benchmark.

	Demonstrates:
	  1. Tier 0 (dispatch loop) vs Tier 1 (basic-block compiler) vs Tier 2
	     (native block compiler + strength-reduced shifts) executing the same
	     guest workload with byte-identical results and measured throughput.
	  2. A 4-core Z-CPU cluster partitioning work via IPC `coreId`, accumulating
	     into shared memory (`sws` / `amoadd`), and synchronizing on `sync`.
	  3. Guest machine code feeding both the Z-NPU (3-lane GEMM + ReLU) and the
	     Avalon R1 GPU (4-tile rasterisation + bulk scanline composite) in one frame.

	From the command line:
		python3 Tests/bundle.py Examples/soc.luau && luau --codegen Tests/debug.luau
]]

local Zindex = __mods and __mods.Zindex or require(game.ReplicatedStorage.Zindex)

--=====================================================================
-- 1. Tier 0 vs Tier 1 vs Tier 2 benchmark
--=====================================================================

local benchSource = [[
		.equ ITERATIONS, 20000
		li r1, 0x4000
		li r2, 0
		li r3, ITERATIONS
		li r4, 0x9E3779B9
		li r5, 0
	loop:
		shli r6, r2, 3
		shri r7, r5, 2
		xor r8, r6, r7
		add r5, r5, r4
		xor r5, r5, r8
		andi r9, r2, 63
		shli r9, r9, 2
		add r10, r1, r9
		sw r5, 0(r10)
		addi r2, r2, 1
		bltu r2, r3, loop
		halt
]]

local results = {}
for _, tier in { 0, 1, 2 } do
	local chip = Zindex.new({ ramSize = 0x10000, tier = tier })
	chip:assemble(benchSource)
	local t0 = os.clock()
	local cycles = chip:run(2000000)
	local elapsed = math.max(1e-6, os.clock() - t0)
	results[tier] = {
		hash = chip:reg(5),
		cycles = cycles,
		steps = chip.core.steps,
		ms = elapsed * 1000,
		mips = (chip.core.steps / elapsed) / 1e6,
		blocks = chip.core.stats.blocksCompiled,
	}
end

print('--- Execution tiers (20,000 loop iterations) ---')
for _, tier in { 0, 1, 2 } do
	local r = results[tier]
	print(
		string.format(
			'Tier %d: %6.2f ms | %6.2f M instr/s | cycles=%d | blocks=%d | checksum=0x%08X',
			tier,
			r.ms,
			r.mips,
			r.cycles,
			r.blocks,
			r.hash
		)
	)
end
assert(results[0].hash == results[1].hash and results[1].hash == results[2].hash, 'tier checksum mismatch')
assert(results[0].cycles == results[1].cycles and results[1].cycles == results[2].cycles, 'tier cycle mismatch')

--=====================================================================
-- 2. 4-core Z-CPU cluster with shared memory and SYNC barrier
--=====================================================================

local cluster = Zindex.new({ ramSize = 0x10000, coreCount = 4, sharedWords = 64 })
cluster:assemble[[
		li r1, 0x0F004000
		lw r2, 0(r1)         ; coreId (0..3)
		addi r3, r2, 1
		muli r4, r3, 25      ; each core produces (coreId + 1) * 25
		sws r4, 0(r2)        ; shared[coreId] = partial result
		li r5, 16
		amoadd r6, r5, r4    ; shared[16] += partial result (atomic)
		sync                 ; wait for all 4 cores
		halt
]]
cluster:run(10000)
print(string.format('4-core atomic reduction: %d (barrierGen=%d)', cluster:readShared(16), cluster.devices.ipc.barrierGen))

--=====================================================================
-- 3. Heterogeneous SoC frame: Z-NPU GEMM + 4-tile Avalon R1 GPU
--=====================================================================

local soc = Zindex.new({
	ramSize = 0x20000,
	width = 32,
	height = 32,
	back = 0x10000,
	depth = 0x12000,
	tileCount = 4,
})

soc:assemble[[
		-- Kick the Z-NPU queue (GEMM 2x2 = (2x3) * (3x2) + bias with ReLU)
		li r1, 0x0F007000
		li r2, npuQueue
		sw r2, 0(r1)
		li r2, 1
		sw r2, 4(r1)
		sw r2, 8(r1)

		-- Kick the GPU queue (CLEAR + 4-tile DRAW_MESH + PRESENT)
		li r3, 0x0F006000
		li r4, gpuQueue
		sw r4, 0(r3)
		li r4, 3
		sw r4, 4(r3)
		li r4, 1
		sw r4, 8(r3)
		halt

		.org 0x6000
	matA:
		.f32 1.0, 2.0, 3.0
		.f32 4.0, -5.0, 1.0
	matB:
		.f32 2.0, 0.0
		.f32 1.0, 3.0
		.f32 0.5, -1.0
	bias:
		.f32 0.5, 1.0
		.org 0x6100
	matC:
		.zero 16

		.org 0x6200
	mvp:
		.f32 1.0, 0.0, 0.0, 0.0
		.f32 0.0, 1.0, 0.0, 0.0
		.f32 0.0, 0.0, 1.0, 0.0
		.f32 0.0, 0.0, 0.0, 1.0
	positions:
		.f32 -0.75, -0.75, 0.0
		.f32  0.75, -0.75, 0.0
		.f32  0.0,   0.75, 0.0
	mesh:
		.word 3, positions, 0, 0, 0, 3

		.org 0x6400
	npuQueue:
		.word 3, matA, matC, 2, matB, bias, 0, 1, 2, 3, 0, 0
	gpuQueue:
		.word 1, 0xFF101018, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
		.word 3, mesh, 0, 0, mvp, 0, 0, 1, 0, 0, 0, 0
		.word 4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
]]

soc:run(5000)

local ram = soc:ram()
print(
	string.format(
		'Z-NPU GEMM C = [%.1f, %.1f; %.1f, %.1f] (%d 3-lane vector ops)',
		buffer.readf32(ram, 0x6100),
		buffer.readf32(ram, 0x6104),
		buffer.readf32(ram, 0x6108),
		buffer.readf32(ram, 0x610C),
		soc.npu.stats.vectorOps
	)
)
print(
	string.format(
		'Avalon GPU: %d fragments written across %d composited tiles, present=%s',
		soc.gpu.raster.stats.drawn,
		soc.gpu.raster.stats.tilesComposited,
		tostring(soc.devices.framebuffer.presentRequested)
	)
)
