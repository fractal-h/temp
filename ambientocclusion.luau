-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage");
local CollectionService = game:GetService("CollectionService");
local RunService = game:GetService("RunService");
local Debris = game:GetService("Debris");
local Players = game:GetService("Players");
local TweenService = game:GetService("TweenService");

-- Assets
local Modules = ReplicatedStorage:WaitForChild("Modules");
local Visual = script:WaitForChild("Visual");
local ClientSideModules = Modules:WaitForChild("ClientSide");
local Exhibit = workspace:WaitForChild("AmbientOcclusionExhibit");
local Sounds = workspace:WaitForChild("ModuleAssets"):WaitForChild("AmbientOcclusion");

repeat task.wait() until game:IsLoaded();

-- Modules
local Utility = require(Modules:WaitForChild("Utility"));
local BGM = require(ClientSideModules:WaitForChild("BackgroundMusic"));

-- Constants
local Player = Players.LocalPlayer;
local RaycastInclude = CollectionService:GetTagged("AmbientOcclusionRaycast");
local AmbientSounds = {};
for _, sound in CollectionService:GetTagged("AmbientOcclusionSound") do 
	AmbientSounds[sound] = {
		sound = sound,
		range = sound:WaitForChild("Range").Value,
		dampening = sound:WaitForChild("Dampening").Value,
		volume = sound:WaitForChild("Volume").Value,
		origin = sound.Parent.Position,
	};
end

-- Raycast Params
local OcclusionRaycastParams = RaycastParams.new();
OcclusionRaycastParams.FilterType = Enum.RaycastFilterType.Include;
OcclusionRaycastParams.FilterDescendantsInstances = RaycastInclude;
OcclusionRaycastParams.RespectCanCollide = false;

-- Generate Vectors
local VECTOR_RESOLUTION = 2;
local VECTOR_REFLECTIONS = 3; -- Amount of reflections allowed per raycast
local VECTOR_FRAMERATE = 1/20; -- in seconds
local VECTOR_DAMPENING_CULL = 0.05; -- minimum volume required to dedicate resources to finding dampened raycast results
local VECTOR_MAX_RANGE = 150; -- maximum range of raycast
local VECTOR_AMOUNT = 0;

local VectorsOrigin = { -- so if VectorResolution is changed, it can be regenerated
	Vector3.new(1, 0, 0),
	Vector3.new(-1, 0, 0),
	Vector3.new(0, 1, 0),
	Vector3.new(0, -1, 0),
	Vector3.new(0, 0, 1),
	Vector3.new(0, 0, -1),
};

local Vectors = {
	Vector3.new(1, 0, 0),
	Vector3.new(-1, 0, 0),
	Vector3.new(0, 1, 0),
	Vector3.new(0, -1, 0),
	Vector3.new(0, 0, 1),
	Vector3.new(0, 0, -1),
};

-- Variables
local character = Player.Character;
local thread = nil;
local visualEnabled = false;
local destination = Vector3.zero;
local whitelistedSounds = {}; -- sounds within range 

-- Functions
function GenerateVectors()
	if (VECTOR_RESOLUTION <= 0) then return end;

	-- Decrease counter
	VECTOR_RESOLUTION -= 1;

	-- Create new table to store created vectors
	local newVectorTable = {};

	for i, vector in Vectors do 
		-- Add vector to table
		table.insert(newVectorTable, vector);

		for i2, vector2 in Vectors do 
			-- Skip if same
			if (i == i2) then continue end;

			-- If vector is opposite to vector2, canceling eachother out, skip
			if (vector == -vector2) then continue end;
			
			-- Find sum of vectors
			local sum = (vector + vector2);

			table.insert(newVectorTable, sum.Unit);
		end
	end
	
	-- Cull duplicate vectors
	
	--TEMP (will be replaced with more optimized version later, this is very poorly made)
	for index, vector in newVectorTable do 
		for i, vector2 in newVectorTable do 
			if (i == index) then continue end;
			if (vector2 == vector) then 
				table.remove(newVectorTable, i);
			end
		end
	end
	print(newVectorTable)
	--/TEMP

	-- Replace old table
	Vectors = newVectorTable;
	VECTOR_AMOUNT = #Vectors;

	-- Recursively generate vectors
	GenerateVectors();
end
GenerateVectors();

print("Current vector amount: ", VECTOR_AMOUNT);

-- dampen sounds
local function Dampen(number, dampening)
	return number * (1-dampening);
end

-- Raycast
local function Raycast(vector)
	-- Create variables for raycasting
	local currentPosition = destination;
	local currentVector = vector;
	local distance = VECTOR_MAX_RANGE;
	local reflections = 0
	
	-- To be done:
	local dampenedRays = {}; -- {distance: number, reflections: number, dampenAmount: number}
	
	-- Create table to store results
	local results = {};

	-- Begin loop
	while (distance > 0 and reflections <= VECTOR_REFLECTIONS) do 
		-- Raycast
		local result: RaycastResult? = workspace:Raycast(currentPosition, vector * distance, OcclusionRaycastParams);
		
		-- If there is no raycast result, break
		if (not result) then break end;
		
		-- Find delta and update values
		local delta = result.Position - currentPosition;
		distance -= delta.Magnitude;
		currentPosition = result.Position;
	
		-- Commented out dampened rays to improve efficiency until they are fully completed
		--[[
		table.insert(dampenedRays, {
			position = currentPosition,
			distance = distance,
		});]]
		
		-- See if ray can be cast into each sound object
		local offset = distance - VECTOR_MAX_RANGE;
		for _, whitelistedSound in whitelistedSounds do 
			-- See if result has already been found, or if result is out of range
			if (results[whitelistedSound.sound]) then continue end;
			if (whitelistedSound.range + offset < 0) then continue end;
			
			-- Find difference in position of result
			local delta = whitelistedSound.origin - currentPosition;
			
			-- Raycast
			local finalRay: RaycastResult = workspace:Raycast(currentPosition, delta, OcclusionRaycastParams);
			
			-- If there is no obstruction, add to result 
			if (not finalRay) then 
				results[whitelistedSound.sound] = distance + delta.Magnitude;
			end
		end
		
		-- If there are no more possible sounds to cast to, break loop 
		if (#whitelistedSounds == #results) then break end;
		
		-- Create visual if enabled (temporary)
		if (visualEnabled) then
			local p = Visual:Clone();
			p.Name = "temp";
			p.Parent = workspace;
			p.Position = currentPosition;
			p.Color = Color3.fromRGB(50 + reflections * 50, 0, 0);
			task.wait(0.01);
		end
		
		-- Update values
		currentVector = Utility.ReflectVector(vector, result.Normal);
		reflections += 1;
	end
	
	return results;
end

-- Ambient Occlusion Loop
function MainLoop()
	task.wait(VECTOR_FRAMERATE);
	if (not character) then return end;
	
	-- Set propogation point of rays to character position 
	destination = character.HumanoidRootPart.Position;
	
	-- Clear old visuals (temporary)
	if (visualEnabled) then 
		for _, part in CollectionService:GetTagged("AmbientVisual") do
			if (part.Name == "temp") then part:Destroy() end;
		end
	end
	
	-- Find out which sounds can be whitelisted for the raycast
	whitelistedSounds = {};
	for _, sound in AmbientSounds do 
		local delta = sound.origin - destination;
		if (delta.Magnitude > sound.range) then continue end;
		table.insert(whitelistedSounds, sound);
	end
	
	-- Find results
	local results = {};
	for _, vector in Vectors do 
		task.spawn(function()
			table.insert(results, Raycast(vector));
		end)
	end
	
	-- Wait for all threads to complete
	repeat task.wait() until #results == VECTOR_AMOUNT;

	-- Go through each result and concatenate them 
	local finalVolumes = {};
	for _, rayResult in results do 
		for sound, distance in rayResult do 
			local distanceAlpha = distance / VECTOR_MAX_RANGE;
			local maxVolume = AmbientSounds[sound].volume / VECTOR_AMOUNT;
			local addition = math.min(maxVolume * distanceAlpha, maxVolume)
			finalVolumes[sound] = finalVolumes[sound] and finalVolumes[sound] + addition or addition;
		end
	end
	
	-- Set sound volume to 0 if no rays found them
	for sound, _ in AmbientSounds do 
		if (not finalVolumes[sound]) then sound.Volume = 0 end;
	end
	
	-- Update volumes
	for sound, v in finalVolumes do
		sound.Volume = v;
	end
	
	-- Loop function
	MainLoop();
end

-- Enable Disable Sounds
local function EnableSounds()
	for _, sound in AmbientSounds do 
		sound.sound:Play();
	end
end

local function DisableSounds()
	for _, sound in AmbientSounds do 
		sound.sound:Stop();
	end
end

-- Character Handling
local function CharacterAdded(char)
	character = char;
end

-- Module
local AmbientOcclusion = {
	PlayerAdded = function(player: Player)
		BGM.Pause();
		EnableSounds();
		
		thread = task.spawn(MainLoop);
	end,
	PlayerRemoving = function(player: Player)
		BGM.Resume();
		DisableSounds();
		
		if (thread) then 
			task.cancel(thread);
			thread = nil;
		end
	end,
};

-- Events
Player.CharacterAdded:Connect(CharacterAdded);

return AmbientOcclusion;
