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

-- 8. Deferred attach ------------------------------------------------------

test("deferred attach runs factory after deferral", function()
	local tag = uniqueTag()
	local part = makePart(tag)

	local attached = false
	local tbs = TBS.new()
	local unsub = tbs:subscribe(tag, function(_instance)
		attached = true
		return nil
	end, { defer = true })
	tbs:start()

	expect(not attached, "should not attach synchronously with defer")
	local ctx = tbs:getContext(tag, part)
	expect(ctx ~= nil and not ctx.active, "should be pending")

	task.wait()
	task.wait()

	expect(attached, "should attach after deferral")
	expect(tbs:isActive(tag, part), "should be active")

	unsub()
	part:Destroy()
end)

-- 9. Deferred cancellation on tag removal ---------------------------------

test("deferred attach is cancelled when tag is removed before it fires", function()
	local tag = uniqueTag()

	local factoryCalled = false
	local tbs = TBS.new()
	local unsub = tbs:subscribe(tag, function(_instance)
		factoryCalled = true
		return nil
	end, { defer = true })
	tbs:start()

	local part = makePart()
	CollectionService:AddTag(part, tag)
	CollectionService:RemoveTag(part, tag)
	task.wait()
	task.wait()

	expect(not factoryCalled, "factory should not have been called")

	unsub()
	part:Destroy()
end)

-- 10. Deferred cancellation on unsubscribe --------------------------------

test("deferred attach is cancelled when unsubscribed before it fires", function()
	local tag = uniqueTag()
	local part = makePart(tag)

	local factoryCalled = false
	local tbs = TBS.new()
	local unsub = tbs:subscribe(tag, function(_instance)
		factoryCalled = true
		return nil
	end, { defer = true })
	tbs:start()
	unsub()
	task.wait()
	task.wait()

	expect(not factoryCalled, "factory should not run after unsubscribe")

	part:Destroy()
end)

-- 11. Error isolation — factory error doesn't crash service ---------------

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

-- 12. Error isolation — cleanup error doesn't crash service ---------------

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

-- 13. className filtering -------------------------------------------------

test("className filter skips non-matching instances", function()
	local tag = uniqueTag()

	local folder = Instance.new("Folder")
	folder.Parent = workspace
	CollectionService:AddTag(folder, tag)

	local part = makePart(tag)

	local attachedInstances: { Instance } = {}
	local tbs = TBS.new()
	local unsub = tbs:subscribe(tag, function(instance)
		table.insert(attachedInstances, instance)
		return nil
	end, { className = "BasePart" })
	tbs:start()

	expectEqual(#attachedInstances, 1, "only BasePart attached")
	expectEqual(attachedInstances[1], part, "attached instance")

	unsub()
	folder:Destroy()
	part:Destroy()
end)

-- 14. Predicate filtering -------------------------------------------------

test("predicate filter controls which instances are attached", function()
	local tag = uniqueTag()
	local partA = makePart(tag)
	partA.Name = "Allow"
	local partB = makePart(tag)
	partB.Name = "Deny"

	local attached: { string } = {}
	local tbs = TBS.new()
	local unsub = tbs:subscribe(tag, function(instance)
		table.insert(attached, instance.Name)
		return nil
	end, {
		predicate = function(instance)
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

-- 15. Predicate error is isolated -----------------------------------------

test("predicate error skips instance without crashing", function()
	local tag = uniqueTag()
	local part = makePart(tag)

	local attachCount = 0
	local tbs = TBS.new()
	local unsub = tbs:subscribe(tag, function(_instance)
		attachCount += 1
		return nil
	end, {
		predicate = function(_instance)
			error("predicate fail")
		end,
	})
	tbs:start()

	expectEqual(attachCount, 0, "should not attach when predicate errors")

	unsub()
	part:Destroy()
end)

-- 16. Subscribe after start -----------------------------------------------

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

-- 17. getActiveCount -------------------------------------------------------

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

-- 18. Multiple subscriptions for same tag ----------------------------------

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

-- 19. isStarted reflects state correctly -----------------------------------

test("isStarted reflects lifecycle state", function()
	local tbs = TBS.new()
	expect(not tbs:isStarted(), "initial")
	tbs:start()
	expect(tbs:isStarted(), "after start")
end)

-- 20. Factory returning non-function doesn't crash -------------------------

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

-- 21. At-most-once cleanup guarantee --------------------------------------

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

-- ---------------------------------------------------------------------------
-- Summary
-- ---------------------------------------------------------------------------

print("\n========================================")
print(`  Results: {results.passed} passed, {results.failed} failed`)
print("========================================\n")

if results.failed > 0 then
	error(`{results.failed} test(s) failed`)
end
