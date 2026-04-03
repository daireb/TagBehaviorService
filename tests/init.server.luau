--!strict
--[=[
	Integration tests for TagBehaviorService.
	Runs inside a Roblox DataModel (server context).

	Each test creates a fresh instance via `.new()` for isolation
	and cleans up via unsubscribe functions.
]=]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TBS = require(ReplicatedStorage.Packages.TagBehaviorService)

-- ---------------------------------------------------------------------------
-- Minimal test harness
-- ---------------------------------------------------------------------------

local results = { passed = 0, failed = 0 }

local function test(name: string, fn: () -> ())
	local ok, err = pcall(fn)
	if ok then
		results.passed += 1
		print(`  [PASS] {name}`)
	else
		results.failed += 1
		warn(`  [FAIL] {name}: {err}`)
	end
end

local function expect(cond: boolean, msg: string?)
	if not cond then
		error(msg or "Assertion failed", 2)
	end
end

local function expectEqual(actual: unknown, expected: unknown, label: string?)
	if actual ~= expected then
		error(`{label or "Value"}: expected {tostring(expected)}, got {tostring(actual)}`, 2)
	end
end

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local tagCounter = 0
local function uniqueTag(): string
	tagCounter += 1
	return `__TBS_Test_{tagCounter}_{tick()}`
end

local function makePart(tag: string?): Part
	local part = Instance.new("Part")
	part.Parent = workspace
	if tag then
		CollectionService:AddTag(part, tag)
	end
	return part
end

-- ---------------------------------------------------------------------------
-- Tests
-- ---------------------------------------------------------------------------

print("\n========================================")
print("  TagBehaviorService Test Suite")
print("========================================\n")

-- 1. Initial tagged-scan attach -------------------------------------------

test("attaches to instances already tagged before start", function()
	local tag = uniqueTag()
	local part = makePart(tag)

	local attachCount = 0
	local tbs = TBS.new()
	local unsub = tbs:subscribe(tag, function(_instance)
		attachCount += 1
		return nil
	end)
	tbs:start()

	expectEqual(attachCount, 1, "attachCount")
	expect(tbs:isActive(tag, part), "should be active")

	unsub()
	part:Destroy()
end)

-- 2. Runtime add attach ---------------------------------------------------

test("attaches when tag is added at runtime", function()
	local tag = uniqueTag()
	local tbs = TBS.new()

	local attachCount = 0
	local unsub = tbs:subscribe(tag, function(_instance)
		attachCount += 1
		return nil
	end)
	tbs:start()
	expectEqual(attachCount, 0, "before tag")

	local part = makePart()
	CollectionService:AddTag(part, tag)
	task.wait()

	expectEqual(attachCount, 1, "after tag")
	expect(tbs:isActive(tag, part), "active")

	unsub()
	part:Destroy()
end)

-- 3. Remove triggers cleanup ----------------------------------------------

test("runs cleanup when tag is removed", function()
	local tag = uniqueTag()
	local part = makePart(tag)

	local cleanedUp = false
	local tbs = TBS.new()
	local unsub = tbs:subscribe(tag, function(_instance)
		return function()
			cleanedUp = true
		end
	end)
	tbs:start()
	expect(not cleanedUp, "not yet cleaned up")

	CollectionService:RemoveTag(part, tag)
	task.wait()

	expect(cleanedUp, "cleanup should have run")
	expect(not tbs:isActive(tag, part), "should no longer be active")

	unsub()
	part:Destroy()
end)

-- 4. Destroyed instance cleanup -------------------------------------------

test("runs cleanup when instance is destroyed", function()
	local tag = uniqueTag()
	local part = makePart(tag)

	local cleanedUp = false
	local tbs = TBS.new()
	local unsub = tbs:subscribe(tag, function(_instance)
		return function()
			cleanedUp = true
		end
	end)
	tbs:start()

	part:Destroy()
	task.wait()

	expect(cleanedUp, "cleanup should have run on destroy")

	unsub()
end)

-- 5. Duplicate add signals do not double-attach ---------------------------

test("does not double-attach for already-tracked instance", function()
	local tag = uniqueTag()
	local part = makePart(tag)

	local attachCount = 0
	local tbs = TBS.new()
	local unsub = tbs:subscribe(tag, function(_instance)
		attachCount += 1
		return nil
	end)
	tbs:start()
	expectEqual(attachCount, 1, "initial")

	CollectionService:AddTag(part, tag)
	task.wait()
	expectEqual(attachCount, 1, "after duplicate AddTag")

	unsub()
	part:Destroy()
end)

-- 6. Remove then re-add produces exactly two attaches ---------------------

test("re-attaches after tag removal and re-add", function()
	local tag = uniqueTag()
	local part = makePart(tag)

	local attachCount = 0
	local cleanupCount = 0
	local tbs = TBS.new()
	local unsub = tbs:subscribe(tag, function(_instance)
		attachCount += 1
		return function()
			cleanupCount += 1
		end
	end)
	tbs:start()
	expectEqual(attachCount, 1, "first attach")

	CollectionService:RemoveTag(part, tag)
	task.wait()
	expectEqual(cleanupCount, 1, "first cleanup")

	CollectionService:AddTag(part, tag)
	task.wait()
	expectEqual(attachCount, 2, "second attach")

	unsub()
	part:Destroy()
end)

-- 7. Unsubscribe behaviour ------------------------------------------------

test("unsubscribe cleans up active contexts and is idempotent", function()
	local tag = uniqueTag()
	local part = makePart(tag)

	local cleanedUp = false
	local tbs = TBS.new()
	local unsub = tbs:subscribe(tag, function(_instance)
		return function()
			cleanedUp = true
		end
	end)
	tbs:start()

	expect(tbs:isActive(tag, part), "active before unsub")

	unsub()
	expect(cleanedUp, "cleanup ran on unsub")
	expect(not tbs:isActive(tag, part), "not active after unsub")

	-- Idempotent: second call is a no-op
	unsub()

	-- New instances tagged after unsub should not trigger factory
	local part2 = makePart()
	CollectionService:AddTag(part2, tag)
	task.wait()
	expect(not tbs:isActive(tag, part2), "no attach after unsub")
	part2:Destroy()

	part:Destroy()
end)

-- 8. Error isolation — factory error doesn't crash service ----------------

test("factory error does not prevent other subscriptions from working", function()
	local tagBad = uniqueTag()
	local tagGood = uniqueTag()
	local partBad = makePart(tagBad)
	local partGood = makePart(tagGood)

	local goodAttached = false

	local tbs = TBS.new()
	local unsub1 = tbs:subscribe(tagBad, function(_instance)
		error("boom")
	end)
	local unsub2 = tbs:subscribe(tagGood, function(_instance)
		goodAttached = true
		return nil
	end)
	tbs:start()

	expect(goodAttached, "good subscription should still work despite bad factory")

	unsub1()
	unsub2()
	partBad:Destroy()
	partGood:Destroy()
end)

-- 9. Error isolation — cleanup error doesn't crash service ----------------

test("cleanup error does not crash the service", function()
	local tag = uniqueTag()
	local part = makePart(tag)

	local tbs = TBS.new()
	local unsub = tbs:subscribe(tag, function(_instance)
		return function()
			error("cleanup boom")
		end
	end)
	tbs:start()

	CollectionService:RemoveTag(part, tag)
	task.wait()

	expect(not tbs:isActive(tag, part), "context should be cleared")
	expectEqual(tbs:getActiveCount(), 0, "no active contexts")

	unsub()
	part:Destroy()
end)

-- 10. Filter filters instances (IsA example) ------------------------------

test("filter filters instances by class", function()
	local tag = uniqueTag()

	local folder = Instance.new("Folder")
	folder.Parent = workspace
	CollectionService:AddTag(folder, tag)

	local part = makePart(tag)

	local attachedInstances: { Instance } = {}
	local tbs = TBS.new()
	local unsub = tbs:subscribe(tag, {
		factory = function(instance)
			table.insert(attachedInstances, instance)
			return nil
		end,
		filter = function(instance)
			return instance:IsA("BasePart")
		end,
	})
	tbs:start()

	expectEqual(#attachedInstances, 1, "only BasePart attached")
	expectEqual(attachedInstances[1], part, "attached instance")

	unsub()
	folder:Destroy()
	part:Destroy()
end)

-- 11. Filter filters by name ---------------------------------------------

test("filter filters by instance name", function()
	local tag = uniqueTag()
	local partA = makePart(tag)
	partA.Name = "Allow"
	local partB = makePart(tag)
	partB.Name = "Deny"

	local attached: { string } = {}
	local tbs = TBS.new()
	local unsub = tbs:subscribe(tag, {
		factory = function(instance)
			table.insert(attached, instance.Name)
			return nil
		end,
		filter = function(instance)
			return instance.Name == "Allow"
		end,
	})
	tbs:start()

	expectEqual(#attached, 1, "count")
	expectEqual(attached[1], "Allow", "name")

	unsub()
	partA:Destroy()
	partB:Destroy()
end)

-- 12. Filter error is isolated -------------------------------------------

test("filter error skips instance without crashing", function()
	local tag = uniqueTag()
	local part = makePart(tag)

	local attachCount = 0
	local tbs = TBS.new()
	local unsub = tbs:subscribe(tag, {
		factory = function(_instance)
			attachCount += 1
			return nil
		end,
		filter = function(_instance)
			error("filter fail")
		end,
	})
	tbs:start()

	expectEqual(attachCount, 0, "should not attach when filter errors")

	unsub()
	part:Destroy()
end)

-- 13. Subscribe after start -----------------------------------------------

test("subscribe after start immediately activates", function()
	local tag = uniqueTag()
	local part = makePart(tag)

	local tbs = TBS.new()
	tbs:start()

	local attached = false
	local unsub = tbs:subscribe(tag, function(_instance)
		attached = true
		return nil
	end)

	expect(attached, "should attach immediately on subscribe-after-start")

	unsub()
	part:Destroy()
end)

-- 14. getActiveCount -------------------------------------------------------

test("getActiveCount returns correct counts", function()
	local tagA = uniqueTag()
	local tagB = uniqueTag()
	local partA1 = makePart(tagA)
	local partA2 = makePart(tagA)
	local partB1 = makePart(tagB)

	local tbs = TBS.new()
	local unsub1 = tbs:subscribe(tagA, function(_instance)
		return nil
	end)
	local unsub2 = tbs:subscribe(tagB, function(_instance)
		return nil
	end)
	tbs:start()

	expectEqual(tbs:getActiveCount(tagA), 2, "tagA count")
	expectEqual(tbs:getActiveCount(tagB), 1, "tagB count")
	expectEqual(tbs:getActiveCount(), 3, "total count")

	unsub1()
	unsub2()
	partA1:Destroy()
	partA2:Destroy()
	partB1:Destroy()
end)

-- 15. Multiple subscriptions for same tag ----------------------------------

test("multiple subscriptions for the same tag work independently", function()
	local tag = uniqueTag()
	local part = makePart(tag)

	local attachA = 0
	local attachB = 0
	local cleanA = 0
	local cleanB = 0

	local tbs = TBS.new()
	local unsub1 = tbs:subscribe(tag, function(_instance)
		attachA += 1
		return function()
			cleanA += 1
		end
	end)
	local unsub2 = tbs:subscribe(tag, function(_instance)
		attachB += 1
		return function()
			cleanB += 1
		end
	end)
	tbs:start()

	expectEqual(attachA, 1, "attachA")
	expectEqual(attachB, 1, "attachB")

	CollectionService:RemoveTag(part, tag)
	task.wait()

	expectEqual(cleanA, 1, "cleanA")
	expectEqual(cleanB, 1, "cleanB")

	unsub1()
	unsub2()
	part:Destroy()
end)

-- 16. isStarted reflects state correctly -----------------------------------

test("isStarted reflects lifecycle state", function()
	local tbs = TBS.new()
	expect(not tbs:isStarted(), "initial")
	tbs:start()
	expect(tbs:isStarted(), "after start")
end)

-- 17. Factory returning non-function doesn't crash -------------------------

test("factory returning non-function warns but does not crash", function()
	local tag = uniqueTag()
	local tagGood = uniqueTag()
	local part = makePart(tag)
	local partGood = makePart(tagGood)

	local goodAttached = false

	local tbs = TBS.new()
	local unsub1 = tbs:subscribe(tag, function(_instance)
		return "not a function" :: any
	end)
	local unsub2 = tbs:subscribe(tagGood, function(_instance)
		goodAttached = true
		return nil
	end)
	tbs:start()

	expect(goodAttached, "good subscription should still work")

	unsub1()
	unsub2()
	part:Destroy()
	partGood:Destroy()
end)

-- 18. At-most-once cleanup guarantee --------------------------------------

test("cleanup is invoked at most once per activation", function()
	local tag = uniqueTag()
	local part = makePart(tag)

	local cleanupCount = 0
	local tbs = TBS.new()
	local unsub = tbs:subscribe(tag, function(_instance)
		return function()
			cleanupCount += 1
		end
	end)
	tbs:start()

	CollectionService:RemoveTag(part, tag)
	task.wait()
	part:Destroy()
	task.wait()

	expectEqual(cleanupCount, 1, "cleanup count")

	unsub()
end)

-- 19. Update called on attach with dt=0 ------------------------------------

test("update is called on attach with dt=0", function()
	local tag = uniqueTag()
	local part = makePart(tag)

	local updateCalls: { { Instance | number } } = {}
	local tbs = TBS.new()
	local unsub = tbs:subscribe(tag, {
		factory = function(_instance)
			return nil
		end,
		update = function(instance, dt)
			table.insert(updateCalls, { instance, dt })
		end,
	})
	tbs:start()

	expectEqual(#updateCalls, 1, "update call count")
	expectEqual(updateCalls[1][1], part, "update instance")
	expectEqual(updateCalls[1][2], 0, "update dt")

	unsub()
	part:Destroy()
end)

-- 20. updateAll calls update for active instances --------------------------

test("updateAll calls update for all active instances", function()
	local tagA = uniqueTag()
	local tagB = uniqueTag()
	local partA = makePart(tagA)
	local partB = makePart(tagB)

	local updateCount = 0
	local lastDt = 0
	local tbs = TBS.new()
	local unsub1 = tbs:subscribe(tagA, {
		update = function(_instance, dt)
			updateCount += 1
			lastDt = dt
		end,
	})
	local unsub2 = tbs:subscribe(tagB, {
		update = function(_instance, dt)
			updateCount += 1
			lastDt = dt
		end,
	})
	tbs:start()

	-- Reset after initial on-attach updates
	updateCount = 0
	lastDt = 0

	tbs:updateAll(0.5)

	expectEqual(updateCount, 2, "update count")
	expectEqual(lastDt, 0.5, "dt value")

	unsub1()
	unsub2()
	partA:Destroy()
	partB:Destroy()
end)

-- 21. updateTag scopes to correct tag --------------------------------------

test("updateTag only updates the specified tag", function()
	local tagA = uniqueTag()
	local tagB = uniqueTag()
	local partA = makePart(tagA)
	local partB = makePart(tagB)

	local countA = 0
	local countB = 0
	local tbs = TBS.new()
	local unsub1 = tbs:subscribe(tagA, {
		update = function(_instance, _dt)
			countA += 1
		end,
	})
	local unsub2 = tbs:subscribe(tagB, {
		update = function(_instance, _dt)
			countB += 1
		end,
	})
	tbs:start()

	-- Reset after initial on-attach updates
	countA = 0
	countB = 0

	tbs:updateTag(tagA, 0.1)

	expectEqual(countA, 1, "tagA updated")
	expectEqual(countB, 0, "tagB not updated")

	unsub1()
	unsub2()
	partA:Destroy()
	partB:Destroy()
end)

-- 22. Update error is isolated ---------------------------------------------

test("update error does not crash other updates", function()
	local tagBad = uniqueTag()
	local tagGood = uniqueTag()
	local partBad = makePart(tagBad)
	local partGood = makePart(tagGood)

	local goodUpdateCount = 0
	local tbs = TBS.new()
	local unsub1 = tbs:subscribe(tagBad, {
		update = function(_instance, _dt)
			error("update boom")
		end,
	})
	local unsub2 = tbs:subscribe(tagGood, {
		update = function(_instance, _dt)
			goodUpdateCount += 1
		end,
	})
	tbs:start()

	-- Reset after initial on-attach updates (bad one errored, good one ran)
	goodUpdateCount = 0

	tbs:updateAll(0.1)

	expectEqual(goodUpdateCount, 1, "good update still runs")

	unsub1()
	unsub2()
	partBad:Destroy()
	partGood:Destroy()
end)

-- 23. Update not called for instances that fail filter ---------------------

test("update not called for instances filtered by filter", function()
	local tag = uniqueTag()
	local folder = Instance.new("Folder")
	folder.Parent = workspace
	CollectionService:AddTag(folder, tag)

	local part = makePart(tag)

	local updateInstances: { Instance } = {}
	local tbs = TBS.new()
	local unsub = tbs:subscribe(tag, {
		filter = function(instance)
			return instance:IsA("BasePart")
		end,
		update = function(instance, _dt)
			table.insert(updateInstances, instance)
		end,
	})
	tbs:start()

	-- On-attach update should only fire for the part
	expectEqual(#updateInstances, 1, "on-attach count")
	expectEqual(updateInstances[1], part, "on-attach instance")

	-- Reset and do an explicit update
	updateInstances = {}
	tbs:updateAll(0.1)

	expectEqual(#updateInstances, 1, "updateAll count")
	expectEqual(updateInstances[1], part, "updateAll instance")

	unsub()
	folder:Destroy()
	part:Destroy()
end)

-- 24. Update not called after cleanup/unsubscribe --------------------------

test("update not called after unsubscribe", function()
	local tag = uniqueTag()
	local part = makePart(tag)

	local updateCount = 0
	local tbs = TBS.new()
	local unsub = tbs:subscribe(tag, {
		update = function(_instance, _dt)
			updateCount += 1
		end,
	})
	tbs:start()

	-- Reset after on-attach
	updateCount = 0
	unsub()

	tbs:updateAll(0.1)
	expectEqual(updateCount, 0, "no updates after unsub")

	part:Destroy()
end)

-- 25. Subscribe without update works unchanged (backwards compat) ----------

test("subscribe with function shorthand works", function()
	local tag = uniqueTag()
	local part = makePart(tag)

	local attached = false
	local tbs = TBS.new()
	local unsub = tbs:subscribe(tag, function(_instance)
		attached = true
		return nil
	end)
	tbs:start()

	expect(attached, "should attach with function shorthand")

	tbs:updateAll(0.1)

	expect(tbs:isActive(tag, part), "still active after updateAll")

	unsub()
	part:Destroy()
end)

-- 26. getRegisteredTags returns correct tags --------------------------------

test("getRegisteredTags returns correct tags", function()
	local tagA = uniqueTag()
	local tagB = uniqueTag()

	local tbs = TBS.new()
	expectEqual(#tbs:getRegisteredTags(), 0, "empty initially")

	local unsub1 = tbs:subscribe(tagA, function(_instance)
		return nil
	end)
	local unsub2 = tbs:subscribe(tagB, function(_instance)
		return nil
	end)

	local tags = tbs:getRegisteredTags()
	expectEqual(#tags, 2, "two tags registered")

	local hasA = table.find(tags, tagA) ~= nil
	local hasB = table.find(tags, tagB) ~= nil
	expect(hasA, "contains tagA")
	expect(hasB, "contains tagB")

	unsub1()
	tags = tbs:getRegisteredTags()
	expectEqual(#tags, 1, "one tag after unsub")
	expectEqual(tags[1], tagB, "remaining tag is tagB")

	unsub2()
	expectEqual(#tbs:getRegisteredTags(), 0, "empty after all unsubs")
end)

-- 27. hasUpdate returns true/false correctly --------------------------------

test("hasUpdate returns true/false correctly", function()
	local tagWithUpdate = uniqueTag()
	local tagWithout = uniqueTag()

	local tbs = TBS.new()
	expect(not tbs:hasUpdate(tagWithUpdate), "false for unregistered tag")

	local unsub1 = tbs:subscribe(tagWithUpdate, {
		update = function(_instance, _dt) end,
	})

	local unsub2 = tbs:subscribe(tagWithout, function(_instance)
		return nil
	end)

	expect(tbs:hasUpdate(tagWithUpdate), "true for tag with update")
	expect(not tbs:hasUpdate(tagWithout), "false for tag without update")

	unsub1()
	expect(not tbs:hasUpdate(tagWithUpdate), "false after unsub")

	unsub2()
end)

-- 28. updateTag is a no-op for tags with no update -------------------------

test("updateTag is a no-op for tags with no update", function()
	local tag = uniqueTag()
	local part = makePart(tag)

	local tbs = TBS.new()
	local unsub = tbs:subscribe(tag, function(_instance)
		return nil
	end)
	tbs:start()

	-- Should not error
	tbs:updateTag(tag, 0.1)
	tbs:updateTag("nonexistent_tag", 0.1)

	expect(tbs:isActive(tag, part), "still active")

	unsub()
	part:Destroy()
end)

-- 29. Update-only subscription (no factory) --------------------------------

test("update-only subscription works without factory", function()
	local tag = uniqueTag()
	local part = makePart(tag)

	local updateCalls = 0
	local tbs = TBS.new()
	local unsub = tbs:subscribe(tag, {
		update = function(_instance, _dt)
			updateCalls += 1
		end,
	})
	tbs:start()

	expectEqual(updateCalls, 1, "on-attach update")
	expect(tbs:isActive(tag, part), "should be active")

	tbs:updateAll(0.1)
	expectEqual(updateCalls, 2, "after updateAll")

	unsub()
	part:Destroy()
end)

-- 30. Subscribe with table config works ------------------------------------

test("subscribe with table config works", function()
	local tag = uniqueTag()
	local part = makePart(tag)

	local factoryRan = false
	local filterRan = false
	local updateRan = false
	local tbs = TBS.new()
	local unsub = tbs:subscribe(tag, {
		factory = function(_instance)
			factoryRan = true
			return nil
		end,
		filter = function(instance)
			filterRan = true
			return instance:IsA("BasePart")
		end,
		update = function(_instance, _dt)
			updateRan = true
		end,
	})
	tbs:start()

	expect(filterRan, "filter should have run")
	expect(factoryRan, "factory should have run")
	expect(updateRan, "update should have run on attach")

	unsub()
	part:Destroy()
end)

-- ---------------------------------------------------------------------------
-- Summary
-- ---------------------------------------------------------------------------

print("\n========================================")
print(`  Results: {results.passed} passed, {results.failed} failed`)
print("========================================\n")

if results.failed > 0 then
	error(`{results.failed} test(s) failed`)
end
