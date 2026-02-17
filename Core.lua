local ADDON_NAME, APC = ...
APC = APC or _G.AuctionatorPriceCheckNS or {}
_G.AuctionatorPriceCheckNS = APC
local CALLER_ID = "Auctionator_PriceCheck"
local ADDON_MSG_PREFIX = "APCPC1"
local COORDINATION_WINDOW_SECONDS = 0.45
local NativeSendChatMessage = C_ChatInfo and C_ChatInfo.SendChatMessage

local Trim = APC.Trim
local NormalizeSearchText = APC.NormalizeSearchText
local SenderName = APC.SenderName
local FormatPrice = APC.FormatPrice
local FormatPricePlain = APC.FormatPricePlain
local DisplayLabelForItem = APC.DisplayLabelForItem
local GetSavedNameForItemID = APC.GetSavedNameForItemID
local SaveNameForItemID = APC.SaveNameForItemID
local RequestItemNameLoad = function(itemID, state)
  APC.RequestItemNameLoad(state, itemID)
end

if type(NativeSendChatMessage) == "function" and type(debug) == "table" and type(debug.getinfo) == "function" then
  local info = debug.getinfo(NativeSendChatMessage, "S")
  if not info or info.what ~= "C" then
    NativeSendChatMessage = nil
  end
end

local function HasSafeAutoSendPath()
  if type(NativeSendChatMessage) ~= "function" then
    return false, "native SendChatMessage unavailable"
  end

  if C_ChatInfo and type(C_ChatInfo.SendChatMessage) == "function" and type(debug) == "table" and type(debug.getinfo) == "function" then
    local info = debug.getinfo(C_ChatInfo.SendChatMessage, "S")
    if info and info.what ~= "C" then
      return false, "chat API is hooked by another addon"
    end
  end

  local IsAddOnLoaded = C_AddOns and C_AddOns.IsAddOnLoaded or IsAddOnLoaded
  if type(IsAddOnLoaded) == "function" and IsAddOnLoaded("OwoSpeak") then
    return false, "OwoSpeak is loaded and taints chat send"
  end

  return true, nil
end

local PriceCheck = {
  results = {},
  itemCatalog = {},
  itemCatalogBuilt = false,
  itemDataRequestQueue = {},
  itemDataRequested = {},
  itemDataWarmupTicker = nil,
  itemDataWarmupNoticeShown = false,
  pendingCatalogItemIDs = {},
  catalogUpdateScheduled = false,
  scanHooksRegistered = false,
  scanHookRetryTicker = nil,
  scanEventListener = nil,
  decodedRealmCache = {},
  searchToken = 0,
  sendBlocked = false,
  sendBlockedTypes = {},
  pendingSends = {},
  combatBlockedNoticeShown = false,
  coordinatedRequests = {},
  addonPrefixReady = false,
  frame = nil,
  scrollFrame = nil,
  searchBox = nil,
  chatEvents = {
    "CHAT_MSG_SAY",
    "CHAT_MSG_YELL",
    "CHAT_MSG_GUILD",
    "CHAT_MSG_PARTY",
    "CHAT_MSG_PARTY_LEADER",
    "CHAT_MSG_RAID",
    "CHAT_MSG_RAID_LEADER",
    "CHAT_MSG_INSTANCE_CHAT",
    "CHAT_MSG_INSTANCE_CHAT_LEADER",
    "CHAT_MSG_CHANNEL",
  },
}

local function DebugLog(tag, text, fields)
  -- Intentionally left as a no-op in release builds.
end

local function DecodeCBORString(raw)
  if type(raw) ~= "string" then
    return nil
  end

  if C_EncodingUtil and C_EncodingUtil.DeserializeCBOR then
    local ok, data = pcall(C_EncodingUtil.DeserializeCBOR, raw)
    if ok and type(data) == "table" then
      return data
    end
  end

  if type(LibStub) == "function" then
    local lib = LibStub("LibCBOR-1.0", true)
    if lib and type(lib.Deserialize) == "function" then
      local ok, data = pcall(lib.Deserialize, lib, raw)
      if ok and type(data) == "table" then
        return data
      end
    end
  end

  return nil
end

local function GetRealmDataForKey(realmKey)
  if PriceCheck.decodedRealmCache[realmKey] then
    return PriceCheck.decodedRealmCache[realmKey]
  end

  if type(AUCTIONATOR_PRICE_DATABASE) ~= "table" then
    return nil
  end

  local raw = AUCTIONATOR_PRICE_DATABASE[realmKey]
  if type(raw) == "table" then
    PriceCheck.decodedRealmCache[realmKey] = raw
    return raw
  end

  if type(raw) == "string" then
    local decoded = DecodeCBORString(raw)
    if type(decoded) == "table" then
      PriceCheck.decodedRealmCache[realmKey] = decoded
      return decoded
    end
  end

  return nil
end

local function IterateAllRealmDatabases(callback)
  if type(AUCTIONATOR_PRICE_DATABASE) ~= "table" then
    return
  end

  local realmKeys = {}
  for realmKey, _ in pairs(AUCTIONATOR_PRICE_DATABASE) do
    table.insert(realmKeys, realmKey)
  end
  table.sort(realmKeys)

  for _, realmKey in ipairs(realmKeys) do
    if realmKey ~= "__dbversion" then
      local realmData = GetRealmDataForKey(realmKey)
      if type(realmData) == "table" then
        callback(realmKey, realmData)
      end
    end
  end
end

local function LastSeenTimestampForKey(dbKey)
  local entry = nil
  if type(Auctionator) == "table" and type(Auctionator.Database) == "table" then
    local db = Auctionator.Database.db
    if type(db) == "table" then
      entry = db[dbKey]
    end
  end

  if type(entry) ~= "table" or type(entry.h) ~= "table" then
    return nil
  end

  local newest = nil
  for dayKey in pairs(entry.h) do
    local day = tonumber(dayKey)
    if day and (newest == nil or day > newest) then
      newest = day
    end
  end

  if newest == nil or type(Auctionator.Constants) ~= "table" or type(Auctionator.Constants.SCAN_DAY_0) ~= "number" then
    return nil
  end

  return Auctionator.Constants.SCAN_DAY_0 + (newest * 86400)
end

local function ComputeAgeDaysFromTimestamp(timestamp)
  if type(timestamp) ~= "number" then
    return nil
  end
  return math.floor((time() - timestamp) / 86400)
end

local function FormatAgeAgo(lastSeenTs, ageDays)
  if type(lastSeenTs) == "number" then
    local elapsed = math.max(0, time() - lastSeenTs)
    local days = math.floor(elapsed / 86400)
    local hours = math.floor((elapsed % 86400) / 3600)
    local minutes = math.floor((elapsed % 3600) / 60)
    return string.format("%dd %dh %dm ago", days, hours, minutes)
  end

  if type(ageDays) == "number" then
    return string.format("%dd 0h 0m ago", ageDays)
  end

  return "unknown age"
end

local ShowSearchMatches
local RenderStoredResults
local ResolveItem
local LookupAuctionatorInfo
local SendPublicChatMessage
local ExecuteLookup
local TryGetItemIDFromLink

local function IsGroupCoordinatedChat(chatType)
  return chatType == "GUILD" or chatType == "PARTY"
end

local function GetFullPlayerName()
  if type(UnitFullName) == "function" then
    local name, realm = UnitFullName("player")
    if type(name) == "string" and name ~= "" then
      if type(realm) == "string" and realm ~= "" then
        return name .. "-" .. realm
      end
      return name
    end
  end
  return UnitName("player") or "Unknown"
end

local function NormalizePlayerKey(name)
  return tostring(name or ""):lower()
end

local function HashString(text)
  local hash = 5381
  for i = 1, #text do
    hash = ((hash * 33) + text:byte(i)) % 2147483647
  end
  return hash
end

local function BuildCoordinationRequestID(query, sender, chatType, channelTarget)
  local bucket = math.floor(((GetServerTime and GetServerTime()) or time()) / 2)
  local seed = table.concat({
    tostring(sender or ""),
    NormalizeSearchText(query),
    tostring(chatType or ""),
    tostring(channelTarget or ""),
    tostring(bucket),
  }, "|")
  return tostring(HashString(seed))
end

local function TryResolveQuickItemID(query)
  local trimmed = Trim(query)
  if trimmed == "" then
    return nil
  end

  local itemID = tonumber(trimmed)
  if itemID then
    return itemID
  end

  local explicitLink = trimmed:match("(item:[^%s]+)")
  if explicitLink then
    itemID = TryGetItemIDFromLink(explicitLink)
    if itemID then
      return itemID
    end
  end

  local _, itemLink = GetItemInfo(trimmed)
  return TryGetItemIDFromLink(itemLink)
end

local function ComputeQueryStalenessMinutes(query)
  local itemID = TryResolveQuickItemID(query)
  if not itemID then
    return 2147483647
  end

  if type(Auctionator) == "table" and type(Auctionator.API) == "table" and type(Auctionator.API.v1) == "table" and type(Auctionator.API.v1.GetAuctionAgeByItemID) == "function" then
    local ageDays = Auctionator.API.v1.GetAuctionAgeByItemID(CALLER_ID, itemID)
    if type(ageDays) == "number" then
      return math.max(0, ageDays * 1440)
    end
  end

  local lastSeenTs = LastSeenTimestampForKey(tostring(itemID))
  if type(lastSeenTs) == "number" then
    return math.max(0, math.floor((time() - lastSeenTs) / 60))
  end

  return 2147483647
end

local function IsCandidateBetter(candidate, best)
  if not best then
    return true
  end

  if candidate.staleMinutes ~= best.staleMinutes then
    return candidate.staleMinutes < best.staleMinutes
  end

  return candidate.senderKey < best.senderKey
end

local function ParseCoordinationBid(message)
  if type(message) ~= "string" then
    return nil
  end

  local requestID, chatType, channelToken, staleText = message:match("^BID\t([^\t]+)\t([^\t]+)\t([^\t]*)\t([^\t]+)$")
  if not requestID then
    return nil
  end

  local staleMinutes = tonumber(staleText)
  if type(staleMinutes) ~= "number" then
    return nil
  end

  return requestID, chatType, channelToken, staleMinutes
end

local function BroadcastCoordinationBid(requestID, chatType, channelTarget, staleMinutes)
  if not (C_ChatInfo and type(C_ChatInfo.SendAddonMessage) == "function" and PriceCheck.addonPrefixReady) then
    return
  end

  local payload = string.format("BID\t%s\t%s\t%s\t%d", requestID, tostring(chatType or ""), tostring(channelTarget or ""), staleMinutes)
  local ok = pcall(C_ChatInfo.SendAddonMessage, ADDON_MSG_PREFIX, payload, chatType, channelTarget)
  DebugLog("COORD", "broadcast bid", { ok = ok, requestID = requestID, chatType = chatType, staleMinutes = staleMinutes })
end

local function FinalizeCoordinatedLookup(requestID)
  local request = PriceCheck.coordinatedRequests[requestID]
  if not request then
    return
  end
  PriceCheck.coordinatedRequests[requestID] = nil

  if not request.bestCandidate then
    ExecuteLookup(request.query, request.source, request.sender, function(replyText)
      SendPublicChatMessage(replyText, request.chatType, request.channelTarget)
    end)
    return
  end

  if request.bestCandidate.senderKey ~= request.selfSenderKey then
    DebugLog("COORD", "skipping reply; fresher peer won", {
      requestID = requestID,
      winner = request.bestCandidate.sender,
      staleMinutes = request.bestCandidate.staleMinutes,
    })
    return
  end

  DebugLog("COORD", "self elected to reply", { requestID = requestID, staleMinutes = request.bestCandidate.staleMinutes })
  ExecuteLookup(request.query, request.source, request.sender, function(replyText)
    SendPublicChatMessage(replyText, request.chatType, request.channelTarget)
  end)
end

local function StartCoordinatedLookup(query, source, sender, chatType, channelTarget)
  if not IsGroupCoordinatedChat(chatType) then
    ExecuteLookup(query, source, sender, function(replyText)
      SendPublicChatMessage(replyText, chatType, channelTarget)
    end)
    return
  end

  if not (PriceCheck.addonPrefixReady and C_ChatInfo and type(C_ChatInfo.SendAddonMessage) == "function" and type(C_Timer) == "table" and type(C_Timer.After) == "function") then
    DebugLog("COORD", "coordination unavailable; fallback immediate", { chatType = chatType })
    ExecuteLookup(query, source, sender, function(replyText)
      SendPublicChatMessage(replyText, chatType, channelTarget)
    end)
    return
  end

  local requestID = BuildCoordinationRequestID(query, sender, chatType, channelTarget)
  if PriceCheck.coordinatedRequests[requestID] then
    return
  end

  local selfSender = GetFullPlayerName()
  local selfCandidate = {
    sender = selfSender,
    senderKey = NormalizePlayerKey(selfSender),
    staleMinutes = ComputeQueryStalenessMinutes(query),
  }

  PriceCheck.coordinatedRequests[requestID] = {
    requestID = requestID,
    query = query,
    source = source,
    sender = sender,
    chatType = chatType,
    channelTarget = channelTarget,
    selfSenderKey = selfCandidate.senderKey,
    bestCandidate = selfCandidate,
  }

  BroadcastCoordinationBid(requestID, chatType, channelTarget, selfCandidate.staleMinutes)
  C_Timer.After(COORDINATION_WINDOW_SECONDS, function()
    FinalizeCoordinatedLookup(requestID)
  end)
end

local function InvalidateLookupCaches(reason)
  PriceCheck.itemCatalogBuilt = false
  PriceCheck.itemCatalog = {}
  PriceCheck.decodedRealmCache = {}
  PriceCheck.itemDataRequestQueue = {}
  PriceCheck.itemDataRequested = {}
  PriceCheck.pendingCatalogItemIDs = {}
  PriceCheck.catalogUpdateScheduled = false
  PriceCheck.itemDataWarmupNoticeShown = false
  DebugLog("CACHE", "lookup caches invalidated", { reason = reason or "unknown" })

  if PriceCheck.frame and PriceCheck.frame:IsShown() and PriceCheck.searchBox then
    local text = PriceCheck.searchBox:GetText() or ""
    if #Trim(text) >= 3 then
      PriceCheck.searchToken = PriceCheck.searchToken + 1
      ShowSearchMatches(text)
    else
      RenderStoredResults()
    end
  end
end

local function TryRegisterAuctionatorScanHooks()
  if PriceCheck.scanHooksRegistered then
    return true
  end

  if type(Auctionator) ~= "table" or type(Auctionator.EventBus) ~= "table" or type(Auctionator.EventBus.Register) ~= "function" then
    return false
  end

  local events = {}
  if type(Auctionator.FullScan) == "table" and type(Auctionator.FullScan.Events) == "table" then
    if type(Auctionator.FullScan.Events.ScanComplete) == "string" then
      table.insert(events, Auctionator.FullScan.Events.ScanComplete)
    end
  end
  if type(Auctionator.IncrementalScan) == "table" and type(Auctionator.IncrementalScan.Events) == "table" then
    if type(Auctionator.IncrementalScan.Events.ScanComplete) == "string" then
      table.insert(events, Auctionator.IncrementalScan.Events.ScanComplete)
    end
  end

  if #events == 0 then
    return false
  end

  local listener = {
    ReceiveEvent = function(_, eventName)
      DebugLog("EVENT", "auctionator scan event", { event = eventName })
      InvalidateLookupCaches("scan_event:" .. tostring(eventName))
    end
  }

  local ok = pcall(function()
    Auctionator.EventBus:Register(listener, events)
  end)
  if not ok then
    return false
  end

  PriceCheck.scanEventListener = listener
  PriceCheck.scanHooksRegistered = true
  DebugLog("INIT", "registered Auctionator scan hooks", { count = #events })
  return true
end

local function EnsureAuctionatorScanHooks()
  if TryRegisterAuctionatorScanHooks() then
    if PriceCheck.scanHookRetryTicker then
      PriceCheck.scanHookRetryTicker:Cancel()
      PriceCheck.scanHookRetryTicker = nil
    end
    return
  end

  if PriceCheck.scanHookRetryTicker ~= nil or type(C_Timer) ~= "table" or type(C_Timer.NewTicker) ~= "function" then
    return
  end

  local attempts = 0
  PriceCheck.scanHookRetryTicker = C_Timer.NewTicker(2, function()
    attempts = attempts + 1
    if TryRegisterAuctionatorScanHooks() or attempts >= 30 then
      PriceCheck.scanHookRetryTicker:Cancel()
      PriceCheck.scanHookRetryTicker = nil
      if not PriceCheck.scanHooksRegistered then
        DebugLog("INIT", "scan hook registration timed out")
      end
    end
  end)
end

local function ScheduleCatalogIncrementalUpdate()
  if PriceCheck.catalogUpdateScheduled then
    return
  end
  PriceCheck.catalogUpdateScheduled = true
  DebugLog("CATALOG", "incremental update scheduled", { pending = 0 })

  C_Timer.After(0.12, function()
    PriceCheck.catalogUpdateScheduled = false
    if not PriceCheck.itemCatalogBuilt then
      DebugLog("CATALOG", "incremental skipped; catalog not built yet")
      return
    end

    local pendingCount = 0
    for _ in pairs(PriceCheck.pendingCatalogItemIDs) do
      pendingCount = pendingCount + 1
    end
    if pendingCount == 0 then
      return
    end

    local byItemID = {}
    for _, item in ipairs(PriceCheck.itemCatalog) do
      byItemID[item.itemID] = true
    end

    local added = 0
    for itemID in pairs(PriceCheck.pendingCatalogItemIDs) do
      PriceCheck.pendingCatalogItemIDs[itemID] = nil
      if not byItemID[itemID] then
        local itemName, itemLink = GetItemInfo(itemID)
        if itemName then
          local dbKey = tostring(itemID)
          local info = LookupFreshestAcrossAllRealms(dbKey)
          if info and info.price then
            table.insert(PriceCheck.itemCatalog, {
              itemID = itemID,
              itemName = itemName,
              itemNameLower = itemName:lower(),
              itemNameNormalized = NormalizeSearchText(itemName),
              itemLink = itemLink,
              dbKey = dbKey,
              price = info.price,
              lastSeenTs = info.lastSeenTs,
              ageDays = info.ageDays,
            })
            byItemID[itemID] = true
            added = added + 1
          end
        end
      end
    end

    if added > 0 then
      table.sort(PriceCheck.itemCatalog, function(a, b)
        return a.itemNameLower < b.itemNameLower
      end)
      DebugLog("CATALOG", "incremental applied", { added = added, size = #PriceCheck.itemCatalog })

      if PriceCheck.frame and PriceCheck.frame:IsShown() and PriceCheck.searchBox then
        local text = PriceCheck.searchBox:GetText() or ""
        if #Trim(text) >= 3 then
          PriceCheck.searchToken = PriceCheck.searchToken + 1
          ShowSearchMatches(text)
        end
      end
    else
      DebugLog("CATALOG", "incremental no-op", { pending = pendingCount })
    end
  end)
end

local function EnsureItemDataWarmupRunning()
  if PriceCheck.itemDataWarmupTicker ~= nil then
    return
  end

  if type(C_Timer) ~= "table" or type(C_Timer.NewTicker) ~= "function" then
    return
  end

  PriceCheck.itemDataWarmupTicker = C_Timer.NewTicker(0.05, function()
    local sent = 0
    while #PriceCheck.itemDataRequestQueue > 0 and sent < 20 do
      local itemID = table.remove(PriceCheck.itemDataRequestQueue)
      if type(itemID) == "number" and PriceCheck.itemDataRequested[itemID] == "queued" and type(C_Item) == "table" and type(C_Item.RequestLoadItemDataByID) == "function" then
        PriceCheck.itemDataRequested[itemID] = true
        C_Item.RequestLoadItemDataByID(itemID)
        DebugLog("CACHE", "request item data", { itemID = itemID, queue = #PriceCheck.itemDataRequestQueue })
      end
      sent = sent + 1
    end

    if #PriceCheck.itemDataRequestQueue == 0 then
      PriceCheck.itemDataWarmupTicker:Cancel()
      PriceCheck.itemDataWarmupTicker = nil
      DebugLog("CACHE", "item data warmup complete")
    end
  end)
  DebugLog("CACHE", "item data warmup started", { queued = #PriceCheck.itemDataRequestQueue })
end

local function EntryToPriceAndTimestamp(entry)
  if type(entry) == "string" then
    entry = DecodeCBORString(entry)
  end

  if type(entry) ~= "table" or type(entry.h) ~= "table" or type(entry.m) ~= "number" then
    return nil, nil
  end

  local newest = nil
  for dayKey in pairs(entry.h) do
    local day = tonumber(dayKey)
    if day and (newest == nil or day > newest) then
      newest = day
    end
  end

  if newest == nil or type(Auctionator) ~= "table" or type(Auctionator.Constants) ~= "table" then
    return entry.m, nil
  end

  return entry.m, (Auctionator.Constants.SCAN_DAY_0 + newest * 86400)
end

local function ExtractItemIDFromDBKey(dbKey)
  if type(dbKey) ~= "string" then
    return nil
  end

  local direct = tonumber(dbKey)
  if direct then
    return direct
  end

  local gearItemID = tonumber(dbKey:match("^g:(%d+):"))
  if gearItemID then
    return gearItemID
  end

  local randGearItemID = tonumber(dbKey:match("^gr:(%d+):"))
  if randGearItemID then
    return randGearItemID
  end

  return nil
end

local function LookupFreshestAcrossAllRealms(dbKey)
  local best = nil
  local matchedRealms = 0
  IterateAllRealmDatabases(function(realmKey, realmData)
    local price, ts = EntryToPriceAndTimestamp(realmData[dbKey])
    if not price then
      return
    end
    matchedRealms = matchedRealms + 1

    if best == nil then
      best = { price = price, lastSeenTs = ts, realmKey = realmKey }
      return
    end

    local bestTs = best.lastSeenTs or 0
    local tsValue = ts or 0
    if tsValue > bestTs or (tsValue == bestTs and tostring(realmKey) < tostring(best.realmKey)) then
      best = { price = price, lastSeenTs = ts, realmKey = realmKey }
    end
  end)

  if best then
    best.ageDays = ComputeAgeDaysFromTimestamp(best.lastSeenTs)
  end
  DebugLog("DB", "lookup freshest realms", { dbKey = dbKey, found = best ~= nil, matchedRealms = matchedRealms, realm = best and best.realmKey })
  return best
end

local function BuildItemCatalog()
  if PriceCheck.itemCatalogBuilt then
    DebugLog("CATALOG", "build skipped (already built)", { size = #PriceCheck.itemCatalog })
    return
  end

  PriceCheck.itemCatalog = {}
  local merged = {}
  local scannedKeys = 0
  local queuedLoads = 0
  local mergedCount = 0

  IterateAllRealmDatabases(function(_, realmData)
    for dbKey, entry in pairs(realmData) do
      scannedKeys = scannedKeys + 1
      local itemID = ExtractItemIDFromDBKey(dbKey)
      if itemID then
        local price, lastSeenTs = EntryToPriceAndTimestamp(entry)
        if price then
          local mergedKey = tostring(itemID)
          local current = merged[mergedKey]
          local currentTs = current and current.lastSeenTs or 0
          local newTs = lastSeenTs or 0
          local replace = false
          if current == nil or newTs > currentTs then
            replace = true
          elseif current and newTs == currentTs then
            local currentNumeric = tonumber(current.dbKey) ~= nil
            local newNumeric = tonumber(dbKey) ~= nil
            if newNumeric and not currentNumeric then
              replace = true
            elseif newNumeric == currentNumeric and tostring(dbKey) < tostring(current.dbKey) then
              replace = true
            end
          end

          if replace then
            if current == nil then
              mergedCount = mergedCount + 1
            end
            merged[mergedKey] = { itemID = itemID, dbKey = dbKey, price = price, lastSeenTs = lastSeenTs }
          end
        end
      end
    end
  end)

  for _, row in pairs(merged) do
    local itemName, itemLink = GetItemInfo(row.itemID)
    if not itemName then
      itemName = GetSavedNameForItemID(row.itemID)
    end

    if itemName then
      SaveNameForItemID(row.itemID, itemName)
      table.insert(PriceCheck.itemCatalog, {
        itemID = row.itemID,
        itemName = itemName,
        itemNameLower = itemName:lower(),
        itemNameNormalized = NormalizeSearchText(itemName),
        itemLink = itemLink,
        dbKey = row.dbKey,
        price = row.price,
        lastSeenTs = row.lastSeenTs,
        ageDays = ComputeAgeDaysFromTimestamp(row.lastSeenTs),
      })
    elseif not PriceCheck.itemDataRequested[row.itemID] then
      PriceCheck.itemDataRequested[row.itemID] = "queued"
      table.insert(PriceCheck.itemDataRequestQueue, row.itemID)
      queuedLoads = queuedLoads + 1
    end
  end

  table.sort(PriceCheck.itemCatalog, function(a, b)
    if a.itemNameLower == b.itemNameLower then
      return a.itemID < b.itemID
    end
    return a.itemNameLower < b.itemNameLower
  end)

  PriceCheck.itemCatalogBuilt = true
  if queuedLoads > 0 then
    EnsureItemDataWarmupRunning()
  end
  DebugLog("CATALOG", "build complete", {
    catalogSize = #PriceCheck.itemCatalog,
    merged = mergedCount,
    queuedLoads = queuedLoads,
    scannedKeys = scannedKeys,
  })
end

local function IsAuctionatorPriceDatabaseReady()
  if type(AUCTIONATOR_PRICE_DATABASE) ~= "table" then
    return false
  end

  for realmKey in pairs(AUCTIONATOR_PRICE_DATABASE) do
    if realmKey ~= "__dbversion" then
      return true
    end
  end

  return false
end

local function PrewarmCatalogAtLoad()
  if PriceCheck.itemCatalogBuilt then
    return
  end

  local attempts = 0
  local maxAttempts = 20

  local function attemptBuild()
    if PriceCheck.itemCatalogBuilt then
      return
    end

    attempts = attempts + 1
    if IsAuctionatorPriceDatabaseReady() or attempts >= maxAttempts then
      DebugLog("CATALOG", "prewarm attempt", { attempts = attempts, dbReady = IsAuctionatorPriceDatabaseReady() })
      BuildItemCatalog()
      return
    end

    if type(C_Timer) == "table" and type(C_Timer.After) == "function" then
      C_Timer.After(0.25, attemptBuild)
    else
      BuildItemCatalog()
    end
  end

  attemptBuild()
end

local FindCatalogMatchesByName

local function FindExactCatalogMatchesByName(query, limit)
  BuildItemCatalog()

  local needle = Trim(query):lower()
  local needleNormalized = NormalizeSearchText(query)
  if needle == "" then
    return {}
  end

  local exact = {}
  for _, item in ipairs(PriceCheck.itemCatalog) do
    if item.itemNameLower == needle or (needleNormalized ~= "" and item.itemNameNormalized == needleNormalized) then
      table.insert(exact, item)
      if limit and #exact >= limit then
        break
      end
    end
  end
  return exact
end

local function FindCatalogItemByName(query)
  local exact = FindExactCatalogMatchesByName(query, 2)
  if #exact == 1 then
    return exact[1]
  elseif #exact > 1 then
    return nil
  end

  local partial = FindCatalogMatchesByName(query, 1)
  return partial[1]
end

FindCatalogMatchesByName = function(query, limit)
  BuildItemCatalog()

  local needle = Trim(query):lower()
  local needleNormalized = NormalizeSearchText(query)
  if needle == "" then
    DebugLog("SEARCH", "blank query")
    return {}
  end

  local results = {}
  local maxResults = tonumber(limit)
  local seen = {}

  local function addMatches(predicate)
    for _, item in ipairs(PriceCheck.itemCatalog) do
      if not seen[item.dbKey] and predicate(item) then
        seen[item.dbKey] = true
        table.insert(results, item)
        if maxResults and #results >= maxResults then
          return true
        end
      end
    end
    return false
  end

  if addMatches(function(item) return item.itemNameLower == needle end) then
    return results
  end
  if needleNormalized ~= "" and addMatches(function(item) return item.itemNameNormalized == needleNormalized end) then
    return results
  end
  if addMatches(function(item) return item.itemNameLower:sub(1, #needle) == needle end) then
    return results
  end
  if needleNormalized ~= "" and addMatches(function(item) return item.itemNameNormalized:sub(1, #needleNormalized) == needleNormalized end) then
    return results
  end
  if addMatches(function(item) return item.itemNameLower:find(needle, 1, true) ~= nil end) then
    return results
  end
  if needleNormalized ~= "" then
    addMatches(function(item) return item.itemNameNormalized:find(needleNormalized, 1, true) ~= nil end)
  end

  DebugLog("SEARCH", "catalog matches", { query = query, results = #results, limit = limit, catalogSize = #PriceCheck.itemCatalog })
  return results
end

TryGetItemIDFromLink = function(itemLink)
  if not itemLink then
    return nil
  end
  local itemID = GetItemInfoInstant(itemLink)
  if type(itemID) == "number" then
    return itemID
  end
  itemID = tonumber(itemLink:match("item:(%d+)"))
  return itemID
end

ResolveItem = function(query)
  query = Trim(query)
  DebugLog("RESOLVE", "start", { query = query })
  if query == "" then
    DebugLog("RESOLVE", "empty query")
    return nil, "missing item name"
  end

  local itemID = tonumber(query)
  if itemID then
    local itemName, itemLink = GetItemInfo(itemID)
    if not itemName then
      itemName = GetSavedNameForItemID(itemID)
      RequestItemNameLoad(itemID, PriceCheck)
    else
      SaveNameForItemID(itemID, itemName)
    end
    return {
      query = query,
      itemID = itemID,
      itemName = itemName or ("item:" .. itemID),
      itemLink = itemLink or ("item:" .. itemID),
      dbKey = tostring(itemID),
    }
  end

  local explicitLink = query:match("(item:[^%s]+)")
  if explicitLink then
    itemID = TryGetItemIDFromLink(explicitLink)
    local itemName, itemLink = GetItemInfo(explicitLink)
    if not itemID then
      itemID = TryGetItemIDFromLink(itemLink)
    end
    if itemID then
      if not itemName then
        itemName = GetSavedNameForItemID(itemID)
        RequestItemNameLoad(itemID, PriceCheck)
      else
        SaveNameForItemID(itemID, itemName)
      end
      DebugLog("RESOLVE", "resolved from explicit link", { query = query, itemID = itemID })
      return {
        query = query,
        itemID = itemID,
        itemName = itemName or query,
        itemLink = itemLink or ("item:" .. itemID),
        dbKey = tostring(itemID),
      }
    end
  end

  local exactMatches = FindExactCatalogMatchesByName(query, 3)
  if #exactMatches > 1 then
    DebugLog("RESOLVE", "multiple exact catalog matches", { query = query, count = #exactMatches })
    return nil, "multiple exact matches found"
  elseif #exactMatches == 1 then
    local exact = exactMatches[1]
    DebugLog("RESOLVE", "resolved from exact catalog match", { query = query, itemID = exact.itemID, dbKey = exact.dbKey })
    return {
      query = query,
      itemID = exact.itemID,
      itemName = exact.itemName,
      itemLink = exact.itemLink,
      dbKey = exact.dbKey,
    }
  end

  local itemName, itemLink = GetItemInfo(query)
  itemID = TryGetItemIDFromLink(itemLink)
  if itemID then
    if itemName then
      SaveNameForItemID(itemID, itemName)
    else
      itemName = GetSavedNameForItemID(itemID)
      RequestItemNameLoad(itemID, PriceCheck)
    end
    local dbKey = tostring(itemID)
    local hasAuctionData = LookupFreshestAcrossAllRealms(dbKey) ~= nil
    if hasAuctionData then
      DebugLog("RESOLVE", "resolved from item name API", { query = query, itemID = itemID, itemName = itemName })
      return {
        query = query,
        itemID = itemID,
        itemName = itemName or query,
        itemLink = itemLink,
        dbKey = dbKey,
      }
    end
    DebugLog("RESOLVE", "item name API candidate had no data", { query = query, itemID = itemID, itemName = itemName })
  end

  local catalogItem = FindCatalogItemByName(query)
  if catalogItem then
    DebugLog("RESOLVE", "resolved from catalog", { query = query, itemID = catalogItem.itemID, dbKey = catalogItem.dbKey })
    return {
      query = query,
      itemID = catalogItem.itemID,
      itemName = catalogItem.itemName,
      itemLink = catalogItem.itemLink,
      dbKey = catalogItem.dbKey,
    }
  end

  DebugLog("RESOLVE", "not found", { query = query })
  return nil, "item not found in local item cache (try exact name, item link, or itemID)"
end

LookupAuctionatorInfo = function(item)
  local current = nil
  if type(Auctionator) == "table" and type(Auctionator.API) == "table" and type(Auctionator.API.v1) == "table" then
    local price = Auctionator.API.v1.GetAuctionPriceByItemID(CALLER_ID, item.itemID)
    local ageDays = Auctionator.API.v1.GetAuctionAgeByItemID(CALLER_ID, item.itemID)
    local lastSeenTs = LastSeenTimestampForKey(item.dbKey)

    if price then
      current = {
        price = price,
        ageDays = ageDays,
        lastSeenTs = lastSeenTs,
      }
    end
  end

  local allRealms = LookupFreshestAcrossAllRealms(item.dbKey)
  DebugLog("DB", "lookup current vs all realms", {
    itemID = item.itemID,
    dbKey = item.dbKey,
    current = current ~= nil,
    allRealms = allRealms ~= nil,
  })

  if not current and not allRealms then
    return nil, "Auctionator API/database not available"
  end

  if allRealms and (not current or (allRealms.lastSeenTs or 0) > (current.lastSeenTs or 0)) then
    return {
      price = allRealms.price,
      ageDays = allRealms.ageDays,
      lastSeenTs = allRealms.lastSeenTs,
    }
  end

  return current
end

local function BuildResultLine(source, sender, item, info, err)
  local prefix = source or "manual"
  local from = sender and ("<" .. sender .. "> ") or ""

  if err then
    return string.format("[%s] %s%s: %s", prefix, from, item or "(unknown)", err)
  end

  local label = DisplayLabelForItem(item)
  local priceText = FormatPrice(info.price)
  local scanText = "unknown"
  if info.lastSeenTs then
    scanText = date("%Y-%m-%d", info.lastSeenTs)
  end

  local ageText = "unknown age"
  ageText = FormatAgeAgo(info.lastSeenTs, info.ageDays)

  return string.format("[%s] %s%s: %s (last scan %s, %s)", prefix, from, label, priceText, scanText, ageText)
end

local function AddResultLine(line)
  table.insert(PriceCheck.results, 1, line)
  if #PriceCheck.results > 200 then
    table.remove(PriceCheck.results)
  end

  if PriceCheck.scrollFrame then
    PriceCheck.scrollFrame:AddMessage(line)
  end
end

RenderStoredResults = function()
  if not PriceCheck.scrollFrame then
    return
  end

  PriceCheck.scrollFrame:Clear()
  for _, line in ipairs(PriceCheck.results) do
    PriceCheck.scrollFrame:AddMessage(line)
  end
end

local function OutputResult(line)
  AddResultLine(line)
  DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99PriceCheck|r " .. line)
end

ShowSearchMatches = function(query)
  if not PriceCheck.scrollFrame then
    return
  end

  local trimmed = Trim(query)
  DebugLog("SEARCH", "show matches", { query = trimmed, len = #trimmed })
  if #trimmed < 3 then
    RenderStoredResults()
    return
  end

  BuildItemCatalog()
  EnsureItemDataWarmupRunning()

  local matches = FindCatalogMatchesByName(trimmed, 30)

  PriceCheck.scrollFrame:Clear()
  PriceCheck.scrollFrame:AddMessage(string.format("Matches for \"%s\" (%d shown)", trimmed, #matches))

  if #matches == 0 then
    PriceCheck.scrollFrame:AddMessage("No matching items found in local Auctionator scan data.")
    if #PriceCheck.itemDataRequestQueue > 0 then
      if not PriceCheck.itemDataWarmupNoticeShown then
        PriceCheck.itemDataWarmupNoticeShown = true
      end
      PriceCheck.scrollFrame:AddMessage("Loading additional item names in background. Try this search again in a moment.")
      DebugLog("SEARCH", "no matches yet; waiting on cache", { query = trimmed, queued = #PriceCheck.itemDataRequestQueue })
    end
    return
  end

  for _, item in ipairs(matches) do
    local scanText = item.lastSeenTs and date("%Y-%m-%d", item.lastSeenTs) or "unknown"
    local ageText = FormatAgeAgo(item.lastSeenTs, item.ageDays)
    local label = DisplayLabelForItem(item)
    local line = string.format("%s: %s (last scan %s, %s)", label, FormatPrice(item.price), scanText, ageText)
    PriceCheck.scrollFrame:AddMessage(line)
  end
end

local function HandleMultiNameMatches(query, source, sender, publicResponder)
  local matches = FindExactCatalogMatchesByName(query, 3)
  if #matches == 0 then
    matches = FindCatalogMatchesByName(query, 3)
  end
  if #matches == 0 then
    DebugLog("LOOKUP", "no fallback matches", { query = query })
    return false
  end
  DebugLog("LOOKUP", "fallback matches", { query = query, count = #matches })

  local prefix = source or "manual"
  local from = sender and ("<" .. sender .. "> ") or ""
  local label = #matches == 1 and "Match" or "Multiple matches"
  local header = string.format("[%s] %s%s for \"%s\" (%d shown)", prefix, from, label, query, #matches)
  OutputResult(header)
  if publicResponder then
    publicResponder(string.format("PriceCheck %s: %s (%d shown)", query, label:lower(), #matches))
  end

  for _, item in ipairs(matches) do
    local scanText = item.lastSeenTs and date("%Y-%m-%d", item.lastSeenTs) or "unknown"
    local ageText = FormatAgeAgo(item.lastSeenTs, item.ageDays)
    local itemLabel = DisplayLabelForItem(item)
    local info = {
      price = item.price,
      lastSeenTs = item.lastSeenTs,
      ageDays = item.ageDays,
    }
    OutputResult(BuildResultLine(source, sender, item, info, nil))
    if publicResponder then
      publicResponder(string.format("%s: %s (last scan %s, %s)", itemLabel, FormatPricePlain(item.price), scanText, ageText))
    end
  end

  return true
end

local function BuildPublicChatLine(item, info, errText, queryText)
  local label = (type(item) == "table" and (item.itemName or item.query)) or queryText or "(unknown)"
  if errText then
    return string.format("PriceCheck %s: %s", label, errText)
  end

  local scanText = info.lastSeenTs and date("%Y-%m-%d", info.lastSeenTs) or "unknown"
  local ageText = FormatAgeAgo(info.lastSeenTs, info.ageDays)
  return string.format("PriceCheck %s: %s (last scan %s, %s)", label, FormatPricePlain(info.price), scanText, ageText)
end

local function SanitizeForSendChatMessage(text)
  local msg = tostring(text or "")

  -- Strip WoW formatting/hyperlink markup to avoid invalid chat escape codes.
  msg = msg:gsub("|H.-|h(.-)|h", "%1")
  msg = msg:gsub("|T.-|t", "")
  msg = msg:gsub("|c%x%x%x%x%x%x%x%x", "")
  msg = msg:gsub("|r", "")
  msg = msg:gsub("|", "")
  msg = msg:gsub("[%c]", " ")
  msg = Trim(msg)

  if #msg > 240 then
    msg = msg:sub(1, 240)
  end

  return msg
end

local function EnqueuePendingSend(safeText, chatType, channelTarget)
  if #PriceCheck.pendingSends >= 20 then
    table.remove(PriceCheck.pendingSends)
  end

  table.insert(PriceCheck.pendingSends, 1, {
    text = safeText,
    chatType = chatType,
    channelTarget = channelTarget,
  })
end

local function TryNativeSend(safeText, chatType, channelTarget)
  if type(NativeSendChatMessage) ~= "function" then
    return false
  end

  local ok = pcall(NativeSendChatMessage, safeText, chatType, nil, channelTarget)
  return ok
end

SendPublicChatMessage = function(text, chatType, channelTarget)
  local safeText = SanitizeForSendChatMessage(text)
  if safeText == "" then
    DebugLog("SEND", "blocked empty message", { chatType = chatType })
    return false
  end

  local blockKey = tostring(chatType or "UNKNOWN")

  local function QueueManualSend()
    local prefixMap = {
      SAY = "/s ",
      YELL = "/y ",
      GUILD = "/g ",
      PARTY = "/p ",
      RAID = "/ra ",
      INSTANCE_CHAT = "/i ",
    }

    local prefix = prefixMap[chatType]
    if chatType == "CHANNEL" and channelTarget then
      prefix = "/" .. tostring(channelTarget) .. " "
    end

    local prepared = (prefix or "") .. safeText
    DEFAULT_CHAT_FRAME:AddMessage("|cffffff00PriceCheck|r auto-send blocked by UI restrictions.")
    DEFAULT_CHAT_FRAME:AddMessage("|cffffff00PriceCheck prepared:|r " .. prepared)
    DebugLog("SEND", "manual send prepared", { chatType = chatType, target = channelTarget, text = prepared })
  end

  if PriceCheck.sendBlocked or PriceCheck.sendBlockedTypes[blockKey] then
    DebugLog("SEND", "auto-send disabled", { chatType = chatType, target = channelTarget })
    QueueManualSend()
    return false
  end

  if type(InCombatLockdown) == "function" and InCombatLockdown() then
    DebugLog("SEND", "queued due to combat", { chatType = chatType, queue = #PriceCheck.pendingSends + 1 })
    EnqueuePendingSend(safeText, chatType, channelTarget)
    if not PriceCheck.combatBlockedNoticeShown then
      DEFAULT_CHAT_FRAME:AddMessage("|cffffff00PriceCheck|r auto-reply queued until combat ends.")
      PriceCheck.combatBlockedNoticeShown = true
    end
    return false
  end

  -- Prefer a preserved native C reference captured before other addons hook it.
  if TryNativeSend(safeText, chatType, channelTarget) then
    DebugLog("SEND", "sent", { chatType = chatType, target = channelTarget })
    return true
  end

  PriceCheck.sendBlockedTypes[blockKey] = true
  DebugLog("SEND", "native send failed; type blocked", { chatType = chatType, target = channelTarget })
  DEFAULT_CHAT_FRAME:AddMessage("|cffffff00PriceCheck|r auto-send blocked for " .. blockKey .. "; future replies in this chat type will be prepared for manual send.")
  QueueManualSend()
  return false
end

local function FlushPendingSends()
  if #PriceCheck.pendingSends == 0 then
    return
  end

  if type(InCombatLockdown) == "function" and InCombatLockdown() then
    return
  end

  local queued = PriceCheck.pendingSends
  PriceCheck.pendingSends = {}
  PriceCheck.combatBlockedNoticeShown = false
  DebugLog("SEND", "flushing pending sends", { count = #queued })

  for i = #queued, 1, -1 do
    local entry = queued[i]
    if not TryNativeSend(entry.text, entry.chatType, entry.channelTarget) then
      local blockKey = tostring(entry.chatType or "UNKNOWN")
      PriceCheck.sendBlockedTypes[blockKey] = true
      DEFAULT_CHAT_FRAME:AddMessage("|cffffff00PriceCheck|r auto-send blocked for " .. blockKey .. " after combat; future replies in this chat type will be prepared for manual send.")
      DebugLog("SEND", "flush failed", { chatType = entry.chatType, target = entry.channelTarget })
      break
    else
      DebugLog("SEND", "flush sent", { chatType = entry.chatType, target = entry.channelTarget })
    end
  end
end

ExecuteLookup = function(query, source, sender, publicResponder)
  DebugLog("LOOKUP", "start", { query = query, source = source, sender = sender })
  if query == nil or Trim(query) == "" then
    local errText = "missing item name"
    OutputResult(BuildResultLine(source, sender, query, nil, errText))
    if publicResponder then
      publicResponder(BuildPublicChatLine(nil, nil, errText, query))
    end
    return
  end

  local trimmedQuery = Trim(query)
  local isNumericQuery = tonumber(trimmedQuery) ~= nil
  local isLinkQuery = type(query) == "string" and query:find("item:[^%s]+") ~= nil

  if not isNumericQuery and not isLinkQuery and PriceCheck.itemCatalogBuilt then
    local multiMatches = FindCatalogMatchesByName(trimmedQuery, 3)
    if #multiMatches > 1 then
      DebugLog("LOOKUP", "multiple name matches for plain-text query", { query = trimmedQuery, count = #multiMatches })
      HandleMultiNameMatches(trimmedQuery, source, sender, publicResponder)
      return
    end
  end

  local item, resolveErr = ResolveItem(query)
  if not item then
    DebugLog("LOOKUP", "resolve failed", { query = query, err = resolveErr })
    if not HandleMultiNameMatches(query, source, sender, publicResponder) then
      OutputResult(BuildResultLine(source, sender, query, nil, resolveErr))
      if publicResponder then
        publicResponder(BuildPublicChatLine(nil, nil, resolveErr, query))
      end
    end
    return
  end

  local info, lookupErr = LookupAuctionatorInfo(item)
  if not info then
    DebugLog("LOOKUP", "lookup failed", { item = item and item.itemName, itemID = item and item.itemID, err = lookupErr })
    if not isNumericQuery and not isLinkQuery and HandleMultiNameMatches(query, source, sender, publicResponder) then
      return
    end
    OutputResult(BuildResultLine(source, sender, item.itemName, nil, lookupErr))
    if publicResponder then
      publicResponder(BuildPublicChatLine(item, nil, lookupErr, query))
    end
    return
  end

  if not info.price then
    DebugLog("LOOKUP", "no price", { item = item and item.itemName, itemID = item and item.itemID })
    if not isNumericQuery and not isLinkQuery and HandleMultiNameMatches(query, source, sender, publicResponder) then
      return
    end
    local errText = "no Auctionator scan data found"
    OutputResult(BuildResultLine(source, sender, item.itemName, nil, errText))
    if publicResponder then
      publicResponder(BuildPublicChatLine(item, nil, errText, query))
    end
    return
  end

  OutputResult(BuildResultLine(source, sender, item, info, nil))
  DebugLog("LOOKUP", "success", {
    item = item and item.itemName,
    itemID = item and item.itemID,
    price = info and info.price,
    ageDays = info and info.ageDays,
  })
  if publicResponder then
    publicResponder(BuildPublicChatLine(item, info, nil, query))
  end
end

local function CreateWindow()
  if PriceCheck.frame then
    return
  end
  DebugLog("UI", "creating main window")

  local frame = CreateFrame("Frame", "AuctionatorPriceCheckFrame", UIParent, "BasicFrameTemplateWithInset")
  frame:SetSize(560, 360)
  frame:SetPoint("CENTER")
  frame:SetMovable(true)
  frame:EnableMouse(true)
  frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnDragStart", frame.StartMoving)
  frame:SetScript("OnDragStop", frame.StopMovingOrSizing)

  frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  frame.title:SetPoint("LEFT", frame.TitleBg, "LEFT", 8, 0)
  frame.title:SetText("Auctionator Price Check")

  local searchLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  searchLabel:SetPoint("TOPLEFT", frame, "TOPLEFT", 14, -34)
  searchLabel:SetText("Item name / link / ID")

  local searchBox = CreateFrame("EditBox", nil, frame, "InputBoxTemplate")
  searchBox:SetSize(340, 24)
  searchBox:SetPoint("TOPLEFT", searchLabel, "BOTTOMLEFT", 0, -8)
  searchBox:SetAutoFocus(false)
  searchBox:SetScript("OnTextChanged", function(self, userInput)
    if not userInput then
      return
    end
    PriceCheck.searchToken = PriceCheck.searchToken + 1
    local token = PriceCheck.searchToken
    local text = self:GetText()
    C_Timer.After(0.2, function()
      if token ~= PriceCheck.searchToken then
        return
      end
      ShowSearchMatches(text)
    end)
  end)
  searchBox:SetScript("OnEnterPressed", function(self)
    local text = self:GetText()
    ExecuteLookup(text, "window", UnitName("player"))
    self:ClearFocus()
  end)

  local searchButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  searchButton:SetSize(110, 24)
  searchButton:SetPoint("LEFT", searchBox, "RIGHT", 8, 0)
  searchButton:SetText("Check")
  searchButton:SetScript("OnClick", function()
    ExecuteLookup(searchBox:GetText(), "window", UnitName("player"))
  end)

  local clearButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  clearButton:SetSize(70, 24)
  clearButton:SetPoint("LEFT", searchButton, "RIGHT", 8, 0)
  clearButton:SetText("Clear")
  clearButton:SetScript("OnClick", function()
    PriceCheck.results = {}
    if PriceCheck.scrollFrame then
      PriceCheck.scrollFrame:Clear()
    end
  end)

  local output = CreateFrame("ScrollingMessageFrame", nil, frame)
  output:SetPoint("TOPLEFT", searchBox, "BOTTOMLEFT", 0, -12)
  output:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -14, 14)
  output:SetFontObject(GameFontHighlightSmall)
  output:SetJustifyH("LEFT")
  output:SetFading(false)
  output:SetMaxLines(300)
  output:SetHyperlinksEnabled(true)
  output:EnableMouseWheel(true)
  output:SetScript("OnMouseWheel", function(self, delta)
    if delta > 0 then
      self:ScrollUp()
    else
      self:ScrollDown()
    end
  end)

  frame:Hide()

  PriceCheck.frame = frame
  PriceCheck.scrollFrame = output
  PriceCheck.searchBox = searchBox
  RenderStoredResults()
end

local function ToggleWindow()
  if not PriceCheck.frame then
    CreateWindow()
  end

  if PriceCheck.frame:IsShown() then
    PriceCheck.frame:Hide()
    DebugLog("UI", "main window hidden")
  else
    PriceCheck.frame:Show()
    DebugLog("UI", "main window shown")
    if PriceCheck.searchBox then
      ShowSearchMatches(PriceCheck.searchBox:GetText() or "")
      PriceCheck.searchBox:SetFocus()
    end
  end
end

local function HandleSlashCommand(msg)
  local input = Trim(msg)
  DebugLog("SLASH", "received", { input = input })
  if input == "" then
    ToggleWindow()
    return
  end

  local lowered = input:lower()
  if lowered == "refresh" or lowered == "rebuild" or lowered == "reindex" then
    InvalidateLookupCaches("manual_refresh")
    DebugLog("CACHE", "manual refresh command completed")
    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99PriceCheck|r cache cleared. Next lookup will rebuild from Auctionator data.")
    return
  end

  ExecuteLookup(input, "slash", UnitName("player"))
  if not PriceCheck.frame or not PriceCheck.frame:IsShown() then
    ToggleWindow()
  end
end

local function ParseChatCommand(message)
  if not message then
    return nil
  end

  local trimmed = Trim(message)
  local lowered = trimmed:lower()

  if lowered:sub(1, 3) == "!pc" then
    local nextChar = lowered:sub(4, 4)
    if nextChar == "" or nextChar:match("%s") then
      DebugLog("CHAT", "parsed !pc command", { query = Trim(trimmed:sub(4)) })
      return Trim(trimmed:sub(4))
    end
  end

  if lowered:sub(1, 11) == "!pricecheck" then
    local nextChar = lowered:sub(12, 12)
    if nextChar == "" or nextChar:match("%s") then
      DebugLog("CHAT", "parsed !pricecheck command", { query = Trim(trimmed:sub(12)) })
      return Trim(trimmed:sub(12))
    end
  end

  return nil
end

local eventFrame = CreateFrame("Frame")

local function GetChatReplyTarget(event, channelNumber, channelName)
  local map = {
    CHAT_MSG_SAY = "SAY",
    CHAT_MSG_YELL = "YELL",
    CHAT_MSG_GUILD = "GUILD",
    CHAT_MSG_PARTY = "PARTY",
    CHAT_MSG_PARTY_LEADER = "PARTY",
    CHAT_MSG_RAID = "RAID",
    CHAT_MSG_RAID_LEADER = "RAID",
    CHAT_MSG_INSTANCE_CHAT = "INSTANCE_CHAT",
    CHAT_MSG_INSTANCE_CHAT_LEADER = "INSTANCE_CHAT",
    CHAT_MSG_CHANNEL = "CHANNEL",
  }

  local chatType = map[event]
  if not chatType then
    return nil, nil
  end

  if chatType == "CHANNEL" then
    local channel = tonumber(channelNumber)
    if not channel and type(channelName) == "string" then
      channel = tonumber(channelName:match("^(%d+)"))
    end
    DebugLog("CHAT", "reply target resolved", { event = event, chatType = chatType, channel = channel })
    return chatType, channel
  end

  DebugLog("CHAT", "reply target resolved", { event = event, chatType = chatType })
  return chatType, nil
end

eventFrame:SetScript("OnEvent", function(_, event, ...)
  if event == "ADDON_LOADED" or event == "PLAYER_REGEN_ENABLED" or event == "GET_ITEM_INFO_RECEIVED" or event == "CHAT_MSG_ADDON" then
    DebugLog("EVENT", "received", { event = event })
  end
  if event == "ADDON_LOADED" then
    local name = ...
    if name ~= ADDON_NAME then
      return
    end

    if type(AUCTIONATOR_PRICECHECK_NAME_CACHE) ~= "table" then
      AUCTIONATOR_PRICECHECK_NAME_CACHE = {}
    end

    CreateWindow()

    SLASH_AUCTIONATORPRICECHECK1 = "/pc"
    SLASH_AUCTIONATORPRICECHECK2 = "/pricecheck"
    SlashCmdList.AUCTIONATORPRICECHECK = HandleSlashCommand

    for _, chatEvent in ipairs(PriceCheck.chatEvents) do
      eventFrame:RegisterEvent(chatEvent)
    end
    eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
    eventFrame:RegisterEvent("GET_ITEM_INFO_RECEIVED")
    eventFrame:RegisterEvent("CHAT_MSG_ADDON")

    if C_ChatInfo and type(C_ChatInfo.RegisterAddonMessagePrefix) == "function" then
      PriceCheck.addonPrefixReady = C_ChatInfo.RegisterAddonMessagePrefix(ADDON_MSG_PREFIX) and true or false
      DebugLog("COORD", "addon prefix register", { prefix = ADDON_MSG_PREFIX, success = PriceCheck.addonPrefixReady })
    end

    local canAutoSend, reason = HasSafeAutoSendPath()
    if not canAutoSend then
      PriceCheck.sendBlocked = true
      DebugLog("SEND", "auto chat disabled at load", { reason = reason })
      DEFAULT_CHAT_FRAME:AddMessage("|cffffff00PriceCheck|r auto chat replies disabled: " .. tostring(reason) .. ".")
    else
      DebugLog("SEND", "auto chat enabled")
    end

    DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99PriceCheck|r loaded. Use /pc or !pc <item> in chat.")
    DebugLog("INIT", "addon loaded")
    EnsureAuctionatorScanHooks()
    PrewarmCatalogAtLoad()
    eventFrame:UnregisterEvent("ADDON_LOADED")
    return
  end

  if event == "PLAYER_REGEN_ENABLED" then
    DebugLog("EVENT", "combat ended; flushing pending sends", { queued = #PriceCheck.pendingSends })
    FlushPendingSends()
    return
  end

  if event == "GET_ITEM_INFO_RECEIVED" then
    local itemID, success = ...
    DebugLog("CACHE", "item info received", { itemID = itemID, success = success })
    if success and type(itemID) == "number" then
      local itemName = GetItemInfo(itemID)
      if itemName then
        SaveNameForItemID(itemID, itemName)
      end

      if PriceCheck.itemDataRequested[itemID] then
        PriceCheck.pendingCatalogItemIDs[itemID] = true
        ScheduleCatalogIncrementalUpdate()
      end
    end
    return
  end

  if event == "CHAT_MSG_ADDON" then
    local prefix, payload, channel, remoteSender = ...
    if prefix ~= ADDON_MSG_PREFIX then
      return
    end

    local requestID, bidChatType, bidChannelToken, staleMinutes = ParseCoordinationBid(payload)
    if not requestID then
      return
    end

    local request = PriceCheck.coordinatedRequests[requestID]
    if not request then
      return
    end

    if request.chatType ~= bidChatType then
      return
    end

    if tostring(request.channelTarget or "") ~= tostring(bidChannelToken or "") then
      return
    end

    if request.chatType ~= channel then
      return
    end

    local candidate = {
      sender = remoteSender or "Unknown",
      senderKey = NormalizePlayerKey(remoteSender),
      staleMinutes = staleMinutes,
    }

    if IsCandidateBetter(candidate, request.bestCandidate) then
      request.bestCandidate = candidate
      DebugLog("COORD", "updated winner candidate", {
        requestID = requestID,
        sender = candidate.sender,
        staleMinutes = candidate.staleMinutes,
      })
    end
    return
  end

  local message, sender, _, channelName, _, _, _, _, channelNumber = ...
  local query = ParseChatCommand(message)
  if not query then
    return
  end

  DebugLog("CHAT", "chat command dispatch", { event = event, sender = SenderName(sender), query = query, channel = channelName, channelNumber = channelNumber })
  local chatType, channelTarget = GetChatReplyTarget(event, channelNumber, channelName)
  if chatType then
    StartCoordinatedLookup(query, event, SenderName(sender), chatType, channelTarget)
  else
    ExecuteLookup(query, event, SenderName(sender))
  end
end)

eventFrame:RegisterEvent("ADDON_LOADED")
