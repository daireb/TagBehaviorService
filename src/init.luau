--!strict
--[=[
	@class TagBehaviorService

	Manages lifecycle for CollectionService-tagged instances by mapping tags
	to factory callbacks that produce optional cleanup functions.

	This module returns a ready-to-use singleton. For test isolation or
	multi-scope use, `.new()` is available via the metatable.
]=]

local CollectionService = game:GetService("CollectionService")

-- Exported types

export type BehaviorDefinition = {
	tag: string?,
	factory: ((instance: Instance) -> (() -> ())?)?,
	filter: ((instance: Instance) -> boolean)?,
	update: ((instance: Instance, dt: number) -> ())?,
}

-- Internal types

type ErrorPhase = "factory" | "cleanup" | "filter" | "update"

type Context = {
	cleanup: (() -> ())?,
	destroyingConn: RBXScriptConnection?,
}

type Subscription = {
	tag: string,
	factory: ((instance: Instance) -> (() -> ())?)?,
	filter: ((instance: Instance) -> boolean)?,
	update: ((instance: Instance, dt: number) -> ())?,
	contexts: { [Instance]: Context },
	addedConn: RBXScriptConnection?,
	removedConn: RBXScriptConnection?,
}

-- Internal helper functions

local function reportError(phase: ErrorPhase, tag: string, instance: Instance, err: string)
	warn(`[TagBehaviorService] {phase} error for tag "{tag}" on {instance:GetFullName()}: {err}`)
end

local function passesFilter(sub: Subscription, instance: Instance): boolean
	local filter = sub.filter
	if filter == nil then
		return true
	end

	local ok, result = pcall(filter, instance)
	if not ok then
		reportError("filter", sub.tag, instance, tostring(result))
		return false
	end
	return result == true
end

local function runFactory(sub: Subscription, instance: Instance, context: Context)
	if not sub.factory then
		return
	end

	local ok, result = pcall(sub.factory, instance)

	-- Context may have been removed during factory execution (reentrant unsubscribe)
	if sub.contexts[instance] ~= context then
		return
	end

	if not ok then
		reportError("factory", sub.tag, instance, tostring(result))
		return
	end

	if result ~= nil and type(result) ~= "function" then
		reportError("factory", sub.tag, instance, `Factory must return nil or a cleanup function, got {type(result)}`)
		return
	end

	context.cleanup = result :: (() -> ())?
end

local function cleanupContext(sub: Subscription, instance: Instance)
	local context = sub.contexts[instance]
	if not context then
		return
	end

	-- Remove from map first to guarantee at-most-once cleanup
	sub.contexts[instance] = nil

	if context.destroyingConn then
		context.destroyingConn:Disconnect()
		context.destroyingConn = nil
	end

	local cleanup = context.cleanup
	if cleanup ~= nil then
		local ok, err = pcall(cleanup :: any)
		if not ok then
			reportError("cleanup", sub.tag, instance, tostring(err))
		end
	end
end

local function deactivateSubscription(sub: Subscription)
	if sub.addedConn then
		sub.addedConn:Disconnect()
		sub.addedConn = nil
	end

	if sub.removedConn then
		sub.removedConn:Disconnect()
		sub.removedConn = nil
	end

	local instances: { Instance } = {}
	for instance in sub.contexts do
		table.insert(instances, instance)
	end

	for _, instance in instances do
		cleanupContext(sub, instance)
	end
end

-- Module

local TagBehaviorService = {}
TagBehaviorService.__index = TagBehaviorService

type Self = {
	_started: boolean,
	_tagSubs: { [string]: { Subscription } },
}

export type TagBehaviorService = typeof(setmetatable({} :: Self, TagBehaviorService))

function TagBehaviorService.new(): TagBehaviorService
	local self = setmetatable({} :: Self, TagBehaviorService)
	self._started = false
	self._tagSubs = {}
	return self
end

-- Private methods

local function attachInstance(sub: Subscription, instance: Instance)
	if sub.contexts[instance] then
		return
	end

	if not passesFilter(sub, instance) then
		return
	end

	local context: Context = {
		cleanup = nil,
		destroyingConn = nil,
	}
	sub.contexts[instance] = context

	context.destroyingConn = instance.Destroying:Connect(function()
		cleanupContext(sub, instance)
	end)

	runFactory(sub, instance, context)

	if sub.update and sub.contexts[instance] == context then
		local ok, err = pcall(sub.update :: any, instance, 0)
		if not ok then
			reportError("update", sub.tag, instance, tostring(err))
		end
	end
end

function TagBehaviorService._activateSubscription(self: TagBehaviorService, sub: Subscription)
	sub.addedConn = CollectionService:GetInstanceAddedSignal(sub.tag):Connect(function(instance)
		if self._started then
			attachInstance(sub, instance)
		end
	end)

	sub.removedConn = CollectionService:GetInstanceRemovedSignal(sub.tag):Connect(function(instance)
		cleanupContext(sub, instance)
	end)

	for _, instance in CollectionService:GetTagged(sub.tag) do
		attachInstance(sub, instance)
	end
end

function TagBehaviorService._collectAllSubs(self: TagBehaviorService): { Subscription }
	local all: { Subscription } = {}
	for _, subs in self._tagSubs do
		for _, sub in subs do
			table.insert(all, sub)
		end
	end
	return all
end

-- Public API

--[=[
	Subscribes a tag to a behavior.

	The second argument can be:
	- A **function** — treated as the factory (shorthand for simple behaviors)
	- A **table** `{ factory?, filter?, update? }` — for complex behaviors
	- **nil** — warns about an empty subscription

	Returns an idempotent unsubscribe function.
]=]
function TagBehaviorService.subscribe(
	self: TagBehaviorService,
	tag: string,
	config: ((instance: Instance) -> (() -> ())?) | BehaviorDefinition | nil
): () -> ()
	assert(type(tag) == "string" and #tag > 0, "Tag must be a non-empty string")

	local factory: ((instance: Instance) -> (() -> ())?)? = nil
	local filter: ((instance: Instance) -> boolean)? = nil
	local update: ((instance: Instance, dt: number) -> ())? = nil

	if type(config) == "function" then
		factory = config :: (instance: Instance) -> (() -> ())?
	elseif type(config) == "table" then
		local def = config :: BehaviorDefinition
		factory = def.factory
		filter = def.filter
		update = def.update
	end

	if factory == nil and update == nil then
		warn(`[TagBehaviorService] Subscription for tag "{tag}" has no factory or update and will do nothing`)
	end

	local sub: Subscription = {
		tag = tag,
		factory = factory,
		filter = filter,
		update = update,
		contexts = {},
		addedConn = nil,
		removedConn = nil,
	}

	if not self._tagSubs[tag] then
		self._tagSubs[tag] = {}
	end
	table.insert(self._tagSubs[tag], sub)

	if self._started then
		self:_activateSubscription(sub)
	end

	local unsubscribed = false
	return function()
		if unsubscribed then
			return
		end
		unsubscribed = true

		deactivateSubscription(sub)

		local subs = self._tagSubs[tag]
		if subs then
			local idx = table.find(subs, sub)
			if idx then
				table.remove(subs, idx)
			end
			if #subs == 0 then
				self._tagSubs[tag] = nil
			end
		end
	end
end

--[=[
	Starts the service. Activates all current subscriptions: connects
	CollectionService signals and performs an initial scan of tagged instances.
	Idempotent — calling while already started is a no-op.
]=]
function TagBehaviorService.start(self: TagBehaviorService)
	if self._started then
		return
	end

	self._started = true

	for _, sub in self:_collectAllSubs() do
		self:_activateSubscription(sub)
	end
end

--[=[
	Registers every descendant ModuleScript in `folder` as a tag subscription.

	Each module should return either:
	- A factory function (tag defaults to `ModuleScript.Name`)
	- A `BehaviorDefinition` table with optional `factory`, `filter`,
	  `update`, and `tag` fields.

	An optional `moduleFilter` receives each `ModuleScript` before it is
	required and returns a boolean. Modules that fail the filter are
	skipped entirely.

	Returns an idempotent function that unsubscribes all behaviors
	registered from this folder.
]=]
function TagBehaviorService.registerFolder(
	self: TagBehaviorService,
	folder: Instance,
	moduleFilter: ((module: ModuleScript) -> boolean)?
): () -> ()
	local unsubs: { () -> () } = {}

	for _, child in folder:QueryDescendants("ModuleScript") do
		if moduleFilter then
			local filterOk, filterResult = pcall(moduleFilter, child)
			if not filterOk then
				warn(`[TagBehaviorService] Module filter error for {child:GetFullName()}: {tostring(filterResult)}`)
				continue
			end
			if filterResult ~= true then
				continue
			end
		end

		local ok, result = pcall(require, child)
		if not ok then
			warn(`[TagBehaviorService] Failed to require {child:GetFullName()}: {tostring(result)}`)
			continue
		end

		local tag: string

		if type(result) == "function" then
			tag = child.Name
			table.insert(unsubs, self:subscribe(tag, result))
		elseif type(result) == "table" then
			local def = result :: BehaviorDefinition
			tag = def.tag or child.Name

			if def.factory ~= nil and type(def.factory) ~= "function" then
				warn(
					string.format(
						"[TagBehaviorService] %s factory must be a function or nil, got %s",
						child:GetFullName(),
						type(def.factory)
					)
				)
				continue
			end

			table.insert(unsubs, self:subscribe(tag, def))
		else
			warn(`[TagBehaviorService] {child:GetFullName()} must return a function or table, got {type(result)}`)
			continue
		end
	end

	local unregistered = false
	return function()
		if unregistered then
			return
		end
		unregistered = true
		for _, unsub in unsubs do
			unsub()
		end
	end
end

--[=[
	Returns whether the service is currently started.
]=]
function TagBehaviorService.isStarted(self: TagBehaviorService): boolean
	return self._started
end

--[=[
	Returns `true` if there is a binding for the given `(tag, instance)` pair.
]=]
function TagBehaviorService.isActive(self: TagBehaviorService, tag: string, instance: Instance): boolean
	local subs = self._tagSubs[tag]
	if not subs then
		return false
	end

	for _, sub in subs do
		if sub.contexts[instance] then
			return true
		end
	end

	return false
end

--[=[
	Returns the number of active bindings. Pass a tag to scope the count,
	or omit it to count across all tags.
]=]
function TagBehaviorService.getActiveCount(self: TagBehaviorService, tag: string?): number
	local count = 0

	if tag then
		local subs = self._tagSubs[tag]
		if subs then
			for _, sub in subs do
				for _ in sub.contexts do
					count += 1
				end
			end
		end
	else
		for _, subs in self._tagSubs do
			for _, sub in subs do
				for _ in sub.contexts do
					count += 1
				end
			end
		end
	end

	return count
end

--[=[
	Calls the `update` function for every active context whose subscription
	has an update. The consumer is responsible for calling this at the
	desired frequency (e.g. from `RunService.Heartbeat`).
]=]
function TagBehaviorService.updateAll(self: TagBehaviorService, dt: number)
	for _, subs in self._tagSubs do
		for _, sub in subs do
			if sub.update then
				for instance in sub.contexts do
					local ok, err = pcall(sub.update :: any, instance, dt)
					if not ok then
						reportError("update", sub.tag, instance, tostring(err))
					end
				end
			end
		end
	end
end

--[=[
	Calls the `update` function for every active context under the given tag.
	Safe to call on tags with no update function (no-op).
]=]
function TagBehaviorService.updateTag(self: TagBehaviorService, tag: string, dt: number)
	local subs = self._tagSubs[tag]
	if not subs then
		return
	end

	for _, sub in subs do
		if sub.update then
			for instance in sub.contexts do
				local ok, err = pcall(sub.update :: any, instance, dt)
				if not ok then
					reportError("update", sub.tag, instance, tostring(err))
				end
			end
		end
	end
end

--[=[
	Returns a list of all tags that have at least one subscription.
]=]
function TagBehaviorService.getRegisteredTags(self: TagBehaviorService): { string }
	local tags: { string } = {}
	for tag in self._tagSubs do
		table.insert(tags, tag)
	end
	return tags
end

--[=[
	Returns `true` if any subscription for the given tag has an `update` function.
]=]
function TagBehaviorService.hasUpdate(self: TagBehaviorService, tag: string): boolean
	local subs = self._tagSubs[tag]
	if not subs then
		return false
	end

	for _, sub in subs do
		if sub.update then
			return true
		end
	end

	return false
end

return TagBehaviorService.new()
