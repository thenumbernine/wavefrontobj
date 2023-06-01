local ffi = require 'ffi'
local class = require 'ext.class'
local table = require 'ext.table'
local math = require 'ext.math'
local range = require 'ext.range'
local timer = require 'ext.timer'
local vector = require 'ffi.cpp.vector'
local vec2f = require 'vec-ffi.vec2f'
local vec3f = require 'vec-ffi.vec3f'
local box3f = require 'vec-ffi.box3f'
local plane3f = require 'vec-ffi.plane3f'
local matrix_ffi = require 'matrix.ffi'
matrix_ffi.real = 'float'

ffi.cdef[[
typedef struct MeshVertex_t {
	vec3f_t pos;
	vec3f_t texcoord;
	vec3f_t normal;

	// per-triangle stats (duplicated 3x per-vertex)
	// TODO move this to a separate buffer
	vec3f_t com;		//com of tri containing this vertex.  only good for un-indexed drawing.
} MeshVertex_t;
]]

local Mesh = class()

local function triArea(a,b,c)
	-- TODO check nans here?
	local n = (b - a):cross(c - a)
	return .5 * n:norm()
end
Mesh.triArea = triArea

-- TODO the more I use this (and build off it ... giving triangle TNB frames ...)
-- the more I think I should re-introduce storing the triangle normal
local function triNormal(a,b,c)
	local n, len = (b - a):cross(c - b):unitOrZero()
	return n, len * .5
	-- returns the unit normal, triangle area
end
Mesh.triNormal = triNormal

local function triCOM(a,b,c)
	-- TODO check nans here?
	return (a + b + c) * (1/3)
end
Mesh.triCOM = triCOM

-- volume of parallelogram with vertices at 0, a, b, c
-- the 4th pt in the tetrad is zero.  adjust a,b,c accordingly
local function tetradVolume(a,b,c)
	return (a.x * b.y * c.z
		+ a.y * b.z * c.x
		+ a.z * b.x * c.y
		- c.x * b.y * a.z
		- c.y * b.z * a.x
		- c.z * b.x * a.y) / 6
end
Mesh.tetradVolume = tetradVolume

--[[ holds extra info per tri:
.index = what it's 1-based index is
.group = what its group is (unnecessary? finding via groups ranges is probably faster than finding a tri in the .tris table)
.com = triangle center-of-mass (average of 3 vtxs)
.area
.normal = tri surface normal (surface z-axis)
.basis = [3] of tangent, (negative of) binormal, normal

findEdges:
.edges

unwrapuv:
.uvs = [3] vec2f's of the uv's of the triangle (before breaking and writing)
.uvorigin2D
.uvorigin3D
--]]
local Triangle = class()

function Triangle:init(args)
	if args then
		for k,v in pairs(args) do
			self[k] = v
		end
	end
end

function Triangle:indexes(mesh)
	local ti = 3 * (self.index - 1)
	assert(ti >= 0 and ti + 3 <= mesh.triIndexes.size)
	local tp = mesh.triIndexes.v + ti
	local i,j,k = tp[0], tp[1], tp[2]
	assert(i >= 0 and i < mesh.vtxs.size)
	assert(j >= 0 and j < mesh.vtxs.size)
	assert(k >= 0 and k < mesh.vtxs.size)
	return i,j,k
end

function Triangle:vtxs(mesh)
	local i,j,k = self:indexes(mesh)
	return mesh.vtxs.v[i], mesh.vtxs.v[j], mesh.vtxs.v[k]
end

function Triangle:vtxPos(mesh)
	local va,vb,vc = self:vtxs(mesh)
	return va.pos, vb.pos, vc.pos
end

function Triangle:calcCOM(mesh)
	local a, b, c = self:vtxPos(mesh)
	self.com = (a + b + c) * (1 / 3)
end

function Triangle:calcAux(mesh)
	self:calcCOM(mesh)
	self.normal, self.area = mesh.triNormal(self:vtxPos(mesh))
end

-- calculate the barycentric coordinates of point 'p'
function Triangle:calcBCC(p, mesh)
	local ti = 3 * (self.index - 1)
	assert(ti >= 0 and ti + 3 <= mesh.triIndexes.size)
	local tp = mesh.triIndexes.v + ti
	assert(tp[0] >= 0 and tp[0] < mesh.vtxs.size)
	assert(tp[1] >= 0 and tp[1] < mesh.vtxs.size)
	assert(tp[2] >= 0 and tp[2] < mesh.vtxs.size)

	local bcc = vec3f()
	for j=0,2 do
		local v1 = mesh.vtxs.v[tp[(j+1)%3]].pos
		local v2 = mesh.vtxs.v[tp[(j+2)%3]].pos
		local v3 = mesh.vtxs.v[tp[(j+0)%3]].pos
		local vavg = .5 * (v1 + v2)
		local edgeDir = v2 - v1
		local tocom = self.normal:cross(edgeDir):normalize()
		local edgePlane = plane3f():fromDirPt(tocom, vavg)
		local oppDist = edgePlane:dist(v3)
		-- TODO rescale correctly
		-- right now they're only good for signedness test
		bcc.s[j] = (p - v1):dot(tocom) / oppDist
	end
	return bcc
end

-- returns 'true' if 'p' is inside the triangle according to barycentric coordinate test
function Triangle:insideBCC(p, mesh)
	local bcc = self:calcBCC(p, mesh)
	return bcc.x >= 0 and bcc.y >= 0 and bcc.z >= 0
end

function Triangle:calcTetradVolume(mesh)
	return tetradVolume(self:vtxPos(mesh))
end

Mesh.Triangle = Triangle

function Mesh:init(o)
	-- TODO replace my lua-ization of cpp-vectors
	-- ...with a cdef-ization of lua-tables
	-- because everyone knows the stl api is way too longwinded compared to equiv commands in other languages/apis, and is only that way to accomodate functional programming and templates.
	self.vtxs = vector'MeshVertex_t'
	self.triIndexes = vector'int32_t'

	-- array of Triangle's
	self.tris = table()

	-- holds 0-based ranges of tris
	self.groups = table()
end

-- combines 'self' with other meshes.
-- operates in-place.
-- returns self
function Mesh:combine(...)
	self.mtlFilenames = table(self.mtlFilenames)

	for oi=1,select('#', ...) do
		local o = select(oi, ...)

		local firstVtx = self.vtxs.size
		self.vtxs:resize(self.vtxs.size + o.vtxs.size)
		ffi.copy(self.vtxs.v + firstVtx, o.vtxs.v, ffi.sizeof(o.vtxs.type) * o.vtxs.size)

		local firstIndex = self.triIndexes.size
		self.triIndexes:resize(self.triIndexes.size + o.triIndexes.size)
		for i=0,o.triIndexes.size-1 do
			self.triIndexes.v[firstIndex + i] = o.triIndexes.v[i] + firstVtx
		end

		local firstGroup = #self.groups+1
		self.groups:append(o.groups:mapi(function(g)
			g = table(g):setmetatable(nil)
			g.triFirstIndex = g.triFirstIndex + firstIndex/3
			return g
		end))

		self.tris:append(o.tris:mapi(function(t)
			t = Triangle(t)
			local groupIndex = o.groups:find(t.group)
			t.group = groupIndex and self.groups[firstGroup + groupIndex - 1] or nil
			return t
		end))
		for i,t in ipairs(self.tris) do
			t.index = i
		end

		self.mtlFilenames:append(o.mtlFilenames)
	end

	self.mtlFilenames = self.mtlFilenames:mapi(function(v,k,t)
		return true, v
	end):map(function(v,k,t)
		return k, #t+1
	end)

	self.edges = nil
	self.edgeIndexBuf = nil
	self.loadedGL = nil
	self.vtxBuf = nil

	return self
end

function Mesh:clone()
	return Mesh():combine(self)
end

-- TODO operators?  * number, * vec3f, etc?
function Mesh:scale(...)
	for i=0,self.vtxs.size-1 do
		local v = self.vtxs.v[i].pos
		for j=0,2 do
			v.s[j] = v.s[j] * select(j+1, ...)
		end
	end
	self:refreshVtxs()
	return self
end

-- TODO operators?
function Mesh:translate(...)
	for i=0,self.vtxs.size-1 do
		local v = self.vtxs.v[i].pos
		for j=0,2 do
			v.s[j] = v.s[j] + select(j+1, ...)
		end
	end
	self:refreshVtxs()
	return self
end

-- quaternion?  matrix?  angle-axis? detect?
-- quaternion for now.
function Mesh:rotate(q)
	for i=0,self.vtxs.size-1 do
		local v = self.vtxs.v[i].pos
		for j=0,2 do
			v.s[j] = q:rotate(v.s[j])
		end
	end
	self:refreshVtxs()
	return self
end

function Mesh:transform(xform)
	for i=0,self.vtxs.size-1 do
		local v = self.vtxs.v[i]
		local npos = xform * matrix_ffi{v.pos.x, v.pos.y, v.pos.z, 1}
		v.pos:set(npos:unpack())
		local nnormal = xform * matrix_ffi{v.normal.x, v.normal.y, v.normal.z, 0}
		v.normal = vec3f():set(nnormal:unpack()):normalize()
	end
	self:refreshVtxs()
	return self
end

function Mesh:recenter(newOrigin)
	for i=0,self.vtxs.size-1 do
		self.vtxs.v[i].pos = self.vtxs.v[i].pos - newOrigin
	end
	if self.vtxBuf then
		self.vtxBuf:updateData(0, ffi.sizeof'MeshVertex_t' * self.vtxs.size, self.vtxs.v)
	end
	-- recalculate coms
	self:calcCOMs()
end

function Mesh:refreshVtxs()
	if self.loadedGL then
		self.vtxBuf:updateData(0, ffi.sizeof'MeshVertex_t' * self.vtxs.size, self.vtxs.v)
	end
	self.bbox = nil
	-- TODO invalidate instead of recalculate?
	--self:findEdges()
	--self:calcCOMs()
	return self
end

function Mesh:prepare()
-- [[ calculate bbox.
-- do this before merging vertexes
	self:calcBBox()
--]]
-- TODO maybe calc bounding radius? Here or later?  That takes COM, which, for COM2/COM3 takes tris.  COM1 takes edges... should COM1 consider merged edges always?  probably...

	-- store all edges of all triangles
	-- ... why?  who uses this?
	-- unwrapUVs used to but now it uses the 'allOverlappingEdges' structure
	-- it's used for visualization
	self:findEdges()

	-- calculate coms ...
	self:calcCOMs()
end

function Mesh:calcBBox()
	self.bbox = box3f.empty()
	for i=0,self.vtxs.size-1 do
		self.bbox:stretch(self.vtxs.v[i].pos)
	end
end

--[=[
args:
	prec = precision, default 1e-5
	posPrec = precision for testing .pos uniqueness.  nil means no precision means don't even check.
	texCoordPrec = use .texcoord to test uniqueness.
	normalPrec = use .normal to test uniqueness.
	usedIndexes = optional map {[0-based-vtx-index] = true} to flag which indexes to check

returns:
	uniquevs = lua-table holding all the unique 0-based vtx indexes
	indexToUniqueV = {[0-based-vtx-index] = 1-based index in uniquevs} = map from old (0-based c-array) to new (1-based lua-table)

it should always be the case that uniquevs[indexToUniqueV[i]] <= i
--]=]
function Mesh:getUniqueVtxs(posPrec, texCoordPrec, normalPrec, usedIndexes)
	local function vec3ToStrPrec(v, prec)
		return tostring(v:map(function(x)
			return math.round(x / prec) * prec
		end))
	end

	-- map from the vtxs to unique indexes
	local uniquevs = table()

	-- used by tris.
	-- map from all vtxs.v[], into unique indexes
	-- rounds values to precision 'prec'
	-- keys are 0-based, values are 1-based
	local indexToUniqueV = {}

	-- maps from a key (from rounded vec3f) to uniquevs index
	-- goes a *lot* faster than the old way
	local keyToUnique = {}

	for i=0,self.vtxs.size-1 do
		if not usedIndexes or usedIndexes[i] then
			local v = self.vtxs.v[i]
			local k = table{
				posPrec and vec3ToStrPrec(v.pos, posPrec) or '',
				texCoordPrec and vec3ToStrPrec(v.texcoord, texCoordPrec) or '',
				normalPrec and vec3ToStrPrec(v.normal, normalPrec) or ''
			}:concat','
			local j = keyToUnique[k]
			if j then
				indexToUniqueV[i] = j
			else
				uniquevs:insert(i)
				keyToUnique[k] = #uniquevs
				indexToUniqueV[i] = #uniquevs
			end
		end
	end
	return uniquevs, indexToUniqueV
end

function Mesh:mergeMatchingVertexes(skipTexCoords, skipNormals)
	assert(#self.tris*3 == self.triIndexes.size)
	if not self.bbox then self:calcBBox() end
	-- ok the bbox hyp is 28, the smallest maybe valid dist is .077, and everything smalelr is 1e-6 ...
	-- that's a jump from 1/371 to 1/20,000,000
	-- so what's the smallest ratio I should allow?  maybe 1/1million?
	local bboxCornerDist = (self.bbox.max - self.bbox.min):norm()
	local vtxMergeThreshold = bboxCornerDist * 1e-6
--print('vtxMergeThreshold', vtxMergeThreshold)
--print('before merge vtx count', self.vtxs.size, 'tri count', self.triIndexes.size)

	local uniquevs, indexToUniqueV = self:getUniqueVtxs(
		vtxMergeThreshold,
		not skipTexCoords and 1e-7,
		not skipNormals and 1e-7
	)
	for i=self.vtxs.size-1,1,-1 do
		local j = uniquevs[indexToUniqueV[i]]
		assert(j <= i)
		if j < i then
			self:mergeVertex(i,j)
		end
	end
--print('after merge vtx count', self.vtxs.size, 'tri count', self.triIndexes.size)
	assert(#self.tris*3 == self.triIndexes.size)

	-- invalidate
	self.loadedGL = false
	self.vtxBuf = nil
	self.vtxAttrs = nil
	self.vao = nil

	self.edges = nil
	self.edgeIndexBuf = nil
	self.allOverlappingEdges = nil
	self.edges2 = nil
end

-- if a vertex is near an edge (and no vertex) then split the edge and make another vertex next to it
-- TODO this is tempting me to store data like the OBJ file format, as unique positions and unique traits, but not as unique vertexes grouping all those traits...
function Mesh:splitVtxsTouchingEdges()
	print('splitVtxsTouchingEdges BEGIN')
	local edgeLenEpsilon = 1e-7		-- how long an edge has to be for considering it a legit edge - and considering it for splitting
	local edgeDistEpsilon = 1e-3	-- how close a vertex has to be to the edge
	local intervalEpsilon = 1e-3	-- how cloes to the interval endpoints a vertex has to be to consider splitting
::tryagain::
	for _,g in ipairs(self.groups) do
		for ti=g.triFirstIndex+g.triCount-1,g.triFirstIndex,-1 do
--local debug = ({[6]=1,[8]=1,[9]=1,[17]=1})[ti]	-- these re the bad edges on target_basic bricks that need to be correctly split
--local dprint = debug and print or function() end			
			local tp = self.triIndexes.v + 3*ti
--dprint('TRI', ti, 'with indexes', tp[0], tp[1], tp[2])
			for j=0,2 do
				local iv0 = tp[j]
				local iv1 = tp[(j+1)%3]
				local iv2 = tp[(j+2)%3]
--dprint('EDGE', iv0, iv1)
				local v0 = ffi.new('MeshVertex_t', self.vtxs.v[iv0])
				local v1 = ffi.new('MeshVertex_t', self.vtxs.v[iv1])
				local edgeDir = v1.pos - v0.pos
				local edgePlanePos = .5 * (v1.pos + v0.pos)
				local edgeDirLen = edgeDir:norm()
--dprint('...with len', edgeDirLen)
				if edgeDirLen > edgeLenEpsilon then
					edgeDir = edgeDir / edgeDirLen 
					local edgePlane = plane3f():fromDirPt(edgeDir, edgePlanePos)
					local s0 = edgePlane:dist(v0.pos)	-- dist along the edge of v0
					local s1 = edgePlane:dist(v1.pos)	-- dist along the edge of v1
--dprint('... and edge interval '..s0..' to '..s1)
					assert(s1 >= s0) -- because edgeDir points from v0 to v1
					for i=0,self.vtxs.size-1 do
						local vi = ffi.new('MeshVertex_t', self.vtxs.v[i])	-- copy so resizing the vec doesn't invalidate this
						if iv0 ~= i and iv1 ~= i and iv2 ~= i then
							local edgeDist = edgePlane:projectVec(vi.pos - edgePlanePos):norm()	-- how far from the edge is vi
							--print(edgeDist) --, math.abs(s - s0), math.abs(s - s1))
							-- if this vtx is close to the dge
--dprint('testing against vertex', i, 'with edge dist', edgeDist)
							if edgeDist < edgeDistEpsilon then
								local s = edgePlane:dist(vi.pos)	-- dist along the edge of vi
--dprint('vertex '..i..' has dist '..edgeDist..' and edge param '..s)
								-- and it is far from either endpoint of the edge
								if math.abs(s - s0) > intervalEpsilon
								and math.abs(s - s1) > intervalEpsilon
								and s0 < s and s < s1
								then
									-- then we have to split this triangle at this point in the interval
--print("SPLITTING EDGE", v0.pos, v1.pos, 'at', vi.pos)
									local f = (s - s0) / (s1 - s0)
									local iv01 = self.vtxs.size
									local nvtx = self.vtxs:emplace_back()
									nvtx.pos = math.mix(v0.pos, v1.pos, f)
									nvtx.texcoord = math.mix(v0.texcoord, v1.texcoord, f)
									nvtx.normal = math.mix(v0.normal, v1.normal, f)

									-- [[ insertTri
									local nti = ti + 1
									tp[j] = iv0
									tp[(j+1)%3] = iv01
									tp[(j+2)%3] = iv2
									self.triIndexes:insert(self.triIndexes:begin() + 3*ti + 3, iv2)
									self.triIndexes:insert(self.triIndexes:begin() + 3*ti + 3, iv1)
									self.triIndexes:insert(self.triIndexes:begin() + 3*ti + 3, iv01)
--dprint("mod'd", self.triIndexes.v[3*ti+0], self.triIndexes.v[3*ti+1], self.triIndexes.v[3*ti+2])
--dprint('made', self.triIndexes.v[3*ti+3], self.triIndexes.v[3*ti+4], self.triIndexes.v[3*ti+5])
									self.tris:insert(ti+1, Triangle{
										index = nti+1,	-- 1-based
									})
									for _,g2 in ipairs(self.groups) do
										if nti <= g2.triFirstIndex then
											g2.triFirstIndex = g2.triFirstIndex + 1
										end
									end
									g.triCount = g.triCount + 1
									-- I can only split a triangl eonce, then  have to operate on the rest of the split tris
									goto tryagain
									--]]
								end
							end
						end
					end
				end
			end
		end
	end
	print('splitVtxsTouchingEdges END')
	self:rebuildTris()
	self:mergeMatchingVertexes()	-- better to merge vtxs than remove empty tris cuz it will keep seams in models
	self.loadedGL = nil
	self.vtxBuf = nil
	return modified
end

-- 0-based, index-array so 3x from unique tri
function Mesh:triVtxs(ti)
	assert(ti >= 0 and ti + 3 <= self.triIndexes.size)
	local t = self.triIndexes.v + ti
	assert(t[0] >= 0 and t[0] < self.vtxs.size)
	assert(t[1] >= 0 and t[1] < self.vtxs.size)
	assert(t[2] >= 0 and t[2] < self.vtxs.size)
	return self.vtxs.v[t[0]],
			self.vtxs.v[t[1]],
			self.vtxs.v[t[2]]
end

-- 0-based, index-array so 3x from unique tri
function Mesh:triVtxPos(i)
	local a, b, c = self:triVtxs(i)
	return a.pos, b.pos, c.pos
end

function Mesh:removeEmptyTris()
	print('before removeEmptyTris', #self.tris)
	for i,t in ipairs(self.tris) do
		if t.area < 1e-7 then
			self:removeTri(3*(i-1))
		end
	end
	print('after removeEmptyTris', #self.tris)
end

-- rebuild .tris from .triIndexes
function Mesh:rebuildTris(from,to)
	if not from then
		from = 1
		to = self.triIndexes.size/3
	end
	for i,t in ipairs(self.tris) do
		assert(Triangle:isa(t))
	end
	for i=from,to do
		if not self.tris[i] then
			self.tris[i] = Triangle()
		end
		self.tris[i].index = i
		self.tris[i]:calcAux(self)
	end
	if #self.tris*3 ~= self.triIndexes.size then
		error("expected "..(#self.tris*3).." but found "..self.triIndexes.size)
	end
	for i,t in ipairs(self.tris) do
		assert(Triangle:isa(t))
	end
end

-- i know "TNB" is the traditional, cuz thats the order you calculate them in the Frenet frame
-- but if "normal" is the surface dir (which I'm making the 'Z' axis) so that u and v in 2D align with x and y in 3D ...
-- then it becomes tangent-(negative)binormal-normal
function Mesh:clearTriBasis(mesh)
	for i,t in ipairs(mesh.tris) do
		-- TODO unify this with .normal
		t.basis = nil
	end
end

-- generate tangent, binormal, normal
-- TODO merge normal with this
-- TODO TODO merge position with this so that 'pos normal texcoord-u texcoord-v' are a basis
-- pos should go first, not last.  just like time should go first, not last.
-- because ofc pos = eps rot around inf origin = integral of time-velocity = integral of exp map of Lorentz boost-generators (from acceleration)
function Mesh:generateTriBasis()
	--[[ make sure triangles have basis
	vectors are columns ...
	[T|B]' * (pos[i] - pos0) = tc[i] - tc0
	[T|B] = 3x2, ' is transpose is 2x3
	let dpos = pos[i] - pos0, so it is 3x3 with 1rd row 0
	... same with tc
	... and we can truncate those 0 rows
	[T|B] * [T|B]' * dpos = [T|B] * dtc
	[T|B] * [T|B]' = I 2x2 since T and B are orthogonal ... but not vice versa since [T|B] is 3x2
	dpos * dtc^-1 = [T|B] * dtc * dtc^-1
	[T|B] = dpos * dtc^-1
	--]]
	for i,t in ipairs(self.tris) do
		if not t.basis then
			local ti = 3*(i-1)
			assert(ti >= 0 and ti < self.triIndexes.size)
			local tp = self.triIndexes.v + ti
			assert(tp[0] >= 0 and tp[0] < self.vtxs.size)
			assert(tp[1] >= 0 and tp[1] < self.vtxs.size)
			assert(tp[2] >= 0 and tp[2] < self.vtxs.size)
			local va = self.vtxs.v[tp[0]]
			local vb = self.vtxs.v[tp[1]]
			local vc = self.vtxs.v[tp[2]]
			local dpos1 = vb.pos - va.pos
			local dpos2 = vc.pos - va.pos
			local dtc1 = vb.texcoord - va.texcoord	-- only considering 2D of it
			local dtc2 = vc.texcoord - va.texcoord
			-- dtc is matrix with columns of dtc[i]
			local dtc = matrix_ffi{
				{dtc1.x, dtc2.x},
				{dtc1.y, dtc2.y},
			}
			-- now 2x2 invert
			local dtcInv = dtc:inv()
			--assert((dtc * dtcInv - matrix_ffi{{1,0},{0,1}}):normSq() < 1e-7)

			-- get the cols
			local dtcInv1 = vec2f(dtcInv[1][1], dtcInv[2][1])
			local dtcInv2 = vec2f(dtcInv[1][2], dtcInv[2][2])

			local n = dpos1:cross(dpos2):normalize()

			local ex = vec3f(
				dtcInv1:dot(vec2f(dpos1.x, dpos2.x)),
				dtcInv1:dot(vec2f(dpos1.y, dpos2.y)),
				dtcInv1:dot(vec2f(dpos1.z, dpos2.z))
			):normalize()
			--[[ don't use ey ... just use N x ex...
			local ey = vec3f(
				dtcInv2:dot(vec2f(dpos1.x, dpos2.x)),
				dtcInv2:dot(vec2f(dpos1.y, dpos2.y)),
				dtcInv2:dot(vec2f(dpos1.z, dpos2.z))
			):normalize()
			--]]
			--[[ or use the delta as ex ...
			local ex = dpos1:normalize()
			--]]
			-- [[ orthogonalize
			local ey = n:cross(ex):normalize()
			--]]
			t.basis = table{ex, ey, n}
--print(i, table.unpack(t.basis), n:dot(ex), n:dot(ey))
		end
	end
	--[[
	print('tri basis:')
	for i,t in ipairs(self.tris) do
		print(t.basis:unpack())
	end
	--]]
end


--[[
fill the allOverlappingEdges table

TODO 
- don't do subinterval tests.  instead merge vertex with edges before hand so old mesh overlapping edge subintervals are 1:1 with new mesh edges
- get rid of .edges, and use this as the default edge structure instead

angleThresholdInDeg is used for 'isPlanar' calculations
and this can be relatively loose (5 deg or so) for allowing planar uv unwrapping around curves.

normEpsilon is for validating that the norm is nonzero
edgeDistEpsilon is for finding overlapping edges that don't share vertexes but we still want to uv-unwrap fold over.
edgeAngleThreshold is used for ensuring those edges are aligned, so this must be tighter than angleThresholdInDeg.
--]]
function Mesh:calcAllOverlappingEdges(angleThresholdInDeg)
	local cosAngleThreshold = math.cos(math.rad(angleThresholdInDeg))
	--[[
	these are whatever mesh edges are partially overlapping one another.
	they are a result of a shitty artist.
	because of which, there is no guarantee with this table that each tri has 3 edges, and each edge has only 2 tris.
	instead it's a shitfest shitstorm.
	--]]
	self.allOverlappingEdges = table()
	for _,t in ipairs(self.tris) do
		t.allOverlappingEdges = table()
	end
--for _,t in ipairs(self.tris) do
--	print('n = '..t.normal)
--end
	local normEpsilon = 1e-7
	--local edgeDistEpsilon = 1e-7 -- ... is too strict for roof
	local edgeDistEpsilon = 1e-3
	local edgeAngleThreshold = math.rad(1e-1)
	local cosEdgeAngleThreshold = math.cos(edgeAngleThreshold)
	for i1=#self.tris,2,-1 do
		local tp1 = self.triIndexes.v + 3 * (i1 - 1)
		for j1=1,3 do
			-- t1's j1'th edge
			local v11 = self.vtxs.v[tp1[j1-1]].pos
			local v12 = self.vtxs.v[tp1[j1%3]].pos
--print('tri', i1, 'pos', j1, '=', v11)
			local edgeDir1 = v12 - v11
			local edgeDir1Norm = edgeDir1:norm()
			if edgeDir1Norm > normEpsilon then
				edgeDir1 = edgeDir1 / edgeDir1Norm
				for i2=i1-1,1,-1 do
					local t2 = self.tris[i2]
					local tp2 = self.triIndexes.v + 3 * (i2 - 1)
					for j2=1,3 do
						local v21 = self.vtxs.v[tp2[j2-1]].pos
						local v22 = self.vtxs.v[tp2[j2%3]].pos
						local edgeDir2 = v22 - v21
						local edgeDir2Norm = edgeDir2:norm()
						if edgeDir2Norm  > normEpsilon then
							edgeDir2 = edgeDir2 / edgeDir2Norm
							if math.abs(edgeDir1:dot(edgeDir2)) > cosEdgeAngleThreshold then
--print('allOverlappingEdges normals align:', i1-1, j1-1, i2-1, j2-1)
								-- normals align, calculate distance
								--local planePos = v11
							
								-- pick any point on line v1: v11 or v12
								-- or an average is best (when testing tri COM on either side tof the dividing plane)
								-- use the average of the two edges intersection with the plane, not just one edge arbitrarily
								local planePos = .5 * (v21 + v11)
								-- average the two edge-dirs
								local edgeDir
								if edgeDir1:dot(edgeDir2) < 0 then
									edgeDir = (edgeDir1 - edgeDir2):normalize()
								else
									edgeDir = (edgeDir1 + edgeDir2):normalize()
								end
								-- this is the edge projection plane, used for calculating distances to determine the interval of edge tri edge along this (the averaged edge)
								local plane = plane3f():fromDirPt(edgeDir, planePos)	
								-- find ray from the v1 line to any line on v2
								-- project onto the plane normal
								-- calculate the distance of the points both projected onto the plane
								local dist = plane:projectVec(v21 - v11):norm() 	
								if dist < edgeDistEpsilon then
									-- now find where along plane normal the intervals {v11,v12} and {v21,v22}
									local s11 = plane:dist(v11)
									local s12 = plane:dist(v12)
									-- based on edgeDir being the plane normal, s11 and s12 are already sorted
									local s21 = plane:dist(v21)
									local s22 = plane:dist(v22)
									-- since these aren't, they have to be sorted
									if s21 > s22 then s21, s22 = s22, s21 end
									if s11 < s22 and s12 > s21 then
										-- in my loop i2 < i1, but i want it ordered lowest-first, so ... swap them
										assert(i2 < i1)
										local t1 = self.tris[i1]
										local t2 = self.tris[i2]
										normAvg = (t1.normal + t2.normal):normalize()
										-- TODO member functions for edge getters
										local e = {
											tris = {t2, t1},
											triVtxIndexes = {j2, j1},
											intervals = {{s21,s22}, {s11,s12}},
											dist = dist,
											plane = plane,
											planePos = planePos,
											-- TODO test dot abs?  allow flipping of surface orientation?
											isPlanar = t1.normal:dot(t2.normal) > cosAngleThreshold,
											normAvg = normAvg,
											clipPlane = plane3f():fromDirPt(normAvg:cross(edgeDir):normalize(), planePos)
										}
										self.allOverlappingEdges:insert(e)
										t1.allOverlappingEdges:insert(e)
										t2.allOverlappingEdges:insert(e)
									end
								end
							end
						end
					end
				end
			end
		end
	end
--[[
	for _,e in ipairs(self.allOverlappingEdges) do
		print(
			'edges', self.tris:find(e.tris[1])-1, e.triVtxIndexes[1]-1,
			'and', self.tris:find(e.tris[2])-1, e.triVtxIndexes[2]-1,
			'align with dist', e.dist,
			'with projected intervals', table.concat(e.intervals[1], ', '),
			'and', table.concat(e.intervals[2], ', '))
	end
	print('found', #self.allOverlappingEdges, 'overlaps')
--]]


	-- new edge structure
	-- it only represents entire tri edges, like .edges (no subintervals) 
	-- but it contains the normal, planar, etc data of .allOverlappingEdges
	-- TODO this should be used to replace both
	self.edges2 = table()
	for _,t in ipairs(self.tris) do
		t.edges2 = table()
	end
--for _,t in ipairs(self.tris) do
--	print('n = '..t.normal)
--end
	local goodTris = 0
	local badTris = 0
	for i1=#self.tris,2,-1 do
		local tp1 = self.triIndexes.v + 3 * (i1 - 1)
		for j1=1,3 do
			-- t1's j1'th edge
			local v11 = self.vtxs.v[tp1[j1-1]].pos
			local v12 = self.vtxs.v[tp1[j1%3]].pos
--print('tri', i1, 'pos', j1, '=', v11)
			local edgeDir1 = v12 - v11
			local edgeDir1Norm = edgeDir1:norm()
			if edgeDir1Norm > normEpsilon then
				edgeDir1 = edgeDir1 / edgeDir1Norm
				for i2=i1-1,1,-1 do
					local t2 = self.tris[i2]
					local tp2 = self.triIndexes.v + 3 * (i2 - 1)
					for j2=1,3 do
						local v21 = self.vtxs.v[tp2[j2-1]].pos
						local v22 = self.vtxs.v[tp2[j2%3]].pos
						local edgeDir2 = v22 - v21
						local edgeDir2Norm = edgeDir2:norm()
						if edgeDir2Norm  > normEpsilon then
							edgeDir2 = edgeDir2 / edgeDir2Norm
							do --if math.abs(edgeDir1:dot(edgeDir2)) > cosEdgeAngleThreshold then
--print('edges2 normals align:', i1-1, j1-1, i2-1, j2-1)
								-- normals align, calculate distance
								--local planePos = v11
							
								-- pick any point on line v1: v11 or v12
								-- or an average is best (when testing tri COM on either side tof the dividing plane)
								-- use the average of the two edges intersection with the plane, not just one edge arbitrarily
								local planePos = .25 * (v11 + v12 + v21 + v22)
								-- average the two edge-dirs
								local edgeDir
								if edgeDir1:dot(edgeDir2) < 0 then
									edgeDir = edgeDir1 - edgeDir2
								else
									edgeDir = edgeDir1 + edgeDir2
								end
								local edgeDirLen = edgeDir:norm()
								if edgeDirLen > 1e-7 then
									edgeDir = edgeDir / edgeDirLen
									-- this is the edge projection plane, used for calculating distances to determine the interval of edge tri edge along this (the averaged edge)
									local plane = plane3f():fromDirPt(edgeDir, planePos)	
									-- find ray from the v1 line to any line on v2
									-- project onto the plane normal
									-- calculate the distance of the points both projected onto the plane
									local dist = plane:projectVec(v21 - v11):norm() 	
									-- also calc dists of each vtx to one another
									-- only consider if both edge vtxs match 
									-- no more subintervals
									local dist_11_21 = (v11 - v21):norm()
									local dist_12_22 = (v12 - v22):norm()
									local dist_12_21 = (v12 - v21):norm()
									local dist_11_22 = (v11 - v22):norm()
									-- TODO should I store them?
									if dist < edgeDistEpsilon
									and (
										(dist_11_21 < edgeDistEpsilon and dist_12_22 < edgeDistEpsilon)
										or (dist_12_21 < edgeDistEpsilon and dist_11_22 < edgeDistEpsilon)
									)
									then
										assert(i2 < i1)
										local t1 = self.tris[i1]
										local t2 = self.tris[i2]
										
										local s1, s2
										if dist_11_21 < edgeDistEpsilon
										and dist_12_22 < edgeDistEpsilon
										then
											s1 = plane:dist(.5 * (v11 + v21))
											s2 = plane:dist(.5 * (v12 + v22))
											-- TODO in this case we have a cw and ccw tri touching
											-- that's a bad thing, that means inside vs outside orientation is flipping
											-- ... and sure enough, there's a bad triangle in the mesh i'm given ...
											-- in fact this situation makes it tough to decide where exactly to put the clip plane ...
											-- maybe I should avoid it altogether?
											badTris = badTris + 1
										elseif dist_12_21 < edgeDistEpsilon
										and dist_11_22 < edgeDistEpsilon
										then
											goodTris = goodTris + 1
											s1 = plane:dist(.5 * (v12 + v21))
											s2 = plane:dist(.5 * (v11 + v22))
										
											-- in my loop i2 < i1, but i want it ordered lowest-first, so ... swap them
											normAvg = (t1.normal + t2.normal):normalize()
											-- TODO member functions for edge getters
											local e = {
												tris = {t2, t1},
												triVtxIndexes = {j2, j1},
												interval = {s1, s2},
												dist = dist,
												plane = plane,
												planePos = planePos,
												-- TODO test dot abs?  allow flipping of surface orientation?
												isPlanar = t1.normal:dot(t2.normal) > cosAngleThreshold,
												normAvg = normAvg,
												
												clipPlane = plane3f():fromDirPt(normAvg:cross(edgeDir):normalize(), planePos)
											}
											self.edges2:insert(e)
											t1.edges2:insert(e)
											t2.edges2:insert(e)
										else
											error"how did you get here?"
										end
									end
								end
							end
						end
					end
				end
			end
		end
	end
	print("found "..goodTris.." good pairs and "..badTris.." bad pairs")
end

function Mesh:findEdges(getIndex)
	if not getIndex then getIndex = function(a) return a end end
	-- and just for kicks, track all edges
	if not self.edgeIndexBuf then
		self.edgeIndexBuf = vector('int32_t', 6 * #self.tris)
	end
	self.edgeIndexBuf:resize(0)

	assert(#self.tris*3 == self.triIndexes.size)
	for i=1,self.triIndexes.size/3 do
		local t = self.tris[i]
		if not Triangle:isa(t) then
			error("got a bad tri at "..i..": "..require 'ext.tolua'(t))
		end
	end
	timer('edges', function()
		self.edges = {}
		local function addEdge(a,b,t)
			if a > b then return addEdge(b,a,t) end
			self.edges[a] = self.edges[a] or {}
			local e = self.edges[a][b]
			if not e then
				-- new edge?  add it to the index buffer
				self.edgeIndexBuf:push_back(a-1)
				self.edgeIndexBuf:push_back(b-1)
				e = {
					[1] = a,
					[2] = b,
					tris = table(),
					length = (self.vtxs.v[a-1].pos - self.vtxs.v[b-1].pos):norm(),
				}
				self.edges[a][b] = e
			end
			e.tris:insert(t)
			t.edges:insert(e)
		end
		for i=0,self.triIndexes.size-1,3 do
			local tp = self.triIndexes.v + i
			local a = getIndex(tp[0])
			local b = getIndex(tp[1])
			local c = getIndex(tp[2])
			local ti = i/3+1
			local t = self.tris[ti]
			if not Triangle:isa(t) then
				error("got a bad tri at "..ti..": "..require 'ext.tolua'(t))
			end
			t.edges = table()
			addEdge(a+1, b+1, t)
			addEdge(a+1, c+1, t)
			addEdge(b+1, c+1, t)
		end
	end)
end

--[[
calculate and store COMs
TODO store these?  or only calculate upon demand?
this will have to be recalculated every time the mesh changes
a prereq for calcCOM1 is findEdges()
--]]
function Mesh:calcCOMs()
	timer('com0', function()
		self.com0 = self:calcCOM0()
	end)
	print('com0 = '..self.com0)
	timer('com1', function()
		self.com1 = self:calcCOM1()
	end)
	print('com1 = '..self.com1)
	timer('com2', function()
		self.com2 = self:calcCOM2()
	end)
	print('com2 = '..self.com2)
	timer('com3', function()
		self.com3 = self:calcCOM3()
	end)
	print('com3 = '..self.com3)
	-- can only do this with com2 and com3 since they use tris, which are stored per-material
	-- ig i could with edges and vertexes too if I flag them per-material
	timer('group com2/3', function()
		for _,g in ipairs(self.groups) do
			g.com2 = self:calcCOM2(g.name)
			g.com3 = self:calcCOM3(g.name)
		end
	end)
end

-- replace all instances of one vertex index with another
function Mesh:replaceVertex(from,to)
--print('replacing vertex ' ..from..' with '..to)
	assert(from > to)
	assert(from >= 0 and from <= self.vtxs.size)
	assert(to >= 0 and to <= self.vtxs.size)
	-- replace in .tris
	for j=self.triIndexes.size-3,0,-3 do
		local t = self.triIndexes.v + j
		for i=0,2 do
			if t[i] == from then t[i] = to end
		end
	end
end

function Mesh:removeDegenerateTriangles()
	for i=self.triIndexes.size-3,0,-3 do
		local t = self.triIndexes.v + i
		for j=2,1,-1 do
			if t[j] == t[j-1] then
--print('removing degenerate tri '..i..' with duplicate vertices')
				self:removeTri(i)
				break
			end
		end
	end
end

-- index is 0-based in increments of 3
function Mesh:removeTri(i)
	if #self.tris*3 ~= self.triIndexes.size then
		error("3*#tris is "..(3*#self.tris).." while triIndexes is "..self.triIndexes.size)
	end
	self.triIndexes:erase(self.triIndexes.v + i, self.triIndexes.v + i + 3)
	for _,g in ipairs(self.groups) do
		if i < 3*g.triFirstIndex then
			g.triFirstIndex = g.triFirstIndex - 1
		elseif i >= 3*g.triFirstIndex and i < 3*(g.triFirstIndex + g.triCount) then
			g.triCount = g.triCount - 1
		end
	end
	self.tris:remove(i/3+1)
	for j=i/3+1,#self.tris do
		self.tris[j].index = j
	end
end

-- remove all instances of a veretx index
-- remove the vertex from the elf.vs[] list
-- decrement the indexes greater
function Mesh:removeVertex(vi)
	assert(vi >= 0 and vi < self.vtxs.size)
	self.vtxs:erase(self.vtxs.v + vi, self.vtxs.v + vi + 1)
	-- remove in .tris
	-- if you did :replaceVertex and :removeDegenerateFaces first then the rest shouldn't be necessary at all (except for error checking)
	-- if you just straight up remove a vertex then the tris and faces might go out of sync
	for j=self.triIndexes.size-3,0,-3 do
		local t = self.triIndexes.v + j
		for i=0,2 do
			if t[i] == vi then
				--error("found a to-be-removed vertex index in a tri.  you should merge it first, or delete tris containing it first.")
				self:removeTri(j)
				break
			elseif t[i] > vi then
				t[i] = t[i] - 1
			end
		end
	end
end

-- TODO just use a single dense tri array
-- don't use indexes at all

--[[
1) replace the 'from' with the 'to'
2) remove any degenerate triangles/faces
3) remove the to vertex from the list

-- TODO same for .vts and .vns ?
--]]
function Mesh:mergeVertex(from,to)
	assert(from > to)
	self:replaceVertex(from,to)
	self:removeDegenerateTriangles()
	self:removeVertex(from)
end

function Mesh:removeUnusedVtxs()
	local usedVs = {}
	timer('finding used vertexes', function()
		for i=0,self.triIndexes.size-1 do
			usedVs[self.triIndexes.v[i]] = true
		end
	end)
	timer('removing unused vertexes', function()
		print('before removing, #vs', self.vtxs.size)
		for i=self.vtxs.size-1,0,-1 do
			if not usedVs[i] then
				self:removeVertex(i)
			end
		end
		print('after removing, #vs', self.vtxs.size)
	end)
end

--[[ fixme
--nti is the 0-based triangle index
function Mesh:insertTri(a,b,c,nti)
	self.triIndexes:insert(self.triIndexes:begin() + 3*nti, a)
	self.triIndexes:insert(self.triIndexes:begin() + 3*nti+1, b)
	self.triIndexes:insert(self.triIndexes:begin() + 3*nti+2, c)
	self.tris:insert(nti, Triangle{
		index = nti+1,	-- +1 cuz its' 1-based
	})
	for _,g in ipairs(self.groups) do
		if nti <= g.triFirstIndex then
			g.triFirstIndex = g.triFirstIndex + 1
		elseif g.triFirstIndex < nti and nti < g.triFirstIndex + g.triCount then
			g.triCount = g.triCount + 1
		end
	end
	if #self.tris*3 ~= self.triIndexes.size then
		error("3*#tris is "..(3*#self.tris).." while triIndexes is "..self.triIndexes.size)
	end
end
--]]



-- common interface?  for dif 3d format types?
function Mesh:vtxiter()
	return coroutine.wrap(function()
		for i,v in ipairs(self.vs) do
			coroutine.yield(v)
		end
	end)
end

function Mesh:getTriIndexesForMaterial(groupname)
	if groupname then
		local _, g = self.groups:find(nil, function(g) return g.name == groupname end)
		if g then
			return g.triFirstIndex, g.triFirstIndex + g.triCount - 1
		else
			return 0, -1
		end
	else
		return 0, self.triIndexes.size/3-1
	end
end

-- yields with each material collection for a particular material name
-- default = no name = iterates over all materials
function Mesh:groupiter(groupname)
	return coroutine.wrap(function()
		if groupname then
			local _, g = self.groups:find(nil, function(g) return g.name == groupname end)
			if g then coroutine.yield(g, g.name) end
		else
			for _,g in ipairs(self.groups) do
				coroutine.yield(g, g.name)
			end
		end
	end)
end

-- calculate COM by 0-forms (vertexes)
function Mesh:calcCOM0()
	local result = vec3f()
	for i=0,self.vtxs.size-1 do
		result = result + self.vtxs.v[i].pos
	end
	result = result / self.vtxs.size
	if not math.isfinite(result:normSq()) then
io.stderr:write("couldn't even find the com0\n")
		return vec3f()
	end
	return result
end

-- calculate COM by 1-forms (edges)
-- depend on self.edges being stored
function Mesh:calcCOM1()
	local totalCOM = vec3f()
	local totalLen = 0
	for a,bs in pairs(self.edges) do
		for b in pairs(bs) do
			local v1 = self.vtxs.v[a-1].pos
			local v2 = self.vtxs.v[b-1].pos
			-- volume = *<Q,Q> = *(Q∧*Q) where Q = (b-a)
			-- for 1D, volume = |b-a|
			local length = (v1 - v2):norm()
			local com = (v1 + v2) * .5
			totalCOM = totalCOM + com * length
			totalLen = totalLen + length
		end
	end
	if totalLen == 0 then
		return self:calcCOM0()
	end
	local result = totalCOM / totalLen
	assert(math.isfinite(result:normSq()))
	return result
end

-- calculate COM by 2-forms (triangles)
-- volume = *<Q,Q> = *(Q∧*Q) where Q = (b-a) ∧ (c-a)
-- for 2D, volume = |(b-a)x(c-a)|
function Mesh:calcCOM2(groupname)
	local totalCOM = vec3f()
	local totalArea = 0
	local i1, i2 = self:getTriIndexesForMaterial(groupname)
	for i=i1,i2 do
		local t = self.tris[i+1]
		totalCOM = totalCOM + t.com * t.area
		totalArea = totalArea + t.area
	end
	if totalArea == 0 then
		return self:calcCOM1(groupname)
	end
	local result = totalCOM / totalArea
	assert(math.isfinite(result:normSq()))
	return result
end

-- calculate COM by 3-forms (enclosed volume)
function Mesh:calcCOM3(groupname)
	local totalCOM = vec3f()
	local totalVolume = 0
	local i1, i2 = self:getTriIndexesForMaterial(groupname)
	for i=i1,i2 do
		local t = self.tris[i+1]
		-- using [a,b,c,0] as the 4 pts of our tetrahedron
		-- volume = *<Q,Q> = *(Q∧*Q) where Q = (a-0) ∧ (b-0) ∧ (c-0)
		-- for 3D, volume = det|a b c|
		--local com = (a + b + c) * (1/4)
		local com = t.com * (3/4)

		local volume = t:calcTetradVolume(self)
		totalCOM = totalCOM + com * volume
		totalVolume = totalVolume + volume
	end
	-- if there's no volume then technically this can't exist ... but just fallback
	if totalVolume == 0 then
		return self:calcCOM2(groupname)
	end
	local result = totalCOM / totalVolume
	assert(math.isfinite(result:normSq()))
	return result
end

-- calculates volume bounded by triangles
function Mesh:calcVolume()
	local totalVolume = 0
	for i,t in ipairs(self.tris) do
		totalVolume = totalVolume + t:calcTetradVolume(self)
	end
	if totalVolume < 0 then totalVolume = -totalVolume end
	return totalVolume
end

function Mesh:clearVertexNormals()
	for i=0,self.vtxs.size-1 do
		self.vtxs.v[i].normal:set(0,0,0)
	end
end

-- split all indexes so index<->vertex is 1:1
function Mesh:breakAllVertexes()
	print('before breakAllVertexes, #vtxs '..self.vtxs.size..' #triindexes '..self.triIndexes.size)
	local nvtxs = vector('MeshVertex_t', self.triIndexes.size)
	local ntris = vector('uint32_t', self.triIndexes.size)
	for i=0,self.triIndexes.size-1 do
		nvtxs.v[i] = self.vtxs.v[self.triIndexes.v[i]]
		ntris.v[i] = i
	end
	self.vtxs = nvtxs
	self.triIndexes = ntris
	print('after breakAllVertexes, #vtxs '..self.vtxs.size..' #triindexes '..self.triIndexes.size)

	-- TODO update the mesh ranges as well
	-- assert they do not overlap before
	-- then sort them
	-- then remap them as we break tris

	for i,t in ipairs(self.tris) do
		-- update vertex COMs
		-- they are only valid now
		local com = t.com
		for j=0,2 do
			nvtxs.v[3*(i-1)+j].com = com
		end
	end

	-- tell the next draw to regen the buffer
	-- can I resize a gl arraybuffer?
	self.loadedGL = false
	self.vtxBuf = nil
	self.vtxAttrs = nil
	self.vao = nil

	self.edges = nil
	self.edgeIndexBuf = nil
	self.allOverlappingEdges = nil
	self.edges2 = nil

	self:calcBBox()
	self:findEdges()
	self:calcCOMs()
end

-- used for traversing loops
function Mesh:getIndexForLoopChain(l)
	local i = l.e[l.v]-1
	assert(i >= 0 and i < self.vtxs.size)
	return i
end
function Mesh:getVtxForLoopChain(l)
	return self.vtxs.v[self:getIndexForLoopChain(l)]
end
function Mesh:getPosForLoopChain(l)
	return self:getVtxForLoopChain(l).pos
end


--[[
find all edges that don't have exactly 2 triangle neighbors.
hmm ... I would like to use this but with the 'allOverlappingEdges' structure ...

hmm hmm maybe I need a mesh with all vertexes merged into their neighboring edges/triangles
and mapping that information back to the original mesh

TODO I might need this but for all edge segments, based on 'allOverlappingEdges' and each subinterval of each triangle edge.
--]]
function Mesh:findBadEdges()
	-- find edges based on vtx comparing pos
	local uniquevs, indexToUniqueV = self:getUniqueVtxs(1e-6)
	self:findEdges(function(i) return uniquevs[indexToUniqueV[i]] end)

	local border = table()
	local totalEdges = 0
	for a,o in pairs(self.edges) do
		for b,e in pairs(o) do
			if #e.tris == 1 then
				border:insert(e)
			end
			totalEdges = totalEdges + 1
		end
	end

print('edges total', totalEdges, 'border', #border)
assert(#self.tris*3 == self.triIndexes.size)
for i,t in ipairs(self.tris) do assert(t.index == i) end
	
	-- now put in loops
	local all = table(border)
	local loops = table()
	local lines = table()
	while #all > 0 do
		local loop = table()
		local last = all:remove(1)
--print('first edge', last[1], last[2])
		-- loop traversal / first edge vtx should be based on edge/tri orientation
		-- the loop should go opposite the triangle orientation
		-- for our single tri touching the edge ...
		-- find vtx j on the tri such that tri[j], tri[j+1] == e[1], e[2] , order-independent
		-- then for whatever j+1 is on e, start with that one
		assert(#last.tris == 1, "found an edge which isn't really an edge...")
		local lastvi
		for j=0,2 do
			local ti = last.tris[1].index-1
			local tj1 = uniquevs[indexToUniqueV[self.triIndexes.v[j+3*ti]]]
			local tj2 = uniquevs[indexToUniqueV[self.triIndexes.v[(j+1)%3+3*ti]]]
			local e1 = uniquevs[indexToUniqueV[last[1]-1]]
			local e2 = uniquevs[indexToUniqueV[last[2]-1]]
			if tj1 == e1 and tj2 == e2 then
				assert(not lastvi, "we have a tri with two edges that use the same vtxs...")
				lastvi = 2	-- so we start on 2
			elseif tj1 == e2 and tj2 == e1 then
				assert(not lastvi, "we have a tri with two edges that use the same vtxs...")
				lastvi = 1	-- so we start on 1
			end
		end
		assert(lastvi, "we have a first edge with a single tri which it doesn't touch...")
		loop:insert{v=3-lastvi, e=last}
		while true do
			local found
			for i=1,#all do
				local o = all[i]
--print('checking edge', o[1], o[2])
				for j=1,2 do
					if o[j] == last[lastvi] then
						last = o
						lastvi = 3-j
						loop:insert{v=3-lastvi, e=o}
						all:remove(i)
						found = true
--print('adding edge', last[1], last[2])
						break
					end
				end
				if found then break end
			end
			if not found then
--print('found no more edges, adding to lines')
				lines:insert(loop)
				break
			else
				if last[lastvi] == loop[1].e[loop[1].v] then
--print('reached beginning, adding to loops')
					loops:insert(loop)
					break
				end
			end
		end
	end
print('#loops', #loops)
print('#lines', #lines)

	-- no boundary edges that aren't loops
	-- lines?  how to fix those?
	--if #lines > 0 then error("can't fix stupid") end
	-- luckily I never have to find out (yet)
	-- is this even possible?

	for i,loop in ipairs(loops) do
print('loop #'..i..': '..loop:mapi(function(l) return self:getIndexForLoopChain(l) end):concat', ')
		--[[ determine if the loop is planar (and determine its normal)
		for j=1,#loop-1 do
			local a = self:getPosForLoopChain(loop[j])
			local b = self:getPosForLoopChain(loop[j%#loop+1])
			local c = self:getPosForLoopChain(loop[(j+1)%#loop+1])
			local n = (c - b):cross(b - a)
			print(n)
		end
		--]]
		--[[ just add the tris as-is
-- TODO how to determine loop order ...
-- probably based on normal of opposing edges triangles
if loop[1].e.tris[1][1].v == loop[1].e[1] then
loop = loop:reverse()
end
		for j=2,#loop-1 do
			self.triIndexes:push_back(self:getIndexForLoopChain(loop[1]))
			self.triIndexes:push_back(self:getIndexForLoopChain(loop[j]))
			self.triIndexes:push_back(self:getIndexForLoopChain(loop[j+1]))
		end
		--]]
		--assert(#loop >= 3)
	end

	-- here ... optional?
	-- filter out loops with zero area
	for i=#loops,1,-1 do
		local loop = loops[i]
		local n
		local totalArea = 0
		for j=2,#loop-1 do
			local a = self:getPosForLoopChain(loop[1])
			local b = self:getPosForLoopChain(loop[j])
			local c = self:getPosForLoopChain(loop[j+1])
			local ab = b - a
			local ac = c - a
			local x = ab:cross(ac)
			local xlen = x:norm()
			if xlen > 1e-7 then
				local area
				if not n then
					n = x / xlen
					area = .5 * xlen
--print('normal', n)
				else
					area = .5 * ab:cross(ac):dot(n)
				end
--print('adding', area)
				totalArea = totalArea + area
			end
		end
		if totalArea < 1e-7 then
			print('loop #'..i..' has area '..totalArea..' ... removing')
			loops:remove(i)
		else
			print('loop #'..i..' has area '..totalArea..' ... keeping')
		end
	end

	return loops, lines
end

--[[
doesn't break intersecting tris.
just removes any tris that are internal.
--]]
function Mesh:removeInternalTris()
	--[[
	TODO first break-triangle operation first ... how to break triangles
	otherwise this doesn't go far.
	how to break triangles?
	detct collision
	how to detect collision?
		ensure each line segment of A, projected to B is not within B
		and vice versa.
	what if there is a collision -- how to break?
	--]]

	for i=#self.tris,1,-1 do
		for j=i-1,1,-1 do
			-- TODO ...
		end
	end

	local edges = self:findBadEdges()

	-- second ... merge vertexes
	-- in fact I should look at the merge map of vertexes w/o texcoord or normal condition
	if not self.bbox then self:calcBBox() end
	local bboxCornerDist = (self.bbox.max - self.bbox.min):norm()
	local vtxMergeThreshold = bboxCornerDist * 1e-6
	local uniquevs, indexToUniqueV = self:getUniqueVtxs(vtxMergeThreshold)

	-- now find edges based on nearest vtx only
	-- TODO separate the edge info from Mesh?
	self:findEdges(function(i)
		return uniquevs[indexToUniqueV[i]]
	end)

	-- finally remove internal tris.
	-- what determines if a triangle is internal?
	-- 1) it needs to have all edges with >2 neighbors.
	-- 2) per-edge, the other two tris planes must have this tri behind them
	-- this won't skip floating edge tris ... those need to be removed separately.
	-- this also won't remove 'internal' tris if there's a hole on the bounding region.
	assert(#self.tris*3 == self.triIndexes.size)
	for i,t in ipairs(self.tris) do
		-- if the triangle intersects another then it needs to break
	end

	self.edges = nil
	self.edgeIndexBuf = nil
end

-- regenerate the vertex normals based on the face normals, weighted average by angle (tesselation-independent and curvature-driven)
function Mesh:generateVertexNormals()
	-- calculate vertex normals
	-- TODO store this?  in its own self.vn2s[] or something?
--print('zeroing vertex normals')
	for i=0,self.vtxs.size-1 do
		self.vtxs.v[i].normal:set(0,0,0)
	end
--print('accumulating triangle normals into vertex normals')
	for i=0,self.triIndexes.size-1,3 do
		local ia = self.triIndexes.v[i]
		local ib = self.triIndexes.v[i+1]
		local ic = self.triIndexes.v[i+2]
		-- not sure what i'm doing with these ...
		-- cache or regen?
		local va = self.vtxs.v[ia]
		local vb = self.vtxs.v[ib]
		local vc = self.vtxs.v[ic]
		local pa = self.vtxs.v[ia].pos
		local pb = self.vtxs.v[ib].pos
		local pc = self.vtxs.v[ic].pos
		local ab = (pb - pa):normalize()
		local bc = (pc - pb):normalize()
		local ca = (pa - pc):normalize()
		local normal = ab:cross(bc):normalize()
		local thetaA = math.acos(math.clamp(-ab:dot(ca),-1,1))
		local thetaB = math.acos(math.clamp(-bc:dot(ab),-1,1))
		local thetaC = math.acos(math.clamp(-ca:dot(bc),-1,1))
		va.normal = va.normal + normal * thetaA
		vb.normal = vb.normal + normal * thetaB
		vc.normal = vc.normal + normal * thetaC
	end
--print('normals vertex normals')
	for i=0,self.vtxs.size-1 do
		local v = self.vtxs.v[i]
		local len = v.normal:norm()
		if len > 1e-7 then
			v.normal = v.normal * (1 / len)
		else
			v.normal:set(0,0,0)
		end
--print(k, vtxnormals[i])
	end

	if self.vtxBuf then
		self.vtxBuf:updateData(0, ffi.sizeof'MeshVertex_t' * self.vtxs.size, self.vtxs.v)
	end
end

--[[
in-place clip a mesh by a plane
do so by removing all backfacing triangles
and splitting any overlapping triangles

plane = clip plane (not necessarily normalized)
--]]
function Mesh:clip(plane)
	local modified
if #self.tris*3 ~= self.triIndexes.size then
	error("3*#tris is "..(3*#self.tris).." while triIndexes is "..self.triIndexes.size)
end
	for _,g in ipairs(self.groups) do
		for ti=g.triFirstIndex+g.triCount-1,g.triFirstIndex,-1 do
			local t = self.tris[ti+1]
			local tp = self.triIndexes.v + 3*ti
			local vs = range(0,2):mapi(function(j) return self.vtxs.v[tp[j]] end)
			local planeDists = vs:mapi(function(v) return plane:dist(v.pos) end)
			local sides = planeDists:mapi(function(d) return d >= 0 end)
			local frontCount = sides:mapi(function(s) return s and 1 or 0 end):sum()
--print('frontCount', frontCount)
			if frontCount == 3 then
--print('...keep')
				-- keep
			elseif frontCount == 0 then
				modified = true
--print('...remove')
if #self.tris*3 ~= self.triIndexes.size then
	error("3*#tris is "..(3*#self.tris).." while triIndexes is "..self.triIndexes.size)
end
				self:removeTri(3*ti)	-- remove
if #self.tris*3 ~= self.triIndexes.size then
	error("3*#tris is "..(3*#self.tris).." while triIndexes is "..self.triIndexes.size)
end
			-- needs a new vertex:
			else
				modified = true
				local found
				for j=0,2 do
					if (frontCount == 1 and sides[j+1])
					or (frontCount == 2 and not sides[j+1])
					then
--print('splitting on '..j..'th side')
						local j1 = (j+1)%3
						local j2 = (j1+1)%3
						-- separate off this triangle
						local d1 = planeDists[j1+1] - planeDists[j+1]
						local d2 = planeDists[j2+1] - planeDists[j+1]

						local iv01 = self.vtxs.size
						local nv01 = self.vtxs:emplace_back()
						local s01 = (0 - planeDists[j+1]) / d1
						nv01.pos = math.mix(vs[j+1].pos, vs[j1+1].pos, s01)
						nv01.texcoord = math.mix(vs[j+1].texcoord, vs[j1+1].texcoord, s01)
						nv01.normal = math.mix(vs[j+1].normal, vs[j1+1].normal, s01)

						local iv02 = self.vtxs.size
						local nv02 = self.vtxs:emplace_back()
						local s02 = (0 - planeDists[j+1]) / d2
						nv02.pos = math.mix(vs[j+1].pos, vs[j2+1].pos, s02)
						nv02.texcoord = math.mix(vs[j+1].texcoord, vs[j2+1].texcoord, s02)
						nv02.normal = math.mix(vs[j+1].normal, vs[j2+1].normal, s02)

						local iv0 = tp[j]
						local iv1 = tp[j1]
						local iv2 = tp[j2]
						-- now go from iv0 iv1 iv2
						-- to iv0 iv01 iv02, iv01 iv1 iv2, iv01 iv2 iv02
						-- soo .. replace the current with the first, and insert the other two
						-- this is rotating it to put j at 0
						if frontCount == 1 then	-- shorten the leading side
							tp[j] = iv0
							tp[(j+1)%3] = iv01
							tp[(j+2)%3] = iv02
						else -- replace tp with the base and insert a second base to make a quad
if #self.tris*3 ~= self.triIndexes.size then
	error("3*#tris is "..(3*#self.tris).." while triIndexes is "..self.triIndexes.size)
end
							-- insert these into the same material group as we're currently in
							local nti = ti + 1
							tp[0] = iv01
							tp[1] = iv1
							tp[2] = iv2
							-- [[ TODO use insertTri instead
							self.triIndexes:insert(self.triIndexes:begin() + 3*ti + 3, iv01)
							self.triIndexes:insert(self.triIndexes:begin() + 3*ti + 4, iv2)
							self.triIndexes:insert(self.triIndexes:begin() + 3*ti + 5, iv02)
							self.tris:insert(ti+1, Triangle{
								index = nti+1,	-- +1 cuz its' 1-based
							})
							for _,g2 in ipairs(self.groups) do
								if nti <= g2.triFirstIndex then
									g2.triFirstIndex = g2.triFirstIndex + 1
								end
							end
							g.triCount = g.triCount + 1
if #self.tris*3 ~= self.triIndexes.size then
	error("3*#tris is "..(3*#self.tris).." while triIndexes is "..self.triIndexes.size)
end
							--]]
							--[[
							self:insertTri(iv01, iv2, iv02, nti)
							--]]
						end
						found = true
						break
					end
				end
				if not found then
					error'here'
				end
			end
		end
	end

if #self.tris*3 ~= self.triIndexes.size then
	error("3*#tris is "..(3*#self.tris).." while triIndexes is "..self.triIndexes.size)
end
	self:rebuildTris()
	self:mergeMatchingVertexes()	-- better to merge vtxs than remove empty tris cuz it will keep seams in models
	--self:removeEmptyTris()

if #self.tris*3 ~= self.triIndexes.size then
	error("3*#tris is "..(3*#self.tris).." while triIndexes is "..self.triIndexes.size)
end

	self.loadedGL = nil
	self.vtxBuf = nil
	return modified
end

function Mesh:fillHoles()
print('Mesh:fillHoles begin')
	local loops, lines = self:findBadEdges()

	-- just add it to the last group
	local _, g = self.groups:find(nil, function(g)
		return (g.triFirstIndex + g.triCount) * 3 == self.triIndexes.size
	end)
	assert(g, "are you sure you have any groups in this mesh?")

	for i,loop in ipairs(loops) do
print('loop #'..i..': '..loop:mapi(function(l) return self:getIndexForLoopChain(l) end):concat', ')
		-- [[ determine if the loop is planar (and determine its normal)
		local planenormal
		local planeorigin = self:getPosForLoopChain(loop[1])
		for j=1,#loop-1 do
			local a = self:getPosForLoopChain(loop[j])
			local b = self:getPosForLoopChain(loop[j%#loop+1])
			local c = self:getPosForLoopChain(loop[(j+1)%#loop+1])
			local n, len = (b - a):cross(c - a):unitOrZero()
			if len > 1e-1 then
				-- should I average them ?  or should I enforce that they all match?
				if not planenormal then
					planenormal = n
				else
					if math.abs(planenormal:dot(n)) < 1 - 1e-1 then
						io.stderr:write("old normal was "..planenormal..", new normal is "..n..", loop is not planar\n")
					end
				end
			end
		end
		if not planenormal then
			return false, "plane normal not found"
		end
		local ex, ey = planenormal:perpendicular2()
print('plane basis ex ey n', ex, ey, planenormal)
		--]]
		-- [[ just add the tris as-is
		--[=[ TODO how to determine loop order ...
		-- probably based on normal of opposing edges triangles
		if loop[1].e.tris[1][1].v == loop[1].e[1] then
		end
		--]=]
		-- TODO when to reverse ...
		-- this should be based on which side is inside
		-- how to detect that?
		-- ray test from loop center in direction of loop normal
		--loop = loop:reverse()

		-- now I need a basis point (loop[0] works)
		-- and I need a basis vector (orthogonal to plane normal works)
		-- and I need to know the handedness of the edge loop around the vector
		-- and then I need to sort along one basis vector
		-- track edges
		-- and fill in rhombuses as I go
print'calc uv'		
		for _,l in ipairs(loop) do
			local d = self:getPosForLoopChain(l) - planeorigin
			l.uv = vec2f(d:dot(ex), d:dot(ey))
		end

		--[=[ naive fan implementation - only works on convex polygons
		-- TODO pick origin of fan as a corner and reduce # of tris (or gen a lot of 0-area tris to be reduced later)
		-- TODO this only works for convex polygons ...what about concave shapes? gets more complicated.
		-- TODO TODO for that, sweep across the poly, keep track of edges, do just like with software rendering
print'adding indices'		
		for j=2,#loop-1 do
			self.triIndexes:push_back(self:getIndexForLoopChain(loop[1]))
			self.triIndexes:push_back(self:getIndexForLoopChain(loop[j]))
			self.triIndexes:push_back(self:getIndexForLoopChain(loop[j+1]))
			g.triCount = g.triCount + 1
		end
		--]=]
		-- [=[ earcut
		local indata = range(#loop*2):mapi(function(l,i)
			return loop[bit.rshift(i-1,1)+1].uv.s[bit.band(i-1,1)]
		end)
print('indata', require 'ext.tolua'(indata))
		local outdata = require 'mesh.earcut'(indata, {})
print('outdata', require 'ext.tolua'(outdata))
		assert(#outdata % 3 == 0)
		-- TODO when to reverse ...
		for ti=0,#outdata/3-1 do
			for k=0,2 do
				local j = 2-k+3*ti+1
				local o = outdata[j]
print('adding to loop-index', o, 'vtx index', self:getIndexForLoopChain(loop[o]), 'uv', loop[o].uv, 'pos', self:getPosForLoopChain(loop[o]))
				self.triIndexes:emplace_back()[0] = self:getIndexForLoopChain(loop[o])
			end
		end
		g.triCount = g.triCount + #outdata/3
		--]=]
		--]]
		assert(#loop >= 3)
	end

	self.vtxBuf = nil
	self:rebuildTris()
print('Mesh:fillHoles end')
end

-- 'fwd' is used for depth calculation, 'dir' is the ray direction
function Mesh:findClosestVertexToMouseRay(pos, dir, fwd, cosEpsAngle)
	-- assumes dir is 1 unit fwd along the view fwd
	--dir = dir:normalize()
	local dirlen = dir:norm()
	local bestdot, besti, bestdepth
	for i=0,self.vtxs.size-1 do
		local v = self.vtxs.v[i].pos
		local delta = v - pos
		local depth = delta:dot(fwd)
		--local dot = dir:dot(delta) / (delta:norm() * dirlen)
		local dot = dir:unit():dot(delta:unit())
		if dot > cosEpsAngle then
			if not bestdepth
			or depth < bestdepth
			then
				besti = i
				bestdepth = depth
				bestdot = dot
			end
		end
	end
	return besti, bestdepth
end

function Mesh:findClosestTriToMouseRay(pos, dir, fwd, cosEpsAngle)
	-- assumes dir is 1 unit fwd along the view fwd
	--dir = dir:normalize()
	local dirlen = dir:norm()
	local besti, bestdist
	assert(#self.tris * 3 == self.triIndexes.size)
	for ti,t in ipairs(self.tris) do
		local i = 3*(ti-1)
		local tnormal, area = t.normal, t.area

		local a,b,c = t:vtxPos(self)
		local planePt = a
		if area > 1e-7 then
			-- make sure it's pointing towards the ray origin
			if tnormal:dot(dir) < 0 then tnormal = -tnormal end

			local p, s = plane3f():fromDirPt(tnormal, planePt):intersectRay(pos, dir)
			if s >= 0 and (not bestdist or s < bestdist) then
				-- barycentric coordinates
				if t:insideBCC(p, self) then
					besti = i
					bestdist = s
				end
			end
		end
	end
	return besti, bestdist
end


-- all the draw functionality is tied tightly with view.lua so ...
-- idk if i should move it from one or the other


-- upon ctor the images are loaded (in case the caller isn't using GL)
-- so upon first draw - or upon manual call - load the gl textures
function Mesh:loadGL(shader)
	if self.loadedGL then return end
	self.loadedGL = true

	local gl = require 'gl'
	local glreport = require 'gl.report'
	local GLTex2D = require 'gl.tex2d'
	local GLArrayBuffer = require 'gl.arraybuffer'
	local GLAttribute = require 'gl.attribute'
	local GLVertexArray = require 'gl.vertexarray'

	-- load textures
	for _,g in ipairs(self.groups) do
		if g.image_Kd
		and not g.tex_Kd
		then
			g.tex_Kd = GLTex2D{
				image = g.image_Kd,
				minFilter = gl.GL_NEAREST,
				magFilter = gl.GL_LINEAR,
			}
		end
	end

--print('creating array buffer of size', self.vtxs.size)
	if not self.vtxBuf then
		self.vtxBuf = GLArrayBuffer{
			size = self.vtxs.size * ffi.sizeof'MeshVertex_t',
			data = self.vtxs.v,
			usage = gl.GL_STATIC_DRAW,
		}
		assert(glreport'here')

		self.vtxAttrs = table{
			{name='pos', size=3},
			{name='texcoord', size=3},
			{name='normal', size=3},
			{name='com', size=3},
		}:mapi(function(info)
			if not shader.attrs[info.name] then return end
			return GLAttribute{
				buffer = self.vtxBuf,
				size = info.size,
				type = gl.GL_FLOAT,
				stride = ffi.sizeof'MeshVertex_t',
				offset = ffi.offsetof('MeshVertex_t', info.name),
			}, info.name
		end)
		shader:use()
		assert(glreport'here')
		self.vao = GLVertexArray{
			program = shader,
			attrs = self.vtxAttrs,
		}
		shader:setAttrs(self.vtxAttrs)
		shader:useNone()
		assert(glreport'here')
	end
end

function Mesh:draw(args)
	local gl = require 'gl'

	self:loadGL()	-- load if not loaded

	local curtex
	for _,g in ipairs(self.groups) do
		--[[
		if g.Kd then
			gl.glColor4f(g.Kd:unpack())
		else
			gl.glColor4f(1,1,1,1)
		end
		--]]
		--[[
		if g
		and g.tex_Kd
		and not (args and args.disableTextures)
		then
			-- TODO use .Ka, Kd, Ks, Ns, etc
			-- with fixed pipeline?  opengl lighting?
			-- with a shader in the wavefrontobj lib?
			-- with ... nothing?
			curtex = g.tex_Kd
			curtex:enable()
			curtex:bind()
		else
			if curtex then
				curtex:unbind()
				curtex:disable()
				curtex = nil
			end
		end
		--]]
		if args.beginGroup then args.beginGroup(g) end

		--[[ immediate mode
		gl.glBegin(gl.GL_TRIANGLES)
		for vi in self:triindexiter(g.name) do
			-- TODO store a set of unique face v/vt/vn index-vertexes
			-- and then bake those into a unique vertex array, and store its index alongside face's other indexes
			-- that'll be most compat with GL indexed arrays
			local v = self.vtxs.v[vi]
			gl.glTexCoord2fv(v.texcoord.s)
			gl.glNormal3fv(v.normal.s)
			gl.glVertex3fv(self.vtxs.v[vi].pos.s)
		end
		gl.glEnd()
		--]]
		--[[ vertex client arrays
		gl.glVertexPointer(3, gl.GL_FLOAT, ffi.sizeof'MeshVertex_t', g.vtxs.v[0].pos.s)
		gl.glTexCoordPointer(3, gl.GL_FLOAT, ffi.sizeof'MeshVertex_t', g.vtxs.v[0].texcoord.s)
		gl.glNormalPointer(gl.GL_FLOAT, ffi.sizeof'MeshVertex_t', g.vtxs.v[0].normal.s)
		gl.glEnableClientState(gl.GL_VERTEX_ARRAY)
		gl.glEnableClientState(gl.GL_TEXTURE_COORD_ARRAY)
		gl.glEnableClientState(gl.GL_NORMAL_ARRAY)
		gl.glDrawArrays(gl.GL_TRIANGLES, 0, g.vtxs.size)
		gl.glDisableClientState(gl.GL_VERTEX_ARRAY)
		gl.glDisableClientState(gl.GL_TEXTURE_COORD_ARRAY)
		gl.glDisableClientState(gl.GL_NORMAL_ARRAY)
		--]]
		--[[ vertex attrib pointers ... requires specifically-named attrs in the shader
		gl.glVertexAttribPointer(args.shader.attrs.pos.loc, 3, gl.GL_FLOAT, gl.GL_FALSE, ffi.sizeof'MeshVertex_t', g.vtxs.v[0].pos.s)
		gl.glVertexAttribPointer(args.shader.attrs.texcoord.loc, 3, gl.GL_FLOAT, gl.GL_FALSE, ffi.sizeof'MeshVertex_t', g.vtxs.v[0].texcoord.s)
		gl.glVertexAttribPointer(args.shader.attrs.normal.loc, 3, gl.GL_FLOAT, gl.GL_TRUE, ffi.sizeof'MeshVertex_t', g.vtxs.v[0].normal.s)
		gl.glEnableVertexAttribArray(args.shader.attrs.pos.loc)
		gl.glEnableVertexAttribArray(args.shader.attrs.texcoord.loc)
		gl.glEnableVertexAttribArray(args.shader.attrs.normal.loc)
		gl.glDrawArrays(gl.GL_TRIANGLES, 0, g.vtxs.size)
		gl.glDisableVertexAttribArray(args.shader.attrs.pos.loc)
		gl.glDisableVertexAttribArray(args.shader.attrs.texcoord.loc)
		gl.glDisableVertexAttribArray(args.shader.attrs.normal.loc)
		--]]
		-- [[ vao ... getting pretty tightly coupled with the view.lua file ...
		if g.triCount > 0 then
			self.vao:use()
			gl.glDrawElements(gl.GL_TRIANGLES, g.triCount * 3, gl.GL_UNSIGNED_INT, self.triIndexes.v + g.triFirstIndex * 3)
			self.vao:useNone()
		end
		--]]
		if args.endGroup then args.endGroup(g) end
	end
	--[[
	if curtex then
		curtex:unbind()
		curtex:disable()
	end
	--]]
	require 'gl.report''here'
end

-- make sure my edges match my faces
-- can't handle group explode dist because edges aren't stored associted with materials ...
-- they are per-tri, which is per-face, which is per-material, but there can be multiple materials per edge.
function Mesh:drawEdges(triExplodeDist, groupExplodeDist)
	local gl = require 'gl'

	if not self.edgeIndexBuf then
		self:findEdges()
	end

	--gl.glLineWidth(3)
	gl.glColor3f(1,1,0)

	-- TODO shader that does the explode stuff
	gl.glVertexPointer(3, gl.GL_FLOAT, ffi.sizeof'MeshVertex_t', self.vtxs.v[0].pos.s)
	gl.glEnableClientState(gl.GL_VERTEX_ARRAY)
	gl.glDrawElements(gl.GL_LINES, self.edgeIndexBuf.size, gl.GL_UNSIGNED_INT, self.edgeIndexBuf.v)
	gl.glDisableClientState(gl.GL_VERTEX_ARRAY)

	--gl.glLineWidth(1)
end

function Mesh:drawVertexes(triExplodeDist, groupExplodeDist)
	local gl = require 'gl'
	gl.glColor3f(1,1,1)
	gl.glPointSize(3)

	-- TODO shader that does the explode stuff
	gl.glVertexPointer(3, gl.GL_FLOAT, ffi.sizeof'MeshVertex_t', self.vtxs.v[0].pos.s)
	gl.glEnableClientState(gl.GL_VERTEX_ARRAY)
	gl.glDrawArrays(gl.GL_POINTS, 0, self.vtxs.size)
	gl.glDisableClientState(gl.GL_VERTEX_ARRAY)

	gl.glPointSize(1)
end

function Mesh:drawVertexNormals()
	local gl = require 'gl'
	gl.glColor3f(0,1,1)
	gl.glBegin(gl.GL_LINES)
	for i=0,self.vtxs.size-1 do
		local v = self.vtxs.v[i]
		gl.glVertex3f(v.pos:unpack())
		gl.glVertex3f((v.pos + v.normal):unpack())
	end
	gl.glEnd()
end

function Mesh:drawTriNormals()
	local gl = require 'gl'
	gl.glColor3f(0,1,1)
	gl.glBegin(gl.GL_LINES)
	for i,t in ipairs(self.tris) do
		gl.glVertex3fv(t.com.s)
		gl.glVertex3fv((t.com + t.normal).s)
	end
	gl.glEnd()
end

function Mesh:drawTriBasis()
	local gl = require 'gl'
	gl.glLineWidth(3)
	gl.glBegin(gl.GL_LINES)
	for i,t in ipairs(self.tris) do
		if t.basis then
			gl.glColor3f(1,0,0)
			gl.glVertex3f(t.com:unpack())
			gl.glVertex3f((t.com + t.basis[1]):unpack())
			gl.glColor3f(0,1,0)
			gl.glVertex3f(t.com:unpack())
			gl.glVertex3f((t.com + t.basis[2]):unpack())
			gl.glColor3f(0,0,1)
			gl.glVertex3f(t.com:unpack())
			gl.glVertex3f((t.com + t.basis[3]):unpack())
		end
	end
	gl.glEnd()
	gl.glLineWidth(1)
end

return Mesh
