local function run(Reheaven)
	local signal = Reheaven.signal
	local computed = Reheaven.computed
	local effect = Reheaven.effect
	local batch = Reheaven.batch
	local peek = Reheaven.peek
	local scope = Reheaven.scope
	local watch = Reheaven.watch

	if Reheaven.reset then
		Reheaven.reset()
	end

	local passed = 0

	local function expect(actual, expected, label)
		assert(actual == expected, `[Reheaven] {label}: expected {expected}, got {actual}`)
		passed += 1
	end

	local function section(name)
		print(`-- {name}`)
	end

	section("signal basics")

	do
		local get, set = signal(0)

		expect(get(), 0, "initial value")

		set(5)
		expect(get(), 5, "direct set")

		set(function(current)
			return current + 1
		end)
		expect(get(), 6, "functional set")

		set(6)
		expect(get(), 6, "same value remains")
	end

	section("equals comparator")
    
	do
		local get, set = signal({ x = 1 }, function(a, b)
			return a.x == b.x
		end)

		local runs = 0

		local stop = effect(function()
			runs += 1
			get()
		end)

		expect(runs, 1, "initial effect run")

		set({ x = 1 })
		expect(runs, 1, "equivalent table skipped")

		set({ x = 2 })
		expect(runs, 2, "changed table reruns")

		stop()
	end

	section("computed lazy/cache")

	do
		local getCount, setCount = signal(2)
		local calls = 0

		local double = computed(function(previous)
			calls += 1
			return getCount() * 2
		end)

		expect(calls, 0, "lazy before read")

		expect(double(), 4, "first read")
		expect(calls, 1, "first read calls")

		expect(double(), 4, "cached read")
		expect(calls, 1, "cached read calls")

		setCount(3)
		expect(double(), 6, "updates after dependency set")
		expect(calls, 2, "rerun after dependency set")
	end

	section("computed previous value")

	do
		local getCount, setCount = signal(1)
		local previousSeen = "unset"

		local accumulator = computed(function(previous)
			previousSeen = previous
			return getCount() + (previous or 0)
		end)

		expect(accumulator(), 1, "initial previous result")
		expect(previousSeen, nil, "initial previous is nil")

		setCount(2)
		expect(accumulator(), 3, "second previous result")
		expect(previousSeen, 1, "second previous value")
	end

	section("nested computed")

	do
		local getBase, setBase = signal(2)

		local doubleCalls = 0
		local quadrupleCalls = 0

		local double = computed(function()
			doubleCalls += 1
			return getBase() * 2
		end)

		local quadruple = computed(function()
			quadrupleCalls += 1
			return double() * 2
		end)

		expect(quadruple(), 8, "initial nested value")
		expect(doubleCalls, 1, "initial inner calls")
		expect(quadrupleCalls, 1, "initial outer calls")

		setBase(3)

		expect(quadruple(), 12, "updated nested value")
		expect(doubleCalls, 2, "updated inner calls")
		expect(quadrupleCalls, 2, "updated outer calls")
	end

	section("diamond computed graph")

	do
		local getBase, setBase = signal(1)

		local doubleCalls = 0
		local tripleCalls = 0
		local totalCalls = 0

		local double = computed(function()
			doubleCalls += 1
			return getBase() * 2
		end)

		local triple = computed(function()
			tripleCalls += 1
			return getBase() * 3
		end)

		local total = computed(function()
			totalCalls += 1
			return double() + triple()
		end)

		expect(total(), 5, "diamond initial")
		expect(doubleCalls, 1, "diamond double initial calls")
		expect(tripleCalls, 1, "diamond triple initial calls")
		expect(totalCalls, 1, "diamond total initial calls")

		setBase(2)

		expect(total(), 10, "diamond updated")
		expect(doubleCalls, 2, "diamond double updated calls")
		expect(tripleCalls, 2, "diamond triple updated calls")
		expect(totalCalls, 2, "diamond total updated calls")
	end

	section("effect basics")

	do
		local getCount, setCount = signal(0)

		local runs = 0
		local observed = -1

		local stop = effect(function()
			runs += 1
			observed = getCount()
		end)

		expect(runs, 1, "initial effect run")
		expect(observed, 0, "initial observed")

		setCount(1)
		expect(runs, 2, "effect rerun one")
		expect(observed, 1, "observed one")

		setCount(2)
		expect(runs, 3, "effect rerun two")
		expect(observed, 2, "observed two")

		stop()

		setCount(3)
		expect(runs, 3, "stopped effect no rerun")
		expect(observed, 2, "stopped observed unchanged")
	end

	section("effect cleanup")

	do
		local getCount, setCount = signal(0)

		local runs = 0
		local cleanups = 0

		local stop = effect(function()
			runs += 1
			getCount()

			return function()
				cleanups += 1
			end
		end)

		expect(runs, 1, "cleanup initial run")
		expect(cleanups, 0, "cleanup not run initially")

		setCount(1)
		expect(runs, 2, "cleanup rerun")
		expect(cleanups, 1, "cleanup before rerun")

		setCount(2)
		expect(runs, 3, "cleanup second rerun")
		expect(cleanups, 2, "cleanup before second rerun")

		stop()
		expect(cleanups, 3, "cleanup on stop")
	end

	section("computed inside effect")

	do
		local getCount, setCount = signal(1)

		local computeCalls = 0
		local effectRuns = 0
		local observed = 0

		local double = computed(function()
			computeCalls += 1
			return getCount() * 2
		end)

		local stop = effect(function()
			effectRuns += 1
			observed = double()
		end)

		expect(observed, 2, "initial computed observed")
		expect(computeCalls, 1, "initial compute calls")
		expect(effectRuns, 1, "initial effect runs")

		setCount(5)
		expect(observed, 10, "updated computed observed")
		expect(computeCalls, 2, "updated compute calls")
		expect(effectRuns, 2, "updated effect runs")

		stop()
	end

	section("computed manual cleanup")

	do
		local getCount, setCount = signal(1)

		local calls = 0

		local double, stopDouble = computed(function()
			calls += 1
			return getCount() * 2
		end)

		expect(double(), 2, "manual cleanup initial computed")
		expect(calls, 1, "manual cleanup initial calls")

		expect(double(), 2, "manual cleanup cached computed")
		expect(calls, 1, "manual cleanup cached calls")

		stopDouble()

		setCount(2)

		expect(calls, 1, "manual cleanup did not recompute during set")
		expect(double(), 4, "manual cleanup lazy recompute")
		expect(calls, 2, "manual cleanup recomputed on read")

		expect(double(), 4, "manual cleanup cached after revive")
		expect(calls, 2, "manual cleanup cached calls after revive")
	end

	section("computed auto cleanup after effect stops")

	do
		local getCount, setCount = signal(1)

		local calls = 0

		local double = computed(function()
			calls += 1
			return getCount() * 2
		end)

		local stop = effect(function()
			double()
		end)

		expect(calls, 1, "auto cleanup initial computed calls")

		stop()

		setCount(2)

		expect(double(), 4, "auto cleanup lazy recompute after stop")
		expect(calls, 2, "auto cleanup recompute calls after stop")
	end

	section("stopped effect does not keep computed running")

	do
		local getCount, setCount = signal(1)

		local calls = 0
		local observed = 0

		local double = computed(function()
			calls += 1
			return getCount() * 2
		end)

		local stop = effect(function()
			observed = double()
		end)

		expect(observed, 2, "stopped effect initial observed")
		expect(calls, 1, "stopped effect initial computed calls")

		stop()

		setCount(2)
		setCount(3)

		expect(observed, 2, "stopped effect observed unchanged")
		expect(calls, 1, "stopped effect did not recompute during sets")

		expect(double(), 6, "stopped effect manual computed read")
		expect(calls, 2, "stopped effect manual read recomputed once")
	end

	section("batch works after computed cleanup")

	do
		local getCount, setCount = signal(1)

		local calls = 0

		local double, stopDouble = computed(function()
			calls += 1
			return getCount() * 2
		end)

		expect(double(), 2, "batch cleanup initial computed")
		expect(calls, 1, "batch cleanup initial calls")

		stopDouble()

		batch(function()
			setCount(2)
			setCount(3)
			setCount(4)
		end)

		expect(calls, 1, "batch cleanup no recompute before read")
		expect(double(), 8, "batch cleanup final computed value")
		expect(calls, 2, "batch cleanup recomputed once")
	end

	section("same value skips effect")

	do
		local getCount, setCount = signal(1)

		local runs = 0

		local stop = effect(function()
			runs += 1
			getCount()
		end)

		expect(runs, 1, "initial run")

		setCount(1)
		expect(runs, 1, "same direct set skipped")

		setCount(function(current)
			return current
		end)
		expect(runs, 1, "same updater skipped")

		setCount(2)
		expect(runs, 2, "changed value reruns")

		stop()
	end

	section("batch runs effect once after multiple sets")

	do
		local getCount, setCount = signal(0)

		local runs = 0
		local observed = -1

		local stop = effect(function()
			runs += 1
			observed = getCount()
		end)

		expect(runs, 1, "batch initial run")
		expect(observed, 0, "batch initial observed")

		batch(function()
			setCount(1)
			setCount(2)
			setCount(3)
		end)

		expect(runs, 2, "batch ran effect once after sets")
		expect(observed, 3, "batch used final value")

		stop()
	end

	section("nested batch waits until the outer batch ends")

	do
		local getCount, setCount = signal(0)

		local runs = 0
		local observed = -1

		local stop = effect(function()
			runs += 1
			observed = getCount()
		end)

		batch(function()
			setCount(1)

			batch(function()
				setCount(2)
				setCount(3)
			end)

			setCount(4)
		end)

		expect(runs, 2, "nested batch ran effect once")
		expect(observed, 4, "nested batch used final value")

		stop()
	end

	section("batch updates computed once with final value")

	do
		local getCount, setCount = signal(1)

		local computeCalls = 0
		local effectRuns = 0
		local observed = 0

		local double = computed(function()
			computeCalls += 1
			return getCount() * 2
		end)

		local stop = effect(function()
			effectRuns += 1
			observed = double()
		end)

		expect(observed, 2, "batch computed initial observed")
		expect(computeCalls, 1, "batch computed initial calls")
		expect(effectRuns, 1, "batch computed initial effect runs")

		batch(function()
			setCount(2)
			setCount(3)
			setCount(4)
		end)

		expect(observed, 8, "batch computed used final value")
		expect(computeCalls, 2, "batch computed ran once after batch")
		expect(effectRuns, 2, "batch effect ran once after batch")

		stop()
	end

	section("batch skips unchanged values")

	do
		local getCount, setCount = signal(1)

		local runs = 0

		local stop = effect(function()
			runs += 1
			getCount()
		end)

		batch(function()
			setCount(1)
			setCount(1)
			setCount(function(current)
				return current
			end)
		end)

		expect(runs, 1, "unchanged batch did not rerun")

		batch(function()
			setCount(2)
			setCount(2)
		end)

		expect(runs, 2, "changed batch reran once")

		stop()
	end

	section("batch returns callback values")

	do
		local a, b, c = batch(function()
			return 1, nil, 3
		end)

		expect(a, 1, "batch return first")
		expect(b, nil, "batch return nil second")
		expect(c, 3, "batch return third")
	end

	section("batch passes errors through")

	do
		local ok, message = pcall(function()
			batch(function()
				error("batch failure")
			end)
		end)

		expect(ok, false, "batch error thrown")
		expect(type(message), "string", "batch error message")
	end

	section("peek reads do not rerun effects")

	do
		local getName, setName = signal("Alice")
		local getDebug, setDebug = signal(0)

		local runs = 0
		local observedName = ""
		local observedDebug = -1

		local stop = effect(function()
			runs += 1
			observedName = getName()

			observedDebug = peek(function()
				return getDebug()
			end)
		end)

		expect(runs, 1, "peek initial run")
		expect(observedName, "Alice", "peek initial name")
		expect(observedDebug, 0, "peek initial debug")

		setDebug(1)

		expect(runs, 1, "peek value did not rerun effect")
		expect(observedDebug, 0, "peek observed unchanged before tracked update")

		setName("Bob")

		expect(runs, 2, "tracked value reran effect")
		expect(observedName, "Bob", "tracked value updated")
		expect(observedDebug, 1, "peek value read during tracked rerun")

		setDebug(2)

		expect(runs, 2, "second peek update did not rerun effect")

		stop()
	end

	section("peek returns callback values")

	do
		local getCount = signal(5)

		local a, b, c = peek(function()
			return getCount(), nil, getCount() + 1
		end)

		expect(a, 5, "peek return first")
		expect(b, nil, "peek return nil second")
		expect(c, 6, "peek return third")
	end

	section("peek passes errors through")

	do
		local ok, message = pcall(function()
			peek(function()
				error("peek failure")
			end)
		end)

		expect(ok, false, "peek error thrown")
		expect(type(message), "string", "peek error message")
	end

	section("scope cleans effects and computeds")

	do
		local getCount, setCount = signal(1)

		local observed = 0
		local effectRuns = 0
		local effectCleanups = 0
		local computeCalls = 0
		local finalCleanups = 0

		local cleanupScope = scope(function(add)
			local double = computed(function()
				computeCalls += 1
				return getCount() * 2
			end)

			effect(function()
				effectRuns += 1
				observed = double()

				return function()
					effectCleanups += 1
				end
			end)

			return function()
				finalCleanups += 1
			end
		end)

		expect(observed, 2, "scope initial observed")
		expect(effectRuns, 1, "scope initial effect run")
		expect(computeCalls, 1, "scope initial computed call")

		setCount(2)

		expect(observed, 4, "scope updated observed")
		expect(effectRuns, 2, "scope effect reran")
		expect(computeCalls, 2, "scope computed reran")
		expect(effectCleanups, 1, "scope effect cleanup before rerun")

		cleanupScope()

		expect(effectCleanups, 2, "scope effect cleanup on scope cleanup")
		expect(finalCleanups, 1, "scope final cleanup ran")

		setCount(3)

		expect(observed, 4, "scope stopped effect after cleanup")
		expect(effectRuns, 2, "scope no effect rerun after cleanup")
		expect(computeCalls, 2, "scope no computed rerun after cleanup")
	end

	section("scope return cleanup runs")

	do
		local cleanedA = 0
		local cleanedB = 0

		local cleanupScope = scope(function(add)
			return function()
				cleanedA += 1
				cleanedB += 1
			end
		end)

		expect(cleanedA, 0, "scope external cleanup A not run early")
		expect(cleanedB, 0, "scope external cleanup B not run early")

		cleanupScope()

		expect(cleanedA, 1, "scope external cleanup A ran")
		expect(cleanedB, 1, "scope external cleanup B ran")
	end

	section("scope cleanup is unchanging")

	do
		local cleanups = 0

		local cleanupScope = scope(function(add)
			return function()
				cleanups += 1
			end
		end)

		cleanupScope()
		cleanupScope()

		expect(cleanups, 1, "scope cleanup only runs once")
	end

	section("scope cleans up when callback errors")

	do
		local cleanups = 0

		local ok, message = pcall(function()
			scope(function(add)
				effect(function()
					return function()
						cleanups += 1
					end
				end)

				error("scope failure")
			end)
		end)

		expect(ok, false, "scope error thrown")
		expect(type(message), "string", "scope error message")
		expect(cleanups, 1, "scope cleaned after error")
	end

	section("fast effects keep old dependencies")

	do
		local useA, setUseA = signal(true)
		local a, setA = signal(10)
		local b, setB = signal(100)

		local runs = 0
		local observed = 0

		local stop = effect(function()
			runs += 1

			if useA() then
				observed = a()
			else
				observed = b()
			end
		end)

		expect(observed, 10, "initial A")
		expect(runs, 1, "initial runs")

		setUseA(false)
		expect(observed, 100, "switched to B")
		expect(runs, 2, "switch rerun")

		setA(11)
		expect(runs, 2, "old A no longer reruns effect")
		expect(observed, 100, "old A update ignored while using B")

		setB(101)
		expect(runs, 3, "B update reruns")
		expect(observed, 101, "B update observed")

		stop()
	end


	section("watch observes changes after initial read")

	do
		local getCount, setCount = signal(0)

		local runs = 0
		local observed = -1
		local previous = -1

		local stop = watch(getCount, function(current, prev)
			runs += 1
			observed = current
			previous = prev or -1
		end)

		expect(runs, 0, "watch does not run callback initially")

		setCount(1)

		expect(runs, 1, "watch runs after first change")
		expect(observed, 1, "watch observed first change")
		expect(previous, 0, "watch previous first value")

		setCount(2)

		expect(runs, 2, "watch runs after second change")
		expect(observed, 2, "watch observed second change")
		expect(previous, 1, "watch previous second value")

		setCount(2)

		expect(runs, 2, "watch skips same value")

		stop()

		setCount(3)

		expect(runs, 2, "watch stopped no rerun")
		expect(observed, 2, "watch stopped observed unchanged")
	end

	section("watch callback is peek")

	do
		local getTracked, setTracked = signal(0)
		local getIgnored, setIgnored = signal(0)

		local runs = 0
		local observedTracked = -1
		local observedIgnored = -1

		local stop = watch(getTracked, function(current)
			runs += 1
			observedTracked = current
			observedIgnored = getIgnored()
		end)

		setIgnored(1)

		expect(runs, 0, "watch peek callback ignored signal does not run")

		setTracked(1)

		expect(runs, 1, "watch tracked change runs")
		expect(observedTracked, 1, "watch tracked observed")
		expect(observedIgnored, 1, "watch callback can read ignored value")

		setIgnored(2)

		expect(runs, 1, "watch callback read did not subscribe")

		stop()
	end



	section("watch table signal")

	do
		local getState, setState = signal({
			coins = 0,
			level = 1,
		})

		local runs = 0
		local observedCoins = -1
		local observedLevel = -1

		local stop = watch(getState, function(state)
			runs += 1
			observedCoins = state.coins
			observedLevel = state.level
		end)

		expect(runs, 0, "watch table does not run immediately")
		expect(observedCoins, -1, "watch table coins unchanged before set")
		expect(observedLevel, -1, "watch table level unchanged before set")

		setState({
			coins = 100,
			level = 3,
		})

		expect(runs, 1, "watch table ran after set")
		expect(observedCoins, 100, "watch table updated coins")
		expect(observedLevel, 3, "watch table updated level")

		stop()

		setState({
			coins = 200,
			level = 4,
		})

		expect(runs, 1, "stopped watch table no rerun")
		expect(observedCoins, 100, "stopped watch table coins unchanged")
		expect(observedLevel, 3, "stopped watch table level unchanged")
	end

	section("watch computed from table signal")

	do
		local getPlayer, setPlayer = signal({
			health = 100,
			maxHealth = 100,
		})

		local healthPercent = computed(function()
			local player = getPlayer()
			return player.health / player.maxHealth
		end)

		local runs = 0
		local observed = -1

		local stop = watch(healthPercent, function(value)
			runs += 1
			observed = value
		end)

		expect(runs, 0, "watch table computed does not run immediately")
		expect(observed, -1, "watch table computed unchanged before set")

		setPlayer({
			health = 25,
			maxHealth = 100,
		})

		expect(runs, 1, "watch table computed ran after set")
		expect(observed, 0.25, "watch table computed updated value")

		stop()

		setPlayer({
			health = 10,
			maxHealth = 100,
		})

		expect(runs, 1, "stopped watch table computed no rerun")
		expect(observed, 0.25, "stopped watch table computed unchanged")
	end

	section("batch table updates")

	do
		local getState, setState = signal({
			coins = 0,
			level = 1,
		})

		local runs = 0
		local observedCoins = -1
		local observedLevel = -1

		local stop = watch(getState, function(state)
			runs += 1
			observedCoins = state.coins
			observedLevel = state.level
		end)

		expect(runs, 0, "batch table watch does not run immediately")

		batch(function()
			setState({
				coins = 10,
				level = 1,
			})

			setState({
				coins = 20,
				level = 2,
			})

			setState({
				coins = 30,
				level = 3,
			})
		end)

		expect(runs, 1, "batch table ran once")
		expect(observedCoins, 30, "batch table final coins")
		expect(observedLevel, 3, "batch table final level")

		stop()
	end

	section("table signal custom equals with watch")

	do
		local getState, setState = signal({
			coins = 10,
			level = 1,
		}, function(a, b)
			return a.coins == b.coins and a.level == b.level
		end)

		local runs = 0

		local stop = watch(getState, function()
			runs += 1
		end)

		expect(runs, 0, "table equals watch does not run immediately")

		setState({
			coins = 10,
			level = 1,
		})

		expect(runs, 0, "table equals skipped equivalent replacement")

		setState({
			coins = 10,
			level = 2,
		})

		expect(runs, 1, "table equals ran changed replacement")

		stop()
	end

	section("single target computed fast path")

	do
		local getCount, setCount = signal(1)

		local calls = 0

		local double = computed(function()
			calls += 1
			return getCount() * 2
		end)

		expect(double(), 2, "single target initial")
		expect(calls, 1, "single target initial calls")

		setCount(2)

		expect(double(), 4, "single target updated")
		expect(calls, 2, "single target recomputed")
	end

	section("deep table signal replacement")

	do
		local getPlayer, setPlayer = signal({
			stats = {
				combat = {
					attack = 25,
					defense = 10,
				},
			},
			inventory = {
				weapons = {
					primary = "Sword",
				},
			},
		})

		local combatPower = computed(function()
			local player = getPlayer()
			return player.stats.combat.attack + player.stats.combat.defense
		end)

		local weaponName = computed(function()
			local player = getPlayer()
			return player.inventory.weapons.primary
		end)

		local runs = 0
		local observedPower = -1

		local stop = watch(combatPower, function(value)
			runs += 1
			observedPower = value
		end)

		expect(combatPower(), 35, "deep table initial combat power")
		expect(weaponName(), "Sword", "deep table initial weapon")
		expect(runs, 0, "deep table watch does not run immediately")

		setPlayer({
			stats = {
				combat = {
					attack = 40,
					defense = 10,
				},
			},
			inventory = {
				weapons = {
					primary = "Axe",
				},
			},
		})

		expect(combatPower(), 50, "deep table updated combat power")
		expect(weaponName(), "Axe", "deep table updated weapon")
		expect(runs, 1, "deep table watch ran once")
		expect(observedPower, 50, "deep table watch observed updated power")

		stop()
	end

	section("deep table custom equals")

	do
		local getPlayer, setPlayer = signal({
			stats = {
				combat = {
					attack = 10,
					defense = 5,
				},
			},
		}, function(a, b)
			return a.stats.combat.attack == b.stats.combat.attack
				and a.stats.combat.defense == b.stats.combat.defense
		end)

		local runs = 0

		local stop = watch(getPlayer, function()
			runs += 1
		end)

		setPlayer({
			stats = {
				combat = {
					attack = 10,
					defense = 5,
				},
			},
		})

		expect(runs, 0, "deep table equals skipped equivalent nested replacement")

		setPlayer({
			stats = {
				combat = {
					attack = 25,
					defense = 5,
				},
			},
		})

		expect(runs, 1, "deep table equals detected nested attack change")

		stop()
	end

	section("multiple effects watch same signal")

	do
		local getCount, setCount = signal(0)

		local a = 0
		local b = 0

		local stopA = effect(function()
			a = getCount()
		end)

		local stopB = effect(function()
			b = getCount()
		end)

		expect(a, 0, "multiple effects first initial")
		expect(b, 0, "multiple effects second initial")

		setCount(5)

		expect(a, 5, "multiple effects first observed")
		expect(b, 5, "multiple effects second observed")

		stopA()
		setCount(10)

		expect(a, 5, "stopped first effect unchanged")
		expect(b, 10, "second effect still updates")

		stopB()

		setCount(15)

		expect(a, 5, "stopped first effect still unchanged")
		expect(b, 10, "stopped second effect unchanged")
	end

	section("watch stop inside callback")

	do
		local getCount, setCount = signal(0)

		local runs = 0
		local stop

		stop = watch(getCount, function()
			runs += 1
			stop()
		end)

		setCount(1)
		setCount(2)

		expect(runs, 1, "watch stopped itself inside callback")
	end

	section("computed circular dependency throws")

	do
		local a
		local b

		a = computed(function()
			return b()
		end)

		b = computed(function()
			return a()
		end)

		local ok = pcall(function()
			a()
		end)

		expect(ok, false, "circular computed throws")
	end

	section("effect error passes through")

	do
		local ok = pcall(function()
			effect(function()
				error("effect failure")
			end)
		end)

		expect(ok, false, "effect error thrown")
	end

	section("cleanup error passes through")

	do
		local getCount, setCount = signal(0)

		local runs = 0

		local stop = effect(function()
			runs += 1
			getCount()

			return function()
				error("cleanup failure")
			end
		end)

		expect(runs, 1, "cleanup error initial run")

		local ok = pcall(function()
			setCount(1)
		end)

		expect(ok, false, "cleanup error thrown during rerun")

		pcall(stop)
	end


	print(`[Reheaven] all tests passed: {passed}`)

	if Reheaven.reset then
		Reheaven.reset()
	end

	return passed
end

return run
