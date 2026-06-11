local ITERATIONS = 1_000_000

local function run(Reheaven)
	local function resetLib(lib)
		if lib.reset then
			lib.reset()
		end
	end

	local function formatMs(seconds: number): string
		return string.format("%.5f ms", seconds * 1000)
	end

	local function benchSignal(name: string, lib)
		resetLib(lib)

		local signal = lib.signal
		local getCount, setCount = signal(0)

		for i = 1, 10_000 do
			setCount(i)
			getCount()
		end

		local startSet = os.clock()

		for i = 1, ITERATIONS do
			setCount(i)
		end

		local setMs = os.clock() - startSet
		print(`[{name}] set: {formatMs(setMs)}`)

		local total = 0
		local startGet = os.clock()

		for i = 1, ITERATIONS do
			total += getCount()
		end

		local getMs = os.clock() - startGet
		print(`[{name}] get: {formatMs(getMs)}`)

		return total, setMs, getMs
	end

	local function benchComputed(name: string, lib)
		resetLib(lib)

		local signal = lib.signal
		local computed = lib.computed

		local getCount, setCount = signal(0)

		local double = computed(function()
			return getCount() * 2
		end)

		double()

		for i = 1, 10_000 do
			setCount(i)
			double()
		end

		local total = 0
		local startCached = os.clock()

		for i = 1, ITERATIONS do
			total += double()
		end

		local cachedMs = os.clock() - startCached
		print(`[{name}] computed cached get: {formatMs(cachedMs)}`)

		local startSetGet = os.clock()

		for i = 1, ITERATIONS do
			setCount(i)
			total += double()
		end

		local setGetMs = os.clock() - startSetGet
		print(`[{name}] computed set + get: {formatMs(setGetMs)}`)

		return total, cachedMs, setGetMs
	end

	local function benchEffect(name: string, lib)
		resetLib(lib)

		local signal = lib.signal
		local effect = lib.effect

		local getCount, setCount = signal(0)
		local observed = 0

		local stop = effect(function()
			observed = getCount()
		end)

		for i = 1, 10_000 do
			setCount(i)
		end

		local start = os.clock()

		for i = 1, ITERATIONS do
			setCount(i)
		end

		local elapsed = os.clock() - start
		print(`[{name}] effect set/rerun: {formatMs(elapsed)}`)

		stop()

		return observed, elapsed
	end

	local function benchBatch(name: string, lib)
		resetLib(lib)

		local signal = lib.signal
		local effect = lib.effect
		local batch = lib.batch

		if not batch then
			print(`[{name}] batch: missing`)
			return nil, nil, nil
		end

		local getCount, setCount = signal(0)

		local observed = 0
		local runs = 0

		local stop = effect(function()
			runs += 1
			observed = getCount()
		end)

		local start = os.clock()

		batch(function()
			for i = 1, ITERATIONS do
				setCount(i)
			end
		end)

		local elapsed = os.clock() - start
		print(`[{name}] batch 1M sets: {formatMs(elapsed)}`)

		stop()

		return observed, runs, elapsed
	end

	local function benchpeek(name: string, lib)
		resetLib(lib)

		local signal = lib.signal
		local effect = lib.effect
		local peek = lib.peek

		if not peek then
			print(`[{name}] peek: missing`)
			return nil, nil, nil, nil, nil
		end

		local getTracked, setTracked = signal(0)
		local getIgnored, setIgnored = signal(0)

		local observedTracked = 0
		local observedIgnored = 0
		local runs = 0

		local stop = effect(function()
			runs += 1
			observedTracked = getTracked()

			observedIgnored = peek(function()
				return getIgnored()
			end)
		end)

		for i = 1, 10_000 do
			setIgnored(i)
		end

		local startIgnored = os.clock()

		for i = 1, ITERATIONS do
			setIgnored(i)
		end

		local ignoredMs = os.clock() - startIgnored
		print(`[{name}] peek ignored set: {formatMs(ignoredMs)}`)

		local startTracked = os.clock()

		for i = 1, ITERATIONS do
			setTracked(i)
		end

		local trackedMs = os.clock() - startTracked
		print(`[{name}] peek tracked set: {formatMs(trackedMs)}`)

		stop()

		return observedTracked, observedIgnored, runs, ignoredMs, trackedMs
	end

	local function benchScope(name: string, lib)
		resetLib(lib)

		local signal = lib.signal
		local effect = lib.effect
		local computed = lib.computed
		local scope = lib.scope

		if not scope then
			print(`[{name}] scope: missing`)
			return nil, nil, nil, nil, nil, nil, nil
		end

		local getCount, setCount = signal(0)

		local observed = 0
		local runs = 0
		local cleanupRuns = 0
		local finalCleanupRuns = 0

		local startCreate = os.clock()

		local cleanupScope = scope(function(add)
			local double = computed(function()
				return getCount() * 2
			end)

			effect(function()
				runs += 1
				observed = double()

				return function()
					cleanupRuns += 1
				end
			end)

			return function()
				finalCleanupRuns += 1
			end
		end)

		local createMs = os.clock() - startCreate
		print(`[{name}] scope create: {formatMs(createMs)}`)

		local startUpdates = os.clock()

		for i = 1, ITERATIONS do
			setCount(i)
		end

		local updatesMs = os.clock() - startUpdates
		print(`[{name}] scope updates: {formatMs(updatesMs)}`)

		local startCleanup = os.clock()
		cleanupScope()
		local cleanupMs = os.clock() - startCleanup
		print(`[{name}] scope cleanup: {formatMs(cleanupMs)}`)

		return observed, runs, cleanupRuns, finalCleanupRuns, createMs, updatesMs, cleanupMs
	end

    local function benchWatch(name: string, lib)
        resetLib(lib)

        local signal = lib.signal
        local watch = lib.watch

        if not watch then
            print(`[{name}] watch: missing`)
            return nil, nil, nil, nil
        end

        local getCount, setCount = signal(0)

        local observed = 0
        local previous = 0
        local runs = 0

        local stop = watch(getCount, function(current, prev)
            runs += 1
            observed = current
            previous = prev or 0
        end)

        for i = 1, 10_000 do
            setCount(i)
        end

        local start = os.clock()

        for i = 1, ITERATIONS do
            setCount(i)
        end

        local elapsed = os.clock() - start
        print(`[{name}] watch set: {formatMs(elapsed)}`)

        stop()

        return observed, previous, runs, elapsed
    end

	local results = {}

	print("-- effect")
	local effectObserved, effectMs = benchEffect("Reheaven", Reheaven)
	results.effect = { observed = effectObserved, seconds = effectMs }

	print("-- signal")
	local signalTotal, signalSetMs, signalGetMs = benchSignal("Reheaven", Reheaven)
	results.signal = { total = signalTotal, setSeconds = signalSetMs, getSeconds = signalGetMs }

	print("-- computed")
	local computedTotal, computedCachedMs, computedSetGetMs = benchComputed("Reheaven", Reheaven)
	results.computed = { total = computedTotal, cachedSeconds = computedCachedMs, setGetSeconds = computedSetGetMs }

	print("-- batch")
	local batchObserved, batchRuns, batchMs = benchBatch("Reheaven", Reheaven)
	results.batch = { observed = batchObserved, runs = batchRuns, seconds = batchMs }

	print("-- peek")
	local tracked, ignored, peekRuns, ignoredMs, trackedMs = benchpeek("Reheaven", Reheaven)
	results.peek = {
		tracked = tracked;
		ignored = ignored;
		runs = peekRuns;
		ignoredSeconds = ignoredMs;
		trackedSeconds = trackedMs;
	}

	print("-- scope")
	local scopeObserved, scopeRuns, scopeCleanups, scopeFinalCleanups, scopeCreateMs, scopeUpdatesMs, scopeCleanupMs =
		benchScope("Reheaven", Reheaven)

	results.scope = {
		observed = scopeObserved;
		runs = scopeRuns;
		cleanups = scopeCleanups;
		finalCleanups = scopeFinalCleanups;
		createSeconds = scopeCreateMs;
		updatesSeconds = scopeUpdatesMs;
		cleanupSeconds = scopeCleanupMs;
	}

    print("-- watch")
    local watchObserved, watchPrevious, watchRuns, watchMs = benchWatch("Reheaven", Reheaven)

    results.watch = {
        observed = watchObserved;
        previous = watchPrevious;
        runs = watchRuns;
        seconds = watchMs;
    }

	if Reheaven.reset then
		Reheaven.reset()
	end

	return results
end

return run
