# TagBehaviorService

A lightweight, standalone lifecycle manager for [CollectionService](https://create.roblox.com/docs/reference/engine/classes/CollectionService)-tagged instances in Roblox.

Subscribe a tag to a factory callback. The factory runs once per tagged instance and may return a cleanup function. When the tag is removed or the instance is destroyed, cleanup runs automatically.

```luau
local TagBehaviorService = require(path.to.TagBehaviorService)

TagBehaviorService:subscribe("Lava", function(part)
    local conn = part.Touched:Connect(function(hit)
        local hum = hit.Parent and hit.Parent:FindFirstChildOfClass("Humanoid")
        if hum then
            hum:TakeDamage(10)
        end
    end)
    return function()
        conn:Disconnect()
    end
end)

TagBehaviorService:start()
```

## Installation

### pesde

```sh
pesde add gh#daireb/tagbehaviorservice#v0.5.0
```

### Manual

Drop `src/init.luau` into your project and `require` it.

## Quickstart

```luau
local TagBehaviorService = require(game.ReplicatedStorage.Packages.TagBehaviorService)

-- Register behaviors before starting
TagBehaviorService:subscribe("Glowing", {
    factory = function(part)
        local light = Instance.new("PointLight")
        light.Parent = part

        return function()
            light:Destroy()
        end
    end,
    filter = function(instance)
        return instance:IsA("BasePart")
    end,
})

-- Start listening for tagged instances
TagBehaviorService:start()
```

Or use `registerFolder` to auto-register a folder of behavior modules:

```luau
local TagBehaviorService = require(game.ReplicatedStorage.Packages.TagBehaviorService)

TagBehaviorService:registerFolder(script.Behaviors)
TagBehaviorService:start()
```

Where each ModuleScript in `Behaviors/` returns a factory (tag = module name):

```luau
-- Behaviors/Glowing.luau
return function(part)
    local light = Instance.new("PointLight")
    light.Parent = part
    return function()
        light:Destroy()
    end
end
```

Or a table for a custom tag name, filter, or update function:

```luau
-- Behaviors/Glowing.luau
return {
    filter = function(instance)
        return instance:IsA("BasePart")
    end,
    factory = function(part)
        local light = Instance.new("PointLight")
        light.Parent = part
        return function()
            light:Destroy()
        end
    end,
}
```

Behaviors can also define an `update` function for per-frame logic:

```luau
-- Behaviors/Spinner.luau
return {
    update = function(part, dt)
        part.CFrame *= CFrame.Angles(0, math.rad(90) * dt, 0)
    end,
}
```

Wire up updates by calling `updateAll` from your game loop:

```luau
local RunService = game:GetService("RunService")
RunService.Heartbeat:Connect(function(dt)
    TagBehaviorService:updateAll(dt)
end)
```

## API Reference

### `:subscribe(tag, config?) -> unsubscribeFn`

Registers a behavior for the given tag.

The second argument can be:
- A **function** — treated as the factory (shorthand for simple behaviors)
- A **table** `{ factory?, filter?, update? }` — for complex behaviors
- **nil** — warns about an empty subscription

| Table Field | Type | Description |
|-------------|------|-------------|
| `factory` | `((Instance) -> (() -> ())?)?` | Called once per matching instance; may return a cleanup function |
| `filter` | `((Instance) -> boolean)?` | Optional instance filter; errors are caught and warned |
| `update` | `((Instance, dt: number) -> ())?` | Optional per-frame callback; called with `dt=0` on attach, then via `updateAll`/`updateTag` |

**Returns** an idempotent `() -> ()` unsubscribe function. Calling it tears down all active contexts for this subscription and disconnects signals.

---

### `:registerFolder(folder, moduleFilter?) -> unsubscribeAllFn`

Requires every descendant `ModuleScript` in `folder` and subscribes each one.

An optional `moduleFilter` receives each `ModuleScript` before it is required and returns a boolean. Modules that fail the filter are skipped entirely (not even required):

```luau
TBS:registerFolder(script.Behaviors, function(module)
    return module:GetAttribute("RunContext") == "Server"
end)
```

Each module should return either a **factory function** (tag defaults to `ModuleScript.Name`) or a **`BehaviorDefinition` table**:

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `tag` | `string?` | Module name | Override the tag name |
| `factory` | `((Instance) -> (() -> ())?)?` | `nil` | The behavior factory |
| `filter` | `((Instance) -> boolean)?` | `nil` | Optional instance filter |
| `update` | `((Instance, dt: number) -> ())?` | `nil` | Optional per-frame callback |

**Returns** an idempotent function that unsubscribes all behaviors from this folder.

Modules that fail to require or return unexpected types are warned and skipped.

---

### `:start()`

Activates the service. Connects CollectionService signals for every subscription and performs an initial scan of already-tagged instances. Idempotent.

---

### `:isStarted() -> boolean`

Returns `true` if the service is currently started.

---

### `:isActive(tag, instance) -> boolean`

Returns `true` if there is a binding for the given `(tag, instance)` pair.

---

### `:getActiveCount(tag?) -> number`

Returns the number of active bindings. Pass a tag to scope the count, or omit it to count across all tags.

---

### `:updateAll(dt)`

Calls the `update` function for every active context whose subscription has one. The consumer controls when and how often to call this.

```luau
RunService.Heartbeat:Connect(function(dt)
    TagBehaviorService:updateAll(dt)
end)
```

---

### `:updateTag(tag, dt)`

Like `updateAll`, but scoped to a single tag. Safe to call on tags with no update function (no-op). Useful for custom scheduling where different tags update at different rates or in a specific order.

---

### `:getRegisteredTags() -> { string }`

Returns a list of all tags that have at least one subscription. Useful for introspection, debugging, or building custom update schedules.

---

### `:hasUpdate(tag) -> boolean`

Returns `true` if any subscription for the given tag has an `update` function. Useful for filtering debug UIs or scheduler displays to only show updateable behaviors.

## Lifecycle Semantics

```
subscribe(tag, { factory?, filter?, update? })
        |
    start()
        |
        v
  +----- GetTagged(tag) scan -----+
  |                                |
  |   GetInstanceAddedSignal(tag) fires
  |                |
  v                v
  filter? ---false--> skip
        |
       true
        |
  factory?(instance) --> cleanup?
        |
  update?(instance, 0)    <-- initial update on attach
        |
  +-----+----------+-----------------+
  |                 |                 |
  tag removed    Destroying       unsubscribe
  |                 |                 |
  v                 v                 v
  cleanup() (at-most-once, pcall-wrapped)
  context removed

  updateAll(dt) / updateTag(tag, dt)
        |
        v
  for each active context with update:
        update(instance, dt)
```

### Key guarantees

- **Exactly one context per (tag, instance)** — duplicate add signals are idempotent.
- **At-most-once cleanup** — once cleanup runs (or the context is removed), it will never run again for that activation.
- **Error isolation** — a throwing factory, cleanup, or filter is caught with `pcall` and logged via `warn`. Other subscriptions and instances are unaffected.
- **Destroy safety** — if an instance is destroyed without an explicit untag, the `Destroying` event triggers cleanup.
- **Idempotent calls** — `start` and unsubscribe functions are safe to call multiple times.

## Guarantees and Non-Goals

### Guarantees

- Zero external dependencies.
- Works with deferred and immediate signal modes.
- Factory return type is validated at runtime.
- Singleton by default; `.new()` is available via the metatable for test isolation or multi-scope use.

### Non-goals

- **Not a replacement for ECS / state systems.** TagBehaviorService is best for instance-centric concerns: visual helpers, proximity prompts, map props, debug overlays. Authoritative gameplay state should live in dedicated state management.
- **No built-in retry.** If a factory errors, the instance is still tracked to prevent retry loops. Remove and re-add the tag to retry.
- **No ordering guarantees between subscriptions.** If two subscriptions target the same tag, their factory execution order is not guaranteed.
- **No built-in scheduling.** `updateAll` and `updateTag` are pull-based — the consumer decides when and how often to call them. Use `RunService.Heartbeat`, a custom scheduler, or any other driver.

## When to Use

| Use Case | Recommended |
|----------|-------------|
| Attach PointLight to every "Glowing" part | TagBehaviorService |
| Show ProximityPrompt on "Interactable" models | TagBehaviorService |
| Play particle effect on "OnFire" parts | TagBehaviorService |
| Debug collision boxes for "ShowHitbox" | TagBehaviorService |
| Track player health, XP, inventory | ECS / state system |
| Authoritative combat damage | ECS / state system |
| Physics simulation state | ECS / state system |

## Examples

### Simple BasePart behavior

```luau
TagBehaviorService:subscribe("Bouncy", {
    factory = function(part)
        local original = part.CustomPhysicalProperties

        part.CustomPhysicalProperties = PhysicalProperties.new(
            0.7,  -- density
            0.3,  -- friction
            1.0,  -- elasticity
            1.0,  -- friction weight
            1.0   -- elasticity weight
        )

        return function()
            part.CustomPhysicalProperties = original
        end
    end,
    filter = function(instance)
        return instance:IsA("BasePart")
    end,
})
```

### Behavior with attribute check

```luau
TagBehaviorService:subscribe("NPC", {
    factory = function(model)
        local billboard = Instance.new("BillboardGui")
        billboard.Size = UDim2.fromOffset(100, 40)
        billboard.Adornee = model:FindFirstChild("Head")
        billboard.Parent = model

        local label = Instance.new("TextLabel")
        label.Size = UDim2.fromScale(1, 1)
        label.BackgroundTransparency = 1
        label.Text = model.Name
        label.TextColor3 = Color3.new(1, 1, 1)
        label.Parent = billboard

        return function()
            billboard:Destroy()
        end
    end,
    filter = function(model)
        return model:IsA("Model") and model:FindFirstChild("Head") ~= nil
    end,
})
```

### Behavior with per-frame update

```luau
local states = {}

TagBehaviorService:subscribe("Spinner", {
    factory = function(part)
        states[part] = { angle = 0 }
        return function()
            states[part] = nil
        end
    end,
    filter = function(instance)
        return instance:IsA("BasePart")
    end,
    update = function(part, dt)
        local state = states[part]
        state.angle += math.rad(90) * dt
        part.CFrame = CFrame.new(part.Position) * CFrame.Angles(0, state.angle, 0)
    end,
})

-- Drive updates from Heartbeat
local RunService = game:GetService("RunService")
RunService.Heartbeat:Connect(function(dt)
    TagBehaviorService:updateAll(dt)
end)
```

### Behavior using Janitor internally (without depending on Janitor)

```luau
local Janitor = require(path.to.Janitor)

TagBehaviorService:subscribe("InteractableChest", {
    factory = function(chest)
        local janitor = Janitor.new()

        local prompt = janitor:Add(Instance.new("ProximityPrompt"))
        prompt.ActionText = "Open"
        prompt.Parent = chest

        janitor:Add(prompt.Triggered:Connect(function(player)
            print(player.Name, "opened", chest.Name)
        end))

        return function()
            janitor:Destroy()
        end
    end,
    filter = function(instance)
        return instance:IsA("Model")
    end,
})
```

## Testing

The test suite lives in `tests/init.server.luau` and runs inside a Roblox DataModel via Rojo. Each test creates a fresh instance via `.new()` for isolation. It covers:

- Initial tagged-instance scan attach
- Runtime tag-add attach
- Tag-removal cleanup
- Destroyed-instance cleanup
- Duplicate signal idempotency
- Re-attach after remove + re-add
- Unsubscribe behaviour and idempotency
- Error isolation (factory, cleanup, filter)
- Filter filtering (by class, by name)
- `getActiveCount` and introspection helpers
- At-most-once cleanup guarantee
- Factory return-type validation
- Multiple subscriptions per tag
- Update on attach (dt=0), `updateAll`, and `updateTag`
- Update error isolation
- Update not called for filter-excluded or unsubscribed instances
- `getRegisteredTags` and `hasUpdate` introspection
- Subscribe with function shorthand and table config
- `registerFolder` module filter

## License

MIT
