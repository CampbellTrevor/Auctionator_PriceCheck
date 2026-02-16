local _, APC = ...
APC = APC or _G.AuctionatorPriceCheckNS or {}
_G.AuctionatorPriceCheckNS = APC

function APC.Trim(text)
  if text == nil then
    return ""
  end
  return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

function APC.NormalizeSearchText(text)
  local normalized = tostring(text or ""):lower()
  normalized = normalized:gsub("[%p%c]", " ")
  normalized = normalized:gsub("%s+", " ")
  return APC.Trim(normalized)
end

function APC.SenderName(fullName)
  local short = fullName and fullName:match("^[^-]+")
  if short and short ~= "" then
    return short
  end
  return fullName or "Unknown"
end

function APC.FormatPrice(copper)
  if not copper then
    return "n/a"
  end
  return GetCoinTextureString(copper) or tostring(copper)
end

function APC.FormatPricePlain(copper)
  if type(copper) ~= "number" then
    return "n/a"
  end

  local gold = math.floor(copper / 10000)
  local silver = math.floor((copper % 10000) / 100)
  local copperOnly = copper % 100
  return string.format("%dg %ds %dc", gold, silver, copperOnly)
end

function APC.DisplayLabelForItem(item)
  if type(item) ~= "table" then
    return tostring(item)
  end

  local link = item.itemLink
  if type(link) == "string" and link:find("|H", 1, true) then
    return link
  end

  if type(item.itemName) == "string" and item.itemName ~= "" then
    return item.itemName
  end

  if type(link) == "string" and link ~= "" then
    return link
  end

  return item.query or "(unknown)"
end
