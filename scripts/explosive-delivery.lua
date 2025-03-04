local ExplosiveDelivery = {}
local Commands = require("utility/commands")
local Logging = require("utility/logging")
local EventScheduler = require("utility/event-scheduler")
local Utils = require("utility/utils")

ExplosiveDelivery.CreateGlobals = function()
    global.explosiveDelivery = global.explosiveDelivery or {}
    global.explosiveDelivery.nextId = global.explosiveDelivery.nextId or 0
    global.explosiveDelivery.nextSalvoWaveId = global.explosiveDelivery.nextSalvoWaveId or 0
    global.explosiveDelivery.salvoWaveTargetPositions = global.explosiveDelivery.salvoWaveTargetPositions or {}
end

ExplosiveDelivery.OnLoad = function()
    Commands.Register("muppet_streamer_schedule_explosive_delivery", {"api-description.muppet_streamer_schedule_explosive_delivery"}, ExplosiveDelivery.ScheduleExplosiveDeliveryCommand, true)
    EventScheduler.RegisterScheduledEventType("ExplosiveDelivery.DeliverExplosives", ExplosiveDelivery.DeliverExplosives)
end

ExplosiveDelivery.ScheduleExplosiveDeliveryCommand = function(command)
    local errorMessageStart = "ERROR: muppet_streamer_schedule_explosive_delivery command "
    local commandData
    if command.parameter ~= nil then
        commandData = game.json_to_table(command.parameter)
    end
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

    local explosiveCount = tonumber(commandData.explosiveCount)
    if explosiveCount == nil then
        Logging.LogPrint(errorMessageStart .. "explosiveCount is mandatory as a number")
        return
    elseif explosiveCount <= 0 then
        return
    end

    local explosiveType = ExplosiveDelivery.ExplosiveTypes[commandData.explosiveType]
    if explosiveType == nil then
        Logging.LogPrint(errorMessageStart .. "explosiveType is mandatory and must be a supported type")
        return
    end

    local target = commandData.target
    if target == nil then
        Logging.LogPrint(errorMessageStart .. "target is mandatory")
        return
    elseif game.get_player(target) == nil then
        Logging.LogPrint(errorMessageStart .. "target is invalid player name")
        return
    end

    local targetPosition = commandData.targetPosition
    if targetPosition ~= nil then
        targetPosition = Utils.TableToProperPosition(targetPosition)
        if targetPosition == nil then
            Logging.LogPrint(errorMessageStart .. "targetPosition is Optional, but if provided must be a valid position table string")
            return
        end
    end

    local accuracyRadiusMin = 0
    if commandData.accuracyRadiusMin ~= nil then
        accuracyRadiusMin = tonumber(commandData.accuracyRadiusMin)
        if accuracyRadiusMin == nil or accuracyRadiusMin < 0 then
            Logging.LogPrint(errorMessageStart .. "accuracyRadiusMin is Optional, but must be a non-negative number if supplied")
            return
        end
    end

    local accuracyRadiusMax = 0
    if commandData.accuracyRadiusMax ~= nil then
        accuracyRadiusMax = tonumber(commandData.accuracyRadiusMax)
        if accuracyRadiusMax == nil or accuracyRadiusMax < 0 then
            Logging.LogPrint(errorMessageStart .. "accuracyRadiusMax is Optional, but must be a non-negative number if supplied")
            return
        end
    end

    local salvoSize = explosiveCount
    if commandData.salvoSize ~= nil then
        salvoSize = tonumber(commandData.salvoSize)
        if salvoSize == nil or salvoSize < 0 then
            Logging.LogPrint(errorMessageStart .. "salvoSize is Optional, but must be a non-negative number if supplied")
            return
        end
    end

    local salvoDelay = 0
    if commandData.salvoDelay ~= nil then
        salvoDelay = tonumber(commandData.salvoDelay)
        if salvoDelay == nil or salvoDelay < 0 then
            Logging.LogPrint(errorMessageStart .. "salvoDelay is Optional, but must be a non-negative number if supplied")
            return
        end
    end

    -- If this is a multi salvo wave we need to cache the target position from the first delivery for the subsequent deliveryies of that wave. So setup the salvoWaveId for later population.
    local maxBatchNumber = 0 -- Batch 0 is the first batch.
    local salvoWaveId
    if explosiveCount > salvoSize then
        global.explosiveDelivery.nextSalvoWaveId = global.explosiveDelivery.nextSalvoWaveId + 1
        salvoWaveId = global.explosiveDelivery.nextSalvoWaveId
        maxBatchNumber = math.ceil(explosiveCount / salvoSize) - 1
    end

    local explosiveCountRemaining = explosiveCount
    for batchNumber = 0, maxBatchNumber do
        explosiveCount = math.min(salvoSize, explosiveCountRemaining)
        explosiveCountRemaining = explosiveCountRemaining - explosiveCount

        global.explosiveDelivery.nextId = global.explosiveDelivery.nextId + 1
        EventScheduler.ScheduleEvent(
            command.tick + delay + (batchNumber * salvoDelay),
            "ExplosiveDelivery.DeliverExplosives",
            global.explosiveDelivery.nextId,
            {
                explosiveCount = explosiveCount,
                explosiveType = explosiveType,
                accuracyRadiusMin = accuracyRadiusMin,
                accuracyRadiusMax = accuracyRadiusMax,
                target = target,
                targetPosition = targetPosition,
                salvoWaveId = salvoWaveId,
                finalSalvo = batchNumber == maxBatchNumber
            }
        )
    end
end

ExplosiveDelivery.DeliverExplosives = function(eventData)
    local data = eventData.data

    local targetPlayer = game.get_player(data.target)
    if targetPlayer == nil then
        Logging.LogPrint("ERROR: muppet_streamer_schedule_explosive_delivery command target player not found at delivery time: " .. data.target)
        return
    end

    local targetPos
    -- Check if we need to obtain a target position from the salvo wave rather than calculate it now.
    if data.salvoWaveId ~= nil and global.explosiveDelivery.salvoWaveTargetPositions[data.salvoWaveId] ~= nil then
        targetPos = global.explosiveDelivery.salvoWaveTargetPositions[data.salvoWaveId]
        if data.finalSalvo then
            global.explosiveDelivery.salvoWaveTargetPositions[data.salvoWaveId] = nil
        end
    else
        -- Calculate the target position now.
        if data.targetPosition ~= nil then
            targetPos = data.targetPosition
        else
            targetPos = targetPlayer.position
        end
        if data.salvoWaveId ~= nil then
            -- Cache the salvo wave target position for the rest of the salvo wave.
            global.explosiveDelivery.salvoWaveTargetPositions[data.salvoWaveId] = targetPos
        end
    end

    local surface, explosiveType = targetPlayer.surface, data.explosiveType
    for i = 1, data.explosiveCount do
        -- The explosives have to be fired at something, so we make a temporary dummy target entity at the desired explosion position.
        local targetEntityPos = Utils.RandomLocationInRadius(targetPos, data.accuracyRadiusMax, data.accuracyRadiusMin)
        local targetEntity = surface.create_entity {name = "muppet_streamer-explosive-delivery-target", position = targetEntityPos}

        -- Spawn the explosives off the players screen (non map view). Have to allow enough distance for explosives crossing players screen, i.e. the targetPos being NW of the player and the explosives spawn SE of the player, they need to be far away enough away to spawn off the player's screen before flying over their head.
        local explosiveCreateDistance = math.max(100, data.accuracyRadiusMax * 2)
        local explosiveCreatePos = Utils.RandomLocationInRadius(targetPos, explosiveCreateDistance, explosiveCreateDistance)

        if explosiveType.projectileName ~= nil then
            surface.create_entity {name = explosiveType.projectileName, position = explosiveCreatePos, target = targetEntity, speed = explosiveType.speed}
        elseif explosiveType.beamName ~= nil then
            surface.create_entity {name = explosiveType.beamName, position = explosiveCreatePos, target = targetEntity, source_position = explosiveCreatePos}
        end

        -- Remove the temporary dummy target entity.
        targetEntity.destroy()
    end
end

ExplosiveDelivery.ExplosiveTypes = {
    grenade = {
        projectileName = "grenade",
        speed = 0.3
    },
    clusterGrenade = {
        projectileName = "cluster-grenade",
        speed = 0.3
    },
    slowdownCapsule = {
        projectileName = "slowdown-capsule",
        speed = 0.3
    },
    poisonCapsule = {
        projectileName = "poison-capsule",
        speed = 0.3
    },
    artilleryShell = {
        projectileName = "artillery-projectile",
        speed = 1
    },
    explosiveRocket = {
        projectileName = "explosive-rocket",
        speed = 0.3
    },
    atomicRocket = {
        projectileName = "atomic-rocket",
        speed = 0.3
    },
    smallSpit = {
        beamName = "acid-stream-spitter-small",
        speed = 0.3
    },
    mediumSpit = {
        beamName = "acid-stream-worm-medium",
        speed = 0.3
    },
    largeSpit = {
        beamName = "acid-stream-worm-behemoth",
        speed = 0.3
    }
}

return ExplosiveDelivery
