local SpawnAroundPlayer = {}
local Commands = require("utility/commands")
local Logging = require("utility/logging")
local EventScheduler = require("utility/event-scheduler")
local Utils = require("utility/utils")

SpawnAroundPlayer.CreateGlobals = function()
    global.spawnAroundPlayer = global.spawnAroundPlayer or {}
    global.spawnAroundPlayer.nextId = global.spawnAroundPlayer.nextId or 0
    global.spawnAroundPlayer.randomTrees = global.spawnAroundPlayer.randomTrees or {}
end

SpawnAroundPlayer.OnLoad = function()
    Commands.Register("muppet_streamer_spawn_around_player", {"api-description.muppet_streamer_spawn_around_player"}, SpawnAroundPlayer.SpawnAroundPlayerCommand)
    EventScheduler.RegisterScheduledEventType("SpawnAroundPlayer.SpawnAroundPlayerScheduled", SpawnAroundPlayer.SpawnAroundPlayerScheduled)
end

SpawnAroundPlayer.OnStartup = function()
    SpawnAroundPlayer.PopulateRandomTrees()
end

SpawnAroundPlayer.SpawnAroundPlayerCommand = function(command)
    local errorMessageStart = "ERROR: muppet_streamer_spawn_around_player command "
    local commandData = game.json_to_table(command.parameter)
    if commandData == nil or type(commandData) ~= "table" then
        Logging.LogPrint(errorMessageStart .. "requires details in JSON format.")
        return
    end

    local delay = 0
    if commandData.delay ~= nil then
        delay = tonumber(commandData.delay)
        if delay == nil then
            Logging.LogPrint(errorMessageStart .. "delay is Optional, but must be a non-negative number if supplied")
            return
        end
        delay = math.max(delay * 60, 0)
    end

    local target = commandData.target
    if target == nil then
        Logging.LogPrint(errorMessageStart .. "target is mandatory")
        return
    elseif game.get_player(target) == nil then
        Logging.LogPrint(errorMessageStart .. "target is invalid player name")
        return
    end

    local entityName = commandData.entityName
    if entityName == nil or SpawnAroundPlayer.EntityTypeFunctions[entityName] == nil then
        Logging.LogPrint(errorMessageStart .. "entityName is mandatory and must be a supported type")
        return
    end

    local radiusMax = tonumber(commandData.radiusMax)
    if radiusMax == nil or radiusMax <= 0 then
        Logging.LogPrint(errorMessageStart .. "radiusMax is mandatory and must be a number greater than 0")
        return
    end

    local radiusMin = tonumber(commandData.radiusMin)
    if radiusMin == nil or radiusMin < 0 then
        radiusMin = 0
    end

    local existingEntities = commandData.existingEntities
    if existingEntities == nil or (existingEntities ~= "destroyOwn" and existingEntities ~= "destroyAll" and existingEntities ~= "overlap" and existingEntities ~= "avoid") then
        Logging.LogPrint(errorMessageStart .. "existingEntities is mandatory and must be a supported setting type")
        return
    end

    local quantity = tonumber(commandData.quantity)
    local density = tonumber(commandData.density)
    local ammoCount = tonumber(commandData.ammoCount)

    global.spawnAroundPlayer.nextId = global.spawnAroundPlayer.nextId + 1
    EventScheduler.ScheduleEvent(command.tick + delay, "SpawnAroundPlayer.SpawnAroundPlayerScheduled", global.spawnAroundPlayer.nextId, {target = target, entityName = entityName, radiusMax = radiusMax, radiusMin = radiusMin, existingEntities = existingEntities, quantity = quantity, density = density, ammoCount = ammoCount})
end

SpawnAroundPlayer.SpawnAroundPlayerScheduled = function(eventData)
    local errorMessageStart = "ERROR: muppet_streamer_spawn_around_player command "
    local data = eventData.data

    local targetPlayer = game.get_player(data.target)
    if targetPlayer == nil then
        Logging.LogPrint(errorMessageStart .. "target player not found at creation time: " .. data.target)
        return
    end
    local targetPos, surface = targetPlayer.position, targetPlayer.surface

    local entityTypeFunction = SpawnAroundPlayer.EntityTypeFunctions[data.entityName]

    if data.quantity ~= nil then
        local placed, targetPlaced, attempts, maxAttempts = 0, data.quantity, 0, data.quantity * 2
        while placed < targetPlaced do
            local pos = Utils.RandomLocationInRadius(targetPos, data.radiusMax, data.radiusMin)
            local entityName = entityTypeFunction.getEntityName()
            if data.existingEntities == "destroyOwn" then
                local entityBoundingBox = game.entity_prototypes[entityName].collision_box
                Utils.KillAllKillableObjectsInArea(surface, Utils.ApplyBoundingBoxToPosition(pos, entityBoundingBox), nil, true, targetPlayer.force)
            elseif data.existingEntities == "destroyAll" then
                local entityBoundingBox = game.entity_prototypes[entityName].collision_box
                Utils.KillAllKillableObjectsInArea(surface, Utils.ApplyBoundingBoxToPosition(pos, entityBoundingBox), nil, true)
            end
            if data.existingEntities == "avoid" or data.existingEntities == "destroyOwn" or data.existingEntities == "destroyAll" then
                pos = entityTypeFunction.searchPlacement(surface, entityName, pos)
            end
            if pos ~= nil then
                entityTypeFunction.placeEntity(surface, entityName, pos, targetPlayer.force, data.ammoCount)
                placed = placed + 1
            end
            attempts = attempts + 1
            if attempts >= maxAttempts then
                break
            end
        end
    elseif data.density ~= nil then
    --TODO do the creation logic from the settings
    end
end

SpawnAroundPlayer.EntityTypeFunctions = {
    tree = {
        getEntityName = function(surface, position)
            if remote.interfaces["biter_reincarnation"] == nil then
                return global.spawnAroundPlayer.randomTrees[math.random(#global.spawnAroundPlayer.randomTrees)]
            else
                return remote.call("biter_reincarnation", "get_random_tree_type_for_position", surface, position)
            end
        end,
        searchPlacement = function(surface, entityName, position)
            return surface.find_non_colliding_position(entityName, position, 3, 0.2)
        end,
        placeEntity = function(surface, entityName, position, force)
            surface.create_entity {name = entityName, position = position, force = force}
        end
    },
    rock = {
        getEntityName = function()
            local random = math.random()
            if random < 0.2 then
                return "rock-huge"
            elseif random < 0.6 then
                return "rock-big"
            else
                return "sand-rock-big"
            end
        end,
        searchPlacement = function(surface, entityName, position)
            return surface.find_non_colliding_position(entityName, position, 3, 0.2)
        end,
        placeEntity = function(surface, entityName, position)
            surface.create_entity {name = entityName, position = position, force = "neutral"}
        end
    },
    laserTurret = {
        getEntityName = function()
            return "laser-turret"
        end,
        searchPlacement = function(surface, entityName, position)
            return surface.find_non_colliding_position(entityName, position, 3, 1)
        end,
        placeEntity = function(surface, entityName, position, force)
            surface.create_entity {name = entityName, position = position, force = force}
        end
    },
    gunTurretRegularAmmo = {
        getEntityName = function()
            return "gun-turret"
        end,
        searchPlacement = function(surface, entityName, position)
            return surface.find_non_colliding_position(entityName, position, 3, 1)
        end,
        placeEntity = function(surface, entityName, position, force, ammoCount)
            local turret = surface.create_entity {name = entityName, position = position, force = force}
            if turret ~= nil then
                turret.insert("firearm-magazine", ammoCount)
            end
        end
    },
    gunTurretPiercingAmmo = {
        getEntityName = function()
            return "gun-turret"
        end,
        searchPlacement = function(surface, entityName, position)
            return surface.find_non_colliding_position(entityName, position, 3, 1)
        end,
        placeEntity = function(surface, entityName, position, force, ammoCount)
            local turret = surface.create_entity {name = entityName, position = position, force = force}
            if turret ~= nil then
                turret.insert("piercing-rounds-magazine", ammoCount)
            end
        end
    },
    gunTurretUraniumAmmo = {
        getEntityName = function()
            return "gun-turret"
        end,
        searchPlacement = function(surface, entityName, position)
            return surface.find_non_colliding_position(entityName, position, 3, 1)
        end,
        placeEntity = function(surface, entityName, position, force, ammoCount)
            local turret = surface.create_entity {name = entityName, position = position, force = force}
            if turret ~= nil then
                turret.insert("uranium-rounds-magazine", ammoCount)
            end
        end
    },
    fire = {
        getEntityName = function()
            return "fire-flame"
        end,
        searchPlacement = function(surface, entityName, position)
            return surface.find_non_colliding_position(entityName, position, 3, 0.2)
        end,
        placeEntity = function(surface, entityName, position, _, ammoCount)
            surface.create_entity {name = entityName, position = position, force = "neutral", initial_ground_flame_count = ammoCount}
        end
    },
    defenderCapsule = {
        getEntityName = function()
            return "defender-capsule"
        end,
        searchPlacement = function(surface, entityName, position)
            return surface.find_non_colliding_position(entityName, position, 3, 0.2)
        end,
        placeEntity = function(surface, entityName, position, force)
            surface.create_entity {name = entityName, position = position, force = force}
        end
    },
    distractorCapsule = {
        getEntityName = function()
            return "distractor-capsule"
        end,
        searchPlacement = function(surface, entityName, position)
            return surface.find_non_colliding_position(entityName, position, 3, 0.2)
        end,
        placeEntity = function(surface, entityName, position, force)
            surface.create_entity {name = entityName, position = position, force = force}
        end
    },
    destroyedCapsule = {
        getEntityName = function()
            return "destroyer-capsule"
        end,
        searchPlacement = function(surface, entityName, position)
            return surface.find_non_colliding_position(entityName, position, 3, 0.2)
        end,
        placeEntity = function(surface, entityName, position, force)
            surface.create_entity {name = entityName, position = position, force = force}
        end
    }
}

SpawnAroundPlayer.PopulateRandomTrees = function()
    global.spawnAroundPlayer.randomTrees = {}
    for treeName in pairs(game.get_filtered_entity_prototypes({{filter = "type", type = "tree"}})) do
        table.insert(global.spawnAroundPlayer.randomTrees, treeName)
    end
end

return SpawnAroundPlayer
