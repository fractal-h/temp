-- Typedef
type Promise = {
	status: string,
	Then: ((...any?) -> nil, (...any?) -> nil) -> Promise,
	Finally: (...any?) -> Promise,
	Catch: (...any?) -> Promise,
	Reject: (...any?) -> Promise,
	Resolve: (...any?) -> Promise,
	Yield: (number) -> Promise,
	Close: () -> nil,
	Attempt: ((...any?) -> ...any?, ...any?) -> Promise,
	ScheduleAttempt: ((...any?) -> ...any?, number, ...any?) -> Promise,
	Clear: () -> nil,
}

-- High Order Functions
local function insertCallback(self, type, callback: (...any?) -> nil)
	table.insert(self.callbacks, {type = type, callback = callback})
end

local function asynchronousSafeExecutor(promise: Promise, ...)
	-- Assign variable to the saved coroutine 
	local routine = promise.routine
	while true do
		-- Update yield timer 
		promise.yieldTime = math.max(promise.yieldTime - task.wait(), 0)
		if promise.yieldTime > 0 then continue end
		
		-- Resume the coroutine, and if the status of the promise is no longer pending, then the coroutine is closed and the promise is settled.
		-- This prevents promises from continuing to be executed after they have been settled.
		local success, result = coroutine.resume(routine, promise, ...)
		if promise.status ~= "pending" then break end
		
		-- Settling the promise
		
		-- Failure case:
		if not success then
			-- Sets promise status for callbacks and multi-promise dependant functions 
			promise.status = "rejected"
			for _, v in pairs(promise.callbacks) do
				-- Locates callbacks without catch or finally 
				if v.type ~= "catch" and v.type ~= "finally" then continue end
				task.spawn(v.callback, promise, result)
			end
			-- Free data and settle promise
			if promise.status == "rejected" then promise:Clear() end
			break
		end
		
		-- Settle promise if coroutine competes 
		if coroutine.status(routine) ~= "dead" then continue end
		
		-- Success case:
		if success then
			promise:Resolve(result)
			break
		end
	end

	task.wait()
	coroutine.close(routine)
end

-- Promise
local promise
promise = {
	-- Creates a promise which is settled once all passed promises settle. The passed values are only the success cases
	all = function(promises: {Promise}): Promise
		local resultPromise = promise.new()
		local results, size = {}, #promises

		local function handleSettle()
			if size == 0 then
				if #results < 0 then return resultPromise:Reject("None of the specified promises were accepted") end
				return resultPromise:Resolve(results)
			end
		end

		local finalize = function(winner, result)
			size -= 1
			if winner.status == "rejected" then return handleSettle() end
			table.insert(results, result)
			handleSettle()
		end

		for _, p in promises do p:Finally(finalize) end
		return resultPromise
	end,
	
	-- Same for all except it includes rejection cases
	allSettled = function(promises: {Promise}): Promise
		local resultPromise = promise.new()
		local results, size = {}, #promises

		local function handleSettle()
			if size == 0 then
				if #results < 0 then return resultPromise:Reject("None of the specified promises were rejected or completed") end
				return resultPromise:Resolve(results)
			end
		end

		local finalize = function(winner, result)
			size -= 1
			table.insert(results, {status = winner.status, value = result})
			handleSettle()
		end

		for _, p in promises do p:Finally(finalize) end
		return resultPromise
	end,
	
	-- Creates promise that is settled once the first of the passed promises settles
	race = function(promises: {Promise}): Promise
		local resultPromise = promise.new()
		local winnerFound = false

		local finalize = function(winner, result)
			if winnerFound then return end
			winnerFound = true
			resultPromise:Resolve(result)
		end

		for _, p in promises do p:Finally(finalize) end
		return resultPromise
	end,
	
	-- Returns the result of the first promise that was accepted
	any = function(promises: {Promise}): Promise
		local resultPromise = promise.new()
		local winnerFound = false
		local size = #promises

		local finalize = function(winner, result)
			size -= 1
			if winner.status == "rejected" then
				if size == 0 then resultPromise:Reject("None of the specified promises were accepted") end
				return
			end
			if winnerFound then return end
			winnerFound = true
			resultPromise:Resolve(result)
		end

		for _, p in promises do p:Finally(finalize) end
		return resultPromise
	end,
	
	-- Creates a new promise based on a callback, then provides the arguments from the passed ...
	new = function(callback: (...any?) -> ...any?, ...): Promise
		local object = {
			routine = callback and coroutine.create(callback) or nil,
			yieldTime = 0,
			callbacks = {},
			status = "pending",
		}
		if callback then task.spawn(asynchronousSafeExecutor, object, ...) end
		setmetatable(object, promise)
		return object
	end,
}
promise.__index = promise

-- Memory Management
function promise:Clear()
	table.clear(self.callbacks)
	setmetatable(self, nil)
	self = nil
end

-- Returns self to allow chaining of promises
-- Initialization
function promise:ScheduleAttempt(callback: (...any?) -> ...any?, delayTime: number, ...)
	self.status = "pending"
	self.routine = coroutine.create(callback)
	self.yieldTime = delayTime
	task.spawn(asynchronousSafeExecutor, self, ...)

	return self;
end

function promise:Attempt(callback: (...any?) -> ...any?, ...)
	self.status = "pending"
	self.routine = coroutine.create(callback)
	self.yieldTime = 0
	task.spawn(asynchronousSafeExecutor, self, ...)

	return self;
end

-- Resolution Handling
function promise:Finalize(status: boolean, ...)
	local ignoreType = status and "reject" or "resolve"
	local preUpdateStatus = self.status
	local oldRoutine = self.routine

	task.wait()
	for _, callback in pairs(self.callbacks) do
		if callback.type == ignoreType or callback.type == "catch" then continue end
		task.spawn(callback.callback, self, ...)
	end

	task.wait()
	if preUpdateStatus == self.status then 
		self:Clear(); 
		return; 
	end
end

-- Resolution Cases
function promise:Yield(length)
	self.yieldTime += length
	coroutine.yield()

	return self;
end

function promise:Reject(...)
	self.status = "rejected"
	self:Finalize(false, ...)

	return self;
end

function promise:Resolve(...)
	self.status = "fulfilled"
	self:Finalize(true, ...)

	return self;
end

function promise:Cancel()
	self.status = "rejected"
	promise:Finalize(false, "Cancelled")
end

-- Resolution Callbacks
function promise:Then(resolve: (...any?) -> nil, reject: (...any?) -> nil)
	insertCallback(self, "resolve", resolve)
	if reject then insertCallback(self, "reject", reject) end

	return self;
end

function promise:Finally(callback: (...any?) -> nil)
	insertCallback(self, "finally", callback)

	return self;
end

function promise:Catch(callback: (...any?) -> nil)
	insertCallback(self, "catch", callback)

	return self;
end

return promise
