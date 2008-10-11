do
	-- This unique table ID will be used as a key to identify Actor tables
	local actor_key = {}
	RAIL.IsActor = function(actor)
		if type(actor) ~= "table" then return false end
		if actor[actor_key] == nil then return false end
		return true
	end

	-- The Actor "class" is private, because they're generated by referencing Actors
	local Actor = { }

	-- Metatables
	local Actor_mt = {
		__eq = function(self,other)
			if not RAIL.IsActor(other) then return false end

			return self.ID == other.ID
		end,

		__index = Actor,
		__tostring = function(self)
			return string.format("%s #%d [Loc:(%d,%d), Type:%d]",
				self.ActorType, self.ID, self.X[0], self.Y[0], self.Type)
		end,
	}

	-- History tracking
	local History = {}
	do
		-- Some 'private' keys for our history table
		local default_key = {}
		local list_key = {}
		local subtimes_key = {}
		local different_key = {}

		-- A helper funvtion to calculate values
		History.SubValue = function(a,b,target)
			-- Calculate the time difference ratio of A->B to A->Target
			local dest_ratio = (b[2] - a[2]) / (target - a[2])

			-- Divide the A->B value difference by the ratio,
			--	then apply it back to A to get the target value
			return a[1] + (b[1] - a[1]) / dest_ratio
		end

		local History_mt = {
			__index = function(self,key)
				local list = self[list_key]

				-- Check if we have any history
				if list:Size() < 1 then
					-- No history, return the default
					return self[default_key]
				end

				-- How many milliseconds into the past?
				--	negative indexes will "predict" future values
				local target = GetTick() - key

				-- If time older than history is requested, use default
				if target < list[list.first][2] then
					return self[default_key]
				end

				-- If time more recent than latest history, use it
				if target >= list[list.last][2] then
					if list:Size() < 2 then
						-- Since size is only 1, we can't calculate
						return list[list.last][1]
					end

					return History.SubValue(list[list.last-1],list[list.last],target)
				end

				-- Otherwise, binary search for the closest item that isn't newer
				do
					-- left is older, right is newer
					local l,r = list.first,list.last
					local probe
					while true do
						probe = math.floor((l + r) / 2)

						if probe <= l then
							-- This must be the best one
							break
						end

						-- Check the time of the current probe position
						if target < list[probe][2] then
							-- Too new
							r = probe
						elseif target > list[probe][2] then
							-- New enough, search for a better one
							l = probe
						else
							-- If it's exact, go ahead and use it
							return list[probe][1]
						end
					end

					if not self[subtimes_key] then
						return list[probe][1]
					end

					return History.SubValue(list[probe],list[probe+1],target)
				end
			end,
			__newindex = function(self,key,val)
				-- Don't allow new entries to be created directly
			end,
		}

		local default_Different = function(a,b) return a[1] ~= b[1] end

		History.New = function(default_value,calc_sub_vals,diff_func)
			local ret = {
				[default_key] = default_value,
				[list_key] = List.New(),
				[subtimes_key] = calc_sub_vals,
				[different_key] = default_Different
			}
			setmetatable(ret,History_mt)

			if type(diff_func) == "function" then
				ret[different_key] = diff_func
			end

			return ret
		end

		History.Update = function(table,value)
			local list = table[list_key]
			local diff = table[different_key]

			-- New value
			value = {value,GetTick()}

			-- Make sure it's not a duplicate
			if list:Size() < 1 or diff(list[list.last],value) then
				list:PushRight(value)
				return
			end

			-- If we don't calculate sub-values, it won't matter
			if not table[subtimes_key] then return end

			-- Since sub-values are calculated, keep the beginning and end times
			if list:Size() < 2 or diff(list[list.last-1],list[list.last]) then
				list:PushRight(value)
				return
			end

			-- If there's already beginning and end, update the end
			list[list.last] = value
		end

		History.Clear = function(table)
			table[list_key]:Clear()
		end
	end

	-- Initialize a new Actor
	Actor.New = function(self,ID)
		local ret = { }
		setmetatable(ret,Actor_mt)

		ret.ActorType = "Actor"
		ret.ID = ID
		ret.Type = -1			-- "fixed" type (homus don't overlap players)
		ret.Hide = false		-- hidden?
		ret.LastUpdate = -1		-- GetTick() of last :Update() call
		ret.FullUpdate = false		-- Track position, motion, target, etc?
		ret.TargetOf = { }		-- Other Actors that are targeting this one
		ret.IgnoreTime = -1		-- Actor isn't currently ignored

		-- The following have their histories tracked
		ret.Target = History.New(-1,false)
		ret.Motion = History.New(MOTION_STAND,false)

		-- Position tracking uses a specialty "diff" function
		local pos_diff = function(a,b)
			if math.abs(a[1]-b[1]) > 1 then return true end
			if math.abs(a[2]-b[2]) > 500 then return true end
			return false
		end
		-- And they'll also predict sub-history positions
		ret.X = History.New(-1,true,pos_diff)
		ret.Y = History.New(-1,true,pos_diff)

		-- Setup the expiration timeout for 2.5 seconds...
		--	(it will be updated in Actor.Update)
		ret.ExpireTimeout = RAIL.Timeouts:New(2500,false,Actor.Expire,ret)

		-- Initialize the type
		Actor[actor_key](ret)

		-- TODO: Log

		return ret
	end

	-- A temporary "false" return for IsEnemy, as long as an actor is a specific type
	local ret_false = function() return false end

	-- A "private" function to initialize new actor types
	Actor[actor_key] = function(self)
		-- Set the new type
		self[actor_key] = GetV(V_HOMUNTYPE,self.ID)
		self.Type = self[actor_key]

		-- Check the type for sanity
		if self.ID < 100000 and LIF <= self.Type and self.Type <= VANILMIRTH_H2 then
			self.Type = self.Type + 6000
		end

		-- Initialize differently based upon type
		if self.Type == -1 then
			self.ActorType = "Unknown"

			-- Unknown types are never enemies
			self.IsEnemy = ret_false

			-- Track information on unknowns anyway
			self.FullUpdate = true

		-- Portals
		elseif self.Type == 45 then
			self.ActorType = "Portal"

			-- Portals are enemies? Hah! Never!
			self.IsEnemy = ret_false

			-- Don't track position, motion, etc...
			self.FullUpdate = false

		-- Player Jobs
		elseif (0 <= self.Type and self.Type <= 25) or
			(161 <= self.Type and self.Type <= 181) or
			(4001 <= self.Type and self.Type <= 4049)
		then
			self.ActorType = "Player"

			-- Allow the actor to be an enemy if it was previous blocked
			if rawget(self,"IsEnemy") == ret_false then
				rawset(self,"IsEnemy",nil)
			end

			-- Track all the data about them
			self.FullUpdate = true

		-- NPCs (non-player jobs that are below 1000)
		elseif self.Type < 1000 then
			self.ActorType = "NPC"

			-- NPCs aren't enemies
			self.IsEnemy = ret_false

			-- And they don't do much either
			self.FullUpdate = false

		-- All other types
		else
			self.ActorType = "Actor"

			-- Allow the actor to be an enemy if it was previous blocked
			if rawget(self,"IsEnemy") == ret_false then
				rawset(self,"IsEnemy",nil)
			end

			-- Track all the data about them
			self.FullUpdate = true
		end
	end

	-- Update information about the actor
	Actor.Update = function(self)
		-- Check for a type change
		if GetV(V_HOMUNTYPE,self.ID) ~= self[actor_key] then
			Actor[actor_key](self)
		end

		-- Update the expiration timeout
		self.ExpireTimeout[2] = GetTick()
		if not self.ExpireTimeout[1] then
			self.ExpireTimeout[1] = true
			RAIL.Timeouts:Insert(self.ExpireTimeout)
		end

		-- Update ignore time
		if self.IgnoreTime > 0 then
			self.IgnoreTime = self.IgnoreTime - (GetTick() - self.LastUpdate)
		end

		-- Update the LastUpdate field
		self.LastUpdate = GetTick()

		-- Some actors don't require everything tracked
		if not self.FullUpdate then
			return self
		end

		-- Update the motion
		History.Update(self.Motion,GetV(V_MOTION,self.ID))

		-- Update the actor location
		local x,y = GetV(V_POSITION,self.ID)
		if x ~= -1 then
			-- Check for hidden
			if x == 0 and y == 0 then
				if not self.Hide then
					-- Log it
					self.Hide = true
				end
			else
				if self.Hide then
					-- Log it
					self.Hide = false
				end
				History.Update(self.X,x)
				History.Update(self.Y,y)
			end
		end

		-- Check if the actor is able to have a target
		if self.Motion[0] ~= MOTION_DEAD and self.Motion[0] ~= MOTION_SIT then
			-- Update the target
			History.Update(self.Target,GetV(V_TARGET,self.ID))

			-- Tell the other actor that it's being targeted
			Actors[self.Target[0]]:TargetedBy(self)
		else
			-- Can't target, so it should be targeting nothing
			History.Update(self.Target,-1)
		end

		return self
	end

	-- Track when other actors target this one
	local targeted_time = {}
	Actor.TargetedBy = function(self,actor)
		-- Use a table to make looping through and counting it faster
		--	* to determine if an actor is targeting this one, use Actors[id].Target[0] == self.ID
		if self.TargetOf[targeted_time] ~= GetTick() then
			self.TargetOf = Table:New()
			self.TargetOf[targeted_time] = GetTick()
		end

		self.TargetOf:Insert(actor)
		return self
	end

	-- Clear out memory
	Actor.Expire = function(self)
		-- TODO: Log

		-- Clear the histories
		History.Clear(self.Motion)
		History.Clear(self.Target)
		History.Clear(self.X)
		History.Clear(self.Y)
	end

	--------------------
	-- Categorization --
	--------------------
	-- The following functions support other parts of the script

	-- Check if the actor is an enemy (monster/pvp-player)
	Actor.IsEnemy = function(self)
		return IsMonster(self.ID) == 1
	end

	-- Check if the actor is a friend
	Actor.IsFriend = function(self)
		do return false end

		-- TODO: Temporary friends (players within <opt> range of owner)

		-- TODO: Friend list (players only! monster IDs and homu IDs change!!)
	end

	-- Check if the actor is ignored
	Actor.IsIgnored = function(self)
		return self.IgnoreTime > 0
	end

	-- Ignore the actor for a specific amount of time
	Actor.Ignore = function(self,ticks)
		-- If it's already ignored, do nothing
		if self:IsIgnored() then
			return self
		end

		-- Use default ticks if needed
		if type(ticks) ~= "number" then
			-- TODO: This
			ticks = 1000
		end

		-- TODO: Log

		self.IgnoreTime = ticks
	end

	--------------------
	-- Battle Options --
	--------------------

	-- RAIL allowed to kill monster?
	Actor.IsAllowed = function(self)
		-- TODO: This... Attack/Skill Allowed
		return true
	end

	-- TODO: Anti-kill-steal code

	-- The follow list should be retrieved from shared tables (referenced by type):
	-- * Priority

	-- * Attack Allowed
	-- * Defend-only
	-- * Ignore KS

	-- * Skills Allowed
	-- * Min/Max Skill Level
	-- * Time Between Skills
	-- * Max Casts Against


	-- Kite / Attack**
	--	**- based partially on shared table, based partially on homu's current HP?

	--------------------
	-- Utils Wrappers --
	--------------------

	-- Pythagorean Distance
	-- TODO: Support historical locations
	Actor.DistanceTo = function(self,x,y)
		-- Check if "x" is an actor table
		if RAIL.IsActor(x) then
			return self:DistanceTo(x.X[0],x.Y[0])
		end

		return PythagDistance(self.X[0],self.Y[0],x,y)
	end

	-- Straight-line Block Distance
	-- TODO: Support historical locations
	Actor.BlocksTo = function(self,x,y)
		-- Check if "x" is an actor table
		if RAIL.IsActor(x) then
			return self:BlocksTo(x.X[0],x.Y[0])
		end

		return BlockDistance(self.X[0],self.Y[0],x,y)
	end

	-- Angle from actor to point
	-- TODO: Support historical locations
	Actor.AngleTo = function(self,x,y)
		-- Check if "x" is an actor table
		if RAIL.IsActor(x) then
			return self:AngleTo(x.X[0],x.Y[0])
		end

		return GetAngle(self.X[0],self.Y[0],x,y)
	end

	-- Angle from point to actor
	-- TODO: Support historical locations
	Actor.AngleFrom = function(self,x,y)
		-- Check if "x" is an actor table
		if RAIL.IsActor(x) then
			return self:AngleFrom(x.X[0],x.Y[0])
		end

		return GetAngle(x,y,self.X[0],self.Y[0])
	end

	-- Plot a point on a circle around this actor
	-- TODO: Support historical locations
	Actor.PlotCircle = function(self,angle,radius)
		return PlotCircle(self.X[0],self.Y[0],angle,radius)
	end

	-----------------------
	-- Actors Collection --
	-----------------------

	Actors = {}
	setmetatable(Actors,{
		__index = function(self,idx)
			if type(idx) ~= "number" then
				return Actors[-1]
			end

			rawset(self,idx,Actor:New(idx))
			return self[idx]
		end
	})

	-- After setting up the Actor class and Actors table,
	--	rework the API to allow Actor inputs
	--local
end