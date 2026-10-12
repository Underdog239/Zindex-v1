--!nonstrict
--!native
--[[
	Raster - the Z32 raster unit (docs/06-gpu-avalon.md).

	Scanline edge-function rasteriser writing packed RGBA8 words into a colour
	buffer, with a separate f32 depth plane storing 1/w. Implements the pipeline
	documented for Avalon R1:

		MVP transform -> near-plane clip -> perspective divide -> back-face cull
		-> edge-function raster with depth test -> attributes divided by 1/w

	Also implements multi-tile rendering into tile-local colour/depth buffers
	followed by per-scanline `buffer.copy` compositing (docs/06-gpu-avalon.md
	section 4), and dynamic resolution resizing for adaptive scale control.

	Everything is a buffer, nothing is allocated per triangle, and the module
	touches no engine API.
]]

local Memory = require(script.Parent.Memory)

local Raster = {}
Raster.__index = Raster

-- Shading modes
Raster.FLAT = 0
Raster.GOURAUD = 1
Raster.TEXTURED = 2
Raster.MAX_WORK = 1000000
-- Work is measured in screen-space candidate pixels, submitted triangles and
-- tiled viewport copying, so a frame's real cost scales with the viewport. The
-- per-pump budget therefore has a fixed floor plus a per-pixel allowance: a
-- fixed 1,000,000-unit ceiling would reject every CLEAR and every tiled draw on
-- any viewport above 500,000 pixels.
Raster.WORK_PER_PIXEL = 8
Raster.MAX_TRIANGLES = 8192
Raster.MAX_VERTICES = 1000000
Raster.MAX_TEXTURE_PIXELS = 1048576

--- Per-pump work budget for a viewport, in work units.
function Raster.budgetFor(width: number, height: number): number
	local pixels = width * height
	if pixels ~= pixels or pixels <= 0 then
		return Raster.MAX_WORK
	end
	return math.max(Raster.MAX_WORK, Raster.WORK_PER_PIXEL * pixels)
end

local function bufferRangeFits(target: buffer, address: number, size: number): boolean
	if address ~= address or size ~= size or address % 1 ~= 0 or size % 1 ~= 0 then
		return false
	end
	if address < 0 or size < 0 or address > buffer.len(target) then
		return false
	end
	return size <= buffer.len(target) - address
end

local function finiteOrZero(value: number): number
	if value ~= value or value == math.huge or value == -math.huge then
		return 0
	end
	return value
end

local function packRGBA(r: number, g: number, b: number, a: number): number
	return r + g * 256 + b * 65536 + a * 16777216
end

function Raster.new(memory: Memory.Class, width: number, height: number, colour: buffer, depth: buffer, colourBase: number?, depthBase: number?): any
	local self = setmetatable({}, Raster)
	self.memory = memory
	self.width = width
	self.height = height
	self.colour = colour
	self.depth = depth
	self.colourBase = colourBase or 0
	self.depthBase = depthBase or 0
	self.scissorX = 0
	self.scissorY = 0
	self.scissorW = width
	self.scissorH = height
	self.cull = true
	self.stats = { triangles = 0, drawn = 0, culled = 0, clipped = 0, fragments = 0, tilesComposited = 0, workLimitHits = 0 }
	self.workRemaining = nil
	self.workLimitHit = false

	-- Scratch, sized for one clipped triangle (a triangle clipped by a single
	-- plane has at most four vertices). Allocated once, reused forever.
	self.cx = table.create(4)
	self.cy = table.create(4)
	self.cw = table.create(4)
	self.cr = table.create(4)
	self.cg = table.create(4)
	self.cb = table.create(4)
	self.ca = table.create(4)
	self.cu = table.create(4)
	self.cv = table.create(4)
	self.matrixValues = table.create(16)
	self.ax = table.create(3)
	self.ay = table.create(3)
	self.az = table.create(3)
	self.aw = table.create(3)
	self.ar = table.create(3)
	self.ag = table.create(3)
	self.ab = table.create(3)
	self.aa = table.create(3)
	self.au = table.create(3)
	self.av = table.create(3)
	self.sxf = table.create(4)
	self.syf = table.create(4)
	self.siw = table.create(4)
	self.spr = table.create(4)
	self.spg = table.create(4)
	self.spb = table.create(4)
	self.spa = table.create(4)
	self.spu = table.create(4)
	self.spv = table.create(4)
	return self
end

function Raster:resize(width: number, height: number)
	self.width = width
	self.height = height
	self.scissorX = 0
	self.scissorY = 0
	self.scissorW = width
	self.scissorH = height
end

function Raster:setScissor(x: number, y: number, w: number, h: number)
	local x0 = math.clamp(math.floor(finiteOrZero(x)), 0, self.width)
	local y0 = math.clamp(math.floor(finiteOrZero(y)), 0, self.height)
	local right = math.clamp(math.floor(finiteOrZero(x) + math.max(0, finiteOrZero(w))), 0, self.width)
	local bottom = math.clamp(math.floor(finiteOrZero(y) + math.max(0, finiteOrZero(h))), 0, self.height)
	self.scissorX = x0
	self.scissorY = y0
	self.scissorW = math.max(0, right - x0)
	self.scissorH = math.max(0, bottom - y0)
end

--- Fill the colour plane with one packed word and clear depth to 0. Returns
--- false without touching memory if either plane or the bounded work budget fails.
function Raster:clear(word: number): boolean
	local colour: buffer = self.colour
	local depth: buffer = self.depth
	local width: number = self.width
	local height: number = self.height
	local stride: number = width * 4
	local colourBase: number = self.colourBase
	local depthBase: number = self.depthBase
	local scX: number = self.scissorX
	local scY: number = self.scissorY
	local scW: number = self.scissorW
	local scH: number = self.scissorH
	local planeBytes = height * stride
	-- The colour fill is one word per pixel; the depth clear is a bulk
	-- `buffer.fill` per row, so it is charged per row rather than per pixel.
	local work = scW * scH + height
	local remaining = self.workRemaining or Raster.budgetFor(width, height)
	if not bufferRangeFits(colour, colourBase, planeBytes)
		or not bufferRangeFits(depth, depthBase, planeBytes)
		or work > remaining
	then
		return false
	end

	-- buffer.fill writes a *byte* value, so a packed colour has to be written
	-- one 32-bit word at a time. Filling with the word would silently write
	-- only its low byte.
	for row = 0, scH - 1 do
		local offset = colourBase + (scY + row) * stride + scX * 4
		for _ = 1, scW do
			buffer.writeu32(colour, offset, word)
			offset += 4
		end
	end
	for row = 0, height - 1 do
		buffer.fill(depth, depthBase + row * stride, 0, stride)
	end
	if self.workRemaining ~= nil then
		self.workRemaining -= work
	end
	return true
end

function Raster:resetStats()
	self.stats.triangles = 0
	self.stats.drawn = 0
	self.stats.culled = 0
	self.stats.clipped = 0
	self.stats.fragments = 0
	self.stats.tilesComposited = 0
	self.stats.workLimitHits = 0
end

--=====================================================================
-- Drawing
--=====================================================================

local function byteFromUnit(value: number): number
	local scaled = value * 255 + 0.5
	if scaled <= 0 then
		return 0
	elseif scaled >= 255 then
		return 255
	end
	return math.floor(scaled)
end

--- For values already scaled to 0..255.
local function byteFromScaled(value: number): number
	if value <= 0 then
		return 0
	elseif value >= 255 then
		return 255
	end
	return math.floor(value + 0.5)
end

--- Transform one vertex into clip space and store it.
--- Row-major flat 16-number matrix (1-based array `m[1..16]`), column-vector
--- convention: the translation lives in elements 4, 8, 12 (0-based 3, 7, 11)
--- and the projection row in 13..16 (0-based 12..15).
local function transformVertex(m: { number }, ax: { number }, ay: { number }, az: { number }, aw: { number }, index: number, x: number, y: number, z: number)
	ax[index] = m[1] * x + m[2] * y + m[3] * z + m[4]
	ay[index] = m[5] * x + m[6] * y + m[7] * z + m[8]
	az[index] = m[9] * x + m[10] * y + m[11] * z + m[12]
	aw[index] = m[13] * x + m[14] * y + m[15] * z + m[16]
end

--- Draw a mesh. Returns the number of triangles that reached the rasteriser
--- and whether all guest-controlled inputs were valid.
function Raster:drawMesh(meshAddress: number, matrixAddress: number, shading: number, textureAddress: number, cull: boolean?, near: number?): (number, boolean)
	local memory = self.memory
	local ram: buffer = memory.ram
	local viewportBytes = self.width * self.height * 4
	if not memory:containsRange(meshAddress, 24)
		or not memory:containsRange(matrixAddress, 64)
		or not bufferRangeFits(self.colour, self.colourBase, viewportBytes)
		or not bufferRangeFits(self.depth, self.depthBase, viewportBytes)
	then
		return 0, false
	end
	local vertexCount: number = memory:read32(meshAddress + 0x00)
	local positionAddress: number = memory:read32(meshAddress + 0x04)
	local colourAddress: number = memory:read32(meshAddress + 0x08)
	local uvAddress: number = memory:read32(meshAddress + 0x0C)
	local indexAddress: number = memory:read32(meshAddress + 0x10)
	local indexCount: number = memory:read32(meshAddress + 0x14)
	if indexCount == 0 or vertexCount == 0 then
		return 0, true
	end
	local triangleCount = math.floor(indexCount / 3)
	if vertexCount > Raster.MAX_VERTICES or triangleCount > Raster.MAX_TRIANGLES
		or not memory:containsRange(positionAddress, vertexCount * 12)
		or (colourAddress ~= 0 and not memory:containsRange(colourAddress, vertexCount * 4))
		or (uvAddress ~= 0 and not memory:containsRange(uvAddress, vertexCount * 8))
		or (indexAddress ~= 0 and not memory:containsRange(indexAddress, indexCount * 4))
	then
		return 0, false
	end
	local nearPlane: number = near or 0.0001
	if nearPlane ~= nearPlane or nearPlane == math.huge or nearPlane <= 0 then
		return 0, false
	end

	local m: { number } = self.matrixValues
	for i = 0, 15 do
		local value = buffer.readf32(ram, matrixAddress + i * 4)
		if value ~= value or value == math.huge or value == -math.huge then
			return 0, false
		end
		m[i + 1] = value
	end

	if cull ~= nil then
		self.cull = cull
	end
	local culling: boolean = self.cull

	local texWidth: number, texHeight: number, texPixels: number = 0, 0, 0
	if shading == Raster.TEXTURED and textureAddress ~= 0 then
		if not memory:containsRange(textureAddress, 12) then
			return 0, false
		end
		texWidth = memory:read32(textureAddress + 0x00)
		texHeight = memory:read32(textureAddress + 0x04)
		texPixels = memory:read32(textureAddress + 0x08)
		if texWidth > 0 and texHeight > 0 then
			if texWidth > math.floor(Raster.MAX_TEXTURE_PIXELS / texHeight)
				or not memory:containsRange(texPixels, texWidth * texHeight * 4)
			then
				return 0, false
			end
		else
			texWidth = 0
			texHeight = 0
		end
	end

	local width: number = self.width
	local height: number = self.height
	local stride: number = width * 4
	local colour: buffer = self.colour
	local depthBuffer: buffer = self.depth
	local cx: { number }, cy: { number }, cw: { number } = self.cx, self.cy, self.cw
	local cr: { number }, cg: { number }, cb: { number }, ca: { number } = self.cr, self.cg, self.cb, self.ca
	local cu: { number }, cv: { number } = self.cu, self.cv
	local ax: { number }, ay: { number }, az: { number }, aw: { number } = self.ax, self.ay, self.az, self.aw
	local ar: { number }, ag: { number }, ab: { number }, aa: { number } = self.ar, self.ag, self.ab, self.aa
	local au: { number }, av: { number } = self.au, self.av

	local colourBase: number = self.colourBase
	local depthBase: number = self.depthBase
	local xMinBound: number = self.scissorX
	local yMinBound: number = self.scissorY
	local xMaxBound: number = self.scissorX + self.scissorW - 1
	local yMaxBound: number = self.scissorY + self.scissorH - 1

	local triangles: number = math.floor(indexCount / 3)
	local rasterized: number, fragments: number, written: number = 0, 0, 0
	local workRemaining = self.workRemaining or Raster.budgetFor(width, height)
	if workRemaining < 0 or workRemaining % 1 ~= 0 then
		return 0, false
	end
	self.workLimitHit = false
	for triangle = 0, triangles - 1 do
		if workRemaining < 1 then
			self.stats.workLimitHits += 1
			self.workLimitHit = true
			if self.workRemaining ~= nil then
				self.workRemaining = 0
			end
			break
		end
		workRemaining -= 1
		if self.workRemaining ~= nil then
			self.workRemaining = workRemaining
		end
		self.stats.triangles += 1
		local validTriangle = true

		-- Gather the three vertices.
		for corner = 1, 3 do
			local index: number
			if indexAddress ~= 0 then
				index = buffer.readu32(ram, indexAddress + (triangle * 3 + corner - 1) * 4)
			else
				index = triangle * 3 + corner - 1
			end
			if index >= vertexCount then
				index = vertexCount - 1
			end
			local positionOffset = positionAddress + index * 12
			transformVertex(
				m,
				ax,
				ay,
				az,
				aw,
				corner,
				buffer.readf32(ram, positionOffset),
				buffer.readf32(ram, positionOffset + 4),
				buffer.readf32(ram, positionOffset + 8)
			)
			if ax[corner] ~= ax[corner] or ay[corner] ~= ay[corner] or az[corner] ~= az[corner] or aw[corner] ~= aw[corner]
				or ax[corner] == math.huge or ax[corner] == -math.huge
				or ay[corner] == math.huge or ay[corner] == -math.huge
				or az[corner] == math.huge or az[corner] == -math.huge
				or aw[corner] == math.huge or aw[corner] == -math.huge
			then
				validTriangle = false
				break
			end
			if colourAddress ~= 0 then
				local word = buffer.readu32(ram, colourAddress + index * 4)
				ar[corner] = (word % 256) / 255
				ag[corner] = (math.floor(word / 256) % 256) / 255
				ab[corner] = (math.floor(word / 65536) % 256) / 255
				aa[corner] = (math.floor(word / 16777216) % 256) / 255
			else
				ar[corner], ag[corner], ab[corner], aa[corner] = 1, 1, 1, 1
			end
			if uvAddress ~= 0 then
				local u = buffer.readf32(ram, uvAddress + index * 8)
				local v = buffer.readf32(ram, uvAddress + index * 8 + 4)
				if u ~= u or v ~= v or u == math.huge or u == -math.huge or v == math.huge or v == -math.huge then
					validTriangle = false
					break
				end
				au[corner], av[corner] = u, v
			else
				au[corner], av[corner] = 0, 0
			end
		end
		if not validTriangle then
			self.stats.clipped += 1
			continue
		end

		-- Clip against the near plane (w > near), producing 0, 3 or 4 vertices.
		local count = 0
		for corner = 1, 3 do
			local nextCorner = corner % 3 + 1
			local insideHere = aw[corner] > nearPlane
			local insideNext = aw[nextCorner] > nearPlane
			if insideHere then
				count += 1
				cx[count], cy[count] = ax[corner], ay[corner]
				cw[count] = aw[corner]
				cr[count], cg[count], cb[count], ca[count] = ar[corner], ag[corner], ab[corner], aa[corner]
				cu[count], cv[count] = au[corner], av[corner]
			end
			if insideHere ~= insideNext then
				local span = aw[nextCorner] - aw[corner]
				local t = (nearPlane - aw[corner]) / span
				count += 1
				cx[count] = ax[corner] + (ax[nextCorner] - ax[corner]) * t
				cy[count] = ay[corner] + (ay[nextCorner] - ay[corner]) * t
				cw[count] = nearPlane
				cr[count] = ar[corner] + (ar[nextCorner] - ar[corner]) * t
				cg[count] = ag[corner] + (ag[nextCorner] - ag[corner]) * t
				cb[count] = ab[corner] + (ab[nextCorner] - ab[corner]) * t
				ca[count] = aa[corner] + (aa[nextCorner] - aa[corner]) * t
				cu[count] = au[corner] + (au[nextCorner] - au[corner]) * t
				cv[count] = av[corner] + (av[nextCorner] - av[corner]) * t
			end
		end

		if count < 3 then
			self.stats.clipped += 1
			continue
		end

		-- Project the clipped polygon into screen space. Everything an attribute
		-- needs is pre-multiplied by 1/w, so the rasteriser never divides per
		-- attribute - one reciprocal per pixel covers all of them.
		local sxf: { number }, syf: { number }, siw: { number } = self.sxf, self.syf, self.siw
		local spr: { number }, spg: { number }, spb: { number }, spa: { number } = self.spr, self.spg, self.spb, self.spa
		local spu: { number }, spv: { number } = self.spu, self.spv
		for i = 1, count do
			local w = cw[i]
			local invW = 1 / w
			sxf[i] = (0.5 + cx[i] * invW * 0.5) * width
			syf[i] = (0.5 - cy[i] * invW * 0.5) * height
			siw[i] = invW
			spr[i] = cr[i] * invW
			spg[i] = cg[i] * invW
			spb[i] = cb[i] * invW
			spa[i] = ca[i] * invW
			spu[i] = cu[i] * invW
			spv[i] = cv[i] * invW
		end

		-- Fan triangulate the polygon.
		for k = 2, count - 1 do
			local x0, y0 = sxf[1], syf[1]
			local x1, y1 = sxf[k], syf[k]
			local x2, y2 = sxf[k + 1], syf[k + 1]
			local area = (x1 - x0) * (y2 - y0) - (x2 - x0) * (y1 - y0)
			if area == 0 then
				continue
			end
			-- Screen-space y points down, so a front face has negative area and the
			-- culler rejects the rest.
			if culling and area >= 0 then
				self.stats.culled += 1
				continue
			end

			-- Fold the winding into the edge functions and their derivatives, so the
			-- inside test is always "all three are non-negative" and no branch runs
			-- per pixel.
			local sign = if area > 0 then 1 else -1
			local invA = 1 / math.abs(area)
			local d0x = -(y2 - y1) * sign
			local d1x = -(y0 - y2) * sign
			local d2x = -(y1 - y0) * sign

			local xmin = math.max(math.floor(math.min(x0, x1, x2)), xMinBound)
			local xmax = math.min(math.ceil(math.max(x0, x1, x2)), xMaxBound)
			local ymin = math.max(math.floor(math.min(y0, y1, y2)), yMinBound)
			local ymax = math.min(math.ceil(math.max(y0, y1, y2)), yMaxBound)
			if xmin > xmax or ymin > ymax then
				continue
			end
			local candidatePixels = (xmax - xmin + 1) * (ymax - ymin + 1)
			if candidatePixels > workRemaining then
				self.stats.workLimitHits += 1
				self.workLimitHit = true
				workRemaining = 0
				if self.workRemaining ~= nil then
					self.workRemaining = 0
				end
				break
			end
			workRemaining -= candidatePixels
			if self.workRemaining ~= nil then
				self.workRemaining = workRemaining
			end

			local iw0, iw1, iw2 = siw[1], siw[k], siw[k + 1]
			local r0p, r1p, r2p = spr[1], spr[k], spr[k + 1]
			local g0p, g1p, g2p = spg[1], spg[k], spg[k + 1]
			local b0p, b1p, b2p = spb[1], spb[k], spb[k + 1]
			local a0p, a1p, a2p = spa[1], spa[k], spa[k + 1]
			local u0p, u1p, u2p = spu[1], spu[k], spu[k + 1]
			local v0p, v1p, v2p = spv[1], spv[k], spv[k + 1]
			local flatWord = packRGBA(byteFromUnit(cr[1]), byteFromUnit(cg[1]), byteFromUnit(cb[1]), byteFromUnit(ca[1]))
			local textured = shading == Raster.TEXTURED and texWidth > 0 and texHeight > 0

			rasterized += 1
			for y = ymin, ymax do
				local e0 = ((x2 - x1) * (y - y1) - (y2 - y1) * (xmin - x1)) * sign
				local e1 = ((x0 - x2) * (y - y2) - (y0 - y2) * (xmin - x2)) * sign
				local e2 = ((x1 - x0) * (y - y0) - (y1 - y0) * (xmin - x0)) * sign
				local offset = y * stride + xmin * 4
				for _ = xmin, xmax do
					if e0 >= 0 and e1 >= 0 and e2 >= 0 then
						fragments += 1
						local invSum = e0 * iw0 + e1 * iw1 + e2 * iw2
						if invSum * invA > buffer.readf32(depthBuffer, depthBase + offset) then
							buffer.writef32(depthBuffer, depthBase + offset, invSum * invA)
							local word = flatWord
							if shading == Raster.GOURAUD then
								local inv = 1 / invSum
								word = packRGBA(
									byteFromUnit((e0 * r0p + e1 * r1p + e2 * r2p) * inv),
									byteFromUnit((e0 * g0p + e1 * g1p + e2 * g2p) * inv),
									byteFromUnit((e0 * b0p + e1 * b1p + e2 * b2p) * inv),
									byteFromUnit((e0 * a0p + e1 * a1p + e2 * a2p) * inv)
								)
							elseif textured then
								local inv = 1 / invSum
								local u = (e0 * u0p + e1 * u1p + e2 * u2p) * inv
								local v = (e0 * v0p + e1 * v1p + e2 * v2p) * inv
								local tx = math.floor(u * texWidth) % texWidth
								local ty = math.floor(v * texHeight) % texHeight
								local texel = buffer.readu32(ram, texPixels + (ty * texWidth + tx) * 4)
								local tr = texel % 256
								local tg = math.floor(texel / 256) % 256
								local tb = math.floor(texel / 65536) % 256
								local ta = math.floor(texel / 16777216) % 256
								word = packRGBA(
									byteFromScaled((e0 * r0p + e1 * r1p + e2 * r2p) * inv * tr),
									byteFromScaled((e0 * g0p + e1 * g1p + e2 * g2p) * inv * tg),
									byteFromScaled((e0 * b0p + e1 * b1p + e2 * b2p) * inv * tb),
									ta
								)
							end
							buffer.writeu32(colour, colourBase + offset, word)
							written += 1
						end
					end
					e0 += d0x
					e1 += d1x
					e2 += d2x
					offset += 4
				end
			end
			if self.workLimitHit then
				break
			end
		end
		if self.workLimitHit then
			break
		end
	end

	self.stats.fragments += fragments
	self.stats.drawn += written
	return rasterized, true
end

--- Composite a tile buffer into the target colour and depth planes using one
--- bulk `buffer.copy` per scanline row (docs/06-gpu-avalon.md section 4).
function Raster:compositeTile(tileColour: buffer, tileDepth: buffer, tileX: number, tileY: number, tileW: number, tileH: number)
	local stride: number = self.width * 4
	local rowBytes: number = tileW * 4
	local colour: buffer = self.colour
	local depth: buffer = self.depth
	local colourBase: number = self.colourBase
	local depthBase: number = self.depthBase

	for row = 0, tileH - 1 do
		local dstOff = (tileY + row) * stride + tileX * 4
		buffer.copy(colour, colourBase + dstOff, tileColour, dstOff, rowBytes)
		buffer.copy(depth, depthBase + dstOff, tileDepth, dstOff, rowBytes)
	end
	self.stats.tilesComposited += 1
end

--- Render a mesh across `tileCount` horizontal screen tiles into isolated tile
--- buffers and composite each tile into the target framebuffer via `buffer.copy`
--- (docs/06-gpu-avalon.md section 4). Produces pixel-identical output to
--- single-tile rendering while exercising the tile-split + bulk-composite path.
function Raster:drawMeshTiled(
	tileCount: number,
	meshAddress: number,
	matrixAddress: number,
	shading: number,
	textureAddress: number,
	cull: boolean?,
	near: number?
): (number, boolean)
	if tileCount <= 1 then
		return self:drawMesh(meshAddress, matrixAddress, shading, textureAddress, cull, near)
	end

	local width: number = self.width
	local height: number = self.height
	if height <= 0 then
		return 0, false
	end
	tileCount = math.clamp(math.floor(finiteOrZero(tileCount)), 1, math.min(64, height))
	if tileCount <= 1 then
		return self:drawMesh(meshAddress, matrixAddress, shading, textureAddress, cull, near)
	end
	local planeBytes: number = width * height * 4
	local origColour: buffer = self.colour
	local origDepth: buffer = self.depth
	local origColourBase: number = self.colourBase
	local origDepthBase: number = self.depthBase
	local origScX, origScY, origScW, origScH = self.scissorX, self.scissorY, self.scissorW, self.scissorH
	if not bufferRangeFits(origColour, origColourBase, planeBytes)
		or not bufferRangeFits(origDepth, origDepthBase, planeBytes)
	then
		return 0, false
	end

	local ownsBudget = self.workRemaining == nil
	if ownsBudget then
		self.workRemaining = Raster.budgetFor(width, height)
	end
	self.workLimitHit = false
	local copyWork = width * height
	if copyWork > self.workRemaining then
		self.stats.workLimitHits += 1
		self.workLimitHit = true
		if ownsBudget then
			self.workRemaining = nil
		else
			self.workRemaining = 0
		end
		return 0, true
	end
	self.workRemaining -= copyWork
	local tileColour = buffer.create(planeBytes)
	local tileDepth = buffer.create(planeBytes)
	buffer.copy(tileColour, 0, origColour, origColourBase, planeBytes)
	buffer.copy(tileDepth, 0, origDepth, origDepthBase, planeBytes)

	local totalRasterized = 0
	local valid = true
	local bandHeight = math.ceil(origScH / tileCount)

	for t = 0, tileCount - 1 do
		local y0 = origScY + t * bandHeight
		if y0 >= origScY + origScH then
			break
		end
		local h = math.min(bandHeight, (origScY + origScH) - y0)
		local x0 = origScX
		local w = origScW

		-- Seed tile buffers from the current framebuffer region so existing
		-- pixels and depths in the tile are preserved.
		local stride = width * 4
		local rowBytes = w * 4
		for row = 0, h - 1 do
			local off = (y0 + row) * stride + x0 * 4
			buffer.copy(tileColour, off, origColour, origColourBase + off, rowBytes)
			buffer.copy(tileDepth, off, origDepth, origDepthBase + off, rowBytes)
		end

		self.colour = tileColour
		self.depth = tileDepth
		self.colourBase = 0
		self.depthBase = 0
		self:setScissor(x0, y0, w, h)
		local rasterized, accepted = self:drawMesh(meshAddress, matrixAddress, shading, textureAddress, cull, near)
		totalRasterized += rasterized
		if not accepted then
			valid = false
		end

		self.colour = origColour
		self.depth = origDepth
		self.colourBase = origColourBase
		self.depthBase = origDepthBase
		if accepted then
			self:compositeTile(tileColour, tileDepth, x0, y0, w, h)
		else
			valid = false
		end
		if not valid or self.workLimitHit then
			break
		end
	end

	self:setScissor(origScX, origScY, origScW, origScH)
	if ownsBudget then
		self.workRemaining = nil
	end
	return totalRasterized, valid
end

return Raster
