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

export type SubscribeOptions = {
	className: string?,
	predicate: ((instance: Instance) -> boolean)?,
	defer: boolean?,
}

export type ContextInfo = {
	active: boolean,
}

-- Internal types

type ErrorPhase = "factory" | "cleanup" | "predicate"

type ContextState = "pending" | "active"

type Context = {
	cleanup: (() -> ())?,
	destroyingConn: RBXScriptConnection?,
	state: ContextState,
}

type Subscription = {
	tag: string,
	factory: (instance: Instance) -> (() -> ())?,
	options: SubscribeOptions,
	contexts: { [Instance]: Context },
	addedConn: RBXScriptConnection?,
	removedConn: RBXScriptConnection?,
}

-- Internal helper functions

local function reportError(phase: ErrorPhase, tag: string, instance: Instance, err: string)
	warn(`[TagBehaviorService] {phase} error for tag "{tag}" on {instance:GetFullName()}: {err}`)
end

local function passesFilters(sub: Subscription, instance: Instance): boolean
	local className = sub.options.className
	if className ~= nil and not instance:IsA(className) then
		return false
	end

	local predicate = sub.options.predicate
	if predicate ~= nil then
		local ok, result = pcall(predicate, instance)
		if not ok then
			reportError("predicate", sub.tag, instance, tostring(result))
			return false
		end
		if not result then
			return false
		end
	end

	return true
end

local function runFactory(sub: Subscription, instance: Instance, context: Context)
	local ok, result = pcall(sub.factory, instance)

	-- Context may have been removed during factory execution (reentrant unsubscribe)
	if sub.contexts[instance] ~= context then
		return
	end

	if not ok then
		reportError("factory", sub.tag, instance, tostring(result))
		context.state = "active"
		return
	end

	if result ~= nil and type(result) ~= "function" then
		reportError(
			"factory",
			sub.tag,
			instance,
			`Factory must return nil or a cleanup function, got {type(result)}`
		)
		context.state = "active"
		return
	end

	context.cleanup = result :: (() -> ())?
	context.state = "active"
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

	if context.state == "active" then
		local cleanup = context.cleanup
		if cleanup ~= nil then
			local ok, err = pcall(cleanup)
			if not ok then
				reportError("cleanup", sub.tag, instance, tostring(err))
			end
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

	-- Collect instances before iterating to avoid modifying the table during iteration
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

-- Private methods (need self for instance state)

function TagBehaviorService._attachInstance(
	self: TagBehaviorService,
	sub: Subscription,
	instance: Instance
)
	if sub.contexts[instance] then
		return
	end

	if not passesFilters(sub, instance) then
		return
	end

	local context: Context = {
		cleanup = nil,
		destroyingConn = nil,
		state = if sub.options.defer then "pending" else "active" :: ContextState,
	}
	sub.contexts[instance] = context

	context.destroyingConn = instance.Destroying:Connect(function()
		cleanupContext(sub, instance)
	end)

	if sub.options.defer then
		task.defer(function()
			if sub.contexts[instance] ~= context then
				return
			end
			if context.state ~= "pending" then
				return
			end
			if not self._started then
				return
			end
			runFactory(sub, instance, context)
		end)
	else
		runFactory(sub, instance, context)
	end
end

function TagBehaviorService._activateSubscription(self: TagBehaviorService, sub: Subscription)
	sub.addedConn = CollectionService:GetInstanceAddedSignal(sub.tag):Connect(function(instance)
		if self._started then
			self:_attachInstance(sub, instance)
		end
	end)

	sub.removedConn = CollectionService:GetInstanceRemovedSignal(sub.tag):Connect(function(instance)
		cleanupContext(sub, instance)
	end)

	for _, instance in CollectionService:GetTagged(sub.tag) do
		self:_attachInstance(sub, instance)
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
	Subscribes a tag to a factory callback. When the service is started,
	every current and future instance with the given tag will have the
	factory invoked. The factory may return an optional cleanup function
	that runs when the tag is removed, the instance is destroyed, or the
	subscription is cancelled.

	Returns an idempotent unsubscribe function.
]=]
function TagBehaviorService.subscribe(
	self: TagBehaviorService,
	tag: string,
	factory: (instance: Instance) -> (() -> ())?,
	opts: SubscribeOptions?
): () -> ()
	assert(type(tag) == "string" and #tag > 0, "Tag must be a non-empty string")
	assert(type(factory) == "function", "Factory must be a function")

	local sub: Subscription = {
		tag = tag,
		factory = factory,
		options = if opts then opts else {} :: SubscribeOptions,
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
	Returns whether the service is currently started.
]=]
function TagBehaviorService.isStarted(self: TagBehaviorService): boolean
	return self._started
end

--[=[
	Returns introspection info for the first subscription matching the
	given `(tag, instance)` pair, or nil if no binding exists.
]=]
function TagBehaviorService.getContext(
	self: TagBehaviorService,
	tag: string,
	instance: Instance
): ContextInfo?
	local subs = self._tagSubs[tag]
	if not subs then
		return nil
	end

	for _, sub in subs do
		local context = sub.contexts[instance]
		if context then
			return {
				active = context.state == "active",
			}
		end
	end

	return nil
end

--[=[
	Returns `true` if there is an active (non-pending) binding for the
	given `(tag, instance)` pair.
]=]
function TagBehaviorService.isActive(self: TagBehaviorService, tag: string, instance: Instance): boolean
	local subs = self._tagSubs[tag]
	if not subs then
		return false
	end

	for _, sub in subs do
		local context = sub.contexts[instance]
		if context and context.state == "active" then
			return true
		end
	end

	return false
end

--[=[
	Returns the number of active (non-pending) bindings. Pass a tag to
	scope the count, or omit it to count across all tags.
]=]
function TagBehaviorService.getActiveCount(self: TagBehaviorService, tag: string?): number
	local count = 0

	if tag then
		local subs = self._tagSubs[tag]
		if subs then
			for _, sub in subs do
				for _, context in sub.contexts do
					if context.state == "active" then
						count += 1
					end
				end
			end
		end
	else
		for _, subs in self._tagSubs do
			for _, sub in subs do
				for _, context in sub.contexts do
					if context.state == "active" then
						count += 1
					end
				end
			end
		end
	end

	return count
end

return TagBehaviorService.new()
