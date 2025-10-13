-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local driverCam = nil
local dummyViewCam = nil
local dummyViewCam2 = nil
local dummy1Nodes = {}
local dummy2Nodes = {}
local intCollisionNodes = {}
local seatNodes = {}
local seatBeams = {}
local intCollisionBeams = {}
local seatbeltBeams = {}
local cameraOffset = nil
local settingsOffset = {}
local mode = "experimental"
local moveSeats = false
local message = ""

local function roundCoordinate(num)
	return round(num*100)/100
end


local function recalculateBeamLength(b)

	--get coordinates of the beam nodes
	local node1 = v.data.nodes[b.id1].cid
	local node2 = v.data.nodes[b.id2].cid
	
	local x1 = vec3(obj:getNodePosition(node1)).x
	local x2 = vec3(obj:getNodePosition(node2)).x
	local y1 = vec3(obj:getNodePosition(node1)).y
	local y2 = vec3(obj:getNodePosition(node2)).y
	local z1 = vec3(obj:getNodePosition(node1)).z
	local z2 = vec3(obj:getNodePosition(node2)).z
	 
	--calculate distance and set it as new beam length
	local x = math.pow(x2-x1, 2)
	local y = math.pow(y2-y1, 2)
	local z = math.pow(z2-z1, 2)
	local d = math.sqrt(x+y+z)	
	
	obj:setBeamLength(b.cid, d)
	
end


local function reset()

	if mode == "UIMessage" then	
		guihooks.message(message, 10, "dummy mod", "")
	else
		--set new length of interior collision attach beams
		for _, b in pairs(intCollisionBeams) do recalculateBeamLength(b) end
		for _, b in pairs(seatbeltBeams) do recalculateBeamLength(b) end
		if moveSeats == true then for _, b in pairs(seatBeams) do recalculateBeamLength(b) end end
	end

end


local function init(jbeamData)

	mode = jbeamData.mode or "experimental"
	moveSeats = jbeamData.moveSeats or false

	for _, n in pairs(v.data.nodes) do
		--get driver camera nodes, if exist
		if n.name == 'dash' or n.name == 'driver' then driverCam = n end
		if n.name == 'driver_view' then dummyViewCam = n end
		if n.name == 'passenger_F_view' then dummyViewCam2 = n end
		--get dummy nodes, back seat passengers same as front
		if n.name ~= nil and (string.match(n.name,"Dummy1") or string.match(n.name,"Dummy3")) then table.insert(dummy1Nodes,n) end	
		if n.name ~= nil and (string.match(n.name,"Dummy2") or string.match(n.name,"Dummy4")) then table.insert(dummy2Nodes,n) end
		if n.name ~= nil and string.match(n.name,"intcollision_") then table.insert(intCollisionNodes,n) end
		if n.name ~= nil and string.match(n.name,"sf") then table.insert(seatNodes,n) end
	end
	
	table.insert(dummy1Nodes, dummyViewCam)
	table.insert(dummy2Nodes, dummyViewCam2)
	
	--abandon if camera not found
	if driverCam == nil or dummyViewCam == nil then return end
		
	--get all the beams that will change length
	for _, b in pairs(v.data.beams) do
		local node1 = v.data.nodes[b.id1].name
		local node2 = v.data.nodes[b.id2].name
		if node1 ~= nil and node2 ~= nil then
			if string.match(node1,"intcollision_") or string.match(node2,"intcollision_") then
				table.insert(intCollisionBeams,b)
			end
			if (string.match(node1,"Dummy") and string.match(node2,"s")) or (string.match(node1,"s") and string.match(node2,"Dummy")) then
				table.insert(seatbeltBeams,b)
			end
			if string.match(node1,"sf") or string.match(node2,"sf") then
				table.insert(seatBeams,b)
			end
		end
	end
		
	--calculate camera offset	
	local currentCamPos = vec3(obj:getNodePosition(dummyViewCam.cid))
	local calculatedCamPos = vec3(obj:getNodePosition(driverCam.cid))
	--dummy view camera sits a bit forward so you don't see the inside of the head. This means a small fix is required to our calculations
	local targetCamPos = vec3(calculatedCamPos.x, calculatedCamPos.y-0.2, calculatedCamPos.z)

	--now depending on the mode - either move the dummy or just show the message telling the user how to do it in tuning menu
	if mode == "UIMessage" then	
	
		local var_x
		local var_y
		local var_z
		for _, var in pairs(v.data.variables) do
			if var.name == "$cbpdriverOffsetX" then var_x = var.val end
			if var.name == "$cbpdriverOffsetY" then var_y = var.val end
			if var.name == "$cbpdriverOffsetZ" then var_z = var.val end
		end
		local defaultCamPos = vec3(currentCamPos.x-var_x, currentCamPos.y-var_y, currentCamPos.z-var_z)
		settingsOffset = vec3(targetCamPos.x-defaultCamPos.x, targetCamPos.y-defaultCamPos.y, targetCamPos.z-defaultCamPos.z)
		message = "Recommended Tuning tab values for driver position: X=" .. roundCoordinate(settingsOffset.x) .. ", Y=" .. roundCoordinate(settingsOffset.y) .. ", Z=" .. roundCoordinate(settingsOffset.z)
		guihooks.message(message, 10, "dummy mod", "")
		
	else
		
		cameraOffset = vec3(targetCamPos.x-currentCamPos.x, targetCamPos.y-currentCamPos.y, targetCamPos.z-currentCamPos.z)
		--move all dummy nodes by the offset
		for _, n in pairs(dummy1Nodes) do
			local currentPos = vec3(obj:getNodePosition(n.cid))
			obj:setNodePosition(n.cid, vec3(currentPos.x+cameraOffset.x, currentPos.y+cameraOffset.y, currentPos.z+cameraOffset.z))	
		end
		for _, n in pairs(dummy2Nodes) do
			local currentPos = vec3(obj:getNodePosition(n.cid))
			obj:setNodePosition(n.cid, vec3(currentPos.x-cameraOffset.x, currentPos.y+cameraOffset.y, currentPos.z+cameraOffset.z))	
		end
		for _, n in pairs(intCollisionNodes) do
			local currentPos = vec3(obj:getNodePosition(n.cid))
			if currentPos.x < 0 then
				n.desiredPosition =  vec3(currentPos.x-cameraOffset.x, currentPos.y+cameraOffset.y, currentPos.z+cameraOffset.z)	
			else
				n.desiredPosition =  vec3(currentPos.x+cameraOffset.x, currentPos.y+cameraOffset.y, currentPos.z+cameraOffset.z)	
			end
			obj:setNodePosition(n.cid, n.desiredPosition)	
		end
		if moveSeats == true then
			for _, n in pairs(seatNodes) do
				local currentPos = vec3(obj:getNodePosition(n.cid))
				if currentPos.x < 0 then
					n.desiredPosition =  vec3(currentPos.x-cameraOffset.x, currentPos.y+cameraOffset.y, currentPos.z+cameraOffset.z)	
				else
					n.desiredPosition =  vec3(currentPos.x+cameraOffset.x, currentPos.y+cameraOffset.y, currentPos.z+cameraOffset.z)	
				end
				obj:setNodePosition(n.cid, n.desiredPosition)	
			end
		end
		
	end

end


local function updateGFX(dt) -- ms
	
end


-- public interface
M.recalculateBeamLength = recalculateBeamLength
M.init         			= init
M.reset        			= reset
M.updateGFX    			= updateGFX

return M
