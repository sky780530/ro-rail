-- A few persistent-state options used
RAIL.Validate.DefendFriends = {"boolean",false}

-- Actor data-collection
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

	-- Private key for keeping closures
	local closures = {}

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
		ret.BattleOpts = { }		-- Battle options

		-- Set defaults for battle options
		setmetatable(ret.BattleOpts,{
			__index = function(self,key)
				local t =
					--BattleOptsByID[ret.ID] or
					--BattleOptsByType[ret.Type] or
					BattleOptsDefaults or
					{
						Priority = 0,
						AttackAllowed = true,
						DefendOnly = false,
						SkillsAllowed = false,
						MinSkillLevel = 1,
						MaxSkillLevel = 5,
						TicksBetweenSkills = 0,
						MaxCastsAgainst = 0,
					}

				return t[key]
			end,
		})

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

		-- Set initial position
		local x,y = GetV(V_POSITION,ret.ID)
		if x ~= -1 then
			-- Hiding?
			if x == 0 and y == 0 then
				ret.Hide = true
			else
				History.Update(ret.X,x)
				History.Update(ret.Y,y)
			end
		end

		-- Setup the expiration timeout for 2.5 seconds...
		--	(it will be updated in Actor.Update)
		ret.ExpireTimeout = RAIL.Timeouts:New(2500,false,Actor.Expire,ret)

		ret[closures] = {
			DistanceTo = {},
			DistancePlot = {},
			BlocksTo = {},
			AngleTo = {},
			AngleFrom = {},
			AnglePlot = {},
		}

		-- Initialize the type
		Actor[actor_key](ret)

		-- Log
		if ID ~= -1 then
			RAIL.Log(0,"Actor class generated for %s.",tostring(ret))
		end

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
		if (self.ID < 100000 or self.ID > 110000000) and
			LIF <= self.Type and self.Type <= VANILMIRTH_H2
		then
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
		-- Don't update the fail-actor
		if self.ID == -1 then
			return self
		end

		-- Check for a type change
		if GetV(V_HOMUNTYPE,self.ID) ~= self[actor_key] then
			-- Pre-log
			local str = tostring(self)

			-- Call the private type changing function
			Actor[actor_key](self)

			-- Log
			RAIL.Log(0,"%s changed type to %s.",str,tostring(self))
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
			-- Get the current target
			local targ = GetV(V_TARGET,self.ID)

			-- Normalize it...
			if targ == 0 then
				targ = -1
			end

			-- Keep a history of it
			History.Update(self.Target,targ)

			-- Tell the other actor that it's being targeted
			if targ ~= -1 then
				Actors[targ]:TargetedBy(self)
			end
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
		if math.abs((self.TargetOf[targeted_time] or 0) - GetTick()) > 50 then
			self.TargetOf = Table:New()
			self.TargetOf[targeted_time] = GetTick()
		end

		self.TargetOf:Insert(actor)
		return self
	end

	-- Clear out memory
	Actor.Expire = function(self)
		-- Log
		RAIL.Log(0,"Clearing history for %s due to timeout.",tostring(self))

		-- Unset any per-actor battle options
		local k,v
		for k,v in pairs(self.BattleOpts) do
			self.BattleOpts[k] = nil
		end

		-- Clear the histories
		History.Clear(self.Motion)
		History.Clear(self.Target)
		History.Clear(self.X)
		History.Clear(self.Y)
	end

	-------------
	-- Support --
	-------------
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
			-- TODO: Update the time? Max(ticks,self.IgnoreTime)?
			return self
		end

		-- Use default ticks if needed
		if type(ticks) ~= "number" then
			-- TODO: This
			ticks = 1000
		end

		-- TODO: Log
		RAIL.Log(0,"%s ignored for %d milliseconds.",tostring(self),ticks)

		self.IgnoreTime = ticks
	end

	-- Estimate Movement Speed (in milliseconds per cell)
	Actor.EstimateMoveSpeed = function(self)
		-- TODO: Detect movement speeds automatically
		--	(from http://forums.roempire.com/archive/index.php/t-137959.html)
		--	0.15 sec per cell at regular speed
		--	0.11 sec per cell w/ agi up
		--	0.06 sec per cell w/ Lif's emergency avoid
		return 150
	end

	--------------------
	-- Battle Options --
	--------------------

	-- RAIL allowed to kill monster?
	Actor.IsAllowed = function(self)
		-- Determine if the monster is allowed at all
		return self.BattleOpts.AttackAllowed or self.BattleOpts.SkillsAllowed
	end

	-- Determine if attacking this actor would be kill-stealing
	Actor.WouldKillSteal = function(self)
		-- Free-for-all monsters are never kill-stealed
		if self.BattleOpts.FreeForAll then
			return false
		end

		-- Check if it's an enemy
		if not self:IsEnemy() then
			return false
		end

		-- Check if this actor is targeting anything
		local targ = self.Target[0]
		if targ ~= -1 then
			-- Owner and self don't count
			if targ == RAIL.Self.ID or targ == RAIL.Owner.ID then
				return false
			end

			local targ = Actors[targ]

			-- Determine if we're supposed to defend friends
			if RAIL.State.DefendFriends and targ:IsFriend() then
				return false
			end

			-- Determine if it's not targeting another enemy
			if not targ:IsEnemey() then

				-- Determine if the target has been updated recently
				if math.abs(targ.LastUpdate - GetTick()) < 50 then
					-- It would be kill stealing
					return true
				end

			end
		end

		-- Check if this actor is the target of anything
		local i
		for i=1,self.TargetOf:Size(),1 do
			targ = self.TargetOf[i]

			-- Determine if the targeter is...
			if
				targ ~= RAIL.Owner and				-- not the owner
				targ ~= RAIL.Self and				-- not ourself
				not targ:IsEnemy() and				-- not an enemy
				not targ:IsFriend() and				-- not a friend
				math.abs(GetTick() - targ.LastUpdate) < 50	-- updated recently
			then
				-- Likely kill-stealing
				return true
			end
		end

		-- TODO: Moving

		-- Default is not kill-steal
		return false
	end



	-- Kite / Attack**
	--	**- based partially on shared table, based partially on homu's current HP?

	--------------------
	-- Utils Wrappers --
	--------------------

	-- The following wrappers are fairly complex, so here are some examples:
	--
	--	RAIL.Owner:DistanceTo(x,y)
	--		Returns the pythagorean distance between owner and (x,y)
	--
	--	RAIL.Owner:DistanceTo(-500)(x,y)
	--		Returns the pythagorean distance between (x,y) and the owner's
	--		estimated position at 500 milliseconds into the future
	--
	--	RAIL.Owner:DistanceTo(RAIL.Self)
	--		Returns the pythagorean distance between owner and homu/merc
	--
	--	RAIL.Owner:DistanceTo(500)(RAIL.Self)
	--		Returns the pythagorean distance between owner's position
	--		500 milliseconds ago, and the homu/merc's position 500 milliseconds ago
	--
	--	RAIL.Owner:DistanceTo(RAIL.Self.X[500],RAIL.Self.Y[500])
	--		Returns the pythagorean distance between owner's current position
	--		and the homu/merc's position 500 milliseconds ago
	--
	--	RAIL.Owner:DistanceTo(-500)(RAIL.Self.X[0],RAIL.Self.Y[0])
	--		Returns the pythagorean distance between owner's estimated position
	--		(500ms into future), and homu/merc's current position.
	--
	-- Remember:
	--	- negative values represent future (estimated)
	--	- positive values represent past (recorded)
	--
	-- NOTE:
	--	Because of the nature of closures, a new function is generated for each
	--	originating actor and for each millisecond value. In effort to reduce
	--	memory bloat, keep arbitrary actors/numbers to a minimum.
	--		

	-- Pythagorean Distance
	Actor.DistanceTo = function(self,a,b)
		-- Check if a specific closure is requested
		if type(a) == "number" and b == nil then

			-- Check if a closure already exists
			if not self[closures].DistanceTo[a] then

				-- Create closure
				self[closures].DistanceTo[a] = function(x,y)				
					-- Main function logic follows

					-- Check if "x" is an actor table
					if RAIL.IsActor(x) then
						y = x.Y[a]
						x = x.X[a]
					end

					return PythagDistance(self.X(a),self.Y(a),x,y)

				end -- function(x,y)

			end -- not self[closures].DistanceTo[a]

			-- Return the requested closure
			return self[closures].DistanceTo[a]
		end

		-- Not requesting specific closure, so use 0
		return Actor.DistanceTo(self,0)(a,b)
	end

	-- Point along line of self and (x,y)
	Actor.DistancePlot = function(self,a,b,c)
		-- Check if a specific closure is requested
		if type(a) == "number" and c == nil then

			-- Check if a closure already exists
			if not self[closures].DistancePlot[a] then

				-- Create closure
				self[closures].DistancePlot[a] = function(x,y,dist_delta)
					-- Main function logic follows

					-- Check if "x" is an actor table
					if RAIL.IsActor(x) then
						dist = y
						y = x.Y[a]
						x = x.X[a]
					end

					-- TODO: finish
					return 0,0

				end -- function(x,y,dist)

			end -- not self[closures].DistancePlot[a]

			-- Return the requested closure
			return self[closures].DistancePlot[a]
		end

		-- Not requesting specific closure, so use 0
		return Actor.DistancePlot(self,0)(a,b,c)
	end

	-- Straight-line Block Distance
	Actor.BlocksTo = function(self,a,b)
		-- Check if a specific closure is requested
		if type(a) == "number" and b == nil then

			-- Check if a closure already exists
			if not self[closures].BlocksTo[a] then

				-- Create closure
				self[closures].BlocksTo[a] = function(x,y)
					-- Main function logic follows

					-- Check if "x" is an actor table
					if RAIL.IsActor(x) then
						y = x.Y[a]
						x = x.X[a]
					end

					return BlockDistance(self.X[a],self.Y[a],x,y)

				end -- function(x,y)

			end -- not self[closures].BlocksTo[a]

			-- Return the requested closure
			return self[closures].BlocksTo[a]
		end

		-- Not requesting specific closure, so use 0
		return Actor.BlocksTo(self,0)(a,b)
	end

	-- Angle from actor to point
	Actor.AngleTo = function(self,a,b)
		-- Check if a specific closure is requested
		if type(a) == "number" and b == nil then

			-- Check if a closure already exists
			if not self[closures].AngleTo[a] then

				-- Create closure
				self[closures].AngleTo[a] = function(x,y)
					-- Main function logic follows

					-- Check if "x" is an actor table
					if RAIL.IsActor(x) then
						y = x.Y[a]
						x = x.X[a]
					end

					return GetAngle(self.X[a],self.Y[a],x,y)
				end -- function(x,y)

			end -- not self[closures].AngleTo[a]

			-- Return the requested closure
			return self[closures].AngleTo[a]
		end

		-- Not requesting specific closure, so use 0
		return Actor.AngleTo(self,0)(a,b)
	end

	-- Angle from point to actor
	Actor.AngleFrom = function(self,a,b)
		-- Check if a specific closure is requested
		if type(a) == "number" and b == nil then

			-- Check if a closure already exists
			if not self[closures].AngleFrom[a] then

				-- Create closure
				self[closures].AngleFrom[a] = function(x,y)
					-- Main function logic follows

					-- Check if "x" is an actor table
					if RAIL.IsActor(x) then
						y = x.Y[a]
						x = x.X[a]
					end

					return GetAngle(x,y,self.X[a],self.Y[a])
				end -- function(x,y)

			end -- not self[closures].AngleFrom[a]

			-- Return the requested closure
			return self[closures].AngleFrom[a]
		end

		-- Not requesting specific closure, so use 0
		return Actor.AngleFrom(self,0)(a,b)
	end

	-- Plot a point on a circle around this actor
	Actor.AnglePlot = function(self,a,b)
		-- Check if a specific closure is requested
		if type(a) == "number" and b == nil then

			-- Check if a closure already exists
			if not self[closures].AnglePlot[a] then

				-- Create closure
				self[closures].AnglePlot[a] = function(angle,radius)
					-- Main function logic follows

					return PlotCircle(self.X[a],self.Y[a],angle,radius)
				end -- function(angle,radius)

			end -- not self[closures].AnglePlot[a]

			-- Return the requested closure
			return self[closures].AnglePlot[a]
		end

		-- Not requesting specific closure, so use 0
		return Actor.AnglePlot(self,0)(a,b)
	end

	------------------
	-- API Wrappers --
	------------------

	-- These are mainly to allow attacks/skills vs. specific monsters to be
	--	hooked in a more efficient manner than hooking Attack() base API

	Actor.Attack = function(self)
		-- Send the attack
		Attack(RAIL.Self.ID,self.ID)

		-- After sending an attack, this actor can never be kill-stealed (until Actor.Expire)
		self.BattleOpts.FreeForAll = true
	end
	Actor.SkillObject = function(self,level,skill_id)
		-- Send the skill
		SkillObject(RAIL.Self.ID,level,skill_id,self.ID)

		-- Increment skill counter
		self.BattleOpts.SkillsAgainst = (self.BattleOpts.SkillsAgainst or 0) + 1

		-- And never see it as kill-stealing
		self.BattleOpts.FreeForAll = true
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

	-- Create Actors[-1], and disable certain features
	Actors[-1].ExpireTimeout[1] = false

	Actors[-1].IsEnemy   = function() return false end
	Actors[-1].IsFriend  = function() return false end
	Actors[-1].IsIgnored = function() return true end
	Actors[-1].IsAllowed = function() return false end

	-- After setting up the Actor class and Actors table,
	--	rework the API to allow Actor inputs
	--local
	-- TODO? Don't think I even want this...
end