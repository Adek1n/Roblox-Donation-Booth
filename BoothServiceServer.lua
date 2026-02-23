local BoothServiceServer = {}
type BoothServiceServer = typeof(BoothServiceServer) &{
	Events:{[string]:any}
}
--[[ SERVICES ]]--
local ReplicatedStorage=game:GetService("ReplicatedStorage")
local ServerStorage=game:GetService("ServerStorage")
local ServerScriptService=game:GetService("ServerScriptService")
local Players=game:GetService("Players")
local MarketplaceService=game:GetService("MarketplaceService")
local HttpService=game:GetService("HttpService")

--[[ MODULES ]]--
local ProfileServiceServer=require(ServerScriptService.Services.ProfileService.ProfileServiceServer)
--[[ PACKAGES ]]--
local Signal=require(ReplicatedStorage.Packages.Signal)
local NetRay=require(ReplicatedStorage.Packages.NetRay)

--[[ CONFIGURATION ]]--
local WAIT_TIMEOUT=10

--[[ CONSTANTS ]]--
local BOOTHS=workspace.Booths
local BINDABLE_FUNCTIONS_CURRENCYSERVICE=ServerStorage.Server.Functions.CurrencyService

--[[ REMOTE EVENTS ]]--
local RemoteEvents:{[string]:any}={
	["ClaimedBooth"]="EMPTY",
	["UnclaimedBooth"]="EMPTY",
	["EditBooth"]="EMPTY",
	["CreateSlots"]="EMPTY",
	["QueryGamepasses"]="EMPTY",
	["InitiatePurchase"]="EMPTY",
}

--[[ EVENTS ]]--
BoothServiceServer.Events={
	["ClaimBooth"]="EMPTY",
}

--[[ VARIABLES ]]--
local Profiles=ProfileServiceServer.Profiles
local PlayerBooths:{{[Player]:Model}}={}
local PlayerGamepasses:{[Player]:{number}}={}
local PendingTransactions:{[number]:Player}={}

--Initiailize the entire module by calling all the setup functions
function BoothServiceServer.init(self:BoothServiceServer)
	self:setupNetworking()
	self:setupEvents()
	self:setupListeners()
	self:setupMarketplaceListeners()
end

function BoothServiceServer.setupNetworking(self:BoothServiceServer)
	--Registers all the events for NetRay Networking
	for eventName,_ in pairs(RemoteEvents) do
		if(string.find(eventName,"Query")) then
			RemoteEvents[eventName]=NetRay:RegisterRequestEvent(eventName)
			continue
		end
		RemoteEvents[eventName]=NetRay:RegisterEvent(eventName)
	end 
end

function BoothServiceServer.setupEvents(self:BoothServiceServer)
	--Creates all the Signal+ events
	for eventName,_ in pairs(self.Events) do
		self.Events[eventName]=Signal()
	end 
end

function BoothServiceServer.setupListeners(self:BoothServiceServer)
	--All the Listeners
	self.Events["ClaimBooth"]:Connect(function(player:Player,booth:Model)
		--Calls the claim booth function
		claimBooth(player,booth)
	end)
	
	RemoteEvents["EditBooth"]:OnEvent(function(player,data)
		if(not data.text) then
			if(data.text is nil just dont bother)
			return
		end
		editBooth(player,data.text)
	end)
	
	RemoteEvents["QueryGamepasses"]:OnRequest(function(player,data)
		--Request function
		local playerQueried=Players:GetPlayerByUserId(data.playerId)
		print(playerQueried,data)
		if(not playerQueried) then
			return
		end
		--Notes down the start time
		local waitStart=os.time()
		--If the player's data is nil waits until WAIT_TIMEOUT if it is still nil at that point it just returns an empty array
		repeat task.wait() until PlayerGamepasses[playerQueried] or (waitStart+WAIT_TIMEOUT<os.time())
		if(not PlayerGamepasses[playerQueried]) then
			return {gamepassIds={}}
		end
		--Otherwise return the gamepasses of the Player
		return {gamepassIds=PlayerGamepasses[playerQueried]}
	end)

	--Is fired the moment a player clicks on a gamepass on a booth wether it suceeds or not
	RemoteEvents["InitiatePurchase"]:OnEvent(function(buyer: Player, data: any)
		local seller=data.seller
		local gamepassId=data.gamepassId
		print(buyer,seller,gamepassId)
		if(not seller or not gamepassId) then
			return
		end
		--It notes down who is the buyer and the seller and if the buyer is the same as seller it returns
		if buyer == seller then return end
		local sellerBooth = PlayerBooths[seller]
		if not sellerBooth then return end

		if not PendingTransactions[buyer.UserId] then
			PendingTransactions[buyer.UserId] = {}
		end
		--Creates a pending transaction
		PendingTransactions[buyer.UserId][tostring(gamepassId)] = seller
	end)
	
	Players.PlayerAdded:Connect(function(player:Player)
		--The moment you spawn immediately attempt to fetch the gamepasses of the player
		task.spawn(function()
			PlayerGamepasses[player]=getGamepasses(player.UserId)
		end)
	end)
	
	Players.PlayerRemoving:Connect(function(player:Player)
		local claimedBooth=getBooth(player)
		if(not claimedBooth) then
			return
		end
		--Unclaim the booth of a leaving player and remove their data in the server
		unclaimBooth(player,claimedBooth)
		PlayerGamepasses[player]=nil
		PendingTransactions[player.UserId] = nil
	end)
end

function BoothServiceServer.setupMarketplaceListeners(self:BoothServiceServer)
	--When gamepasses purchase succeeds
	MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player, gamepassId, wasPurchased)
		local buyerId = player.UserId
		local passIdStr = tostring(gamepassId)

		if not wasPurchased then 
			if PendingTransactions[buyerId] then
				PendingTransactions[buyerId][passIdStr] = nil 
			end
			return 
		end
		
		local seller = PendingTransactions[buyerId] and PendingTransactions[buyerId][passIdStr]

		--Finds the seller in pending transactions

		if not seller then 
			warn("No seller found in PendingTransactions for buyer:", player.Name)
			print("Current Pending for this user:", PendingTransactions[player.UserId])
			return 
		end 

		--Finds the seller profile

		local sellerProfile = Profiles[seller]
		if sellerProfile then
			local success, gamepassInfo = pcall(function()
				return MarketplaceService:GetProductInfoAsync(gamepassId, Enum.InfoType.GamePass)
			end)
			
			if success and gamepassInfo.PriceInRobux then
				print(success,gamepassInfo.PriceInRobux)
				--Adds robux raised to seller and giftbux to the player who bought the gamepass
				BINDABLE_FUNCTIONS_CURRENCYSERVICE.CurrencyIncrement:Invoke(seller,"RobuxRaised",gamepassInfo.PriceInRobux)
				BINDABLE_FUNCTIONS_CURRENCYSERVICE.CurrencyIncrement:Invoke(player,"GiftBux",gamepassInfo.PriceInRobux)
				updateBooth(seller, getBooth(seller))
			end
		end
		--Deletes the pending transaction
		PendingTransactions[buyerId][passIdStr] = nil
	end)
end

--[[ PRIVATE FUNCTIONS ]]--
function claimBooth(player:Player,booth:Model)
	--If already claimed dont bother
	local claimed=booth:FindFirstChild("Claimed")::BoolValue
	if(claimed==true) then
		return
	end
	--If player already has a booth unclaim that first
	if(PlayerBooths[player]) then
		local claimedBooth=PlayerBooths[player]
		unclaimBooth(player,claimedBooth)
	end

	--This just sets the models objectvalues

	local claimUsername=booth:FindFirstChild("ClaimedUserName")::StringValue
	claimUsername.Value=player.Name
	claimed.Value=true
	
	local base=booth:FindFirstChild("Base")::MeshPart
	if(not base) then
		return
	end

	--Edits the surfaceguis to to match the name 

	local unclaimedDisplay=base:FindFirstChild("Unclaimed")::SurfaceGui
	local claimedDisplay=base:FindFirstChild("ClaimedInfoDisplay")::SurfaceGui
	
	local profile=Profiles[player]
	if(not profile) then
		return
	end
	
	if(not PlayerGamepasses[player]) then
		PlayerGamepasses[player]=getGamepasses(player.UserId)
	end

	--Tells the clients to start creating the slots for the gamepasses which they can touch to buy the gamepass
	RemoteEvents["CreateSlots"]:FireAllClients({booth=booth,gamepassIds=PlayerGamepasses[player]})
	
	unclaimedDisplay.Enabled=false
	claimedDisplay.Enabled=true
	claimedDisplay:FindFirstChild("UserName").Text=player.Name
	claimedDisplay:FindFirstChild("UserRaised").Text=profile.Data.RobuxRaised
	
	
	PlayerBooths[player]=booth
	RemoteEvents["ClaimedBooth"]:FireAllClients({
		player=player,
		booth=booth,
	})
end

function getBooth(player:Player):Model?
	--Simple helper function to return the claimed booth
	local claimedBooth=PlayerBooths[player]
	if(not claimedBooth) then
		return nil
	end
	return claimedBooth
end

function unclaimBooth(player:Player,booth:Model)
	local claimed=booth:FindFirstChild("Claimed")::BoolValue
	if(claimed==false) then
		return
	end

	--Clears the object values

	local claimUsername=booth:FindFirstChild("ClaimedUserName")::StringValue
	claimUsername.Value=""
	claimed.Value=false

	local base=booth:FindFirstChild("Base")::MeshPart
	if(not base) then
		return
	end
	local unclaimedDisplay=base:FindFirstChild("Unclaimed")::SurfaceGui
	local claimedDisplay=base:FindFirstChild("ClaimedInfoDisplay")::SurfaceGui

	--Shows the unclaimed the unclaimed display

	unclaimedDisplay.Enabled=true
	claimedDisplay.Enabled=false
	claimedDisplay:FindFirstChild("UserName").Text=""
	claimedDisplay:FindFirstChild("UserRaised").Text=""

	local signPart=booth:FindFirstChild("SignPart")::BasePart
	if(not signPart) then
		return
	end
	local surfaceGui=signPart:FindFirstChild("SurfaceGui")::SurfaceGui
	if(not surfaceGui) then
		return	
	end
	local boothText=surfaceGui:FindFirstChild("UserMessage")::TextLabel
	if(not boothText) then
		return	
	end

	--Reverts to default text
	
	boothText.Text="your text here"

	PlayerBooths[player]=nil
	RemoteEvents["UnclaimedBooth"]:FireAllClients({
		player=player,
		booth=booth,
	})
end

function editBooth(player:Player,text:string)
	local booth=getBooth(player)
	if(not booth) then
		return
	end
	--Finds the textlabel
	local signPart=booth:FindFirstChild("SignPart")::BasePart
	if(not signPart) then
		return
	end
	local surfaceGui=signPart:FindFirstChild("SurfaceGui")::SurfaceGui
	if(not surfaceGui) then
		return	
	end
	local boothText=surfaceGui:FindFirstChild("UserMessage")::TextLabel
	if(not boothText) then
		return	
	end
	--Edit the text
	boothText.Text=text
end

function updateBooth(player:Player,booth:Model)
	if(not player or not booth) then
		return
	end
	local base=booth:FindFirstChild("Base")::MeshPart
	if(not base) then
		return
	end
	local profile=Profiles[player]
	if(not profile) then
		return
	end
	--Change the  user raised value when someone buys a gamepass from them

	local claimedDisplay=base:FindFirstChild("ClaimedInfoDisplay")::SurfaceGui
	
	claimedDisplay:FindFirstChild("UserRaised").Text=profile.Data.RobuxRaised
end

function getGamepasses(userId):{string}
    local gamepassIds = {}

	--Uses HTTP Service and roproxy to first fetch the user's created games

    local gamesUrl = "https://games.roproxy.com/v2/users/" .. userId .. "/games?accessFilter=2&limit=50&sortOrder=Asc"
    
    local success, response = pcall(function()
        return HttpService:GetAsync(gamesUrl)
    end)
    
    if success then
        local data = HttpService:JSONDecode(response)
        if data and data.data then
			--Loops through all the public games the user has created
            for _, gameInfo in ipairs(data.data) do
                local universeId = gameInfo.id
                local passUrl = "https://apis.roproxy.com/game-passes/v1/universes/" .. universeId .. "/game-passes"
                
                local passSuccess, passResponse = pcall(function()
                    return HttpService:GetAsync(passUrl)
                end)

				--Gets the gamepasses of this game
                
                if passSuccess then
                    local passData = HttpService:JSONDecode(passResponse)
                    
                    local list = passData.gamePasses or passData.data

					--Inserts the individual gamepass into the table

                    if list then
                        for _, pass in ipairs(list) do
                            if pass.isForSale == true or pass.isForSale == nil then
								table.insert(gamepassIds, tostring(pass.id))
                            end
                        end
                    end
                end

				--Wait a bit so that you dont hit the limit 

                task.wait(0.2)
            end
        end
    end

	--Return the gamepasses
    return gamepassIds
end

return BoothServiceServer
