--[[
@wiindsom | 𝑅𝐸𝐻𝐸𝒜𝒱𝐸𝒩 v1
Documentation -> https://arc.is-a.dev/Reheaven

Inspired by Charm & Alien Signals

Licensed under the MIT License
]]

local DEBUG_WARNINGS = true

local runtime = require("@self/runtime")
local graph = require("@self/graph")

export type Getter<T> = runtime.Getter<T>
export type Setter<T> = runtime.Setter<T>
export type Cleanup = runtime.Cleanup

runtime.setDebugWarning(DEBUG_WARNINGS)

return {
	signal = runtime.signal;
	computed = runtime.computed;
	effect = runtime.effect;
	batch = runtime.batch;
	peek = runtime.peek;
	scope = runtime.scope;
	watch = runtime.watch;
	
	reset = runtime.reset;
	stats = graph.stats;
}
