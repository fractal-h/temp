export type BrainrotData = {
	id: number, -- ID of brainrot for searching
	level: number, -- level of brainrot
	modifiers: {string}, -- modifiers (gold, emerald, majestic, whatever)
	position: number -- position in players base 	
};

export type PlayerData = {
	speed: number,
	money: number,
	rebirth: number,
	brainrots: {BrainrotData},	
	gamepasses: {string}, -- will not exist unless true
};

-- Services
local Promise = require(game.ReplicatedStorage.Assets.Shared.Modules.Services.Promise); -- https://github.com/fractal-h/Roblox-Packages/blob/main/Promise.luau
local Event = require(game.ReplicatedStorage.Assets.Shared.Modules.Services.Event); -- https://github.com/fractal-h/Roblox-Packages/blob/main/Event.luau
local Players = game:GetService("Players");
local marketplace = game:GetService("MarketplaceService");
local gamepassData = require(game.ReplicatedStorage.Assets.Shared.Modules.Data.MonetizationData);

-- Data
local dss = game:GetService("DataStoreService");
local DATA_KEY = "test_version_2";
local dataStore = dss:GetDataStore(DATA_KEY);

-- DataSave Queue
local gameClosing = false;
local queue = {};

-- Safe Save
local function SafeSave(key, data)
	local result = false;

	-- Attempts to save to data store, if failed, waits 2 seconds then attempts again. 10 attempts are alloted before ending the attempt.
	local attempts = 10;
	while (result == false) do 
		
		-- dataStore failing results in an error, so you put it in a protected call function 
		local success, error = pcall(function()
			dataStore:SetAsync(key, data);
		end)

		-- if the pcall was unsuccessful wait 2 seconds and try again, ticking down attempts
		result = success;
		if (not result) then 
			task.wait(2);
			attempts -= 1;

			if (attempts <= 0) then 
				break;
			end
		end
	end

	return result;
end

-- Metatable
local saveQueries = {};
local metaTable = {
	Save = function(self)
		-- if game is closing then add it to the queue and exit call
		if (gameClosing) then 
			table.insert(queue, self);
			return true;
		end

		-- Prevent previous saves overwriting recent saves
		if (saveQueries[self.author]) then 
			task.cancel(saveQueries[self.author]);
		end

		-- Needs to be threaded so task.wait() doesnt slow all saves
		saveQueries[self.author] = task.spawn(function()
			SafeSave(self.author, self.data);
		end)

		return true;
	end,

	-- redirect __newindex to non-readonly sections of data
	__newindex = function(self, key, value)
		if (not self.data[key]) then return end;
		self.data[key] = value;
	end,
	__index = function(self, key)
		local metatable = getmetatable(self);
		if (metatable[key]) then return metatable[key] end;

		local notData = rawget(self, key);
		if (notData) then return notData end;

		return rawget(self, "data")[key];
	end,
};

-- Functions
local function CreateEmpty(author: Player, overwrite: {})
	-- Creates empty data template and separates data because author is meant to be read only and not changed by later events
	local empty = {
		author = author.UserId,

		data = {
			speed = 18, 
			rebirth = 0,
			money = 0,
			brainrots = {},
			gamepasses = {},
		}
	};
	
	-- if there is no data to overwrite it returns the empty data
	if (not overwrite) then 
		return setmetatable(empty, metaTable);
	end

	-- Overwrite existing data
	-- also reconsiles existing data with new data sets
	for i, v in overwrite do
		if (not empty.data[i]) then 
			warn("Attempted to set value of data that doesnt exist");
			continue;
		end

		empty.data[i] = v;
	end

	return setmetatable(empty, metaTable);
end

-- Handle game closing 
game:BindToClose(function()
	gameClosing = true;

	-- Greater than equal too in case players leave before data is saved
	local playerAmount = #game:GetService("Players"):GetPlayers();
	repeat task.wait() until #queue >= playerAmount;

	-- Create a promise that saves all queue'd player data
	local closingPromise = Promise.new(function(self)
		while (#queue > 0) do 
			SafeSave(queue[1].author, queue[1].data);
			table.remove(queue, 1);
		end
		self:Resolve();
	end)

	-- confirm all player data has been saved successfully 
	closingPromise:Then(function()
		warn("All data has been saved successfully, closing server");
	end)
end)

-- Service
local DataService = {
	Empty = CreateEmpty(),
	FetchData = function(client: Player)
		-- fetch existing data from datastore 
		local existingData = dataStore:GetAsync(client.UserId);

		-- Applys existing data to template, so if new members are added to PlayerData type they will be added to existing data without issue.
		local reconsiledData = CreateEmpty(client, existingData);

		return reconsiledData;
	end,	
};

-- Active 
local active = {};

-- Client Service
local Client;
Client = {
	-- Fetch player from active with either user ID or player object
	FetchPlayer = function(index: number | Player)
		if (typeof(index) == "Player") then 
			return active[index.UserId];
		end

		return active[index];
	end,
	
	-- returns list of all active players
	FetchPlayers = function()
		return active;
	end,

	-- Creates player object and adds data
	PlayerAdded = function(client: Player)
		-- create obj
		active[client.UserId] = setmetatable({
			id = client.UserId,
			data = DataService.FetchData(client),
		}, Client);

		-- ensure all gamepasses are loaded
		for name, gamepass in gamepassData.Raw() do 
			if (gamepass.type ~= "gamepass") then continue end;
			if (not marketplace:UserOwnsGamePassAsync(gamepass.id)) then continue end;
			if (active[client.UserId].data.gamepasses[name]) then continue end;
			table.insert(active[client.UserId].data.gamepasses, name);
		end

		return active[client.UserId];
	end,	
	PlayerRemoving = function(player: Player)
		-- find data
		local data = active[player.UserId];

		-- attempt to save data 
		local dataSave = Promise.new(function(self)
			local result = data.data:Save();

			if (result) then
				return self:Resolve();
			end

			return self:Reject();
		end)
			:Then(function() -- if data saves successfully then free players data
				active[player.UserId] = nil;
			end)
			:Catch(function() -- if data save is unsuccessful then try again
				Client.PlayerRemoving(player);
			end)
	end,
};
Client.__index = Client;

-- Methods
function Client:Rebirth()
	-- creates buffer table to save data once all clearable data is cleared
	local dataToSave = {
		gamepasses = self.data.gamepasses,
		rebirth = self.data.rebirth
	};

	-- set data to new data and immediately save
	self.data = DataService.Empty(dataToSave);
	self.data.rebirth += 1;
	self.data:Save();
end

-- Connections
Players.PlayerAdded:Connect(Client.PlayerAdded);
Players.PlayerRemoving:Connect(Client.PlayerRemoving)

return Client;
