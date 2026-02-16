local _, APC = ...
APC = APC or _G.AuctionatorPriceCheckNS or {}
_G.AuctionatorPriceCheckNS = APC

function APC.GetSavedNameForItemID(itemID)
  if type(itemID) ~= "number" or type(AUCTIONATOR_PRICECHECK_NAME_CACHE) ~= "table" then
    return nil
  end
  local value = AUCTIONATOR_PRICECHECK_NAME_CACHE[tostring(itemID)]
  if type(value) == "string" and value ~= "" then
    return value
  end
  return nil
end

function APC.SaveNameForItemID(itemID, itemName)
  if type(itemID) ~= "number" or type(itemName) ~= "string" or itemName == "" then
    return
  end
  if itemName:match("^item:%d+$") then
    return
  end
  if type(AUCTIONATOR_PRICECHECK_NAME_CACHE) ~= "table" then
    AUCTIONATOR_PRICECHECK_NAME_CACHE = {}
  end
  AUCTIONATOR_PRICECHECK_NAME_CACHE[tostring(itemID)] = itemName
end

function APC.RequestItemNameLoad(state, itemID)
  if type(itemID) ~= "number" then
    return
  end
  if type(C_Item) == "table" and type(C_Item.RequestLoadItemDataByID) == "function" then
    if type(state) == "table" then
      state.itemDataRequested[itemID] = true
    end
    C_Item.RequestLoadItemDataByID(itemID)
  end
end
