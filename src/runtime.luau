--!native

local graph = require("./graph")

export type Getter<T> = () -> T
export type Setter<T> = (update: Update<T>) -> T
export type Cleanup = () -> ()

type Update<T> = ((current: T) -> T) | T
type Equals<T> = (current: T, incoming: T) -> boolean
type Disposable = Instance | RBXScriptConnection | thread | (() -> ...any)
type Add = <T>(item: T & Disposable) -> T

-----------------------------------------------------------------------------

local ReactiveFlags = graph.ReactiveFlags

local createNode = graph.createNode
local getFlags = graph.getFlags
local setFlags = graph.setFlags
local getTargets = graph.getTargets
local getSources = graph.getSources

local link = graph.link
local unlink = graph.unlink
local propagate = graph.propagate
local shallowPropagate = graph.shallowPropagate
local beginTrackingSources = graph.beginTrackingSources
local purgeStaleSources = graph.purgeStaleSources
local checkDirty = graph.checkDirty
local hasStaleSources = graph.hasStaleSources
local hasSingleTarget = graph.hasSingleTarget
local createReactiveSystem = graph.createReactiveSystem

local NONE = ReactiveFlags.None
local MUTABLE = ReactiveFlags.Mutable
local WATCHING = ReactiveFlags.Watching
local DIRTY = ReactiveFlags.Dirty
local PENDING = ReactiveFlags.Pending
local QUEUED = ReactiveFlags.Queued

local TRACKABLE_FLAGS = bit32.bor(MUTABLE, WATCHING)
local MUTABLE_DIRTY = bit32.bor(MUTABLE, DIRTY)
local CLEAR_QUEUED = bit32.bnot(QUEUED)
local CLEAR_WATCHING = bit32.bnot(WATCHING)

const NODE_NONE = 0
const NODE_SIGNAL = 1
const NODE_COMPUTED = 2
const NODE_EFFECT = 3

const NIL = graph.NIL

local readu8 = buffer.readu8
local writeu8 = buffer.writeu8

local meta = graph.createMetaBuffers(2)

local metaBuffers = meta.buffers
local nodeKindBuffer = metaBuffers[1]
local nodeHasCleanupBuffer = metaBuffers[2]

local function ensureMetaCapacity(node: graph.NodeId)
	metaBuffers = meta.ensure(node)
	nodeKindBuffer = metaBuffers[1]
	nodeHasCleanupBuffer = metaBuffers[2]
end

local DEBUG_WARNINGS = true

-----------------------------------------------------------------------------

local nodeValue: { [graph.NodeId]: any } = {}
local nodePendingValue: { [graph.NodeId]: any } = {}
local nodeSignalCommit: { [graph.NodeId]: () -> boolean } = {}
local nodeComputedUpdate: { [graph.NodeId]: () -> boolean } = {}
local nodeComputedMarkDirty: { [graph.NodeId]: () -> () } = {}
local nodeEffectFn: { [graph.NodeId]: () -> ...any } = {}
local nodeCleanups: { [graph.NodeId]: { Cleanup } } = {}

local ownedGetters: { [Getter<any>]: boolean? } = {}

local cycle = 0
local activeTarget = NIL
local activeScope: { Disposable }?

local queued: { [number]: graph.NodeId } = {}
local queuedLength = 0
local notifyIndex = 0
local batchDepth = 0

-----------------------------------------------------------------------------

local function warnAt(message: string)
	local source, line = debug.info(2, "sl")
	warn(`{message}\nSource: {source}:{line}`)
end

local function stale(node: graph.NodeId)
	local nodeIndex = node - 1
	if readu8(nodeKindBuffer, nodeIndex) == NODE_COMPUTED then
		local mark = nodeComputedMarkDirty[node]
		if mark then
			mark()
		end
	end
end

local function getActiveTarget()
	return activeTarget
end

local function setActiveTarget(target: graph.NodeId?)
	local previous = activeTarget
	activeTarget = target or NIL
	return previous
end

local function purgeSources(target: graph.NodeId)
	local sourceLink = getSources(target)
	while sourceLink ~= NIL do
		sourceLink = unlink(sourceLink, target)
	end
end

local function runCleanups(cleanups: { Cleanup })
	for index, cleanup in cleanups do
		cleanups[index] = nil
		cleanup()
	end
end

local function updateSignal(node: graph.NodeId): boolean
	local commit = nodeSignalCommit[node]
	if commit then return commit() end
	setFlags(node, MUTABLE)
	local pendingValue = nodePendingValue[node]
	if nodeValue[node] ~= pendingValue then
		nodeValue[node] = pendingValue
		return true
	end
	return false
end

local function updateComputed(node: graph.NodeId): boolean
	local recompute = nodeComputedUpdate[node]
	if recompute then return recompute() end
	return false
end

local function runEffect(node: graph.NodeId)
	local flags = getFlags(node)
	if flags == NONE then return end
	if bit32.band(flags, DIRTY) ~= 0 then
	elseif bit32.band(flags, PENDING) ~= 0 then
		local sources = getSources(node)
		if sources == NIL or not checkDirty(sources, node) then
			setFlags(node, WATCHING)
			return
		end
	else
		setFlags(node, WATCHING)
		return
	end
	
	local nodeIndex = node - 1
	if readu8(nodeHasCleanupBuffer, nodeIndex) ~= 0 then
		local existingCleanups = nodeCleanups[node]
		if existingCleanups then
			runCleanups(existingCleanups)
			if getFlags(node) == NONE then return end
		end
		writeu8(nodeHasCleanupBuffer, nodeIndex, 0)
	end
	cycle += 1
	setFlags(node, WATCHING)
	
	local previousTarget = activeTarget
	activeTarget = node
	beginTrackingSources(node)
	
	local ok, result = pcall(nodeEffectFn[node])
	activeTarget = previousTarget
	if hasStaleSources(node) then purgeStaleSources(node) end
	if not ok then error(result, 2) end
	
	if result then
		local cleanups = nodeCleanups[node]
		if cleanups == nil then
			cleanups = {}
			nodeCleanups[node] = cleanups
		end
		table.insert(cleanups, result)
		writeu8(nodeHasCleanupBuffer, nodeIndex, 1)
	end
end

-----------------------------------------------------------------------------

local function update(node: graph.NodeId): boolean
	local kind = readu8(nodeKindBuffer, node - 1)
	if kind == NODE_SIGNAL then
		return updateSignal(node)
	elseif kind == NODE_COMPUTED then
		return updateComputed(node)
	end
	return false
end

local function notify(node: graph.NodeId)
	local flags = getFlags(node)
	if bit32.band(flags, QUEUED) ~= 0 then return end
	queuedLength += 1
	queued[queuedLength] = node
	setFlags(node, bit32.bor(bit32.band(flags, CLEAR_WATCHING), QUEUED))
end

local function unwatched(node: graph.NodeId)
	local nodeIndex = node - 1
	local kind = readu8(nodeKindBuffer, nodeIndex)
	if kind == NODE_COMPUTED then
		purgeSources(node)
		setFlags(node, MUTABLE)
		local mark = nodeComputedMarkDirty[node]
		if mark then
			mark()
		end
	elseif kind == NODE_EFFECT then
		setFlags(node, NONE)
		purgeSources(node)
		if readu8(nodeHasCleanupBuffer, nodeIndex) ~= 0 then
			local cleanups = nodeCleanups[node]
			if cleanups then
				runCleanups(cleanups)
			end
			writeu8(nodeHasCleanupBuffer, nodeIndex, 0)
		end
		writeu8(nodeKindBuffer, nodeIndex, NODE_NONE)
		nodeEffectFn[node] = nil
		nodeCleanups[node] = nil
	end
end

local function flush()
	if batchDepth ~= 0 or notifyIndex ~= 0 or queuedLength == 0 then return end
	while notifyIndex < queuedLength do
		notifyIndex += 1
		local node = queued[notifyIndex]
		queued[notifyIndex] = nil
		local flags = getFlags(node)
		if bit32.band(flags, QUEUED) ~= 0 then
			setFlags(node, bit32.band(flags, CLEAR_QUEUED))
		end
		runEffect(node)
	end
	notifyIndex = 0
	queuedLength = 0
end

-----------------------------------------------------------------------------

local function signal<T>(initialValue: T, equals: Equals<T>?): (Getter<T>, Setter<T>)
	local node = createNode(MUTABLE)
	local nodeIndex = node - 1
	
	local currentValue, pendingValue = initialValue, initialValue
	local hasTargets = false
	local lastTarget = NIL
	local lastTargetCycle = -1
	
	local directEffectNode = NIL
	local directComputedNode = NIL
	local directComputedUpdate: (() -> boolean)? = nil
	local directComputedMarkDirty: (() -> ())? = nil
	
	ensureMetaCapacity(node)
	writeu8(nodeKindBuffer, nodeIndex, NODE_SIGNAL)
	writeu8(nodeHasCleanupBuffer, nodeIndex, 0)
	nodeValue[node] = currentValue
	nodePendingValue[node] = pendingValue
	
	local function commit(): boolean
		setFlags(node, MUTABLE)
		if currentValue ~= pendingValue then
			currentValue = pendingValue
			nodeValue[node] = currentValue
			return true
		end
		return false
	end
	
	local function commitImmediate(value: T)
		currentValue = value
		pendingValue = value
		nodeValue[node] = value
		nodePendingValue[node] = value
		setFlags(node, MUTABLE)
	end
	
	nodeSignalCommit[node] = commit
	
	local function signalGetter(): T
		local target = activeTarget
		if target == NIL then return currentValue end
		
		local nodeFlags = getFlags(node)
		if bit32.band(nodeFlags, DIRTY) ~= 0 then
			if commit() then
				local targets = getTargets(node)
				if targets ~= NIL then
					shallowPropagate(targets)
				end
			end
		end
		if target == lastTarget and lastTargetCycle == cycle then
			return currentValue
		end
		
		local targetFlags = getFlags(target)
		if bit32.band(targetFlags, TRACKABLE_FLAGS) ~= 0 then
			link(node, target, cycle)
			hasTargets = true
			lastTarget = target
			lastTargetCycle = cycle
			local targetKind = readu8(nodeKindBuffer, target - 1)
			if targetKind == NODE_EFFECT then
				directEffectNode = target
			elseif targetKind == NODE_COMPUTED then
				directComputedNode = target
				directComputedUpdate = nodeComputedUpdate[target]
				directComputedMarkDirty = nodeComputedMarkDirty[target]
			end
		end
		return currentValue
	end
	
	local function signalSetter(updateValue: Update<T>): T
		local value: T
		
		if type(updateValue) == "function" then
			value = (updateValue :: (current: T) -> T)(pendingValue)
		else
			value = updateValue
		end
		
		local changed = if equals then not equals(pendingValue, value) else pendingValue ~= value
		if not changed then
			return pendingValue
		end
		
		local writingEffect = activeTarget
		local selfWriteEffect = false
		if writingEffect ~= NIL and type(updateValue) ~= "function" then
			local targetKind = readu8(nodeKindBuffer, writingEffect - 1)
			selfWriteEffect =
				targetKind == NODE_EFFECT
				and lastTarget == writingEffect
				and lastTargetCycle == cycle
			if DEBUG_WARNINGS and selfWriteEffect then
				warnAt("[Reheaven] Signal was read and updated inside the same effect. Reheaven skipped rerunning this effect to prevent recursion. Use an updater function or peek() to avoid accidental tracking.")
			end
		end
		pendingValue = value
		if batchDepth ~= 0 then
			if not hasTargets then
				currentValue = value
				return value
			end
			nodePendingValue[node] = value
			if directEffectNode ~= NIL then
				local effectFlags = getFlags(directEffectNode)
				if effectFlags ~= NONE then
					if selfWriteEffect and directEffectNode == writingEffect then
						currentValue = value
						pendingValue = value
						nodeValue[node] = value
						nodePendingValue[node] = value
						setFlags(node, MUTABLE)
						return value
					end
					
					if bit32.band(effectFlags, QUEUED) ~= 0 then
						currentValue = value
						pendingValue = value
						return value
					end
					currentValue = value
					pendingValue = value
					nodeValue[node] = value
					setFlags(node, MUTABLE)
					if directComputedMarkDirty then directComputedMarkDirty() end
					queuedLength += 1
					queued[queuedLength] = directEffectNode
					setFlags(directEffectNode, bit32.bor(effectFlags, DIRTY, QUEUED))
					return value
				end
				directEffectNode = NIL
			end
			
			local targets = getTargets(node)
			if targets ~= NIL then
				setFlags(node, MUTABLE_DIRTY)
				propagate(targets)
			else
				hasTargets = false
				directEffectNode = NIL
				directComputedNode = NIL
				currentValue = value
				nodeValue[node] = value
			end
			return value
		end
		if not hasTargets then
			currentValue = value
			return value
		end
		nodePendingValue[node] = value
		
		local targets = getTargets(node)
		if targets == NIL then
			hasTargets = false
			directEffectNode = NIL
			directComputedNode = NIL
			currentValue = value
			nodeValue[node] = value
			return value
		end
		if directEffectNode ~= NIL and notifyIndex == 0 and hasSingleTarget(node) then
			if selfWriteEffect and directEffectNode == writingEffect then
				commitImmediate(value)
				return value
			end
			if getFlags(directEffectNode) ~= NONE then
				commitImmediate(value)
				if directComputedMarkDirty then directComputedMarkDirty() end
				setFlags(directEffectNode, DIRTY)
				runEffect(directEffectNode)
				return value
			end
			directEffectNode = NIL
		end
		if directComputedNode ~= NIL and notifyIndex == 0 and hasSingleTarget(node) then
			if getFlags(directComputedNode) ~= NONE and getTargets(directComputedNode) == NIL and directComputedUpdate then
				commitImmediate(value)
				directComputedUpdate()
				return value
			end
			directComputedNode = NIL
			directComputedUpdate = nil
			directComputedMarkDirty = nil
		end
		setFlags(node, MUTABLE_DIRTY)
		propagate(targets)
		flush()
		return value
	end
	
	if DEBUG_WARNINGS then
		ownedGetters[signalGetter] = true
	end
	
	return signalGetter, signalSetter
end

local function computed<T>(getter: (previousValue: T?) -> T): (Getter<T>, Cleanup)
	local node = createNode(MUTABLE)
	local nodeIndex = node - 1
	
	local currentValue: T
	local dirty = true
	local computing = false
	local lastTarget = NIL
	local lastTargetCycle = -1
	
	ensureMetaCapacity(node)
	writeu8(nodeKindBuffer, nodeIndex, NODE_COMPUTED)
	writeu8(nodeHasCleanupBuffer, nodeIndex, 0)
	
	local function recompute(): boolean
		if computing then
			error("[Reheaven] circular computed dependency detected", 2)
		end
		computing = true
		cycle += 1
		
		local oldValue = currentValue
		local previousTarget = activeTarget
		activeTarget = node
		beginTrackingSources(node)
		
		local ok, newValue = pcall(getter, oldValue)
		activeTarget = previousTarget
		if hasStaleSources(node) then purgeStaleSources(node) end
		computing = false
		if not ok then error(newValue, 2) end
		dirty = false
		currentValue = newValue
		nodeValue[node] = newValue
		setFlags(node, MUTABLE)
		if oldValue ~= newValue then
			local targets = getTargets(node)
			if targets ~= NIL then
				shallowPropagate(targets)
			end
			return true
		end
		return false
	end
	
	nodeComputedUpdate[node] = recompute
	nodeComputedMarkDirty[node] = function()
		dirty = true
	end
	
	local function computedGetter(): T
		local target = activeTarget
		if dirty then recompute() end
		if target ~= NIL and (target ~= lastTarget or lastTargetCycle ~= cycle) then
			link(node, target, cycle)
			lastTarget = target
			lastTargetCycle = cycle
		end
		return currentValue
	end
	
	local function stopComputed()
		purgeSources(node)
		setFlags(node, MUTABLE)
		dirty = true
		lastTarget = NIL
		lastTargetCycle = -1
	end
	
	if DEBUG_WARNINGS then
		ownedGetters[computedGetter] = true
	end
	if activeScope then
		table.insert(activeScope, stopComputed)
	end
	return computedGetter, stopComputed
end

local function effect<R...>(fn: () -> R...): Cleanup
	local node = createNode(WATCHING)
	local nodeIndex = node - 1
	ensureMetaCapacity(node)
	writeu8(nodeKindBuffer, nodeIndex, NODE_EFFECT)
	writeu8(nodeHasCleanupBuffer, nodeIndex, 0)
	nodeEffectFn[node] = fn
	nodeCleanups[node] = nil
	batchDepth += 1
	
	local previousTarget = activeTarget
	activeTarget = node
	beginTrackingSources(node)
	
	local ok, result = pcall(fn :: any)
	activeTarget = previousTarget
	if hasStaleSources(node) then
		purgeStaleSources(node)
	end
	batchDepth -= 1
	if not ok then
		setFlags(node, NONE)
		purgeSources(node)
		writeu8(nodeKindBuffer, nodeIndex, NODE_NONE)
		nodeEffectFn[node] = nil
		nodeCleanups[node] = nil
		flush()
		error(result, 2)
	end
	if result then
		local cleanups = {}
		nodeCleanups[node] = cleanups
		table.insert(cleanups, result)
		writeu8(nodeHasCleanupBuffer, nodeIndex, 1)
	end
	flush()
	
	local function stopEffect()
		setFlags(node, NONE)
		purgeSources(node)
		if readu8(nodeHasCleanupBuffer, nodeIndex) ~= 0 then
			local cleanups = nodeCleanups[node]
			if cleanups then
				runCleanups(cleanups)
			end
			writeu8(nodeHasCleanupBuffer, nodeIndex, 0)
		end
		writeu8(nodeKindBuffer, nodeIndex, NODE_NONE)
		nodeEffectFn[node] = nil
		nodeCleanups[node] = nil
	end
	
	if activeScope then
		table.insert(activeScope, stopEffect)
	end
	return stopEffect
end

local function batch<A..., R...>(fn: (A...) -> R..., ...: A...): R...
	batchDepth += 1
	
	local results = table.pack(pcall(fn :: any, ...))
	batchDepth -= 1
	flush()
	
	if not results[1] then
		error(results[2], 2)
	end
	return table.unpack(results, 2, results.n)
end

local function peek<A..., R...>(fn: (A...) -> R..., ...: A...): R...
	local previousTarget = activeTarget
	activeTarget = NIL
	
	local results = table.pack(pcall(fn :: any, ...))
	activeTarget = previousTarget
	
	if not results[1] then
		error(results[2], 2)
	end
	return table.unpack(results, 2, results.n)
end

local function dispose(item: Disposable)
	local kind = typeof(item)
	if kind == "Instance" then
		(item :: Instance):Destroy()
	elseif kind == "RBXScriptConnection" then
		(item :: RBXScriptConnection):Disconnect()
	elseif kind == "thread" then
		pcall(task.cancel, item :: thread)
	elseif kind == "function" then
		(item :: () -> ...any)()
	end
end

local function scope<R...>(fn: (Add) -> R...): Cleanup
	local previousScope = activeScope
	local bin: { Disposable } = {}
	
	local function add<T>(item: T & Disposable): T
		if DEBUG_WARNINGS then
			local kind = typeof(item)
			if kind ~= "Instance"
				and kind ~= "RBXScriptConnection"
				and kind ~= "thread"
				and kind ~= "function"
			then
				warnAt("[Reheaven] add() expected Instance, RBXScriptConnection, thread, or cleanup function.")
				return item
			end
			if kind == "function" and ownedGetters[item :: any] then
				warnAt("[Reheaven] add() received a signal/computed getter. Use add() for cleanup functions, not getters.")
				return item
			end
			for _, scopedItem in bin do
				if scopedItem == item then
					warnAt("[Reheaven] This cleanup is already tracked by scope; no need to add it manually.")
					return item
				end
			end
		end
		table.insert(bin, item :: any)
		return item
	end
	
	activeScope = bin
	
	local success, result = pcall(fn :: any, add)
	activeScope = previousScope
	if not success then
		for index = #bin, 1, -1 do
			dispose(bin[index])
			bin[index] = nil
		end
		error(result, 2)
	end
	if typeof(result) == "function" then
		table.insert(bin, result)
	end
	local function cleanupScope()
		if #bin == 0 then return end
		for index = #bin, 1, -1 do
			dispose(bin[index])
			bin[index] = nil
		end
	end
	return cleanupScope
end

local function watch<T>(getter: Getter<T>, callback: (state: T, lastState: T) -> ()): Cleanup
	if DEBUG_WARNINGS and not ownedGetters[getter] then
		warnAt("[Reheaven] watch() expected a signal or computed getter.")
		return function() end
	end
	local current: T
	local firstRun = true
	return effect(function()
		local previous = current
		current = getter()
		if firstRun then
			firstRun = false
			return
		end
		peek(callback, current, previous)
	end)
end

local function reset()
	graph.reset()
	
	metaBuffers = meta.reset()
	nodeKindBuffer = metaBuffers[1]
	nodeHasCleanupBuffer = metaBuffers[2]
	
	nodeValue = {}
	nodePendingValue = {}
	nodeSignalCommit = {}
	nodeComputedUpdate = {}
	nodeComputedMarkDirty = {}
	nodeEffectFn = {}
	nodeCleanups = {}
	
	ownedGetters = {}
	
	cycle = 0
	activeTarget = NIL
	activeScope = nil
	
	queued = {}
	queuedLength = 0
	notifyIndex = 0
	batchDepth = 0
end

local function setDebugWarning(state: boolean)
	DEBUG_WARNINGS = state
end

-----------------------------------------------------------------------------

createReactiveSystem(update, notify, unwatched, stale)

return {
	signal = signal;
	computed = computed;
	effect = effect;
	batch = batch;
	peek = peek;
	scope = scope;
	watch = watch;
	
	reset = reset;
	setDebugWarning = setDebugWarning;
	
	getActiveTarget = getActiveTarget;
	setActiveTarget = setActiveTarget;
}
