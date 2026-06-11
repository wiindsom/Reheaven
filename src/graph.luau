--!native

export type NodeId = number
export type LinkId = number
export type ReactiveFlags = number

export type MetaBuffers = {
	buffers: { buffer };
	ensure: (node: NodeId) -> { buffer };
	reset: () -> { buffer };
}

-----------------------------------------------------------------------------

const NIL = 0
const U32 = 4

const NONE = 0b000000
const MUTABLE = 0b000001
const WATCHING = 0b000010
const RECURSED_CHECK = 0b000100
const RECURSED = 0b001000
const DIRTY = 0b010000
const PENDING = 0b100000
const QUEUED = 0b1000000

const MUTABLE_DIRTY = bit32.bor(MUTABLE, DIRTY)
const MUTABLE_PENDING = bit32.bor(MUTABLE, PENDING)
const RECURSION_FLAGS = bit32.bor(RECURSED_CHECK, RECURSED)
const STALE_FLAGS = bit32.bor(RECURSED_CHECK, RECURSED, DIRTY, PENDING)
const PENDING_DIRTY = bit32.bor(PENDING, DIRTY)
const WATCHING_CHECK = bit32.bor(WATCHING, RECURSED_CHECK)

local ReactiveFlags = table.freeze({
	None = NONE;
	Mutable = MUTABLE;
	Watching = WATCHING;
	RecursedCheck = RECURSED_CHECK;
	Recursed = RECURSED;
	Dirty = DIRTY;
	Pending = PENDING;
	Queued = QUEUED;
})

-----------------------------------------------------------------------------

const GRAPH_INITIAL_CAPACITY = 262_144 -- how much nodes/links are preallocated before dynamic growth, u dont have to touch..

const NODE_INITIAL_CAPACITY = GRAPH_INITIAL_CAPACITY
const LINK_INITIAL_CAPACITY = GRAPH_INITIAL_CAPACITY
const STACK_INITIAL_CAPACITY = GRAPH_INITIAL_CAPACITY // 64

-----------------------------------------------------------------------------

local nodeCapacity = NODE_INITIAL_CAPACITY
local linkCapacity = LINK_INITIAL_CAPACITY
local stackCapacity = STACK_INITIAL_CAPACITY

local nodeCount, linkCount = 0, 0
local freeLink = NIL

local nodeFlags = buffer.create(nodeCapacity)
local nodeSources = buffer.create(nodeCapacity * U32)
local nodeSourcesTail = buffer.create(nodeCapacity * U32)
local nodeTargets = buffer.create(nodeCapacity * U32)
local nodeTargetsTail = buffer.create(nodeCapacity * U32)

local linkVersion = buffer.create(linkCapacity * U32)
local linkSource = buffer.create(linkCapacity * U32)
local linkTarget = buffer.create(linkCapacity * U32)
local linkPrevSource = buffer.create(linkCapacity * U32)
local linkNextSource = buffer.create(linkCapacity * U32)
local linkPrevTarget = buffer.create(linkCapacity * U32)
local linkNextTarget = buffer.create(linkCapacity * U32)

local stackData = buffer.create(stackCapacity * U32)

local readu8 = buffer.readu8
local writeu8 = buffer.writeu8
local readu32 = buffer.readu32
local writeu32 = buffer.writeu32
local create = buffer.create
local copy = buffer.copy

local update: (node: NodeId) -> boolean
local notify: (node: NodeId) -> ()
local unwatched: (node: NodeId) -> ()
local stale: (node: NodeId) -> ()

-----------------------------------------------------------------------------

local function createMetaBuffers(count: number): MetaBuffers
	local capacity = GRAPH_INITIAL_CAPACITY
	local buffers = table.create(count)
	for i = 1, count do
		buffers[i] = buffer.create(capacity)
	end
	local function ensure(node: NodeId)
		if node <= capacity then
			return buffers
		end
		local oldCapacity = capacity
		repeat
			capacity *= 2
		until node <= capacity
		for i = 1, count do
			local old = buffers[i]
			local new = buffer.create(capacity)
			buffer.copy(new, 0, old, 0, oldCapacity)
			buffers[i] = new
		end
		return buffers
	end
	local function reset()
		capacity = GRAPH_INITIAL_CAPACITY
		for i = 1, count do
			buffers[i] = buffer.create(capacity)
		end
		return buffers
	end
	return {
		buffers = buffers;
		ensure = ensure;
		reset = reset;
	}
end

local function nodeOffset(node: NodeId): number
	return (node - 1) * U32
end

local function linkOffset(link: LinkId): number
	return (link - 1) * U32
end

local function flagOffset(node: NodeId): number
	return node - 1
end

local function growNodeBuffers()
	local oldCapacity = nodeCapacity
	nodeCapacity *= 2
	
	local oldFlags = nodeFlags
	local oldSources = nodeSources
	local oldSourcesTail = nodeSourcesTail
	local oldTargets = nodeTargets
	local oldTargetsTail = nodeTargetsTail
	nodeFlags = create(nodeCapacity)
	nodeSources = create(nodeCapacity * U32)
	nodeSourcesTail = create(nodeCapacity * U32)
	nodeTargets = create(nodeCapacity * U32)
	nodeTargetsTail = create(nodeCapacity * U32)
	copy(nodeFlags, 0, oldFlags, 0, oldCapacity)
	copy(nodeSources, 0, oldSources, 0, oldCapacity * U32)
	copy(nodeSourcesTail, 0, oldSourcesTail, 0, oldCapacity * U32)
	copy(nodeTargets, 0, oldTargets, 0, oldCapacity * U32)
	copy(nodeTargetsTail, 0, oldTargetsTail, 0, oldCapacity * U32)
end

local function growLinkBuffers()
	local oldCapacity = linkCapacity
	linkCapacity *= 2
	
	local oldVersion = linkVersion
	local oldSource = linkSource
	local oldTarget = linkTarget
	local oldPrevSource = linkPrevSource
	local oldNextSource = linkNextSource
	local oldPrevTarget = linkPrevTarget
	local oldNextTarget = linkNextTarget
	linkVersion = create(linkCapacity * U32)
	linkSource = create(linkCapacity * U32)
	linkTarget = create(linkCapacity * U32)
	linkPrevSource = create(linkCapacity * U32)
	linkNextSource = create(linkCapacity * U32)
	linkPrevTarget = create(linkCapacity * U32)
	linkNextTarget = create(linkCapacity * U32)
	
	local bytes = oldCapacity * U32
	copy(linkVersion, 0, oldVersion, 0, bytes)
	copy(linkSource, 0, oldSource, 0, bytes)
	copy(linkTarget, 0, oldTarget, 0, bytes)
	copy(linkPrevSource, 0, oldPrevSource, 0, bytes)
	copy(linkNextSource, 0, oldNextSource, 0, bytes)
	copy(linkPrevTarget, 0, oldPrevTarget, 0, bytes)
	copy(linkNextTarget, 0, oldNextTarget, 0, bytes)
end

local function growStack()
	local oldCapacity = stackCapacity
	local oldStack = stackData
	stackCapacity *= 2
	stackData = create(stackCapacity * U32)
	copy(stackData, 0, oldStack, 0, oldCapacity * U32)
end

local function stackWrite(index: number, value: number)
	if index > stackCapacity then growStack() end
	writeu32(stackData, (index - 1) * U32, value)
end

local function stackRead(index: number): number
	return readu32(stackData, (index - 1) * U32)
end

local function createNode(flags: number): NodeId
	nodeCount += 1
	if nodeCount > nodeCapacity then growNodeBuffers() end
	local node = nodeCount
	local offset = nodeOffset(node)
	writeu8(nodeFlags, flagOffset(node), flags)
	writeu32(nodeSources, offset, NIL)
	writeu32(nodeSourcesTail, offset, NIL)
	writeu32(nodeTargets, offset, NIL)
	writeu32(nodeTargetsTail, offset, NIL)
	return node
end

local function getFlags(node: NodeId): number
	return readu8(nodeFlags, flagOffset(node))
end

local function setFlags(node: NodeId, flags: number)
	writeu8(nodeFlags, flagOffset(node), flags)
end

local function getSources(node: NodeId): LinkId
	return readu32(nodeSources, nodeOffset(node))
end

local function getTargets(node: NodeId): LinkId
	return readu32(nodeTargets, nodeOffset(node))
end

local function allocLink(): LinkId
	if freeLink ~= NIL then
		local link = freeLink
		freeLink = readu32(linkNextTarget, linkOffset(link))
		return link
	end
	linkCount += 1
	if linkCount > linkCapacity then growLinkBuffers() end
	return linkCount
end

local function recycleLink(link: LinkId)
	local offset = linkOffset(link)
	writeu32(linkVersion, offset, NIL)
	writeu32(linkSource, offset, NIL)
	writeu32(linkTarget, offset, NIL)
	writeu32(linkPrevSource, offset, NIL)
	writeu32(linkNextSource, offset, NIL)
	writeu32(linkPrevTarget, offset, NIL)
	writeu32(linkNextTarget, offset, freeLink)
	freeLink = link
end

local function isValidLink(checkLink: LinkId, target: NodeId): boolean
	local current = readu32(nodeSourcesTail, nodeOffset(target))
	while current ~= NIL do
		if current == checkLink then
			return true
		end
		current = readu32(linkPrevSource, linkOffset(current))
	end
	return false
end

local function link(source: NodeId, target: NodeId, version: number)
	local sourceOffset = nodeOffset(source)
	local targetOffset = nodeOffset(target)
	local prevSource = readu32(nodeSourcesTail, targetOffset)
	if prevSource ~= NIL then
		local prevSourceOffset = linkOffset(prevSource)
		if readu32(linkSource, prevSourceOffset) == source then
			writeu32(linkVersion, prevSourceOffset, version)
			return
		end
	end
	
	local nextSource = if prevSource ~= NIL
		then readu32(linkNextSource, linkOffset(prevSource))
		else readu32(nodeSources, targetOffset)
	if nextSource ~= NIL then
		local nextSourceOffset = linkOffset(nextSource)
		if readu32(linkSource, nextSourceOffset) == source then
			writeu32(linkVersion, nextSourceOffset, version)
			writeu32(nodeSourcesTail, targetOffset, nextSource)
			return
		end
	end
	
	local prevTarget = readu32(nodeTargetsTail, sourceOffset)
	if prevTarget ~= NIL then
		local prevTargetOffset = linkOffset(prevTarget)
		if readu32(linkVersion, prevTargetOffset) == version and readu32(linkTarget, prevTargetOffset) == target then
			return
		end
	end
	
	local newLink = allocLink()
	local newOffset = linkOffset(newLink)
	writeu32(linkVersion, newOffset, version)
	writeu32(linkSource, newOffset, source)
	writeu32(linkTarget, newOffset, target)
	writeu32(linkPrevSource, newOffset, prevSource)
	writeu32(linkNextSource, newOffset, nextSource)
	writeu32(linkPrevTarget, newOffset, prevTarget)
	writeu32(linkNextTarget, newOffset, NIL)
	writeu32(nodeSourcesTail, targetOffset, newLink)
	writeu32(nodeTargetsTail, sourceOffset, newLink)

	if nextSource ~= NIL then
		writeu32(linkPrevSource, linkOffset(nextSource), newLink)
	end
	if prevSource ~= NIL then
		writeu32(linkNextSource, linkOffset(prevSource), newLink)
	else
		writeu32(nodeSources, targetOffset, newLink)
	end
	if prevTarget ~= NIL then
		writeu32(linkNextTarget, linkOffset(prevTarget), newLink)
	else
		writeu32(nodeTargets, sourceOffset, newLink)
	end
end

local function unlink(linkId: LinkId, target: NodeId?): LinkId
	local linkOffsetValue = linkOffset(linkId)
	local targetNode = target or readu32(linkTarget, linkOffsetValue)
	
	local source = readu32(linkSource, linkOffsetValue)
	local sourceOffset = nodeOffset(source)
	local targetOffset = nodeOffset(targetNode)
	local prevSource = readu32(linkPrevSource, linkOffsetValue)
	local nextSource = readu32(linkNextSource, linkOffsetValue)
	local prevTarget = readu32(linkPrevTarget, linkOffsetValue)
	local nextTarget = readu32(linkNextTarget, linkOffsetValue)
	if nextSource ~= NIL then
		writeu32(linkPrevSource, linkOffset(nextSource), prevSource)
	else
		writeu32(nodeSourcesTail, targetOffset, prevSource)
	end
	if prevSource ~= NIL then
		writeu32(linkNextSource, linkOffset(prevSource), nextSource)
	else
		writeu32(nodeSources, targetOffset, nextSource)
	end
	if nextTarget ~= NIL then
		writeu32(linkPrevTarget, linkOffset(nextTarget), prevTarget)
	else
		writeu32(nodeTargetsTail, sourceOffset, prevTarget)
	end
	if prevTarget ~= NIL then
		writeu32(linkNextTarget, linkOffset(prevTarget), nextTarget)
	else
		writeu32(nodeTargets, sourceOffset, nextTarget)
		if nextTarget == NIL then
			unwatched(source)
		end
	end
	recycleLink(linkId)
	return nextSource
end

local function beginTrackingSources(target: NodeId)
	writeu32(nodeSourcesTail, nodeOffset(target), NIL)
end

local function purgeStaleSources(target: NodeId)
	local targetOffset = nodeOffset(target)
	local tail = readu32(nodeSourcesTail, targetOffset)
	local current = if tail ~= NIL
		then readu32(linkNextSource, linkOffset(tail))
		else readu32(nodeSources, targetOffset)
	
	while current ~= NIL do
		current = unlink(current, target)
	end
end

local function propagate(firstLink: LinkId)
	local current = firstLink
	local stackTop = 0
	while current ~= NIL do
		local currentOffset = linkOffset(current)
		local target = readu32(linkTarget, currentOffset)
		if target == NIL then
			current = readu32(linkNextTarget, currentOffset)
			continue
		end
		
		local targetOffset = nodeOffset(target)
		local flags = readu8(nodeFlags, flagOffset(target))
		if bit32.band(flags, STALE_FLAGS) == 0 then
			writeu8(nodeFlags, flagOffset(target), bit32.bor(flags, PENDING))
			stale(target)
		elseif bit32.band(flags, RECURSION_FLAGS) == 0 then
			flags = NONE
		elseif bit32.band(flags, RECURSED_CHECK) == 0 then
			writeu8(nodeFlags, flagOffset(target), bit32.bor(bit32.band(flags, bit32.bnot(RECURSED)), PENDING))
			stale(target)
		elseif bit32.band(flags, PENDING_DIRTY) == 0 and isValidLink(current, target) then
			writeu8(nodeFlags, flagOffset(target), bit32.bor(flags, RECURSED, PENDING))
			flags = bit32.band(flags, MUTABLE)
		else
			flags = NONE
		end
		if bit32.band(flags, WATCHING_CHECK) == WATCHING then
			notify(target)
		end
		local nextTarget = readu32(linkNextTarget, currentOffset)
		if bit32.btest(flags, MUTABLE) then
			local childTargets = readu32(nodeTargets, targetOffset)
			if childTargets ~= NIL then
				if nextTarget ~= NIL then
					stackTop += 1
					stackWrite(stackTop, nextTarget)
				end
				current = childTargets
				continue
			end
		end
		if nextTarget ~= NIL then
			current = nextTarget
		elseif stackTop > 0 then
			current = stackRead(stackTop)
			stackTop -= 1
		else
			current = NIL
		end
	end
end

local function shallowPropagate(firstLink: LinkId)
	local current = firstLink
	while current ~= NIL do
		local currentOffset = linkOffset(current)
		local target = readu32(linkTarget, currentOffset)
		local flags = readu8(nodeFlags, flagOffset(target))
		if bit32.band(flags, PENDING_DIRTY) == PENDING then
			writeu8(nodeFlags, flagOffset(target), bit32.bor(flags, DIRTY))
			stale(target)
			if bit32.band(flags, WATCHING_CHECK) == WATCHING then
				notify(target)
			end
		end
		current = readu32(linkNextTarget, currentOffset)
	end
end

local function checkDirty(firstLink: LinkId, target: NodeId): boolean
	local current = firstLink
	local sub = target
	local dirty = false
	local stackTop = 0
	
	while true do
		local currentOffset = linkOffset(current)
		local source = readu32(linkSource, currentOffset)
		local sourceOffset = nodeOffset(source)
		local sourceFlags = readu8(nodeFlags, flagOffset(source))
		if bit32.btest(readu8(nodeFlags, flagOffset(sub)), DIRTY) then
			dirty = true
		elseif bit32.band(sourceFlags, MUTABLE_DIRTY) == MUTABLE_DIRTY then
			if update(source) then
				local targets = readu32(nodeTargets, sourceOffset)
				if targets ~= NIL and readu32(linkNextTarget, linkOffset(targets)) ~= NIL then
					shallowPropagate(targets)
				end
				dirty = true
			end
		elseif bit32.band(sourceFlags, MUTABLE_PENDING) == MUTABLE_PENDING then
			stackTop += 1
			stackWrite(stackTop, current)
			current = readu32(nodeSources, sourceOffset)
			sub = source
			continue
		end
		if not dirty then
			local nextSource = readu32(linkNextSource, currentOffset)
			if nextSource ~= NIL then
				current = nextSource
				continue
			end
		end
		
		local advanced = false
		while stackTop > 0 do
			current = stackRead(stackTop)
			stackTop -= 1
			currentOffset = linkOffset(current)
			if dirty then
				local targets = readu32(nodeTargets, nodeOffset(sub))
				if update(sub) then
					if targets ~= NIL and readu32(linkNextTarget, linkOffset(targets)) ~= NIL then
						shallowPropagate(targets)
					end
					sub = readu32(linkTarget, currentOffset)
					continue
				end
				dirty = false
			else
				local subFlags = readu8(nodeFlags, flagOffset(sub))
				writeu8(nodeFlags, flagOffset(sub), bit32.band(subFlags, bit32.bnot(PENDING)))
			end
			sub = readu32(linkTarget, currentOffset)
			local nextSource = readu32(linkNextSource, currentOffset)
			if nextSource ~= NIL then
				current = nextSource
				advanced = true
				break
			end
		end
		if advanced then continue end
		return dirty and readu8(nodeFlags, flagOffset(sub)) ~= NONE
	end
end

local function hasStaleSources(target: NodeId): boolean
	local targetOffset = nodeOffset(target)
	local tail = readu32(nodeSourcesTail, targetOffset)
	if tail ~= NIL then
		return readu32(linkNextSource, linkOffset(tail)) ~= NIL
	end
	return readu32(nodeSources, targetOffset) ~= NIL
end

local function hasSingleTarget(source: NodeId): boolean
	local first = readu32(nodeTargets, nodeOffset(source))
	if first == NIL then
		return false
	end
	return readu32(linkNextTarget, linkOffset(first)) == NIL
end

local function reset()
	nodeCount = 0
	linkCount = 0
	freeLink = NIL
end

local function stats()
	return {
		nodeCount = nodeCount;
		linkCount = linkCount;
		nodeCapacity = nodeCapacity;
		linkCapacity = linkCapacity;
		stackCapacity = stackCapacity;
	}
end

local function createReactiveSystem(
	updateFn: (node: NodeId) -> boolean,
	notifyFn: (node: NodeId) -> (),
	unwatchedFn: (node: NodeId) -> (),
	staleFn: (node: NodeId) -> ()
)
	update = updateFn
	notify = notifyFn
	unwatched = unwatchedFn
	stale = staleFn
end

-----------------------------------------------------------------------------

return {
	ReactiveFlags = ReactiveFlags;
	NIL = NIL;
	
	createMetaBuffers = createMetaBuffers;
	createNode = createNode;
	getFlags = getFlags;
	setFlags = setFlags;
	getSources = getSources;
	getTargets = getTargets;
	
	link = link;
	unlink = unlink;
	beginTrackingSources = beginTrackingSources;
	hasStaleSources = hasStaleSources;
	hasSingleTarget = hasSingleTarget;
	purgeStaleSources = purgeStaleSources;
	propagate = propagate;
	shallowPropagate = shallowPropagate;
	checkDirty = checkDirty;
	
	reset = reset;
	stats = stats;
	
	createReactiveSystem = createReactiveSystem;
}