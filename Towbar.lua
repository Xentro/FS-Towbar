--
-- Towbar
--
-- Author:  Xentro
-- Website: https://xentro.se, https://github.com/Xentro
--
-- This is an rewrite of the "Puller" script which was written by the following authors 
-- Peppe978, TyKonKet
-- 

Towbar = {
    MOD_NAME = g_currentModName,
}

function Towbar.prerequisitesPresent(specializations)
	return true
end

function Towbar.initSpecialization()
    local schema         = Vehicle.xmlSchema
    local schemaSavegame = Vehicle.xmlSchemaSavegame

    schema:setXMLSpecializationType("Towbar")
    schema:register(XMLValueType.NODE_INDEX, "vehicle.towbar#node",                    "towbar joint node")
    schema:register(XMLValueType.NODE_INDEX, "vehicle.towbar#rootNode",                "rootNode used to create towbar joint")
    schema:register(XMLValueType.FLOAT,      "vehicle.towbar#attachDistance",          "Attach distance to towbar vehicle")
    schema:register(XMLValueType.BOOL,       "vehicle.towbar#isGrabbable",             "Allow attach to towbar")
    schema:register(XMLValueType.BOOL,       "vehicle.towbar#isGrabbableOnlyIfDetach", "Allow attach to towbar only if not attached to something")
    schema:register(XMLValueType.BOOL,       "vehicle.towbar#matchParentVehicle",      "Match brake and motor to parent vehicle")
    schema:register(XMLValueType.STRING,     "vehicle.towbar#inputName",               "Input name", "IMPLEMENT_EXTRA2")

    schemaSavegame:register(XMLValueType.INT, "vehicles.vehicle(?).towbar#vehicleId",  "Vehicle id of attached vehicle")
    schemaSavegame:register(XMLValueType.INT, "vehicles.vehicle(?).towbar#jointIndex", "Index of attacher joint")
end

function Towbar.registerFunctions(vehicleType)
    SpecializationUtil.registerFunction(vehicleType, "setTowbarVehicle", Towbar.setTowbarVehicle)
    SpecializationUtil.registerFunction(vehicleType, "allowTowbar", Towbar.allowTowbar)
end

function Towbar.registerEventListeners(vehicleType)
	SpecializationUtil.registerEventListener(vehicleType, "onLoad", Towbar)
	SpecializationUtil.registerEventListener(vehicleType, "onPostLoad", Towbar)
	SpecializationUtil.registerEventListener(vehicleType, "onDelete", Towbar)
	SpecializationUtil.registerEventListener(vehicleType, "onReadStream", Towbar)
	SpecializationUtil.registerEventListener(vehicleType, "onWriteStream", Towbar)
	SpecializationUtil.registerEventListener(vehicleType, "onUpdateTick", Towbar)
	SpecializationUtil.registerEventListener(vehicleType, "onRegisterActionEvents", Towbar)
end

function Towbar:onLoad(vehicle)
    self.spec_towbar = self["spec_" .. Towbar.MOD_NAME .. ".towbar"]
    local spec = self.spec_towbar
    
    spec.attachNode              = self.xmlFile:getValue("vehicle.towbar#node", nil, self.components, self.i3dMappings)
    spec.attachRootNode          = self.xmlFile:getValue("vehicle.towbar#rootNode", "0>", self.components, self.i3dMappings)
    spec.attachDistance          = self.xmlFile:getValue("vehicle.towbar#attachDistance", 1.5)
    spec.isGrabbable             = self.xmlFile:getValue("vehicle.towbar#isGrabbable", true)
    spec.isGrabbableOnlyIfDetach = self.xmlFile:getValue("vehicle.towbar#isGrabbableOnlyIfDetach", true)
    spec.matchParentVehicle      = self.xmlFile:getValue("vehicle.towbar#matchParentVehicle", false)
    local inputName              = self.xmlFile:getValue("vehicle.towbar#inputName")

    if inputName ~= nil then
        spec.attachButton = InputAction[inputName]
    end

    spec.attachButton = Utils.getNoNil(spec.attachButton, InputAction.IMPLEMENT_EXTRA2)

    spec.isAttached = false
    spec.attachedVehicleJoint = {}
    spec.vehicleInRange = nil
    spec.lastVehicleInRangeUpdate = nil

    assert(spec.attachNode ~= nil, "Towbar: Couldn't find an valid node for vehicle.towbar.node")
end

function Towbar:onPostLoad(savegame)
    local spec = self.spec_towbar

    if savegame ~= nil and not savegame.resetVehicles then
        local vehicleId = savegame.xmlFile:getValue(savegame.key .. ".towbar#vehicleId")
        local jointIndex = savegame.xmlFile:getValue(savegame.key .. ".towbar#jointIndex")

        if vehicleId ~= nil and jointIndex ~= nil then
            spec.attachOnLoad = {
                vehicleId = vehicleId,
                index = jointIndex
            }
        end
    end
end

function Towbar:onDelete()
    local spec = self.spec_towbar

    if spec.isAttached then
        self:setTowbarVehicle(Towbar.STATE_DETACH, nil, nil, true)
    end
end

function Towbar:saveToXMLFile(xmlFile, key, usedModNames)
    local spec = self.spec_towbar
    local avj = spec.attachedVehicleJoint
    local keyUpdate = key:gsub("." .. Towbar.MOD_NAME, "") -- I do not want the mod name...

    if spec.isAttached ~= nil and avj ~= nil and avj.vehicle ~= nil then
        xmlFile:setValue(keyUpdate .. "#vehicleId",  avj.vehicle.currentSavegameId)
        xmlFile:setValue(keyUpdate .. "#jointIndex", avj.attacherJointIndex)
    end
end

function Towbar:onReadStream(streamId, connection)
    local spec = self.spec_towbar

    if streamReadBool(streamId) then
        local vehicle = NetworkUtil.readNodeObject(streamId)
        local index = streamReadInt8(streamId)

        if vehicle ~= nil and vehicle:getIsSynchronized() then
            self:setTowbarVehicle(Towbar.STATE_ATTACH, vehicle, index, true)
        end
    end
end

function Towbar:onWriteStream(streamId, connection)
    local spec = self.spec_towbar

    streamWriteBool(streamId, spec.isAttached)

    if spec.isAttached then
        NetworkUtil.writeNodeObject(streamId, spec.attachedVehicleJoint.vehicle)
        streamWriteInt8(streamId, spec.attachedVehicleJoint.attacherJointIndex)
    end
end

function Towbar:onUpdateTick(dt, isActiveForInput, isActiveForInputIgnoreSelection, isSelected)
    local spec = self.spec_towbar

    if spec.attachOnLoad ~= nil then
        local vehicle = g_currentMission.savegameIdToVehicle[spec.attachOnLoad.vehicleId]

        if vehicle ~= nil then 
            self:setTowbarVehicle(Towbar.STATE_ATTACH, vehicle, spec.attachOnLoad.index, true)
        end

        spec.attachOnLoad = nil
    end

    if spec.attachedVehicleJoint ~= nil then
        if spec.isAttached and not spec.attachedVehicleJoint.vehicle.spec_enterable.isControlled then
            local vehicle = spec.attachedVehicleJoint.vehicle
            local inputJoint = self.spec_attachable.attacherJoint -- Created upon attaching to vehicle
            
            if inputJoint ~= nil then
                -- Turn towed vehicle towards input attacher joint
                local xTarget, yTarget, zTarget = getWorldTranslation(inputJoint.node)
                local tX, _, tZ = worldToLocal(vehicle.rootNode, xTarget, yTarget, zTarget)

                local tX_2 = tX * 0.5
                local tZ_2 = tZ * 0.5

                local d1X, d1Z = tZ_2, -tX_2
                if tX > 0 then
                    d1X, d1Z = -tZ_2, tX_2
                end

                local rotTime = 0
                local hit, _, f2 = MathUtil.getLineLineIntersection2D(tX_2,tZ_2, d1X,d1Z, 0,0, tX, 0)
                
                if hit and math.abs(f2) < 100000 then
                    local radius = tX * f2

                    rotTime = vehicle:getSteeringRotTimeByCurvature(1 / radius)

                    if vehicle:getReverserDirection() < 0 then
                        rotTime = -rotTime
                    end
                end

                local targetRotTime

                if rotTime >= 0 then
                    targetRotTime = math.min(rotTime, vehicle.maxRotTime)
                else
                    targetRotTime = math.max(rotTime, vehicle.minRotTime)
                end

                if targetRotTime > vehicle.rotatedTime then
                    vehicle.rotatedTime = math.min(vehicle.rotatedTime + dt*vehicle:getAISteeringSpeed(), targetRotTime)
                else
                    vehicle.rotatedTime = math.max(vehicle.rotatedTime - dt*vehicle:getAISteeringSpeed(), targetRotTime)
                end
				
                local attacherVehicle = self:getAttacherVehicle()
				if spec.matchParentVehicle and attacherVehicle ~= nil then
                    -- Match to parent Vehicle
					vehicle.spec_wheels.brakePedal = attacherVehicle.spec_wheels.brakePedal
                    
                    -- Work In Progress
                    -- check motor and match
				else
					-- Keep brakes inactive as long as nothing controls vehicle
					vehicle.spec_wheels.brakePedal = 0
				end
			else
                -- Nothing attached infront, put the brakes back!
                vehicle.spec_wheels.brakePedal = 1
            end
        else
            -- Keep active to force vehicle to stop if its moving upon detach
            if spec.detachTimer ~= nil then
                if spec.detachTimer > 0 then
                    spec.detachTimer = spec.detachTimer - dt
                else
                    spec.detachTimer = nil
                    spec.attachedVehicleJoint.vehicle.forceIsActive = false
                    spec.attachedVehicleJoint = nil
                end
            end
        end
    end

    if isActiveForInputIgnoreSelection then
        if not spec.isAttached then
            local nothingFound = true
            local x, y, z = getWorldTranslation(spec.attachNode)

            for k, vehicle in pairs(g_currentMission.vehicles) do
                local update = false
                local vx, vy, vz = getWorldTranslation(vehicle.rootNode)

                -- Check distance to vehicle
                if MathUtil.vector3Length(x - vx, y - vy, z - vz) <= 10 then
                    for index, joint in pairs(vehicle.spec_attacherJoints.attacherJoints) do

                        if joint.jointType == AttacherJoints.JOINTTYPE_TRAILER or joint.jointType == AttacherJoints.JOINTTYPE_TRAILERLOW then
                            local x1, y1, z1 = getWorldTranslation(joint.jointTransform)
                            local distance = MathUtil.vector3Length(x - x1, y - y1, z - z1)

                            if distance <= spec.attachDistance then
                                if spec.vehicleInRange == nil then
                                    update = true
                                else
                                    -- Distance is shorter or currently closest index
                                    if distance < spec.vehicleInRange.distance or (vehicle == spec.vehicleInRange.vehicle and index == spec.vehicleInRange.index) then
                                        update = true
                                    end
                                end

                                if update then
                                    spec.vehicleInRange = {
                                        vehicle = vehicle,
                                        index = index,
                                        distance = distance
                                    }
                                    nothingFound = false
                                end
                            end
                        end
                    end
                end
            end

            if nothingFound then
                spec.vehicleInRange = nil
            end

            if spec.vehicleInRange ~= nil and not spec.isAttached then
                g_currentMission.hud.contextActionDisplay:setContext(spec.attachButton, ContextActionDisplay.CONTEXT_ICON.ATTACH, g_currentMission:getVehicleName(spec.vehicleInRange.vehicle))
            end

            if spec.lastVehicleInRangeUpdate ~= nothingFound then
                spec.lastVehicleInRangeUpdate = nothingFound
                Towbar.updateActionText(self)
            end
        end
    end
end

Towbar.STATE_DETACH = 0
Towbar.STATE_ATTACH = 1

function Towbar:setTowbarVehicle(state, vehicle, jointIndex, noEventSend)
    local spec = self.spec_towbar

    if state == Towbar.STATE_DETACH then
        if self.isServer then
            removeJoint(spec.attachedVehicleJoint.index)
        end

        vehicle = spec.attachedVehicleJoint.vehicle
        vehicle.isBroken = spec.attachedVehicleJoint.isBroken

        if not vehicle.spec_enterable.isControlled then
            vehicle.spec_wheels.brakePedal = 1
        end

        spec.isAttached = false
        spec.detachTimer = 500

    elseif state == Towbar.STATE_ATTACH then
        spec.attachedVehicleJoint = {
            vehicle = vehicle,
            isBroken = vehicle.isBroken
        }
        spec.isAttached = true
        vehicle.forceIsActive = true
        vehicle.isBroken = false

        if not vehicle.spec_enterable.isControlled then
            vehicle.rotatedTime = 0
            vehicle.spec_wheels.brakePedal = 0
        end

        if self.isServer then
            local jointDesc = vehicle.spec_attacherJoints.attacherJoints[jointIndex]
            
            local constr = JointConstructor:new()
            constr:setActors(spec.attachRootNode, jointDesc.rootNode)
            constr:setJointTransforms(spec.attachNode, Utils.getNoNil(jointDesc.jointTransform, jointDesc.node))

            for i = 1, 3 do
                constr:setTranslationLimit(i - 1, true, 0, 0)
                constr:setRotationLimit(i - 1, -0.35, 0.35)
                constr:setEnableCollision(false)
            end

            spec.attachedVehicleJoint.index = constr:finalize()
            spec.attachedVehicleJoint.attacherJointIndex = jointIndex
        end
    end

    if self.isClient then
        Towbar.updateActionText(self)
    end

    setTowbarVehicleEvent.sendEvent(state, vehicle, jointIndex, noEventSend)
end

function Towbar:allowTowbar()
    local spec = self.spec_towbar

    if spec.isGrabbable then
        if spec.isGrabbableOnlyIfDetach then
            if not spec.isAttached and spec.attacherVehicle == nil then
                return true
            end
        else
            return true
        end
    end
    
    return false
end

-- Input

function Towbar:onRegisterActionEvents(isActiveForInput, isActiveForInputIgnoreSelection)
    if self.isClient then
		local spec = self.spec_towbar

		self:clearActionEventsTable(spec.actionEvents)

        if isActiveForInputIgnoreSelection then
            local state, actionEventId = self:addActionEvent(spec.actionEvents, spec.attachButton, self, Towbar.actionEventStateCallback, false, true, false, true, nil)
            g_inputBinding:setActionEventTextPriority(actionEventId, GS_PRIO_NORMAL)
        end

        Towbar.updateActionText(self)
    end
end

function Towbar:actionEventStateCallback(actionName, inputValue, callbackState, isAnalog)
    local spec = self.spec_towbar

    if actionName == spec.attachButton then
        if spec.vehicleInRange ~= nil and not spec.isAttached then
            self:setTowbarVehicle(Towbar.STATE_ATTACH, spec.vehicleInRange.vehicle, spec.vehicleInRange.index)
            self:playAttachSound(spec.vehicleInRange.vehicle.spec_attacherJoints.attacherJoints[spec.vehicleInRange.vehicle.index])

        elseif spec.isAttached then
            self:setTowbarVehicle(Towbar.STATE_DETACH)
            
            if spec.attachedVehicleJoint ~= nil then
                self:playDetachSound(spec.attachedVehicleJoint.vehicle.spec_attacherJoints.attacherJoints[spec.attachedVehicleJoint.vehicle.attacherJointIndex])
            end
        end
    end
end

function Towbar:updateActionText()
    local spec = self.spec_towbar

	if self.isClient then
		local actionEvent = spec.actionEvents[spec.attachButton]

		if actionEvent ~= nil then
            local showAction = false

            if spec.vehicleInRange ~= nil and not spec.isAttached then
                g_inputBinding:setActionEventText(actionEvent.actionEventId, g_i18n:getText("towbar_attach"))
                showAction = true

            elseif spec.isAttached then
                g_inputBinding:setActionEventText(actionEvent.actionEventId, g_i18n:getText("towbar_detach"))
                showAction = true
            end

            g_inputBinding:setActionEventActive(actionEvent.actionEventId, showAction)
        end
    end
end

-- Debug

function Towbar:updateDebugValues(values)
    local spec = self.spec_towbar

    table.insert(values, {name = "Vehicle attached to towbar", value = string.format("%s", tostring(spec.isAttached))})
    table.insert(values, {name = "Vehicle In Range",           value = string.format("%s", tostring(spec.vehicleInRange ~= nil))})

    if spec.vehicleInRange ~= nil then
        table.insert(values, {name = "In Range distance", value = string.format("%.2f", spec.vehicleInRange.distance)})
    end

    if spec.attachedVehicleJoint ~= nil then
        local v = spec.attachedVehicleJoint.vehicle
        table.insert(values, {name = "rotatedTime", value = string.format("%.2f", v.rotatedTime)})
        table.insert(values, {name = "brakePedal", value = string.format("%.2f", v.spec_wheels.brakePedal)})
    end
end


-- Event

setTowbarVehicleEvent = {}
local AutoLoaderExtendedSetUnloadSideEvent_mt = Class(setTowbarVehicleEvent, Event)

InitEventClass(setTowbarVehicleEvent, "setTowbarVehicleEvent")

function setTowbarVehicleEvent.emptyNew()
    local self = Event.new(AutoLoaderExtendedSetUnloadSideEvent_mt)

    return self
end

function setTowbarVehicleEvent.new(vehicle, state, attachVehicle, jointIndex)
    local self = setTowbarVehicleEvent.emptyNew()

    self.vehicle = vehicle
    self.state = state
    self.attachVehicle = attachVehicle
    self.jointIndex = jointIndex

    return self
end

function setTowbarVehicleEvent:readStream(streamId, connection)
    self.vehicle = NetworkUtil.readNodeObject(streamId)
    self.state = streamReadUIntN(streamId, 2)
    
    if self.state == 1 then
        self.attachVehicle = NetworkUtil.readNodeObject(streamId)
        self.jointIndex = streamReadInt8(streamId)
    end

    self:run(connection)
end

function setTowbarVehicleEvent:writeStream(streamId, connection)
    NetworkUtil.writeNodeObject(streamId, self.vehicle)
    streamWriteUIntN(streamId, self.state, 2)
    
    if self.state == 1 then
        NetworkUtil.writeNodeObject(streamId, self.attachVehicle)
        streamWriteInt8(streamId, self.jointIndex)
    end
end

function setTowbarVehicleEvent:run(connection)
    if self.vehicle ~= nil and self.vehicle:getIsSynchronized() then
		self.vehicle:setTowbarVehicle(self.state, self.attachVehicle, self.jointIndex, true)
	end

    if not connection:getIsServer() then
        g_server:broadcastEvent(self, false, connection, self.vehicle)
    end
end

function setTowbarVehicleEvent.sendEvent(vehicle, state, attachVehicle, jointIndex, noEventSend)
    if noEventSend == nil or not noEventSend then
        if g_server ~= nil then
            -- Server -> Client
            g_server:broadcastEvent(setTowbarVehicleEvent.new(vehicle, state, attachVehicle, jointIndex), nil, nil, vehicle)
        else
            -- Client -> Server
            g_client:getServerConnection():sendEvent(setTowbarVehicleEvent.new(vehicle, state, attachVehicle, jointIndex))
        end
    end
end