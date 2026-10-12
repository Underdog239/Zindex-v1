--!nonstrict
--!native
--[[
	Raster - the Z32 raster unit (docs/06-gpu-avalon.md).

	Scanline edge-function rasteriser writing packed RGBA8 words into a colour
	buffer, with a separate f32 depth plane storing 1/w. Implements the pipeline
	documented for Avalon R1:

		MVP transform -> near-plane clip -> perspective divide -> back-face cull
		-> edge-function raster with depth test -> attributes divided by 1/w

	Everything is a buffer, nothing is allocated per triangle, and the module
	touches no engine API.

	Colour layout matches Avalon exactly: one `buffer.writeu32` per pixel,
	packRGBA(r, g, b, a) = r + g*256 + b*65536 + a*16777216.  Depth stores 1/w,
	so a larger value is nearer, and the plane is cleared to 0.

	Mesh descriptor:
		+0x00  vertexCount
		+0x04  positions address   (float3 per vertex)
		+0x08  colours address     (RGBA8 per vertex, or 0)
		+0x0C  uvs address         (float2 per vertex, or 0)
		+0x10  indices address     (u32 per index, or 0 for a plain triangle list)
		+0x14  indexCount

	Texture descriptor:
		+0x00  width
		+0x04  height
		+0x08  pixels address      (RGBA8, row major)

	The matrix is 16 floats, row major, column-vector convention.
]]

local Memory = require(script.Parent.Memory)

local Raster = {}
Raster.__index = Raster

-- Shading modes
Raster.FLAT = 0
Raster.GOURAUD = 1
Raster.TEXTURED = 2

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
	self.stats = { triangles = 0, drawn = 0, culled = 0, clipped = 0, fragments = 0 }

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

function Raster:setScissor(x: number, y: number, w: number, h: number)
	self.scissorX = x
	self.scissorY = y
	self.scissorW = w
	self.scissorH = h
end

--- Fill the colour plane with one packed word and clear depth to 0.
function Raster:clear(word: number)
	local stride = self.width * 4
	-- buffer.fill writes a *byte* value, so a packed colour has to be written
	-- one 32-bit word at a time. Filling with the word would silently write
	-- only its low byte.
	for row = 0, self.scissorH - 1 do
		local offset = self.colourBase + (self.scissorY + row) * stride + self.scissorX * 4
		for _ = 1, self.scissorW do
			buffer.writeu32(self.colour, offset, word)
			offset += 4
		end
	end
	for row = 0, self.height - 1 do
		buffer.fill(self.depth, self.depthBase + row * stride, 0, self.width * 4)
	end
end

function Raster:resetStats()
	self.stats.triangles = 0
	self.stats.drawn = 0
	self.stats.culled = 0
	self.stats.clipped = 0
	self.stats.fragments = 0
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
--- Row-major flat 16-number matrix, column-vector convention: the translation
--- lives in elements 3, 7, 11 and the projection row in 12..15. This is the
--- convention docs/06-gpu-avalon.md states, and the one Avalon R1 uses.
local function transformVertex(m, ax, ay, az, aw, index, x, y, z)
	ax[index] = m[0] * x + m[1] * y + m[2] * z + m[3]
	ay[index] = m[4] * x + m[5] * y + m[6] * z + m[7]
	az[index] = m[8] * x + m[9] * y + m[10] * z + m[11]
	aw[index] = m[12] * x + m[13] * y + m[14] * z + m[15]
end

--- Draw a mesh. Returns the number of triangles that reached the rasteriser.
function Raster:drawMesh(meshAddress: number, matrixAddress: number, shading: number, textureAddress: number, cull: boolean?, near: number?): number
	local memory = self.memory
	local vertexCount = memory:read32(meshAddress + 0x00)
	local positionAddress = memory:read32(meshAddress + 0x04)
	local colourAddress = memory:read32(meshAddress + 0x08)
	local uvAddress = memory:read32(meshAddress + 0x0C)
	local indexAddress = memory:read32(meshAddress + 0x10)
	local indexCount = memory:read32(meshAddress + 0x14)
	if indexCount == 0 or vertexCount == 0 then
		return 0
	end

	local m = self.matrixValues
	for i = 0, 15 do
		m[i] = memory:readf32(matrixAddress + i * 4)
	end

	local nearPlane = near or 0.0001
	if cull ~= nil then
		self.cull = cull
	end
	local culling = self.cull

	local texWidth, texHeight, texPixels = 0, 0, 0
	if shading == Raster.TEXTURED and textureAddress ~= 0 then
		texWidth = memory:read32(textureAddress + 0x00)
		texHeight = memory:read32(textureAddress + 0x04)
		texPixels = memory:read32(textureAddress + 0x08)
	end

	local width = self.width
	local height = self.height
	local stride = width * 4
	local colour = self.colour
	local depthBuffer = self.depth
	local cx, cy, cw = self.cx, self.cy, self.cw
	local cr, cg, cb, ca = self.cr, self.cg, self.cb, self.ca
	local cu, cv = self.cu, self.cv
	local ax, ay, az, aw = self.ax, self.ay, self.az, self.aw
	local ar, ag, ab, aa = self.ar, self.ag, self.ab, self.aa
	local au, av = self.au, self.av

	local colourBase = self.colourBase
	local depthBase = self.depthBase
	local xMinBound = self.scissorX
	local yMinBound = self.scissorY
	local xMaxBound = self.scissorX + self.scissorW - 1
	local yMaxBound = self.scissorY + self.scissorH - 1

	local triangles = math.floor(indexCount / 3)
	local rasterized, fragments, written = 0, 0, 0
	for triangle = 0, triangles - 1 do
		self.stats.triangles += 1

		-- Gather the three vertices.
		for corner = 1, 3 do
			local index
			if indexAddress ~= 0 then
				index = memory:read32(indexAddress + (triangle * 3 + corner - 1) * 4)
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
				memory:readf32(positionOffset),
				memory:readf32(positionOffset + 4),
				memory:readf32(positionOffset + 8)
			)
			if colourAddress ~= 0 then
				local word = memory:read32(colourAddress + index * 4)
				ar[corner] = (word % 256) / 255
				ag[corner] = (math.floor(word / 256) % 256) / 255
				ab[corner] = (math.floor(word / 65536) % 256) / 255
				aa[corner] = (math.floor(word / 16777216) % 256) / 255
			else
				ar[corner], ag[corner], ab[corner], aa[corner] = 1, 1, 1, 1
			end
			if uvAddress ~= 0 then
				au[corner] = memory:readf32(uvAddress + index * 8)
				av[corner] = memory:readf32(uvAddress + index * 8 + 4)
			else
				au[corner], av[corner] = 0, 0
			end
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
		local sxf, syf, siw = self.sxf, self.syf, self.siw
		local spr, spg, spb, spa = self.spr, self.spg, self.spb, self.spa
		local spu, spv = self.spu, self.spv
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
								local texel = memory:read32(texPixels + (ty * texWidth + tx) * 4)
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
		end
	end

	self.stats.fragments += fragments
	self.stats.drawn += written
	return rasterized
end

return Raster
