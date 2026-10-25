--[[
  KitShop - магазин КОМПЛЕКТОВ для OpenComputers + OpenPeripheral PIM + AE2 ME Interface

  Игрок встаёт на PIM -> авторизация -> одно сканирование ME -> три вкладки
  (у владельца) или две (у клиента):
    Квесты/Комплекты | Пополнение | Создание (только владелец)

  Всё хранится в файле базы (CONFIG.DB_PATH): балансы, покупки,
  незабранные ресурсы, комплекты, ресурсы пополнения, отзывы.

  РЕЖИМЫ (CONFIG.MODE):
    standalone - один ПК, всё как раньше (по умолчанию);
    server     - ПК-сервер: хранит базу и отвечает терминалам по сети (экран, PIM и ME не нужны);
    terminal   - ПК-терминал: PIM + ME Interface + экран + сетевая карта; базы у него нет,
                 все данные берёт у сервера. Терминалов можно ставить сколько угодно.

  Экран рассчитан на 160x50 (подстраивается под реальное разрешение).
]]

local component = require("component")
local computer  = require("computer")
local event     = require("event")
local fs        = require("filesystem")
local ser       = require("serialization")
local unicode   = require("unicode")

local ARGS = { ... }               -- аргументы командной строки
local SELF_SRC = debug.getinfo(1, "S").source   -- откуда загружен файл (нужно для автозапуска)

-- Оригинальные обработчики прерывания запоминаем ОДИН раз (до возможных перезапусков main)
local ORIG_INT, ORIG_SOFT = event.shouldInterrupt, event.shouldSoftInterrupt

----------------------------------------------------------------------
-- НАСТРОЙКИ
----------------------------------------------------------------------
local CONFIG = {
  OWNERS   = {},                    -- необязательно: ники прямо в файле.
                                    -- Основной способ: lua kitshop.lua owner add Ник
  CURRENCY = "coin",                  -- название валюты на экране

  DB_PATH  = "/home/kitshop/db.dat",
  LOG_PATH = "/home/kitshop/error.log",
  CMD_PATH = "/home/kitshop/owner.cmd",   -- очередь команд owner add/del для запущенного сервера

  -- Стороны.
  ME_EXPORT_SIDE = "up",            -- откуда ME Interface выдаёт предметы (в сторону PIM)
  PIM_PUSH_SIDE  = "north",         -- сторона для pim.pushItem (если не сработает, код переберёт остальные сам
                                    -- и запомнит рабочую; впишите её сюда, когда узнаете)

  REFRESH_COOLDOWN = 60,            -- кнопка "Обновить" не чаще раза в N секунд
  SCREEN_W = 160, SCREEN_H = 50,     -- желаемое разрешение (подстроится под экран)

  PICK_MAX = 300,                   -- сколько предметов ME показывать в списке выбора (дальше - поиском)

  MEM_LOW = 500 * 1024,             -- порог свободной ОЗУ (байт): ниже него выгружаем лишнее (см. memGuard)

  FEEDBACK_COOLDOWN = 30,           -- пауза между отзывами одного игрока, сек
  FEEDBACK_MAX_LEN  = 200,
  FEEDBACK_KEEP     = 100,          -- сколько последних отзывов хранить

  -- Сеть (для режимов server / terminal). На ВСЕХ ПК значения NET_PORT и NET_KEY должны совпадать.
  MODE        = "standalone",       -- "standalone" | "server" | "terminal"
  NET_PORT    = 4747,               -- порт запросов к серверу (ответы идут на NET_PORT + 1)
  NET_KEY     = "change-me",        -- общий пароль сети: ЗАМЕНИТЕ на свой
  NET_TIMEOUT = 3,                  -- сколько секунд ждать ответ сервера
  NET_RETRIES = 3,                  -- сколько раз повторять запрос
  NET_CHUNK   = 6000,               -- размер куска сообщения, байт (пакет модема ограничен 8192)
}

local MODE = CONFIG.MODE or "standalone"
if ARGS[1] == "server" then MODE = "server" end

----------------------------------------------------------------------
-- ОБОРУДОВАНИЕ
----------------------------------------------------------------------
local gpu, me, pim, modem
if MODE ~= "server" then
  if not component.isAvailable("me_interface") then
    error("Не найден компонент me_interface (ME Interface должен быть подключён к компьютеру)")
  end
  if not component.isAvailable("pim") then
    error("Не найден компонент pim (OpenPeripheral PIM)")
  end
  gpu = component.gpu
  me  = component.me_interface
  pim = component.pim
end
if MODE ~= "standalone" then
  if not component.isAvailable("modem") then
    error("Не найден modem (сетевая или беспроводная карта) - он нужен в режиме " .. MODE)
  end
  modem = component.modem
end
local pendingOff = false      -- игрок ушёл с PIM во время длинной операции (см. сеть и диалоги)

-- Принудительная сборка мусора. В OpenComputers функции collectgarbage может не быть,
-- зато вызов computer.freeMemory() запускает сборку мусора (так её и принято вызывать).
-- Всё под pcall: если ничего не сработает, магазин просто продолжит работу.
local gc = function()
  if type(collectgarbage) == "function" then pcall(collectgarbage)
  else pcall(computer.freeMemory) end
end

-- Сторож памяти. Когда свободной ОЗУ меньше CONFIG.MEM_LOW, по очереди вызываются «освободители»
-- (от дешёвых к дорогим) и после каждого проверяется, хватило ли. Освободители регистрируются
-- ниже, рядом с тем кэшем, который они чистят. Возвращает true, если память была на исходе.
local memReleasers = {}
local function memGuard()
  local okf, free = pcall(computer.freeMemory)
  if not okf or free >= CONFIG.MEM_LOW then return false end
  for _, release in ipairs(memReleasers) do
    pcall(release)
    gc()
    local ok2, f2 = pcall(computer.freeMemory)
    if ok2 and f2 >= CONFIG.MEM_LOW then break end
  end
  return true
end

-- Русские названия предметов: словарь "<id>&&<damage>" -> название (см. build_ru_from_nei.py).
-- Файл необязателен: без него названия остаются такими, как их отдаёт ME.
-- Словари делает nei_to_lua.py: ru_names.lua (предметы) и ru_extra.lua (виды, чары/зелья, обработчики).
-- Грузятся лениво и под pcall: нет файла или не хватило памяти - возвращается запасной текст.
local ru = {}
do
  local DIR = "/home/kitshop"
  local SHARD_DIR = DIR .. "/ru_names"       -- папка с файлами по модам (делает split_ru_names.py)
  local SHARD_KEEP = 3                       -- сколько файлов-модов держать в ОЗУ одновременно
  local shards, shardCount = {}, 0
  local legacy, extra

  local function load(path)
    local ok, t = pcall(dofile, path)
    if ok and type(t) == "table" then return t end
    return {}
  end
  local function modFile(name)
    local mod = tostring(name):match("^([^:]+):") or "_"
    return (mod:gsub("[^%w_%-]", "_"))
  end
  -- словарь одного мода (~несколько КБ вместо 300 КБ целиком)
  local function shardFor(name)
    local f = modFile(name)
    local t = shards[f]
    if t == nil then
      if shardCount >= SHARD_KEEP then shards, shardCount = {}, 0; gc() end
      local path = SHARD_DIR .. "/" .. f .. ".lua"
      t = fs.exists(path) and load(path) or {}
      shards[f] = t; shardCount = shardCount + 1
    end
    return t
  end
  local useShards
  local function sharded()
    if useShards == nil then useShards = fs.isDirectory(SHARD_DIR) end
    return useShards
  end

  function ru.item(name, dmg, fb)
    local key = tostring(name) .. "&&" .. math.floor(tonumber(dmg) or 0)
    if sharded() then return shardFor(name)[key] or fb end
    -- запасной вариант: папки ru_names/ нет, грузим старый общий файл целиком
    if not legacy then legacy = load(DIR .. "/ru_names.lua") end
    return legacy[key] or fb
  end
  local function getExtra()
    if not extra then
      extra = load(DIR .. "/ru_extra.lua")
      extra.species, extra.keys, extra.handlers =
        extra.species or {}, extra.keys or {}, extra.handlers or {}
    end
    return extra
  end
  function ru.species(uid, fb) return getExtra().species[tostring(uid)] or fb end
  function ru.key(k, fb)       return getExtra().keys[tostring(k)] or fb end
  function ru.handler(c, fb)   return getExtra().handlers[tostring(c)] or fb end
  function ru.unload()
    shards, shardCount, legacy, extra, useShards = {}, 0, nil, nil, nil
    gc()
  end
end
local function ruName(name, dmg, fallback) return ru.item(name, dmg, fallback) end
memReleasers[#memReleasers + 1] = function() ru.unload() end          -- 1) словари переводов

----------------------------------------------------------------------
-- УТИЛИТЫ
----------------------------------------------------------------------
local function lower(s) return unicode.lower(tostring(s)) end
local function trim(s) return (tostring(s):match("^%s*(.-)%s*$")) end
local function round2(n) return math.floor(n * 100 + 0.5) / 100 end
local function fmt(n)
  n = round2(tonumber(n) or 0)
  if n == math.floor(n) then return string.format("%d", n) end
  return string.format("%.2f", n)
end
-- var - «вариант» предмета (например, какая жидкость в баке). Пусто для обычных предметов.
local function itemKey(name, dmg, var)
  local k = tostring(name) .. "&&" .. tostring(math.floor(tonumber(dmg) or 0))
  if var and var ~= "" then k = k .. "&&" .. tostring(var) end
  return k
end

-- NBT-хеш предмета (если ME / PIM его отдают). Нужен, чтобы отличать предметы с одинаковыми id и damage.
local function nbtOf(it)
  if type(it) ~= "table" then return nil end
  for _, k in ipairs({ "nbt_hash", "nbtHash", "hash", "nbt" }) do
    local v = it[k]
    if v ~= nil and type(v) ~= "table" and tostring(v) ~= "" then return tostring(v) end
  end
  return nil
end

-- Тип жидкости в предмете (только для отображения, без количества): "chocolatemilk".
-- Ищем в it.fluid (ME) и в it.fluid_container.contents (PIM).
local function fluidVariant(it)
  local f = type(it) == "table" and it.fluid
  if type(f) ~= "table" then
    local fc = type(it) == "table" and it.fluid_container
    f = type(fc) == "table" and fc.contents or nil
  end
  if type(f) ~= "table" then return "" end
  local nm = f.name or f.fluid or f.fluidName or f.fluid_name or f.id or f.label or f.localizedName
  if nm ~= nil and type(nm) ~= "table" then return tostring(nm) end
  local parts = {}
  for k, v in pairs(f) do
    local ks = lower(k)
    if type(v) ~= "table" and not ks:find("amount", 1, true) and not ks:find("capacity", 1, true)
       and not ks:find("size", 1, true) and not ks:find("qty", 1, true) then
      parts[#parts + 1] = tostring(k) .. "=" .. tostring(v)
    end
  end
  table.sort(parts)
  return table.concat(parts, ";")
end

-- Вариант предмета (ME-стек или стек из PIM):
--   1) NBT-хеш "#<хеш>" - точный (нужен для exportItem, у баков с жидкостью он свой);
--   2) если хеша нет - тип жидкости;
--   3) иначе "" (обычный предмет).
local function variantOf(it)
  local h = nbtOf(it)
  if h then return "#" .. h end
  return fluidVariant(it)
end

-- raw=true: не трогать словарь переводов (для клиентов и лёгкого скана - экономия ОЗУ)
local function labelOf(it, var, raw)
  local l = raw and tostring(it.label or it.name) or ruName(it.name, it.damage, tostring(it.label or it.name))
  if var and var ~= "" then
    local fl = fluidVariant(it)
    local tag
    if var:sub(1, 1) == "#" then tag = ((fl ~= "") and (fl .. " ") or "") .. var:sub(1, 7)
    else tag = (fl ~= "") and fl or var end
    l = l .. " (" .. tag .. ")"
  end
  return l
end

-- совпадают ли варианты предметов: оба по хешу - строго; оба по жидкости - строго;
-- если у одного хеш, а у другого жидкость (PIM и ME описывают предмет по-разному) - считаем совпадением
local function sameVariant(a, b)
  a, b = a or "", b or ""
  if a == b then return true end
  if a == "" or b == "" then return false end
  local ha, hb = (a:sub(1, 1) == "#"), (b:sub(1, 1) == "#")
  if ha ~= hb then return true end
  return false
end

-- обрезать/дополнить пробелами до ширины w (учитывает кириллицу)
local function pad(s, w)
  s = tostring(s)
  local l = unicode.len(s)
  if l > w then return unicode.sub(s, 1, math.max(0, w)) end
  return s .. string.rep(" ", w - l)
end

local function wrap(s, width)
  local lines, cur = {}, ""
  for word in tostring(s):gmatch("%S+") do
    if cur ~= "" and unicode.len(cur) + unicode.len(word) + 1 > width then
      lines[#lines + 1] = cur; cur = word
    else
      cur = (cur == "") and word or (cur .. " " .. word)
    end
    while unicode.len(cur) > width do
      lines[#lines + 1] = unicode.sub(cur, 1, width)
      cur = unicode.sub(cur, width + 1)
    end
  end
  if cur ~= "" then lines[#lines + 1] = cur end
  if #lines == 0 then lines[1] = "" end
  return lines
end

local function dateStr(t)
  local ok, s = pcall(os.date, "%d.%m %H:%M", t)
  return ok and s or "?"
end

----------------------------------------------------------------------
-- БАЗА ДАННЫХ (один файл, сохраняется после каждого изменения)
----------------------------------------------------------------------
local db

local function defaultDB()
  return { owners = {}, ownerUids = {}, kits = {}, nextKitId = 1, topup = {}, players = {}, feedback = {}, nextPurchaseId = 1, withdraw = false, cfgVer = 0, nextFbId = 1 }
end

local function loadDB()
  -- основной файл, а если он пропал (сбой между remove и rename в saveDB) - временный
  for _, path in ipairs({ CONFIG.DB_PATH, CONFIG.DB_PATH .. ".tmp" }) do
    if fs.exists(path) then
      local f = io.open(path, "r")
      if f then
        local data = f:read("*a"); f:close()
        local t = ser.unserialize(data)
        data = nil
        if type(t) == "table" then
          for k, v in pairs(defaultDB()) do if t[k] == nil then t[k] = v end end
          return t
        end
        -- файл повреждён: не затираем, а откладываем в сторону
        pcall(fs.copy, path, path .. ".bad")
      end
    end
  end
  return defaultDB()
end

local Net = {}        -- сетевой слой (заполняется ниже)

local function saveDB()
  if MODE == "terminal" then return Net.flush() end      -- у терминала своей базы нет: отправляем на сервер
  pcall(fs.makeDirectory, fs.path(CONFIG.DB_PATH))
  local tmp = CONFIG.DB_PATH .. ".tmp"
  memGuard()                           -- serialize строит всю базу строкой: освободим место заранее
  local f = assert(io.open(tmp, "w"))
  f:write(ser.serialize(db))
  f:close()
  fs.remove(CONFIG.DB_PATH)
  fs.rename(tmp, CONFIG.DB_PATH)
end

local function getPlayer(name)
  local k = lower(name)
  local p = db.players[k]
  if not p and MODE == "terminal" then
    pcall(Net.pullPlayer, name)             -- запись могла пропасть после отката - берём заново у сервера
    p = db.players[k]
  end
  if not p then
    p = { name = name, balance = 0, purchases = {}, rev = 0 }
    db.players[k] = p
    if MODE ~= "terminal" then saveDB() end
  end
  p.name = name
  p.purchases = p.purchases or {}
  return p
end

-- Владелец определяется по нику И привязывается к UUID при первом входе:
-- если ник потом освободят и займёт другой человек, UUID не совпадёт.
local function isOwner(name, uid)
  local match = false
  for _, o in ipairs(CONFIG.OWNERS) do
    if lower(o) == lower(name) then match = true end
  end
  for _, o in ipairs((db and db.owners) or {}) do
    if lower(o) == lower(name) then match = true end
  end
  if not match then return false end
  if uid and db then
    db.ownerUids = db.ownerUids or {}
    local k, bound = lower(name), db.ownerUids[lower(name)]
    if not bound then
      db.ownerUids[k] = tostring(uid); saveDB()
    elseif bound ~= tostring(uid) then
      return false
    end
  end
  return true
end

local function findKit(id)
  for i, k in ipairs(db.kits) do if k.id == id then return k, i end end
end

local function findPurchase(p, id)
  for i, pu in ipairs(p.purchases) do if pu.id == id then return pu, i end end
end

local function purchasePending(pu)
  local n = 0
  for _, it in ipairs(pu.items) do if it.qty > 0 then n = n + 1 end end
  return n
end

local function pendingCount(p)
  local n = 0
  for _, pu in ipairs(p.purchases) do n = n + purchasePending(pu) end
  return n
end

-- убрать полностью выданные покупки
local function purgePurchases(p)
  local changed = false
  for i = #p.purchases, 1, -1 do
    if purchasePending(p.purchases[i]) == 0 then table.remove(p.purchases, i); changed = true end
  end
  if changed then saveDB() end
end

-- сколько каждого предмета уже оплачено игроками, но ещё не выдано
local function reservedMap(fresh)
  if MODE == "terminal" then
    if fresh or not Net.res or computer.uptime() - Net.resT > 3 then
      local ok, r = pcall(Net.req, "reserved", {})
      if ok then Net.res, Net.resT = r.map or {}, computer.uptime()
      elseif fresh then error(r, 0)
      else Net.res, Net.resT = Net.res or {}, computer.uptime() end
    end
    return Net.res
  end
  local r = {}
  for _, p in pairs(db.players) do
    for _, pu in ipairs(p.purchases or {}) do
      for _, it in ipairs(pu.items) do
        if it.qty > 0 then
          local k = itemKey(it.name, it.damage, it.var)
          r[k] = (r[k] or 0) + it.qty
        end
      end
    end
  end
  return r
end

local function unreadFeedback()
  if MODE == "terminal" and not Net.fbLoaded then return Net.unread or 0 end
  local n = 0
  for _, f in ipairs(db.feedback) do if not f.read then n = n + 1 end end
  return n
end

----------------------------------------------------------------------
-- СЕТЬ: сервер хранит базу, терминалы спрашивают его по модему
----------------------------------------------------------------------
do
local NET_TAG = "KS1"
local termId = computer.address():sub(1, 8)
local ridCounter = 0

-- режет строку на куски, не разрывая многобайтные символы UTF-8
local function netSplit(payload)
  local parts, pos, len, size = {}, 1, #payload, CONFIG.NET_CHUNK
  if len == 0 then return { "" } end
  while pos <= len do
    local stop = math.min(len, pos + size - 1)
    while stop < len and stop > pos do
      local b = payload:byte(stop + 1)
      if b and b >= 0x80 and b < 0xC0 then stop = stop - 1 else break end
    end
    parts[#parts + 1] = payload:sub(pos, stop)
    pos = stop + 1
  end
  return parts
end

local function netSend(addr, port, rid, payload)
  local parts = netSplit(payload)
  for i, part in ipairs(parts) do
    if addr then modem.send(addr, port, NET_TAG, CONFIG.NET_KEY, rid, i, #parts, part)
    else modem.broadcast(port, NET_TAG, CONFIG.NET_KEY, rid, i, #parts, part) end
  end
end

-- складывает пришедшие куски; когда все на месте - возвращает целую строку
local function netCollect(box, ekey, idx, total, part)
  local now = computer.uptime()
  for k, b in pairs(box) do if now - b.t > 60 then box[k] = nil end end    -- недособранное выбрасываем
  if type(idx) ~= "number" or type(total) ~= "number" or type(part) ~= "string" then return nil end
  local b = box[ekey]
  if not b then b = { n = 0, total = total, parts = {}, t = now }; box[ekey] = b end
  if not b.parts[idx] then b.parts[idx] = part; b.n = b.n + 1 end
  b.t = now
  if b.n >= b.total then
    box[ekey] = nil
    return table.concat(b.parts, "", 1, b.total)
  end
end

---------- сервер: обработчики команд (работают с авторитетной базой db) ----------
local SRV = {}

local function cfgOf()
  return { kits = db.kits, nextKitId = db.nextKitId, topup = db.topup, withdraw = db.withdraw }
end

SRV.hello = function() return { ok = true } end

SRV.login = function(a)
  local name = tostring(a.name)
  local owner = isOwner(name, a.uid)
  local p = getPlayer(name)
  return { ok = true, owner = owner, player = p, cfg = cfgOf(), ver = db.cfgVer or 0, unread = unreadFeedback() }
end

SRV.player = function(a) return { ok = true, player = getPlayer(tostring(a.name)) } end

SRV.config = function() return { ok = true, cfg = cfgOf(), ver = db.cfgVer or 0 } end

SRV.pushConfig = function(a)
  if not isOwner(tostring(a.who)) then return { err = "forbidden" } end
  if (db.cfgVer or 0) ~= a.base then return { err = "stale" } end
  local c = a.cfg or {}
  db.kits, db.topup = c.kits or {}, c.topup or {}
  db.nextKitId = c.nextKitId or db.nextKitId
  db.withdraw = c.withdraw or false
  db.cfgVer = (db.cfgVer or 0) + 1
  saveDB()
  return { ok = true, ver = db.cfgVer }
end

-- запись игрока: принимается только если версия (rev) совпала; chk - проверка остатков при покупке
SRV.pushPlayer = function(a)
  local sp = getPlayer(tostring(a.name))
  if (sp.rev or 0) ~= (a.base or 0) then return { err = "rev" } end
  local oldBal, oldPur = sp.balance, sp.purchases
  sp.balance, sp.purchases = tonumber(a.rec.balance) or 0, a.rec.purchases or {}
  if a.chk then
    local res = reservedMap()
    for _, c in ipairs(a.chk) do
      if (res[c.key] or 0) > c.real then
        sp.balance, sp.purchases = oldBal, oldPur
        return { err = "stock" }
      end
    end
  end
  sp.rev = (sp.rev or 0) + 1
  saveDB()
  return { ok = true, rev = sp.rev }
end

SRV.reserved = function() return { ok = true, map = reservedMap() } end

SRV.wanted = function()
  local w = {}
  for _, p in pairs(db.players) do
    for _, pu in ipairs(p.purchases or {}) do
      for _, it in ipairs(pu.items) do w[it.name] = true end
    end
  end
  return { ok = true, names = w }
end

SRV.allocId = function()
  local id = db.nextPurchaseId
  db.nextPurchaseId = id + 1
  saveDB()
  return { ok = true, id = id }
end

local function fbIds()
  db.nextFbId = db.nextFbId or 1
  for _, f in ipairs(db.feedback) do
    if not f.id then f.id = db.nextFbId; db.nextFbId = db.nextFbId + 1 end
  end
end

SRV.fbAdd = function(a)
  fbIds()
  db.feedback[#db.feedback + 1] = { id = db.nextFbId, player = tostring(a.player), text = tostring(a.text):sub(1, 300),
                                    time = os.time(), read = false }
  db.nextFbId = db.nextFbId + 1
  while #db.feedback > CONFIG.FEEDBACK_KEEP do table.remove(db.feedback, 1) end
  saveDB()
  return { ok = true }
end

SRV.fbList = function()
  fbIds()
  return { ok = true, list = db.feedback, unread = unreadFeedback() }
end

SRV.fbOp = function(a)
  fbIds()
  if a.op == "read" then for _, f in ipairs(db.feedback) do f.read = true end
  elseif a.op == "clear" then db.feedback = {}
  elseif a.op == "del" then
    for i = #db.feedback, 1, -1 do if db.feedback[i].id == a.id then table.remove(db.feedback, i) end end
  end
  saveDB()
  return { ok = true }
end

SRV.owner = function(a)
  local cmd, nick, lines = a.cmd, a.nick, {}
  if cmd == "add" and nick then
    if isOwner(nick) then lines[1] = "Уже владелец: " .. nick
    else db.owners[#db.owners + 1] = nick; saveDB(); lines[1] = "Владелец добавлен: " .. nick end
  elseif cmd == "del" and nick then
    for i = #db.owners, 1, -1 do
      if lower(db.owners[i]) == lower(nick) then table.remove(db.owners, i) end
    end
    db.ownerUids = db.ownerUids or {}
    db.ownerUids[lower(nick)] = nil
    saveDB(); lines[1] = "Удалён из владельцев: " .. nick
  elseif cmd == "list" then
    for _, o in ipairs(CONFIG.OWNERS) do lines[#lines + 1] = o .. "  (из файла)" end
    for _, o in ipairs(db.owners) do lines[#lines + 1] = o end
  else
    return { err = "Использование: lua shop.lua owner add|del|list [Ник]" }
  end
  return { ok = true, lines = lines }
end

-- команды владельцев, поставленные в очередь на самом сервере (lua shop.lua owner add Ник)
function Net.applyQueue()
  local f = io.open(CONFIG.CMD_PATH, "r")
  if not f then return end
  local data = f:read("*a"); f:close()
  pcall(fs.remove, CONFIG.CMD_PATH)
  for line in data:gmatch("[^\n]+") do
    local cmd, nick = line:match("^(%w+)\t(.+)$")
    if cmd then
      local r = SRV.owner({ cmd = cmd, nick = nick })
      print(r.err or (r.lines and r.lines[1]) or "")
    end
  end
end

-- команды, ответ на которые кэшируется: повтор запроса (потерялся ответ) не должен выполнить его дважды
local IDEMPOTENT = { pushPlayer = true, allocId = true, fbAdd = true, fbOp = true, pushConfig = true, owner = true }
local srvBox, replyCache, replyOrder = {}, {}, {}

local seenTerm, lastBadKey = {}, -100
function Net.serverHandle(e)
  if e[4] ~= CONFIG.NET_PORT or e[6] ~= NET_TAG then return end
  if e[7] ~= CONFIG.NET_KEY then
    if computer.uptime() - lastBadKey > 10 then
      lastBadKey = computer.uptime()
      print("Запрос с неверным NET_KEY от " .. tostring(e[3]):sub(1, 8) .. " (ключ должен совпадать на всех ПК)")
    end
    return
  end
  local remote, rid = e[3], e[8]
  if not seenTerm[remote] then seenTerm[remote] = true; print("Терминал на связи: " .. tostring(remote):sub(1, 8)) end
  if type(rid) ~= "string" then return end
  if replyCache[rid] then netSend(remote, CONFIG.NET_PORT + 1, rid, replyCache[rid]); return end
  local str = netCollect(srvBox, remote .. rid, e[9], e[10], e[11])
  if not str then return end
  local req = ser.unserialize(str)
  local reply
  if type(req) == "table" and req.cmd ~= "owner" and SRV[req.cmd] then
    local ok, r = xpcall(SRV[req.cmd], debug.traceback, type(req.a) == "table" and req.a or {})
    if ok then reply = r else reply = { err = "server: " .. tostring(r):sub(1, 300) }; print(tostring(r)) end
  else
    reply = { err = "unknown command" }
  end
  local out = ser.serialize(reply)
  if req and IDEMPOTENT[req.cmd] then
    replyCache[rid] = out
    replyOrder[#replyOrder + 1] = rid
    if #replyOrder > 100 then replyCache[table.remove(replyOrder, 1)] = nil end
  end
  netSend(remote, CONFIG.NET_PORT + 1, rid, out)
end

---------- терминал: запросы к серверу ----------
local netBox = {}

-- один запрос; возвращает таблицу-ответ или nil, "NETFAIL"
function Net.call(cmd, a, tries)
  ridCounter = ridCounter + 1
  local rid = termId .. "-" .. math.floor(os.time()) .. "-" .. ridCounter
  local payload = ser.serialize({ cmd = cmd, a = a or {}, term = termId })
  for _ = 1, tries or CONFIG.NET_RETRIES do
    netSend(nil, CONFIG.NET_PORT, rid, payload)
    local deadline = computer.uptime() + CONFIG.NET_TIMEOUT
    while true do
      local left = deadline - computer.uptime()
      if left <= 0 then break end
      local e = table.pack(event.pullMultiple(left, "modem_message", "player_off"))
      if e[1] == "player_off" then
        pendingOff = true
      elseif e[1] == "modem_message" and e[4] == CONFIG.NET_PORT + 1 and e[6] == NET_TAG
             and e[7] == CONFIG.NET_KEY and e[8] == rid then
        local str = netCollect(netBox, rid, e[9], e[10], e[11])
        if str then
          local r = ser.unserialize(str)
          if type(r) == "table" then return r end
          return nil, "NETFAIL"
        end
        deadline = computer.uptime() + CONFIG.NET_TIMEOUT      -- куски идут: ждём остальные
      end
    end
  end
  return nil, "NETFAIL"
end

-- запрос: при обрыве связи бросает понятное игроку сообщение; ответ-отказ (r.err) возвращает как есть
function Net.try(cmd, a, tries)
  local r = Net.call(cmd, a, tries)
  if not r then error("USERMSG:Нет связи с сервером. Попробуйте позже.", 0) end
  return r
end

-- то же, но любой отказ сервера тоже считается ошибкой
function Net.req(cmd, a, tries)
  local r = Net.try(cmd, a, tries)
  if r.err then error("USERMSG:Ошибка сервера: " .. tostring(r.err):sub(1, 120), 0) end
  return r
end

local function applyCfg(c, ver)
  db.kits, db.topup = c.kits or {}, c.topup or {}
  db.nextKitId = c.nextKitId or 1
  db.withdraw = c.withdraw or false
  Net.cfgVer = ver or 0
  Net.cfgSnap = Net.owner and ser.serialize(cfgOf()) or nil     -- снимок нужен только владельцу (чтобы заметить правки)
end

function Net.pullConfig()
  local r = Net.req("config", {})
  applyCfg(r.cfg, r.ver)
end

function Net.pullPlayer(name)
  local r = Net.req("player", { name = name })
  r.player.name = name
  r.player.purchases = r.player.purchases or {}
  db.players[lower(name)] = r.player
end

-- вход игрока: данные игрока + настройки магазина одним запросом
function Net.login(name, uid)
  local r = Net.call("login", { name = name, uid = uid and tostring(uid) })
  if not r or not r.ok then return nil, "NETFAIL" end
  db.players = {}
  r.player.name = name
  r.player.purchases = r.player.purchases or {}
  db.players[lower(name)] = r.player
  Net.who, Net.owner, Net.unread, Net.fbLoaded = name, r.owner, r.unread or 0, false
  db.feedback = {}
  Net.res = nil
  applyCfg(r.cfg, r.ver)
  return r
end

function Net.logout()
  db.players, db.feedback = {}, {}
  Net.who, Net.owner, Net.cfgSnap, Net.fbLoaded = nil, false, nil, false
  Net.res = nil
end

-- отправка записи игрока; false, причина - если сервер не принял
local function pushPlayerRec(p, chk, tries)
  local r = Net.try("pushPlayer", { name = p.name, base = p.rev or 0,
                                    rec = { balance = p.balance, purchases = p.purchases }, chk = chk }, tries)
  Net.res = nil
  if r.ok then p.rev = r.rev; return true end
  return false, r.err
end

-- откат: взять запись игрока у сервера заново (если не получилось - убрать локальную, она подтянется позже)
local function rollbackPlayer(name)
  if not pcall(Net.pullPlayer, name) then db.players[lower(name)] = nil end
end

-- saveDB() терминала: отправить правки (настройки - только от владельца, запись игрока - всегда)
function Net.flush()
  if Net.owner and Net.who then
    local snap = ser.serialize(cfgOf())
    if snap ~= Net.cfgSnap then
      local r = Net.try("pushConfig", { who = Net.who, base = Net.cfgVer, cfg = cfgOf() }, 5)
      if r.err == "stale" then
        pcall(Net.pullConfig)
        error("USERMSG:Настройки изменили с другого терминала. Действие отменено, повторите.", 0)
      end
      if r.err then error("USERMSG:Ошибка сервера: " .. tostring(r.err):sub(1, 120), 0) end
      Net.cfgVer, Net.cfgSnap = r.ver, snap
    end
  end
  for _, p in pairs(db.players) do
    local okc, ok, why = pcall(pushPlayerRec, p, nil, 5)
    if not okc then rollbackPlayer(p.name); error(ok, 0) end
    if not ok then
      rollbackPlayer(p.name)
      error("USERMSG:Данные игрока обновились на другом терминале. Повторите действие.", 0)
    end
  end
end

-- покупка: записать игрока с проверкой остатков на сервере. true или false, текст для игрока
function Net.commitPlayer(p, chk)
  local name = p.name
  local okc, ok, why = pcall(pushPlayerRec, p, chk, 5)
  if not okc then rollbackPlayer(name); error(ok, 0) end
  if ok then return true end
  rollbackPlayer(name)
  if why == "stock" then return false, "Комплект только что закончился (его купили на другом терминале)." end
  return false, "Данные игрока обновились на другом терминале. Повторите действие."
end

function Net.newPurchaseId()
  if MODE == "terminal" then return Net.req("allocId", {}).id end
  local id = db.nextPurchaseId
  db.nextPurchaseId = id + 1
  return id
end

-- отзывы владельца
local fbStamp
function Net.fbEnsure(force)
  if MODE ~= "terminal" then return end
  if force or not Net.fbLoaded or computer.uptime() - (fbStamp or 0) > 5 then
    local r = Net.req("fbList", {})
    db.feedback, Net.unread, Net.fbLoaded, fbStamp = r.list or {}, r.unread or 0, true, computer.uptime()
  end
end
function Net.fbMarkRead()
  if MODE == "terminal" then pcall(Net.req, "fbOp", { op = "read" }); Net.unread = 0
  else saveDB() end
end
function Net.fbDelete(idx)
  if MODE == "terminal" then
    local f = db.feedback[idx]
    if f then Net.req("fbOp", { op = "del", id = f.id }) end
    Net.fbEnsure(true)
  else table.remove(db.feedback, idx); saveDB() end
end
function Net.fbClear()
  if MODE == "terminal" then Net.req("fbOp", { op = "clear" }); db.feedback = {}
  else db.feedback = {}; saveDB() end
end
function Net.fbAddEntry(player, text)
  if MODE == "terminal" then Net.req("fbAdd", { player = player, text = text }); return end
  db.feedback[#db.feedback + 1] = { player = player, text = text, time = os.time(), read = false }
  while #db.feedback > CONFIG.FEEDBACK_KEEP do table.remove(db.feedback, 1) end
  saveDB()
end
end

----------------------------------------------------------------------
-- ME: кэш остатков (сканируется при входе игрока и по кнопке "Обновить")
----------------------------------------------------------------------
-- cache.byKey  - остатки только нужных магазину предметов
-- cache.items  - список для выбора предметов (ТОЛЬКО у владельца, только в окне выбора,
--                максимум CONFIG.PICK_MAX штук, фильтруется поиском)
local cache = { items = {}, byKey = {}, time = nil, pickMore = false, pickTotal = 0 }

-- какие предметы нужны магазину: комплекты, ресурсы пополнения, неотданные покупки
-- Владелец (full=true): комплекты, пополнение и покупки ВСЕХ игроков (нужно для миграции и учёта резерва).
-- Клиент: комплекты, пополнение и только его собственные покупки - меньше предметов, меньше ОЗУ.
local function wantedNames(who, full)
  local w = {}
  for _, k in ipairs(db.kits) do for _, it in ipairs(k.items) do w[it.name] = true end end
  for _, t in ipairs(db.topup) do w[t.name] = true end
  if db.withdraw then w[db.withdraw.name] = true end
  local mine = who and lower(who)
  if MODE == "terminal" and full then
    local ok, r = pcall(Net.req, "wanted", {})
    if ok then for n in pairs(r.names or {}) do w[n] = true end end
  end
  for key, p in pairs(db.players) do
    if full or not mine or key == mine then
      for _, pu in ipairs(p.purchases or {}) do
        for _, it in ipairs(pu.items) do w[it.name] = true end
      end
    end
  end
  return w
end

-- Миграция старых записей: var был названием жидкости ("chocolatemilk"), теперь это NBT-хеш "#...".
local function migrateVariants(by)
  local changed = false
  local function fix(x)
    local v = x.var or ""
    if v ~= "" and v:sub(1, 1) ~= "#" then
      for _, e in pairs(by) do
        if e.name == x.name and e.damage == x.damage and e.fluid == v and e.var:sub(1, 1) == "#" then
          x.var = e.var; changed = true; break
        end
      end
    end
  end
  for _, k in ipairs(db.kits) do for _, it in ipairs(k.items) do fix(it) end end
  for _, t in ipairs(db.topup) do fix(t) end
  if db.withdraw then fix(db.withdraw) end
  for _, p in pairs(db.players) do
    for _, pu in ipairs(p.purchases or {}) do for _, it in ipairs(pu.items) do fix(it) end end
  end
  if changed then saveDB() end
end

-- Список предметов ME с NBT-хешем.
-- Обычные предметы берём из getItemsInNetwork (там есть название), а предметы с NBT (hasTag),
-- например баки с жидкостью, - из getAvailableItems: там у fingerprint есть nbt_hash.
-- Жидкость и название NBT-предмета читаем из getItemDetail (кэш по хешу).
-- fname/fdmg - необязательный фильтр по одному предмету.
-- Кэш деталей NBT-предметов ограничен по размеру и хранит только нужные поля (экономия ОЗУ).
local detailCache, detailCount, DETAIL_MAX = {}, 0, 200
memReleasers[#memReleasers + 1] = function() detailCache, detailCount = {}, 0 end   -- 2) детали NBT-предметов
local function shallow(t)
  if type(t) ~= "table" then return nil end
  local r = {}
  for k, v in pairs(t) do if type(v) ~= "table" then r[k] = v end end
  return r
end
-- Из полного списка getAvailableItems берём ТОЛЬКО NBT-предметы (маленькая таблица),
-- а сам огромный список сразу отпускаем: он не должен жить одновременно с getItemsInNetwork.
-- match(f) - фильтр по fingerprint (f.id, f.dmg).
local function taggedFromRaw(match)
  gc()                                 -- освободить память ДО тяжёлого запроса
  memGuard()                           -- и выгрузить кэши, если ОЗУ на исходе
  local ok, raw = pcall(me.getAvailableItems)
  if not ok or type(raw) ~= "table" then return nil end
  local t = {}
  for _, e in ipairs(raw) do
    local f = type(e) == "table" and e.fingerprint
    if type(f) == "table" and f.id and f.nbt_hash and match(f) then
      local fp = {}
      for k, v in pairs(f) do fp[k] = v end
      t[#t + 1] = { fp = fp, qty = tonumber(e.qty or e.size) or 0 }
    end
  end
  raw = nil
  gc()                                 -- огромный список больше не нужен
  return t
end

-- Склеивает обычные предметы из base (без hasTag) и NBT-предметы из tagged (с деталями из кэша).
-- Нет NBT-предметов - возвращает base как есть.
local function mergeTagged(base, tagged)
  if not tagged or #tagged == 0 then return base end
  local out = {}
  for _, it in ipairs(base) do
    if type(it) == "table" and not it.hasTag then out[#out + 1] = it end
  end
  for _, e in ipairs(tagged) do
    local f = e.fp
    local it = { name = f.id, damage = f.dmg, size = e.qty,
                 nbt_hash = f.nbt_hash, label = f.id, maxSize = 64 }
    local d = detailCache[f.nbt_hash]
    if d == nil then
      local ok3, det = pcall(me.getItemDetail, f)
      if ok3 and type(det) == "table" and det.all ~= nil then
        local ok4, all = pcall(det.all); if ok4 then det = all end
      end
      d = false
      if ok3 and type(det) == "table" then
        local fc = shallow(det.fluid_container)
        if fc and type(det.fluid_container.contents) == "table" then
          fc.contents = shallow(det.fluid_container.contents)
        end
        d = { label = det.display_name or det.label, fluid_container = fc,
              maxSize = tonumber(det.max_size or det.maxSize) }
      end
      if detailCount >= DETAIL_MAX then detailCache, detailCount = {}, 0 end
      detailCache[f.nbt_hash] = d
      detailCount = detailCount + 1
    end
    if d then
      it.label = d.label or it.label
      it.fluid_container = d.fluid_container
      it.maxSize = d.maxSize or 64
    end
    out[#out + 1] = it
  end
  return out
end

local function meList(fname, fdmg)
  local function fmatch(f)
    return not fname or (f.id == fname and (fdmg == nil or math.floor(tonumber(f.dmg) or 0) == fdmg))
  end
  local ok, base, tagged
  if fname then
    ok, base = pcall(me.getItemsInNetwork, { name = fname, damage = fdmg })
    if not ok then return tostring(base) end
    if type(base) ~= "table" then return base end
    if me.getAvailableItems == nil then return base end
    -- тяжёлый getAvailableItems нужен только если среди предметов есть NBT
    local anyTag = false
    for _, it in ipairs(base) do
      if type(it) == "table" and it.hasTag then anyTag = true; break end
    end
    if not anyTag then return base end
    tagged = taggedFromRaw(fmatch)
  else
    -- полный список: сначала NBT-предметы (большой raw тут же освобождается), потом обычные
    if me.getAvailableItems ~= nil then tagged = taggedFromRaw(fmatch); gc() end
    ok, base = pcall(me.getItemsInNetwork)
    if not ok then return tostring(base) end
    if type(base) ~= "table" then return base end
  end
  return mergeTagged(base, tagged)
end

-- Лёгкий скан при входе: запоминаем остатки только нужных предметов.
-- who - ник игрока, full - владелец ли он (см. wantedNames).
-- Если нужных id немного, спрашиваем ME по каждому отдельно (маленькие ответы) вместо полного
-- списка сети. Полный список с NBT (getAvailableItems) берём только если среди ответов есть NBT-предметы.
-- Словарь переводов здесь не нужен: названия уже лежат в записях комплектов и покупок.
local function scanME(who, full)
  return pcall(function()
    local want, names = wantedNames(who, full), {}
    for n in pairs(want) do names[#names + 1] = n end

    local list, anyTag = {}, false
    if #names > 0 then
      if #names <= 200 then          -- по одному id (маленькие ответы); полный список сети - только в крайнем случае
        for _, n in ipairs(names) do
          local ok, part = pcall(me.getItemsInNetwork, { name = n })
          if not ok then error("ME вернула " .. tostring(part)) end
          if type(part) ~= "table" then error("ME вернула " .. tostring(part)) end
          memGuard()
          for _, it in ipairs(part) do
            if type(it) == "table" then
              if it.hasTag then anyTag = true end
              list[#list + 1] = it
            end
          end
        end
        if anyTag and me.getAvailableItems ~= nil then
          -- есть NBT-предметы: один раз берём их хеши (только нужные id), полный список сети не держим
          list = mergeTagged(list, taggedFromRaw(function(f) return want[f.id] end))
        end
      else
        list = meList()
        if type(list) ~= "table" then error("ME вернула " .. tostring(list)) end
      end
    end

    local by = {}
    for _, it in ipairs(list) do
      local name = type(it) == "table" and it.name
      if name and want[name] then
        local dmg = math.floor(tonumber(it.damage) or 0)
        local size = tonumber(it.size) or 0
        local var = variantOf(it)
        local k = itemKey(name, dmg, var)
        local e = by[k]
        if e then e.size = e.size + size
        else
          by[k] = { key = k, name = name, damage = dmg, var = var, fluid = fluidVariant(it),
                    label = labelOf(it, var, true), size = size, maxSize = tonumber(it.maxSize) or 64 }
        end
      end
    end
    list = nil
    migrateVariants(by)
    cache.byKey, cache.time = by, computer.uptime()
    gc()
  end)
end

-- нормализация для поиска: нижний регистр, разделители -> пробелы
local function searchNorm(s)
  return (lower(s):gsub("[_:%-%.]", " "))
end

-- Список для выбора предметов (владелец): ВСЕ предметы ME, отсортированные по алфавиту.
-- Поиск: каждое слово запроса должно встречаться в названии или id предмета.
local function pickerScan(filter)
  cache.items = {}
  gc()                                 -- результаты прошлого поиска и мусор от них - долой до нового запроса
  return pcall(function()
    local list = meList()
    if type(list) ~= "table" then error("ME вернула " .. tostring(list)) end

    local words = {}
    for w in searchNorm(filter or ""):gmatch("%S+") do words[#words + 1] = w end

    -- Сортируем исходный список прямо на месте (без копий): предметы одного мода идут подряд,
    -- поэтому файл словаря мода читается один раз, а не дёргается по кругу.
    table.sort(list, function(a, b)
      local an = type(a) == "table" and tostring(a.name) or ""
      local bn = type(b) == "table" and tostring(b.name) or ""
      if an ~= bn then return an < bn end
      return (type(a) == "table" and tonumber(a.damage) or 0) < (type(b) == "table" and tonumber(b.damage) or 0)
    end)

    local function cmp(a, b)
      if a[3] ~= b[3] then return a[3] < b[3] end
      if a[1] ~= b[1] then return a[1] < b[1] end
      return a[2] < b[2]
    end

    -- В памяти держим не все предметы ME, а только PICK_MAX первых по алфавиту:
    -- копим буфер и, когда он вырос вдвое, сортируем и обрезаем.
    -- Без поискового запроса список уже отсортирован по id, поэтому первые K записей известны сразу:
    -- название (а с ним словарь перевода) считаем только для них, а не для всех предметов сети.
    -- С запросом название нужно каждому предмету (по нему идёт поиск).
    local K = CONFIG.PICK_MAX
    local buf, total = {}, 0
    local pName, pDmg, pVar, prevEntry
    local searching = #words > 0
    for i = 1, #list do
      local it = list[i]
      list[i] = false                  -- отпускаем ссылку сразу, как обработали
      if i % 64 == 0 then memGuard() end
      local name = type(it) == "table" and it.name
      if name then
        local dmg = math.floor(tonumber(it.damage) or 0)
        local var = variantOf(it)
        if name == pName and dmg == pDmg and var == pVar then
          -- тот же предмет подряд (несколько стеков): складываем количество
          if prevEntry then prevEntry[4] = prevEntry[4] + (tonumber(it.size) or 0) end
        elseif not searching then
          pName, pDmg, pVar = name, dmg, var
          total = total + 1
          if #buf < K then
            prevEntry = { name, dmg, labelOf(it, var), tonumber(it.size) or 0, tonumber(it.maxSize) or 64, var }
            buf[#buf + 1] = prevEntry
          else
            prevEntry = nil
          end
        else
          local label = labelOf(it, var)
          local hay = searchNorm(label .. " " .. tostring(it.label) .. " " .. name)
          local match = true
          for _, w in ipairs(words) do
            if not hay:find(w, 1, true) then match = false; break end
          end
          if match then
            local e = { name, dmg, label, tonumber(it.size) or 0, tonumber(it.maxSize) or 64, var }
            pName, pDmg, pVar, prevEntry = name, dmg, var, e
            total = total + 1
            buf[#buf + 1] = e
            if #buf >= K * 2 then
              table.sort(buf, cmp)
              for j = #buf, K + 1, -1 do buf[j] = nil end
            end
          end
        end
      end
    end
    list = nil
    table.sort(buf, cmp)
    local more = total > K
    for j = #buf, K + 1, -1 do buf[j] = nil end
    cache.items, cache.pickTotal, cache.pickMore = buf, total, more
    gc()
  end)
end
-- точный запрос по одному предмету (дёшево, используется при покупке/выдаче)
local function meCount(name, damage, var)
  local list = meList(name, damage)
  if type(list) ~= "table" then return nil end
  local total = 0
  for _, it in ipairs(list) do
    if it.name == name and math.floor(tonumber(it.damage) or 0) == damage
       and variantOf(it) == (var or "") then
      total = total + (tonumber(it.size) or 0)
    end
  end
  return total
end

-- Подбирает вариант предмета из ME под вариант из инвентаря (PIM и ME могут описывать
-- один и тот же предмет по-разному: жидкость / хеш). Возвращает вариант ME и остаток, либо nil.
local function meResolve(name, damage, var)
  var = var or ""
  local list = meList(name, damage)
  if type(list) ~= "table" then return nil end
  local sizes, order = {}, {}
  for _, it in ipairs(list) do
    if it.name == name and math.floor(tonumber(it.damage) or 0) == damage then
      local v = variantOf(it)
      if sizes[v] == nil then sizes[v] = 0; order[#order + 1] = v end
      sizes[v] = sizes[v] + (tonumber(it.size) or 0)
    end
  end
  if sizes[var] then return var, sizes[var] end
  if #order == 1 then return order[1], sizes[order[1]] end
  for _, v in ipairs(order) do
    if sameVariant(v, var) then return v, sizes[v] end
  end
  return nil
end

local function availFn()
  local res = reservedMap()
  return function(key)
    local e = cache.byKey[key]
    return math.max(0, (e and e.size or 0) - (res[key] or 0))
  end
end

local function kitStock(kit, avail)
  if #kit.items == 0 then return 0 end
  local m = math.huge
  for _, it in ipairs(kit.items) do
    m = math.min(m, math.floor(avail(itemKey(it.name, it.damage, it.var)) / it.qty))
  end
  return m
end

local function refreshRemaining()
  if not cache.time then return 0 end
  return math.max(0, math.ceil(CONFIG.REFRESH_COOLDOWN - (computer.uptime() - cache.time)))
end

local function ageText()
  if not cache.time then return "не сканировалась" end
  local s = math.floor(computer.uptime() - cache.time)
  if s < 60 then return s .. " с назад" end
  return math.floor(s / 60) .. " мин назад"
end

----------------------------------------------------------------------
-- PIM: инвентарь игрока
----------------------------------------------------------------------
local function stackInfo(st)
  local dmg = st.dmg or st.damage or 0
  return st.id or st.name, math.floor(tonumber(dmg) or 0), tonumber(st.qty or st.size) or 1,
         tonumber(st.max_size or st.maxSize) or 64, variantOf(st)
end

-- читает 36 слотов: slots[s] = false (пусто) | {name,damage,qty,max,var} | nil (ошибка чтения)
local function readSlots()
  local slots = {}
  for s = 1, 36 do
    local ok, st = pcall(pim.getStackInSlot, s)
    if ok then
      if st then
        local n, d, q, mx, v = stackInfo(st)
        slots[s] = { name = n, damage = d, qty = q, max = mx, var = v }
      else
        slots[s] = false
      end
    end
  end
  return slots
end

-- подходит ли стек из слота под запись (id + damage + вариант: жидкость / NBT-хеш)
local function stackMatches(st, name, damage, var)
  if not st or st.name ~= name or st.damage ~= damage then return false end
  var = var or ""
  local sv = st.var or ""
  if sv == var then return true end
  -- PIM не всегда отдаёт тип жидкости: стек без варианта подходит под запись с жидкостью
  if sv == "" and var ~= "" and var:sub(1, 1) ~= "#" then return true end
  return sameVariant(sv, var)
end

local function countIn(slots, name, damage, var)
  local c = 0
  for s = 1, 36 do
    local st = slots[s]
    if stackMatches(st, name, damage, var) then c = c + st.qty end
  end
  return c
end

-- сколько штук предмета ещё влезет в инвентарь (пустые слоты + недобитые стаки)
local function spaceIn(slots, name, damage, maxSize, var)
  local space = 0
  for s = 1, 36 do
    local st = slots[s]
    if st == false then
      space = space + maxSize
    elseif stackMatches(st, name, damage, var) then
      space = space + math.max(0, maxSize - st.qty)
    end
  end
  return space
end

-- количество конкретного предмета в одном слоте (nil - ошибка чтения)
local function slotQty(s, name, damage)
  local ok, st = pcall(pim.getStackInSlot, s)
  if not ok then return nil end
  if not st then return 0 end
  local n, d, q = stackInfo(st)
  if n == name and d == damage then return q end
  return 0
end

-- Список для выбора предметов из ИНВЕНТАРЯ игрока на PIM (тот же формат, что у pickerScan):
-- { name, damage, label, qty_в_инвентаре, maxSize, var }
local function invPickerScan(filter)
  cache.items = {}
  return pcall(function()
    local words = {}
    for w in searchNorm(filter or ""):gmatch("%S+") do words[#words + 1] = w end

    local out, seen = {}, {}
    for s = 1, 36 do
      local ok, st = pcall(pim.getStackInSlot, s)
      if ok and st then
        local name, dmg, qty, mx, var = stackInfo(st)
        if name then
          local label = labelOf({ name = name, damage = dmg,
                                  label = st.display_name or st.label or st.rawName or name }, var)
          local match = true
          if #words > 0 then
            local hay = searchNorm(label .. " " .. tostring(name))
            for _, w in ipairs(words) do
              if not hay:find(w, 1, true) then match = false; break end
            end
          end
          if match then
            local k = itemKey(name, dmg, var)
            local e = seen[k]
            if e then
              e[4] = e[4] + qty
            else
              e = { name, dmg, label, qty, mx, var }
              seen[k] = e
              out[#out + 1] = e
            end
          end
        end
      end
    end
    table.sort(out, function(a, b)
      if a[3] ~= b[3] then return a[3] < b[3] end
      if a[1] ~= b[1] then return a[1] < b[1] end
      return a[2] < b[2]
    end)
    cache.items, cache.pickTotal, cache.pickMore = out, #out, false
  end)
end

----------------------------------------------------------------------
-- ЭКРАН: примитивы и сетка
--
--   колонка 1 и колонка W - пустые поля; содержимое занимает 2 .. W-1
--   строки: 1 шапка | 3-5 вкладки | 6 сообщение | 7+ содержимое (сдвиг UI.oy) |
--           список карточек по 3 строки + 1 пропуск | H-3..H-1 подвал (строка H пустая)
----------------------------------------------------------------------
local W, H = 160, 50
local C = {
  bg = 0x101010, panel = 0x1e1e1e, panel2 = 0x2d2d2d, bar = 0x0a0a0a,
  text = 0xdddddd, dim = 0x888888, accent = 0x68f029, gold = 0xf2b233,
  red = 0xff5555, blue = 0x2f5fb3, green = 0x2f7d1a, disabled = 0x262626,
  tabOn = 0x3a7d1e, tabOff = 0x2a2a2a, dlg = 0x2a2a2a,
}
local UI = { btns = {}, tag = nil, oy = 0 }   -- oy: сдвиг по Y для содержимого вкладок
local CONTENT_OY = 1                          -- на сколько строк содержимое ниже базовой сетки

local LIST_Y = 10       -- начало списка карточек на обычных экранах
local SUB_Y  = 14       -- начало списка на вкладке «Создание»
local BW     = 18       -- стандартная ширина кнопки в карточке
local BW2    = 14       -- ширина кнопок, когда их две в ряд

-- положение текста внутри карточки (полоска 3 строки): было 0 и 2
local CARD_TITLE_DY, CARD_SUB_DY = 0, 1

local function fill(x, y, w, h, bg)
  if w <= 0 or h <= 0 then return end
  gpu.setBackground(bg)
  gpu.fill(x, y + UI.oy, w, h, " ")
end

local function text(x, y, s, fg, bg)
  gpu.setBackground(bg or C.bg)
  gpu.setForeground(fg or C.text)
  gpu.set(x, y + UI.oy, s)
end

-- рамка из символов псевдографики (края окна, чтобы не сливались с фоном)
local function frame(x, y, w, h, fg, bg)
  gpu.setBackground(bg or C.dlg)
  gpu.setForeground(fg or C.accent)
  gpu.set(x, y + UI.oy, "╭" .. string.rep("─", w - 2) .. "╮")
  gpu.set(x, y + UI.oy + h - 1, "╰" .. string.rep("─", w - 2) .. "╯")
  gpu.fill(x, y + UI.oy + 1, 1, h - 2, "│")
  gpu.fill(x + w - 1, y + UI.oy + 1, 1, h - 2, "│")
end

-- текст по центру экрана
local function ctext(y, s, fg, bg)
  s = tostring(s)
  text(math.floor((W - unicode.len(s)) / 2) + 1, y, s, fg, bg)
end

local function addBtn(x, y, w, h, label, o)
  o = o or {}
  local bg = o.disabled and C.disabled or (o.bg or C.panel2)
  local fg = o.disabled and C.dim or (o.fg or C.text)
  fill(x, y, w, h, bg)
  label = tostring(label)
  local l = unicode.len(label)
  if l > w then label = unicode.sub(label, 1, w); l = w end
  text(x + math.floor((w - l) / 2), y + math.floor((h - 1) / 2), label, fg, bg)
  if not o.disabled and o.fn then
    UI.btns[#UI.btns + 1] = { x = x, y = y + UI.oy, w = w, h = h, fn = o.fn, tag = UI.tag }
  end
end

-- кнопка, прижатая к правому краю содержимого (последняя колонка = W-1).
-- off - отступ от правого края; возвращает отступ для следующей кнопки слева.
local function rb(y, off, w, label, o)
  addBtn(W - off - w, y, w, 3, label, o)
  return off + w + 1
end

-- карточка на всю ширину содержимого; reserve - сколько колонок справа занято кнопками
local function card(y, title, sub, subColor, reserve)
  reserve = reserve or (BW + 2)
  local tw = math.max(1, W - reserve - 4)
  fill(2, y, W - 2, 3, C.panel)
  text(3, y + CARD_TITLE_DY, pad(title, tw), C.accent, C.panel)
  text(3, y + CARD_SUB_DY, pad(sub, tw), subColor or C.dim, C.panel)
end

-- карточка в одну строку: Название (accent) + KIT_GAP колонок + информация.
-- Строка прижата к левому краю карточки и стоит по центру полоски по вертикали
-- (средняя из трёх). reserve - сколько колонок справа занято кнопками.
local KIT_GAP = 10
local PENCIL_W = 3
local function lineCard(y, title, info, infoColor, reserve, onEdit)
  reserve = reserve or (BW + 2)
  fill(2, y, W - 2, 3, C.panel)
  local x0 = 3                                          -- левый край (как у остальных карточек)
  local shift = 0
  if onEdit then                                        -- маленький карандаш слева: переименовать
    addBtn(x0, y, PENCIL_W, 3, "✎", { bg = C.blue, fg = 0xffffff, fn = onEdit })
    shift = PENCIL_W + 1
    x0 = x0 + shift
  end
  local rw = math.max(10, W - reserve - 1 - shift)      -- ширина области: колонки 2 .. rw+1
  title, info = tostring(title), tostring(info)
  local li = unicode.len(info)
  local room = rw - 2 - KIT_GAP - li
  if room < 6 then                                      -- не влезает: режем информацию
    info = unicode.sub(info, 1, math.max(1, rw - 2 - KIT_GAP - 6)); li = unicode.len(info)
    room = 6
  end
  if unicode.len(title) > room then title = unicode.sub(title, 1, room) end
  local lt = unicode.len(title)
  text(x0, y + 1, title, C.accent, C.panel)
  text(x0 + lt + KIT_GAP, y + 1, info, infoColor or C.text, C.panel)
end

----------------------------------------------------------------------
-- СОСТОЯНИЕ
----------------------------------------------------------------------
local S = { player = nil }
-- 4) список окна выбора: освобождаем, только если окно выбора сейчас не открыто
memReleasers[#memReleasers + 1] = function()
  if not (S.player and S.view == "pick") then cache.items = {} end
end
pendingOff = false
local running = true
local render, nav, flash, status   -- объявлены заранее

-- сообщение рисуется в собственной строке 6 (без сдвига), содержимое его не затирает
local function drawMessage()
  local oy = UI.oy; UI.oy = 0
  fill(1, 6, W, 1, C.bg)
  if S.msg and S.msg ~= "" then
    text(2, 6, pad(S.msg, W - 2), S.msgOk == false and C.red or C.accent, C.bg)
  end
  UI.oy = oy
end

status = function(msg) S.msg = msg; S.msgOk = true; drawMessage() end
flash  = function(msg, ok) S.msg = msg; S.msgOk = (ok ~= false); render() end
nav = function(fields, msg, ok)
  for k, v in pairs(fields or {}) do S[k] = v end
  S.page = 1; S.confirm = nil; S.backFn = nil
  S.msg = msg or ""; S.msgOk = (ok ~= false)
  render()
end

-- Ctrl+Alt+C: ожидание события бросает "interrupted". В режиме киоска глотаем это
-- и ждём дальше (в режиме debug ошибка пробрасывается, программу можно остановить).
local function safePull(fn, ...)
  while true do
    local r = table.pack(pcall(fn, ...))
    if r[1] then return table.unpack(r, 2, r.n) end
    if ARGS[1] == "debug" or not tostring(r[2]):find("interrupted", 1, true) then error(r[2], 0) end
    os.sleep(0.05)
  end
end

-- Крестик «закрыть» внутри окна, в строке заголовка (справа, с отступом от рамки).
-- Esc в игре закрывает сам GUI экрана и до программы не доходит, поэтому отмена
-- делается касанием крестика.
local CROSS_W, CROSS_H = 3, 1
local function crossPos(bx, by, bw)
  return bx + bw - CROSS_W - 2, by + 1     -- внутри рамки: 1 колонка отступа от правой границы
end
local function drawCross(bx, by, bw)
  local x, y = crossPos(bx, by, bw)
  fill(x, y, CROSS_W, CROSS_H, 0x8a2222)
  text(x + math.floor(CROSS_W / 2), y, "×", 0xffffff, 0x8a2222)
end
local function hitCross(e, bx, by, bw)
  local x, y = e[3], e[4]
  if type(x) ~= "number" or type(y) ~= "number" then return false end
  local cx, cy = crossPos(bx, by, bw)
  return x >= cx and x <= cx + CROSS_W - 1
     and y == cy + UI.oy
end

local function prompt(title, initial, maxLen)
  maxLen = maxLen or 60
  local bw = math.min(W - 4, 80)
  local bh = 7
  local bx, by = math.floor((W - bw) / 2) + 1, math.floor((H - bh) / 2) + 1
  local buf = initial or ""
  local function draw()
    fill(bx, by, bw, bh, C.dlg)
    frame(bx, by, bw, bh, C.accent, C.dlg)                 -- рамка окна
    text(bx + 2, by + 1, pad(title, bw - 6 - CROSS_W), C.gold, C.dlg)
    drawCross(bx, by, bw)
    frame(bx + 2, by + 2, bw - 4, 3, C.dim, C.dlg)         -- рамка поля ввода
    fill(bx + 3, by + 3, bw - 6, 1, 0x000000)
    local shown, room = buf, bw - 8
    if unicode.len(shown) > room then shown = unicode.sub(shown, unicode.len(shown) - room + 1) end
    text(bx + 3, by + 3, shown .. "_", C.accent, 0x000000)
    text(bx + 2, by + 5, pad("Enter - принять,  × - отмена", bw - 4), C.dim, C.dlg)
  end
  draw()
  while true do
    local e = table.pack(safePull(event.pullMultiple, "key_down", "touch", "player_off"))
    if e[1] == "player_off" then pendingOff = true; return nil end
    local who = (e[1] == "touch") and e[6] or e[5]
    if e[1] == "touch" then
      if (not who or not S.player or lower(who) == lower(S.player.name)) and hitCross(e, bx, by, bw) then
        return nil
      end
    elseif not who or not S.player or lower(who) == lower(S.player.name) then
      local ch, code = e[3], e[4]
      if code == 28 or code == 156 or ch == 13 then return buf
      elseif code == 1 then return nil
      elseif code == 14 or ch == 8 then
        if unicode.len(buf) > 0 then buf = unicode.sub(buf, 1, unicode.len(buf) - 1) end
        draw()
      elseif ch and ch >= 32 and ch ~= 127 and unicode.len(buf) < maxLen then
        buf = buf .. unicode.char(ch)
        draw()
      end
    end
  end
end

local function askNumber(title, initial, integer)
  local s = prompt(title, initial and tostring(initial) or "", 12)
  if not s then return nil end
  s = trim((s:gsub(",", ".")))
  if not s:match("^%d+%.?%d*$") then return nil end     -- только обычная запись: без 0x10, 1e300, inf
  local n = tonumber(s)
  if not n or n ~= n or n < 0 or n > 10000000 then return nil end
  if integer then n = math.floor(n) end
  return n
end

-- цена: строго больше нуля
local function askPrice(title, initial)
  local v = askNumber(title, initial, false)
  if v and round2(v) <= 0 then
    flash("Цена не может быть 0. Укажите значение больше нуля.", false)
    return nil
  end
  return v
end

local function modal(title, body)
  local bw = math.min(W - 4, 100)
  local lines = wrap(body, bw - 4)
  local bh = #lines + 5
  local bx, by = math.floor((W - bw) / 2) + 1, math.max(2, math.floor((H - bh) / 2) + 1)
  fill(bx, by, bw, bh, C.dlg)
  frame(bx, by, bw, bh, C.gold, C.dlg)                     -- рамка окна
  text(bx + 2, by + 1, pad(title, bw - 6 - CROSS_W), C.gold, C.dlg)
  drawCross(bx, by, bw)
  for i, l in ipairs(lines) do text(bx + 2, by + 2 + i, l, C.text, C.dlg) end
  text(bx + 2, by + bh - 1, pad("Коснитесь экрана, чтобы закрыть", bw - 4), C.dim, C.dlg)
  while true do
    local e = table.pack(safePull(event.pullMultiple, "touch", "key_down", "player_off"))
    if e[1] == "player_off" then pendingOff = true; return end
    local who = (e[1] == "touch") and e[6] or e[5]
    if not who or not S.player or lower(who) == lower(S.player.name) then return end
  end
end

----------------------------------------------------------------------
-- ДЕЙСТВИЯ: покупка, выдача, пополнение, обновление, отзывы
----------------------------------------------------------------------
local function scanInventory()
  status("Читаю инвентарь...")
  S.slots = readSlots()
end

local function verifyStock(kit)
  local res = reservedMap(true)
  local chk = {}
  for _, it in ipairs(kit.items) do
    local k = itemKey(it.name, it.damage, it.var)
    local real
    if (it.var or "") == "" then
      -- обычный предмет: точный лёгкий запрос по одному id (без getAvailableItems)
      real = meCount(it.name, it.damage, it.var)
      if real == nil then return false, "ME-сеть недоступна. Попробуйте позже." end
      if cache.byKey[k] then cache.byKey[k].size = real end
    else
      -- NBT-предмет: точный запрос требует полного списка ME (дорого по ОЗУ),
      -- поэтому берём остаток из кэша; реальное наличие всё равно проверит doClaim при выдаче
      real = cache.byKey[k] and cache.byKey[k].size or 0
    end
    if real - (res[k] or 0) < it.qty then
      return false, "Комплект только что закончился: не хватает «" .. it.label .. "»."
    end
    chk[#chk + 1] = { key = k, real = real }
  end
  return true, nil, chk
end

local function doBuy(kit)
  local p = getPlayer(S.player.name)
  if #kit.items == 0 then return flash("Комплект пуст.", false) end
  if round2(kit.price) <= 0 then return flash("Цена комплекта не задана.", false) end
  if round2(p.balance) < round2(kit.price) then
    return flash("Не хватает средств: нужно " .. fmt(kit.price) .. ", на балансе " .. fmt(p.balance) ..
                 ". Загляните во вкладку «Пополнение».", false)
  end
  status("Проверяю наличие ресурсов...")
  local ok, err, chk = verifyStock(kit)
  if not ok then return flash(err, false) end

  p.balance = round2(p.balance - kit.price)
  local pu = { id = Net.newPurchaseId(), kit = kit.name, items = {} }
  for _, it in ipairs(kit.items) do
    pu.items[#pu.items + 1] = { name = it.name, damage = it.damage, var = it.var, label = it.label,
                                customLabel = it.customLabel, qty = it.qty }
  end
  p.purchases[#p.purchases + 1] = pu
  if MODE == "terminal" then
    local okc, why = Net.commitPlayer(p, chk)
    if not okc then return flash(why, false) end
  else
    saveDB()
  end
  nav({ view = "purchase", purchaseId = pu.id },
      "Оплачено! Заберите ресурсы кнопками «Забрать» (можно по одному, можно позже).", true)
end

-- Отпечаток предмета для exportItem. Если в записи нет NBT-хеша (ME его не отдаёт, а предмет -
-- бак с жидкостью), ищем хеш среди предметов сети: перебираем getAvailableItems() с тем же id+dmg
-- и сравниваем жидкость в getItemDetail() с нужной.
local lastExportErr
local meFingerprintRaw
-- Кэшируем только маленький результат (fingerprint одного предмета), а не весь список ME:
-- при «Забрать всё» повторные выдачи одного и того же бака не качают getAvailableItems заново.
local fpCache, fpCount = {}, 0
memReleasers[#memReleasers + 1] = function() fpCache, fpCount = {}, 0 end           -- 3) отпечатки предметов
local function meFingerprint(name, dmg, var)
  var = var or ""
  if var == "" then return { id = name, dmg = dmg } end
  local ck = name .. "&&" .. dmg .. "&&" .. var
  local c = fpCache[ck]
  if c then return { id = c.id, dmg = c.dmg, nbt_hash = c.nbt_hash } end
  local f, err = meFingerprintRaw(name, dmg, var)
  if f then
    if fpCount >= 100 then fpCache, fpCount = {}, 0 end
    fpCache[ck] = { id = f.id, dmg = f.dmg, nbt_hash = f.nbt_hash }
    fpCount = fpCount + 1
  end
  return f, err
end

meFingerprintRaw = function(name, dmg, var)
  var = var or ""
  if var == "" then return { id = name, dmg = dmg } end
  -- если хеш известен, getAvailableItems не нужен вообще
  if var:sub(1, 1) == "#" then return { id = name, dmg = dmg, nbt_hash = var:sub(2) } end
  local ok, list = pcall(me.getAvailableItems)
  if not ok or type(list) ~= "table" then
    if var:sub(1, 1) == "#" then return { id = name, dmg = dmg, nbt_hash = var:sub(2) } end
    return nil, "ME не отдала список"
  end
  local hash = var:sub(1, 1) == "#" and var:sub(2) or nil
  local want = lower(var)
  for _, e in ipairs(list) do
    local f = type(e) == "table" and e.fingerprint
    if type(f) == "table" and f.id == name then
      if hash then
        if tostring(f.nbt_hash) == hash then return f end
      elseif f.nbt_hash and math.floor(tonumber(f.dmg) or 0) == dmg then
        local ok2, d = pcall(me.getItemDetail, f)
        if ok2 and type(d) == "table" then
          if d.all ~= nil then local ok3, all = pcall(d.all); if ok3 then d = all end end
          local fc = d.fluid_container
          local raw = type(fc) == "table" and type(fc.contents) == "table" and lower(tostring(fc.contents.rawName or "")) or ""
          if lower(fluidVariant(d)) == want or raw == want then return f end
        end
      end
    end
  end
  return nil, "бак не найден в ME (var=" .. var:sub(1, 12) .. ")"
end

local function doClaim(pu, it, quiet)
  -- quiet: массовая выдача, итог показывает claimAll; возвращает "ok" | "space" | "me" | "fail"
  local function out(msg, ok)
    if quiet then S.msg = msg; S.msgOk = (ok ~= false) else flash(msg, ok) end
  end
  -- в сообщениях хеш не показываем
  local shown = tostring(it.label):gsub("%s*#[%w_%-]+", ""):gsub("%s*%(%s*%)", "")
  if it.qty <= 0 then return "ok" end
  local key = itemKey(it.name, it.damage, it.var)
  local maxSize = (cache.byKey[key] and cache.byKey[key].maxSize) or 64

  status("Проверяю место в инвентаре...")
  local slots = readSlots()
  local space = spaceIn(slots, it.name, it.damage, maxSize, it.var)
  if space <= 0 then
    out("Нет места в инвентаре. Освободите слот и нажмите «Забрать» ещё раз.", false)
    return "space"
  end
  local real = meCount(it.name, it.damage, it.var)
  if real == nil then out("ME-сеть недоступна. Попробуйте позже.", false); return "me" end
  if real <= 0 then
    out("Ресурса сейчас нет в ME. Напишите владельцу через «Обратная связь».", false)
    return "me"
  end

  local fp, fpErr = meFingerprint(it.name, it.damage, it.var)
  if not fp then out("Не могу выдать «" .. shown .. "»: " .. tostring(fpErr), false); return "fail" end
  local deliver = math.min(it.qty, space, real)
  local bySpace = space < it.qty and space <= real
  local before = countIn(slots, it.name, it.damage, it.var)

  -- сначала списываем в базе (чтобы при сбое питания выдача не удвоилась)
  it.qty = it.qty - deliver
  saveDB()

  status("Выдаю...")
  local left = deliver
  lastExportErr = nil
  while left > 0 do
    local chunk = math.min(left, maxSize)
    local ok, res = pcall(me.exportItem, fp, CONFIG.ME_EXPORT_SIDE, chunk)
    if not ok then lastExportErr = tostring(res); break end
    local moved = tonumber(res) or (type(res) == "table" and tonumber(res.size)) or nil
    if moved == 0 then lastExportErr = "exportItem вернул 0"; break end
    left = left - chunk
  end

  -- реально выданное считаем по разнице в инвентаре, остаток возвращаем в долг магазина
  local after = countIn(readSlots(), it.name, it.damage, it.var)
  local given = math.max(0, math.min(deliver, after - before))
  if given < deliver then it.qty = it.qty + (deliver - given) end
  if cache.byKey[key] then cache.byKey[key].size = math.max(0, cache.byKey[key].size - given) end
  saveDB()

  if given == 0 then
    local extra = ""
    if S.player.owner and lastExportErr then extra = " [" .. lastExportErr:sub(1, 80) .. "]" end
    out("Не удалось выдать «" .. shown .. "». Попробуйте ещё раз." .. extra, false)
    return "fail"
  elseif it.qty > 0 then
    out("Выдано " .. given .. " из " .. (given + it.qty) .. " («" .. shown ..
        "»). Освободите место и нажмите «Забрать» снова.", true)
    return bySpace and "space" or "me"
  end
  out("Выдано: " .. shown .. " x" .. given, true)
  return "ok"
end

-- «Забрать всё»: выдаём ресурсы по очереди, пока есть место в инвентаре
local function claimAll(pu)
  local total, noMe, stopSpace = 0, 0, false
  status("Выдаю всё по очереди...")
  for _, it in ipairs(pu.items) do
    if it.qty > 0 then
      local before = it.qty
      local r = doClaim(pu, it, true)
      total = total + (before - it.qty)
      if r == "space" then stopSpace = true; break end
      if it.qty > 0 and (r == "me" or r == "fail") then noMe = noMe + 1 end
    end
  end
  local msg = "Выдано предметов: " .. total .. "."
  if stopSpace then msg = msg .. " Нет места в инвентаре: освободите слоты и нажмите «Забрать всё» снова."
  elseif noMe > 0 then msg = msg .. " Не удалось выдать позиций: " .. noMe .. " (нет в ME или ошибка)." end
  flash(msg, total > 0 or not (stopSpace or noMe > 0))
end

-- Пополнение: pim.pushItem толкает предмет из слота игрока в соседний инвентарь (ME Interface).
-- Если сторона из CONFIG не подошла, перебираем остальные и запоминаем ту, через которую
-- предмет реально ушёл (проверяем по слоту).
local ALL_SIDES = { "north", "south", "east", "west", "up", "down" }
local pushSideOk, lastPushErr = nil, nil

-- толкает предмет из слота в ME; возвращает, сколько реально ушло
local function pushFromSlot(s, take, name, damage)
  local before = slotQty(s, name, damage)
  if not before or before <= 0 then return 0 end
  take = math.min(take, before)

  -- порядок: ранее сработавшая, из CONFIG, потом все остальные
  local sides, seen = {}, {}
  local function add(x) if x and not seen[x] then seen[x] = true; sides[#sides + 1] = x end end
  add(pushSideOk)
  add(lower(CONFIG.PIM_PUSH_SIDE))
  for _, x in ipairs(ALL_SIDES) do add(x) end

  for _, side in ipairs(sides) do
    local variants = (side == side:upper()) and { side } or { side, side:upper() }
    for _, variant in ipairs(variants) do
      local ok, res = pcall(pim.pushItem, variant, s, take)
      if ok then
        local after = slotQty(s, name, damage)
        if after and before - after > 0 then
          pushSideOk = variant      -- запомнили рабочую сторону
          return before - after
        end
      else
        lastPushErr = tostring(res)
      end
    end
  end
  return 0
end

local function doDeposit(e, amount)
  status("Читаю инвентарь...")
  local before = readSlots()
  local have = countIn(before, e.name, e.damage, e.var)
  local want = amount and math.min(amount, have) or have
  if want <= 0 then return flash("В инвентаре нет «" .. e.label .. "».", false) end

  status("Принимаю ресурсы...")
  lastPushErr = nil
  local left = want
  for s = 1, 36 do
    if left <= 0 then break end
    local st = before[s]
    if stackMatches(st, e.name, e.damage, e.var) then
      left = left - pushFromSlot(s, math.min(st.qty, left), e.name, e.damage)
    end
  end

  local afterSlots = readSlots()
  local after = countIn(afterSlots, e.name, e.damage, e.var)
  local moved = math.max(0, math.min(want, have - after))
  S.slots = afterSlots
  if moved <= 0 then
    local msg = "Не удалось принять предметы. Проверьте подключение ME Interface к PIM и свободное место в ME."
    if S.player.owner and lastPushErr then msg = msg .. " [" .. lastPushErr:sub(1, 80) .. "]" end
    return flash(msg, false)
  end

  local p = getPlayer(S.player.name)
  local gain = round2(moved * e.price)
  p.balance = round2(p.balance + gain)
  local c = cache.byKey[itemKey(e.name, e.damage, e.var)]
  if c then c.size = c.size + moved end
  saveDB()
  flash("Принято " .. moved .. " шт. «" .. e.label .. "». Зачислено: " .. fmt(gain) .. " " .. CONFIG.CURRENCY, true)
end

local function doRefresh()
  if refreshRemaining() > 0 then return end
  if MODE == "terminal" then pcall(Net.pullConfig) end      -- подтянуть правки владельца с других терминалов
  status("Сканирую ME-сеть...")
  local ok, err = scanME(S.player and S.player.name, S.player and S.player.owner)
  if ok and S.player and S.player.owner and S.view == "pick" then
    if S.pickSource == "inv" then ok, err = invPickerScan(S.filter)
    else ok, err = pickerScan(S.filter) end
  end
  if ok then flash("Список обновлён.", true)
  else
    -- технический текст ошибки видит только владелец
    flash("Не удалось просканировать ME." ..
          ((S.player and S.player.owner) and (" " .. tostring(err)) or ""), false)
  end
end

-- открыть окно выбора предмета (только владелец).
-- source: "me" - из ME-сети (по умолчанию), "inv" - из инвентаря игрока на PIM
local function openPicker(mode, source)
  source = source or "me"
  status(source == "inv" and "Читаю инвентарь..." or "Загружаю список ME...")
  local ok, err
  if source == "inv" then ok, err = invPickerScan("") else ok, err = pickerScan("") end
  local f = { view = "pick", pickMode = mode, pickSource = source, filter = "" }
  if ok then nav(f)
  else nav(f, "Не удалось получить список: " .. tostring(err), false) end
end

local feedbackLast = {}
local function sendFeedback()
  local k = lower(S.player.name)
  local now = computer.uptime()
  if feedbackLast[k] and now - feedbackLast[k] < CONFIG.FEEDBACK_COOLDOWN then
    return flash("Подождите " .. math.ceil(CONFIG.FEEDBACK_COOLDOWN - (now - feedbackLast[k])) ..
                 " с перед следующим сообщением.", false)
  end
  local txt = prompt("Опишите баг или пожелание:", "", CONFIG.FEEDBACK_MAX_LEN)
  if not txt or trim(txt) == "" then return render() end
  feedbackLast[k] = now
  Net.fbAddEntry(S.player.name, trim(txt))
  flash("Спасибо! Сообщение отправлено владельцу.", true)
end

----------------------------------------------------------------------
-- ВЫВОД: баланс -> один предмет, заданный владельцем (db.withdraw)
----------------------------------------------------------------------
-- сколько штук игрок может вывести прямо сейчас: баланс, место в инвентаре, остаток в ME
local function withdrawMax()
  local w = db.withdraw
  local p = getPlayer(S.player.name)
  local byBal = math.floor(round2(p.balance) / w.price + 1e-9)
  if byBal <= 0 then return 0, "Не хватает средств на балансе даже на 1 шт." end
  local key = itemKey(w.name, w.damage, w.var)
  local mx = (cache.byKey[key] and cache.byKey[key].maxSize) or 64
  local space = spaceIn(readSlots(), w.name, w.damage, mx, w.var)
  if space <= 0 then return 0, "Нет места в инвентаре." end
  local real = meCount(w.name, w.damage, w.var)
  if real == nil then return nil, "ME-сеть недоступна." end
  local avail = real - (reservedMap(true)[key] or 0)
  if avail <= 0 then return 0, "Предмета сейчас нет в ME." end
  return math.max(0, math.min(byBal, space, avail))
end

-- окно вывода: возвращает количество или nil (отмена)
local function withdrawDialog()
  local w = db.withdraw
  local bw, bh = math.min(W - 4, 70), 13
  local bx, by = math.floor((W - bw) / 2) + 1, math.floor((H - bh) / 2) + 1
  local mw = 12
  local fw = bw - 4 - mw - 1
  local buf, err = "", nil
  local function qty() return tonumber(buf) or 0 end
  local function draw()
    local p = getPlayer(S.player.name)
    fill(bx, by, bw, bh, C.dlg)
    frame(bx, by, bw, bh, C.gold, C.dlg)
    text(bx + 2, by + 1, pad("Вывод: " .. w.label, bw - 6 - CROSS_W), C.gold, C.dlg)
    drawCross(bx, by, bw)
    text(bx + 2, by + 3, pad("Цена: " .. fmt(w.price) .. " " .. CONFIG.CURRENCY .. " за шт     Баланс: " ..
         fmt(p.balance) .. " " .. CONFIG.CURRENCY, bw - 4), C.text, C.dlg)
    text(bx + 2, by + 4, pad("Сколько штук вывести:", bw - 4), C.dim, C.dlg)
    frame(bx + 2, by + 5, fw, 3, C.dim, C.dlg)
    fill(bx + 3, by + 6, fw - 2, 1, 0x000000)
    local shown = buf
    if unicode.len(shown) > fw - 4 then shown = unicode.sub(shown, unicode.len(shown) - fw + 5) end
    text(bx + 3, by + 6, shown .. "_", C.accent, 0x000000)
    fill(bx + bw - 2 - mw, by + 5, mw, 3, C.blue)
    text(bx + bw - 2 - mw + math.floor((mw - 3) / 2), by + 6, "MAX", 0xffffff, C.blue)
    if err then text(bx + 2, by + 8, pad(err, bw - 4), C.red, C.dlg)
    else text(bx + 2, by + 8, pad("К списанию: " .. fmt(qty() * w.price) .. " " .. CONFIG.CURRENCY, bw - 4), C.gold, C.dlg) end
    fill(bx + 2, by + 9, bw - 4, 3, C.tabOn)
    text(bx + 2 + math.floor((bw - 4 - 7) / 2), by + 10, "Вывести", 0xffffff, C.tabOn)
  end
  local function submit()
    if qty() < 1 then err = "Введите количество больше нуля."; draw(); return nil end
    return qty()
  end
  draw()
  while true do
    local e = table.pack(safePull(event.pullMultiple, "key_down", "touch", "player_off"))
    if e[1] == "player_off" then pendingOff = true; return nil end
    local who = (e[1] == "touch") and e[6] or e[5]
    if not who or not S.player or lower(who) == lower(S.player.name) then
      if e[1] == "touch" then
        local x, y = e[3], e[4]
        if type(x) == "number" and type(y) == "number" then
          if hitCross(e, bx, by, bw) then return nil end
          if x >= bx + bw - 2 - mw and x <= bx + bw - 3 and y >= by + 5 and y <= by + 7 then
            local m, why = withdrawMax()
            if m == nil or m <= 0 then buf = ""; err = why or "Вывести нечего."
            else buf = tostring(m); err = nil end
            draw()
          elseif x >= bx + 2 and x <= bx + bw - 3 and y >= by + 9 and y <= by + 11 then
            local q = submit(); if q then return q end
          end
        end
      else
        local ch, code = e[3], e[4]
        if code == 28 or code == 156 or ch == 13 then
          local q = submit(); if q then return q end
        elseif code == 1 then return nil
        elseif code == 14 or ch == 8 then
          buf = unicode.sub(buf, 1, math.max(0, unicode.len(buf) - 1)); err = nil; draw()
        elseif ch and ch >= 48 and ch <= 57 and unicode.len(buf) < 7 then
          buf = buf .. unicode.char(ch); err = nil; draw()
        end
      end
    end
  end
end

local function doWithdraw(q)
  local w = db.withdraw
  if not w then return flash("Вывод не настроен владельцем.", false) end
  if not q or q < 1 then return render() end
  local p = getPlayer(S.player.name)
  local cost = round2(q * w.price)
  if round2(p.balance) < cost then
    return flash("Не хватает средств: нужно " .. fmt(cost) .. ", на балансе " .. fmt(p.balance) .. ".", false)
  end
  status("Проверяю наличие в ME...")
  local real = meCount(w.name, w.damage, w.var)
  if real == nil then return flash("ME-сеть недоступна. Попробуйте позже.", false) end
  local k = itemKey(w.name, w.damage, w.var)
  if real - (reservedMap(true)[k] or 0) < q then
    return flash("В ME недостаточно предмета для вывода.", false)
  end

  -- списываем баланс и оформляем выдачу как покупку (дальше работает обычная надёжная выдача)
  p.balance = round2(p.balance - cost)
  local it = { name = w.name, damage = w.damage, var = w.var, label = w.label,
               customLabel = w.customLabel, qty = q }
  local pu = { id = Net.newPurchaseId(), kit = "Вывод", items = { it } }
  p.purchases[#p.purchases + 1] = pu
  if MODE == "terminal" then
    local okc, why = Net.commitPlayer(p, { { key = k, real = real } })
    if not okc then return flash(why, false) end
  else
    saveDB()
  end

  doClaim(pu, it, true)
  local left = it.qty
  purgePurchases(p)
  if left <= 0 then
    flash("Выведено: " .. w.label .. " x" .. q .. ". Списано: " .. fmt(cost) .. " " .. CONFIG.CURRENCY, true)
  else
    flash("Выдано " .. (q - left) .. " из " .. q .. ". Остаток ждёт в «Незабранное» (освободите место).", true)
  end
end

local function openWithdraw()
  if not db.withdraw then
    return flash("Вывод пока не настроен владельцем.", false)
  end
  local q = withdrawDialog()
  if pendingOff then return end
  if q then doWithdraw(q) else render() end
end

----------------------------------------------------------------------
-- ЭКРАНЫ
----------------------------------------------------------------------
-- сколько карточек влезает: от строки y0 до подвала, шаг 4 (3 строки + пропуск)
local function paged(count, y0)
  local per = math.max(1, math.floor((H - 2 - y0 - UI.oy) / 4))
  local pages = math.max(1, math.ceil(count / per))
  if S.page > pages then S.page = pages end
  if S.page < 1 then S.page = 1 end
  S.pages = pages
  local first = (S.page - 1) * per + 1
  return first, math.min(count, first + per - 1)
end

---------------------------------------------------------- заставка (экран ожидания)
local SPL_BAND = 5            -- высота полосы фонового градиента, строк
local SPL_BOX_W, SPL_BOX_H = 40, 5
local SPL_GLYPH = {           -- крупные буквы: # = закрашено
  ["К"] = { "#   #", "#  # ", "###  ", "#  # ", "#   #" },
  ["В"] = { "#### ", "#   #", "#### ", "#   #", "#### " },
  ["Е"] = { "#####", "#    ", "#### ", "#    ", "#####" },
  ["С"] = { " ####", "#    ", "#    ", "#    ", " ####" },
  ["Т"] = { "#####", "  #  ", "  #  ", "  #  ", "  #  " },
  ["Ы"] = { "#     #", "#     #", "####  #", "#   # #", "####  #" },
}
local SPL_WORD = "КВЕСТЫ"
local splashStep = 0
local splashStars = {}

local function mix(a, b, t)
  local function ch(c, d) return math.floor(c / d) % 256 end
  local r  = math.floor(ch(a, 65536) * (1 - t) + ch(b, 65536) * t + 0.5)
  local g  = math.floor(ch(a, 256)   * (1 - t) + ch(b, 256)   * t + 0.5)
  local bl = math.floor((a % 256)    * (1 - t) + (b % 256)    * t + 0.5)
  return r * 65536 + g * 256 + bl
end

local function skyAt(y)
  local bands = math.max(1, math.ceil(H / SPL_BAND))
  local i = math.floor((y - 1) / SPL_BAND)
  return mix(0x0a1024, 0x2b1246, i / math.max(1, bands - 1))
end

local function spaced(s)
  local t = {}
  for i = 1, unicode.len(s) do t[#t + 1] = unicode.sub(s, i, i) end
  return table.concat(t, " ")
end

local function splashGeom()
  local g = {}
  g.sx = (W >= 120) and 3 or 2
  g.sy = (H >= 40) and 2 or 1
  local n = unicode.len(SPL_WORD)
  local gw = 0
  for i = 1, n do gw = gw + #SPL_GLYPH[unicode.sub(SPL_WORD, i, i)][1] * g.sx end
  g.gw = gw + (n - 1) * g.sx
  g.gh = 5 * g.sy
  local blockH = g.gh + 7 + SPL_BOX_H
  g.top  = math.max(2, math.floor((H - blockH) / 2) + 1)
  g.gx   = math.floor((W - g.gw) / 2) + 1
  g.subY = g.top + g.gh + 2
  g.divY = g.subY + 2
  g.boxX = math.floor((W - SPL_BOX_W) / 2) + 1
  g.boxY = g.divY + 3
  return g
end

local function makeStars(g)
  splashStars = {}
  local seed = 20260
  local function rnd(n) seed = (seed * 1103515245 + 12345) % 2147483648; return seed % n + 1 end
  for _ = 1, math.floor(W * H / 90) do
    local x, y = rnd(math.max(1, W - 4)) + 2, rnd(math.max(1, H - 4)) + 2
    local inside = x >= g.gx - 4 and x <= g.gx + g.gw + 4 and y >= g.top - 1 and y <= g.boxY + SPL_BOX_H
    if not inside then splashStars[#splashStars + 1] = { x = x, y = y, ph = rnd(3), k = rnd(4) } end
  end
end

local STAR_COL = { 0x3a4a7a, 0x8fa4e8, 0xffffff }
local function drawStars(onlyThird)
  for i, st in ipairs(splashStars) do
    if not onlyThird or (i + splashStep) % 3 == 0 then
      gpu.setBackground(skyAt(st.y))
      gpu.setForeground(STAR_COL[(st.ph + splashStep) % 3 + 1])
      gpu.set(st.x, st.y, st.k == 1 and "+" or "·")
    end
  end
end

local function drawSplashFrame()
  local fg = 0x2f7d1a
  gpu.setForeground(fg)
  gpu.setBackground(skyAt(1));  gpu.set(1, 1, "╔" .. string.rep("═", W - 2) .. "╗")
  gpu.setBackground(skyAt(H));  gpu.set(1, H, "╚" .. string.rep("═", W - 2) .. "╝")
  for i = 0, math.ceil(H / SPL_BAND) - 1 do
    local y0 = math.max(2, i * SPL_BAND + 1)
    local y1 = math.min(H - 1, (i + 1) * SPL_BAND)
    if y1 >= y0 then
      gpu.setBackground(skyAt(y0))
      gpu.fill(1, y0, 1, y1 - y0 + 1, "║")
      gpu.fill(W, y0, 1, y1 - y0 + 1, "║")
    end
  end
end

local function drawTitle(g)
  local n = unicode.len(SPL_WORD)
  for pass = 1, 2 do                       -- 1 = тень, 2 = сами буквы
    local x = g.gx
    for i = 1, n do
      local glyph = SPL_GLYPH[unicode.sub(SPL_WORD, i, i)]
      local gwid = #glyph[1]
      for r = 1, 5 do
        gpu.setForeground(pass == 1 and 0x04060e or mix(0xc4ff9a, 0x3fae22, (r - 1) / 4))
        local row, c = glyph[r], 1
        while c <= gwid do
          if row:sub(c, c) == "#" then
            local c2 = c
            while c2 < gwid and row:sub(c2 + 1, c2 + 1) == "#" do c2 = c2 + 1 end
            local dx = (pass == 1) and 1 or 0
            local dy = (pass == 1) and 1 or 0
            gpu.fill(x + (c - 1) * g.sx + dx, g.top + (r - 1) * g.sy + dy, (c2 - c + 1) * g.sx, g.sy, "█")
            c = c2 + 1
          else
            c = c + 1
          end
        end
      end
      x = x + gwid * g.sx + g.sx
    end
  end
end

local function drawSplashPrompt(g, bright)
  local bg = 0x121833
  gpu.setBackground(bg)
  gpu.fill(g.boxX, g.boxY, SPL_BOX_W, SPL_BOX_H, " ")
  gpu.setForeground(0x2f7d1a)
  gpu.set(g.boxX, g.boxY, "╭" .. string.rep("─", SPL_BOX_W - 2) .. "╮")
  gpu.set(g.boxX, g.boxY + SPL_BOX_H - 1, "╰" .. string.rep("─", SPL_BOX_W - 2) .. "╯")
  gpu.fill(g.boxX, g.boxY + 1, 1, SPL_BOX_H - 2, "│")
  gpu.fill(g.boxX + SPL_BOX_W - 1, g.boxY + 1, 1, SPL_BOX_H - 2, "│")
  local s = "▼   ВСТАНЬТЕ НА PIM   ▼"
  gpu.setForeground(bright and 0x68f029 or 0x3a7d1e)
  gpu.set(g.boxX + math.floor((SPL_BOX_W - unicode.len(s)) / 2), g.boxY + math.floor(SPL_BOX_H / 2), s)
end

local function drawIdle()
  UI.oy = 0
  local g = splashGeom()
  -- фон: ступенчатый градиент
  for i = 0, math.ceil(H / SPL_BAND) - 1 do
    local y0 = i * SPL_BAND + 1
    gpu.setBackground(skyAt(y0))
    gpu.fill(1, y0, W, math.min(SPL_BAND, H - y0 + 1), " ")
  end
  makeStars(g)
  drawStars(false)
  drawSplashFrame()
  drawTitle(g)

end

-- вызывается раз в ~0.7 с, пока на PIM никого нет: мерцание звёзд и «дыхание» надписи
local function idleTick()
  if S.player then return end
  UI.oy = 0
  splashStep = splashStep + 1
  drawStars(true)
  drawSplashPrompt(splashGeom(), splashStep % 2 == 0)
end

local function switchTab(t)
  S.tab = t; S.view = "list"; S.csub = "kits"; S.page = 1
  S.msg = ""; S.confirm = nil; S.filter = ""
  if #cache.items > 0 then cache.items = {}; ru.unload() end     -- ушли из окна выбора: освобождаем
  if t == "topup" then scanInventory() end
  render()
end

local function drawHeader()
  fill(1, 1, W, 1, C.bar)
  local bal = "Баланс: " .. fmt(getPlayer(S.player.name).balance) .. " " .. CONFIG.CURRENCY
  local balW = unicode.len(bal)
  text(W - balW, 1, bal, C.gold, C.bar)
  addBtn(W - balW - 10, 1, 8, 1, "Вывод", { bg = db.withdraw and C.tabOn or C.panel2, fg = 0xffffff, fn = openWithdraw })
  local who = S.player.name .. (S.player.owner and " [владелец]" or "")
  text(20, 1, pad(who, math.max(1, W - balW - 32)), C.text, C.bar)

  local tabs = { { "kits", "Квесты/Комплекты" }, { "topup", "Пополнение" } }
  if S.player.owner then tabs[#tabs + 1] = { "create", "Создание" } end
  local n = #tabs
  local tw = math.floor(W / n)
  for i, t in ipairs(tabs) do
    local on = (S.tab == t[1])
    local x = (i - 1) * tw + 1
    local w = (i == n) and (W - x + 1) or tw
    addBtn(x, 3, w, 3, t[2],
      { bg = on and C.tabOn or C.tabOff, fg = on and 0xffffff or C.dim, fn = function() switchTab(t[1]) end })
  end
end

local function drawFooter()
  local y = H - 3                          -- кнопки на 1 строку выше нижнего края
  fill(1, y, W, 4, C.bar)
  addBtn(2, y, 14, 3, "Назад", { disabled = not S.backFn, fn = S.backFn })
  addBtn(18, y, 6, 3, "<", { disabled = S.page <= 1, fn = function() S.page = S.page - 1; render() end })
  text(26, y + 1, pad("стр " .. S.page .. "/" .. (S.pages or 1), 11), C.dim, C.bar)
  addBtn(38, y, 6, 3, ">", { disabled = S.page >= (S.pages or 1), fn = function() S.page = S.page + 1; render() end })
  local rem = refreshRemaining()
  addBtn(46, y, 24, 3, rem > 0 and ("Обновить (" .. rem .. "с)") or "Обновить",
    { disabled = rem > 0, bg = C.green, fn = doRefresh })
  rb(y, 0, 20, "Обратная связь", { bg = C.blue, fn = sendFeedback })
end

local function redrawFooter()
  local keep = {}
  for _, b in ipairs(UI.btns) do if b.tag ~= "foot" then keep[#keep + 1] = b end end
  UI.btns = keep
  UI.tag = "foot"; drawFooter(); UI.tag = nil
end

---------------------------------------------------------- вкладка: комплекты
local function screenKitView()
  local kit = findKit(S.kitId)
  if not kit then S.view = "list"; return false end
  local avail = availFn()
  local stock = kitStock(kit, avail)
  text(2, 6, pad(kit.name, W - 34), C.accent, C.bg)
  text(2, 8, pad("Цена: " .. fmt(kit.price) .. " " .. CONFIG.CURRENCY .. "   В наличии: " .. stock .. " шт", W - 34),
       stock > 0 and C.text or C.red, C.bg)
  rb(6, 0, 30, "Купить за " .. fmt(kit.price),
    { disabled = stock <= 0, bg = C.tabOn, fn = function() doBuy(kit) end })

  local first, last = paged(#kit.items, LIST_Y)
  for i = first, last do
    local it = kit.items[i]
    local y = LIST_Y + (i - first) * 4
    local a = avail(itemKey(it.name, it.damage, it.var))
    card(y, it.label .. "   x" .. it.qty, "В наличии: " .. a .. (a >= it.qty and "" or "   (не хватает)"),
         a >= it.qty and C.dim or C.red, 0)
  end
  S.backFn = function() nav({ view = "list" }) end
  return true
end

local function screenPurchase(p)
  local pu = findPurchase(p, S.purchaseId)
  if not pu then S.view = "mine"; return false end
  text(2, 6, pad("Покупка #" .. pu.id .. ": " .. pu.kit, W - 36), C.accent, C.bg)
  text(2, 8, pad("Забирайте по одному или кнопкой «Забрать всё».", W - 36), C.dim, C.bg)
  addBtn(W - 33, 6, 30, 3, "Забрать всё", { disabled = purchasePending(pu) == 0, bg = C.tabOn,
    fn = function() claimAll(pu) end })
  local first, last = paged(#pu.items, LIST_Y)
  for i = first, last do
    local it = pu.items[i]
    local y = LIST_Y + (i - first) * 4
    card(y, it.label, it.qty > 0 and ("Осталось выдать: " .. it.qty) or "Выдано полностью",
         it.qty > 0 and C.gold or C.dim)
    rb(y, 0, BW, it.qty > 0 and "Забрать" or "Выдано",
      { disabled = it.qty <= 0, bg = C.tabOn, fn = function() doClaim(pu, it) end })
  end
  S.backFn = function()
    purgePurchases(p)
    nav({ view = (pendingCount(p) > 0) and "mine" or "list" })
  end
  return true
end

local function screenMine(p)
  purgePurchases(p)
  text(2, 6, "Незабранные покупки", C.accent, C.bg)
  text(2, 8, "Здесь то, что вы оплатили, но ещё не забрали.", C.dim, C.bg)
  local first, last = paged(#p.purchases, LIST_Y)
  if #p.purchases == 0 then text(2, LIST_Y, "Пока ничего нет.", C.dim, C.bg) end
  for i = first, last do
    local pu = p.purchases[i]
    local y = LIST_Y + (i - first) * 4
    card(y, "#" .. pu.id .. "  " .. pu.kit, "Осталось позиций: " .. purchasePending(pu), C.gold)
    rb(y, 0, BW, "Открыть", { bg = C.tabOn, fn = function() nav({ view = "purchase", purchaseId = pu.id }) end })
  end
  S.backFn = function() nav({ view = "list" }) end
  return true
end

local function screenKits()
  local p = getPlayer(S.player.name)
  if S.view == "kit" and screenKitView() then return end
  if S.view == "purchase" and screenPurchase(p) then return end
  if S.view == "mine" and screenMine(p) then return end
  S.view = "list"

  local avail = availFn()
  local list = {}
  for _, k in ipairs(db.kits) do if #k.items > 0 then list[#list + 1] = k end end
  local pend = pendingCount(p)
  text(2, 6, "Комплектов: " .. #list, C.accent, C.bg)
  text(2, 8, "Остатки ME: " .. ageText(), C.dim, C.bg)
  rb(6, 0, 30, "Незабранное: " .. pend,
    { disabled = (pend == 0), bg = C.gold, fg = 0x000000, fn = function() nav({ view = "mine" }) end })

  local first, last = paged(#list, LIST_Y)
  if #list == 0 then text(2, LIST_Y, "Владелец ещё не добавил комплекты.", C.dim, C.bg) end
  for i = first, last do
    local k = list[i]
    local y = LIST_Y + (i - first) * 4
    local stock = kitStock(k, avail)
    lineCard(y, k.name, "Цена: " .. fmt(k.price) .. " " .. CONFIG.CURRENCY .. "   Ресурсов: " .. #k.items ..
                        "   В наличии: " .. stock .. " шт", stock > 0 and C.text or C.red)
    rb(y, 0, BW, stock > 0 and "Перейти" or "Нет в наличии",
      { disabled = stock <= 0, bg = C.tabOn, fn = function() nav({ view = "kit", kitId = k.id }) end })
  end
end

---------------------------------------------------------- вкладка: пополнение
local function screenTopup()
  local p = getPlayer(S.player.name)
  text(2, 6, "Положите ресурсы в инвентарь и нажмите «Внести всё» или «Ввести число».", C.accent, C.bg)
  text(2, 8, "Баланс: " .. fmt(p.balance) .. " " .. CONFIG.CURRENCY, C.gold, C.bg)
  rb(6, 0, 30, "Проверить инвентарь", { fn = function() scanInventory(); render() end })

  local list = db.topup
  local first, last = paged(#list, LIST_Y)
  if #list == 0 then text(2, LIST_Y, "Владелец ещё не добавил ресурсы для пополнения.", C.dim, C.bg) end
  local reserve = BW * 2 + 1 + 2
  for i = first, last do
    local e = list[i]
    local y = LIST_Y + (i - first) * 4
    local have = countIn(S.slots or {}, e.name, e.damage, e.var)
    lineCard(y, e.label, "Цена: " .. fmt(e.price) .. " " .. CONFIG.CURRENCY .. " за шт   У вас в инвентаре: " .. have .. " шт",
             have > 0 and C.text or C.dim, reserve)
    local off = rb(y, 0, BW, "Ввести число", { disabled = have <= 0, fn = function()
      local n = askNumber("Сколько «" .. e.label .. "» внести?", "", true)
      if n and n > 0 then doDeposit(e, n) else render() end
    end })
    rb(y, off, BW, "Внести всё",
      { disabled = have <= 0, bg = C.tabOn, fn = function() doDeposit(e, nil) end })
  end
end

---------------------------------------------------------- вкладка: создание (владелец)
local function subBar()
  local unread = unreadFeedback()
  local subs = { { "kits", "Комплекты" }, { "topup", "Ресурсы пополнения" }, { "withdraw", "Вывод" },
                 { "feedback", "Отзывы" .. (unread > 0 and (" (" .. unread .. ")") or "") } }
  local exitW, gap = 14, 1
  local region = (W - 2) - exitW - gap            -- ширина под три вкладки (колонки 2 .. W-1-exitW-gap)
  local bw = math.floor((region - gap * 3) / 4)
  for i, s in ipairs(subs) do
    local on = (S.csub == s[1])
    addBtn(2 + (i - 1) * (bw + gap), 6, bw, 3, s[2],
      { bg = on and C.blue or C.panel2, fn = function() nav({ csub = s[1], view = "list", filter = "" }) end })
  end
  local exitArmed = (S.confirm == "exit")
  rb(6, 0, exitW, exitArmed and "Точно?" or "Выход",
    { bg = exitArmed and C.red or C.panel2, fn = function()
      if S.confirm == "exit" then running = false else S.confirm = "exit"; render() end
    end })
end

-- переименование ресурса (запись комплекта или ресурса пополнения) по карандашу на карточке.
-- Пустое название - вернуть автоматическое (русское из словаря / из ME).
local function renameEntry(entry)
  local nm = prompt("Название ресурса (пусто - сбросить):", entry.label, 60)
  if nm == nil then return render() end
  nm = trim(nm)
  if nm == "" then
    local c = cache.byKey[itemKey(entry.name, entry.damage, entry.var)]
    entry.label = ruName(entry.name, entry.damage, (c and c.label) or entry.label)
    entry.customLabel = nil
    ru.unload()
  else
    entry.label = nm
    entry.customLabel = true
  end
  saveDB()
  render()
end

local function screenKitEdit()
  local kit = findKit(S.kitId)
  if not kit then S.view = "list"; return false end
  local n, gap = 5, 1
  local bw = math.floor(((W - 2) - gap * (n - 1)) / n)
  local function bx(i) return 2 + (i - 1) * (bw + gap) end
  local lastW = (W - 1) - bx(n) + 1
  local armed = (S.confirm == "del" .. kit.id)
  addBtn(bx(1), 6, bw, 3, "Название", { fn = function()
    local nm = prompt("Название комплекта:", kit.name, 40)
    if nm and trim(nm) ~= "" then kit.name = trim(nm); saveDB() end
    render()
  end })
  addBtn(bx(2), 6, bw, 3, "Цена: " .. fmt(kit.price), { fn = function()
    local v = askPrice("Цена комплекта (" .. CONFIG.CURRENCY .. "):", fmt(kit.price))
    if v then kit.price = round2(v); saveDB() end
    render()
  end })
  addBtn(bx(3), 6, bw, 3, "+ Ресурс (ME)", { bg = C.tabOn, fn = function() openPicker("kit", "me") end })
  addBtn(bx(4), 6, bw, 3, "+ Из инвентаря", { bg = C.blue, fn = function() openPicker("kit", "inv") end })
  addBtn(bx(5), 6, lastW, 3, armed and "Точно удалить?" or "Удалить комплект",
    { bg = armed and C.red or C.panel2, fn = function()
      if S.confirm == "del" .. kit.id then
        local _, idx = findKit(kit.id)
        table.remove(db.kits, idx); saveDB()
        nav({ view = "list" }, "Комплект удалён.", true)
      else S.confirm = "del" .. kit.id; render() end
    end })

  text(2, 9, pad("Комплект: " .. kit.name .. "   Цена: " .. fmt(kit.price) .. " " .. CONFIG.CURRENCY ..
       "   Склад: " .. kitStock(kit, availFn()) .. " шт", W - 2), C.accent, C.bg)
  local y0 = LIST_Y + 1
  local first, last = paged(#kit.items, y0)
  if #kit.items == 0 then text(2, y0, "Пусто. Нажмите «+ Ресурс (ME)» или «+ Из инвентаря», чтобы добавить предмет.", C.dim, C.bg) end
  local reserve = BW2 * 2 + 1 + 2
  for i = first, last do
    local it = kit.items[i]
    local y = y0 + (i - first) * 4
    local c = cache.byKey[itemKey(it.name, it.damage, it.var)]
    -- одна строка, как у остальных карточек
    lineCard(y, it.label .. "   [" .. it.name .. ":" .. it.damage .. "]",
             "x" .. it.qty .. "   В ME: " .. (c and c.size or 0), C.text, reserve,
             function() renameEntry(it) end)
    local off = rb(y, 0, BW2, "Убрать", { fn = function()
      table.remove(kit.items, i); saveDB(); render()
    end })
    rb(y, off, BW2, "Кол-во", { fn = function()
      local q = askNumber("Количество «" .. it.label .. "»:", tostring(it.qty), true)
      if q and q >= 1 then it.qty = q; saveDB() end
      render()
    end })
  end
  S.backFn = function() nav({ view = "list" }) end
  return true
end

-- e = { name, damage, label, size, maxSize, var }
local function pickItem(e)
  local name, dmg, label, size, mx, var = e[1], e[2], e[3], e[4], e[5], e[6] or ""
  local k = itemKey(name, dmg, var)
  if S.pickSource == "inv" then
    -- size в списке - это количество у игрока на руках, а остаток в ME берём отдельно.
    -- Вариант (жидкость/хеш) приводим к тому, каким его видит ME, иначе остатки не сойдутся.
    local mv, msize = meResolve(name, dmg, var)
    if mv then
      var = mv; size = msize
      local base = e[3]
      if (e[6] or "") ~= "" then base = (base:gsub(" %b()$", "")) end   -- убираем вариант PIM из названия
      label = base
      if var ~= "" then label = label .. " (" .. ((var:sub(1, 1) == "#") and var:sub(1, 7) or var) .. ")" end
    else
      size = 0
    end
    k = itemKey(name, dmg, var)
    if cache.byKey[k] then cache.byKey[k].size = size end
  end
  if not cache.byKey[k] then
    cache.byKey[k] = { key = k, name = name, damage = dmg, var = var, label = label, size = size, maxSize = mx }
  end
  if S.pickMode == "kit" then
    local kit = findKit(S.kitId)
    if not kit then return nav({ view = "list" }) end
    local q = askNumber("Сколько «" .. label .. "» [" .. name .. ":" .. dmg .. "] в комплекте?", "1", true)
    if not q or q < 1 then return render() end
    local found = false
    for _, it in ipairs(kit.items) do
      if it.name == name and it.damage == dmg and (it.var or "") == var then it.qty = it.qty + q; found = true end
    end
    if not found then kit.items[#kit.items + 1] = { name = name, damage = dmg, var = var, label = label, qty = q } end
    saveDB()
    flash("Добавлено: " .. label .. " x" .. q .. ". Выберите ещё или нажмите «Назад».", true)
  elseif S.pickMode == "withdraw" then
    local price = askPrice("Цена вывода за 1 шт «" .. label .. "» [" .. name .. ":" .. dmg .. "] (" .. CONFIG.CURRENCY .. "):", "1")
    if not price then return render() end
    db.withdraw = { name = name, damage = dmg, var = var, label = label, price = round2(price) }
    saveDB()
    flash("Предмет вывода сохранён: " .. label .. " по " .. fmt(price), true)
  else
    local price = askPrice("Цена за 1 шт «" .. label .. "» [" .. name .. ":" .. dmg .. "] (" .. CONFIG.CURRENCY .. "):", "1")
    if not price then return render() end
    local found = false
    for _, t in ipairs(db.topup) do
      if t.name == name and t.damage == dmg and (t.var or "") == var then t.price = round2(price); found = true end
    end
    if not found then db.topup[#db.topup + 1] = { name = name, damage = dmg, var = var, label = label, price = round2(price) } end
    saveDB()
    flash("Ресурс пополнения сохранён: " .. label .. " по " .. fmt(price), true)
  end
end

local function applyPickFilter(f)
  S.filter = f; S.page = 1
  status(S.pickSource == "inv" and "Ищу в инвентаре..." or "Ищу в ME...")
  local ok, err
  if S.pickSource == "inv" then ok, err = invPickerScan(S.filter)
  else ok, err = pickerScan(S.filter) end
  if not ok then return flash("Не удалось получить список: " .. tostring(err), false) end
  render()
end

local function screenPick()
  local hasFilter = S.filter and S.filter ~= ""
  addBtn(2, 6, 44, 3, "Поиск: " .. (hasFilter and S.filter or "(нажмите)"), { fn = function()
    local f = prompt("Поиск по названию:", S.filter or "", 40)
    if f then applyPickFilter(trim(f)) else render() end
  end })
  addBtn(48, 6, 16, 3, "Сбросить", { disabled = not hasFilter, fn = function() applyPickFilter("") end })
  local fromInv = (S.pickSource == "inv")
  local info = "Найдено: " .. cache.pickTotal .. (cache.pickMore and ("  (показаны первые " .. #cache.items .. ", уточните поиск)") or "")
  info = info .. "   [свободно ОЗУ: " .. math.floor(computer.freeMemory() / 1024) .. " КБ]"   -- диагностика для владельца
  text(66, 6, pad(info, W - 66), C.dim, C.bg)
  text(66, 8, pad(fromInv and "Источник: ваш инвентарь (кол-во - у вас на руках)"
                  or ("Данные ME: " .. ageText()), W - 66), C.dim, C.bg)

  local list = cache.items
  local first, last = paged(#list, LIST_Y)
  if #list == 0 then
    if hasFilter then text(2, LIST_Y, "Ничего не найдено.", C.dim, C.bg)
    elseif fromInv then text(2, LIST_Y, "В инвентаре нет предметов.", C.red, C.bg)
    else text(2, LIST_Y, "Список ME пуст или недоступен. Нажмите «Обновить» внизу.", C.red, C.bg) end
  end
  for i = first, last do
    local e = list[i]
    local y = LIST_Y + (i - first) * 4
    -- одна строка, как у остальных карточек
    lineCard(y, e[3] .. "   [" .. e[1] .. ":" .. e[2] .. "]", (fromInv and "У вас: " or "В ME: ") .. e[4], C.text)
    rb(y, 0, BW, "Выбрать", { bg = C.tabOn, fn = function() pickItem(e) end })
  end
  S.backFn = function()
    cache.items = {}                       -- освобождаем память
    ru.unload()                            -- и словарь переводов (нужен только владельцу в этом окне)
    if S.pickMode == "kit" then nav({ view = "edit", filter = "" })
    elseif S.pickMode == "withdraw" then nav({ view = "list", csub = "withdraw", filter = "" })
    else nav({ view = "list", csub = "topup", filter = "" }) end
  end
end

local function screenCreate()
  if S.view == "edit" and screenKitEdit() then return end
  if S.view == "pick" then return screenPick() end
  S.view = "list"
  subBar()

  if S.csub == "kits" then
    addBtn(2, 10, 28, 3, "+ Новый комплект", { bg = C.tabOn, fn = function()
      local nm = prompt("Название нового комплекта:", "", 40)
      if nm and trim(nm) ~= "" then
        local kit = { id = db.nextKitId, name = trim(nm), price = 0, items = {} }
        db.nextKitId = db.nextKitId + 1
        db.kits[#db.kits + 1] = kit
        saveDB()
        nav({ view = "edit", kitId = kit.id }, "Комплект создан. Добавьте ресурсы и цену.", true)
      else render() end
    end })
    local avail = availFn()
    local first, last = paged(#db.kits, SUB_Y)
    if #db.kits == 0 then text(2, SUB_Y, "Комплектов пока нет.", C.dim, C.bg) end
    for i = first, last do
      local k = db.kits[i]
      local y = SUB_Y + (i - first) * 4
      lineCard(y, k.name, "Цена: " .. fmt(k.price) .. " " .. CONFIG.CURRENCY .. "   Ресурсов: " .. #k.items ..
                          "   Склад: " .. kitStock(k, avail) .. " шт")
      rb(y, 0, BW, "Изменить", { bg = C.tabOn, fn = function() nav({ view = "edit", kitId = k.id }) end })
    end

  elseif S.csub == "topup" then
    addBtn(2, 10, 28, 3, "+ Добавить ресурс", { bg = C.tabOn, fn = function() openPicker("topup", "me") end })
    addBtn(30, 10, 28, 3, "+ Из инвентаря", { bg = C.blue, fn = function() openPicker("topup", "inv") end })
    text(60, 11, "Что игрок может сдать, чтобы пополнить баланс.", C.dim, C.bg)
    local first, last = paged(#db.topup, SUB_Y)
    if #db.topup == 0 then text(2, SUB_Y, "Ресурсов пополнения пока нет.", C.dim, C.bg) end
    local reserve = BW2 * 2 + 1 + 2
    for i = first, last do
      local e = db.topup[i]
      local y = SUB_Y + (i - first) * 4
      lineCard(y, e.label .. " [" .. e.name .. ":" .. e.damage .. "]",
               "Цена за 1 шт: " .. fmt(e.price) .. " " .. CONFIG.CURRENCY, C.text, reserve,
               function() renameEntry(e) end)
      local off = rb(y, 0, BW2, "Убрать", { fn = function() table.remove(db.topup, i); saveDB(); render() end })
      rb(y, off, BW2, "Цена", { fn = function()
        local v = askPrice("Новая цена за 1 шт «" .. e.label .. "»:", fmt(e.price))
        if v then e.price = round2(v); saveDB() end
        render()
      end })
    end

  elseif S.csub == "withdraw" then
    addBtn(2, 10, 28, 3, "+ Выбрать (ME)", { bg = C.tabOn, fn = function() openPicker("withdraw", "me") end })
    addBtn(30, 10, 28, 3, "+ Из инвентаря", { bg = C.blue, fn = function() openPicker("withdraw", "inv") end })
    text(60, 11, "Единственный предмет, который игроки могут вывести за баланс.", C.dim, C.bg)
    local w = db.withdraw
    if not w then
      text(2, SUB_Y, "Предмет вывода не задан.", C.dim, C.bg)
    else
      local reserve = BW2 * 2 + 1 + 2
      lineCard(SUB_Y, w.label .. " [" .. w.name .. ":" .. w.damage .. "]",
               "Цена за 1 шт: " .. fmt(w.price) .. " " .. CONFIG.CURRENCY, C.text, reserve,
               function() renameEntry(w) end)
      local off = rb(SUB_Y, 0, BW2, "Убрать", { fn = function() db.withdraw = false; saveDB(); render() end })
      rb(SUB_Y, off, BW2, "Цена", { fn = function()
        local v = askPrice("Новая цена вывода за 1 шт «" .. w.label .. "»:", fmt(w.price))
        if v then w.price = round2(v); saveDB() end
        render()
      end })
    end

  else -- отзывы
    Net.fbEnsure()
    local armed = (S.confirm == "clearfb")
    addBtn(2, 10, 28, 3, armed and "Точно очистить?" or "Очистить все", { disabled = #db.feedback == 0,
      bg = armed and C.red or C.panel2, fn = function()
        if S.confirm == "clearfb" then Net.fbClear(); nav({ csub = "feedback", view = "list" }, "Отзывы очищены.", true)
        else S.confirm = "clearfb"; render() end
      end })
    text(32, 11, "Сообщения игроков и автоматические отчёты об ошибках.", C.dim, C.bg)
    local n = #db.feedback
    local first, last = paged(n, SUB_Y)
    if n == 0 then text(2, SUB_Y, "Отзывов пока нет.", C.dim, C.bg) end
    local changed = false
    local reserve = BW2 * 2 + 1 + 2
    for i = first, last do
      local idx = n - i + 1                 -- новые сверху
      local f = db.feedback[idx]
      local y = SUB_Y + (i - first) * 4
      card(y, (f.read and "" or "* ") .. dateStr(f.time) .. "  " .. f.player, f.text,
           f.read and C.dim or C.text, reserve)
      if not f.read then f.read = true; changed = true end
      local off = rb(y, 0, BW2, "Удалить", { fn = function() Net.fbDelete(idx); render() end })
      rb(y, off, BW2, "Читать", { fn = function() modal(f.player .. "  " .. dateStr(f.time), f.text); render() end })
    end
    if changed then Net.fbMarkRead() end
  end
end

----------------------------------------------------------------------
-- ОТРИСОВКА
----------------------------------------------------------------------
render = function()
  UI.btns = {}
  UI.oy = 0
  gpu.setBackground(C.bg)
  gpu.fill(1, 1, W, H, " ")
  if not S.player then return drawIdle() end
  S.backFn = nil
  S.pages = 1
  drawHeader()
  drawMessage()
  UI.oy = CONTENT_OY
  local ok, err = pcall(function()
    if S.tab == "kits" then screenKits()
    elseif S.tab == "topup" then screenTopup()
    elseif S.tab == "create" and S.player.owner then screenCreate()
    else S.tab = "kits"; screenKits() end
  end)
  UI.oy = 0
  if not ok then error(err, 0) end
  UI.tag = "foot"; drawFooter(); UI.tag = nil   -- с тегом, чтобы redrawFooter не плодил дубли кнопок
end

----------------------------------------------------------------------
-- СОБЫТИЯ
----------------------------------------------------------------------
-- player_on приходит как (адрес PIM, ник, uuid) или (ник, uuid): адрес пропускаем
local function parsePlayerOn(e)
  local args = {}
  for i = 2, (e.n or #e) do
    local v = e[i]
    if v ~= nil and v ~= pim.address then args[#args + 1] = v end
  end
  return tostring(args[1] or "?"), args[2]
end

local function onPlayerOn(e)
  local name, uid = parsePlayerOn(e)
  S = { player = { name = name, uid = uid, owner = (MODE ~= "terminal") and isOwner(name, uid) or false },
        tab = "kits", view = "list", csub = "kits", page = 1, pages = 1,
        msg = "", msgOk = true, slots = {}, filter = "" }
  UI.btns = {}
  UI.oy = 0
  cache.items = {}
  gpu.setBackground(C.bg); gpu.fill(1, 1, W, H, " ")
  ctext(math.floor(H / 2), "Здравствуйте, " .. S.player.name .. "!", C.accent, C.bg)
  ctext(math.floor(H / 2) + 2, "Загружаю данные...", C.dim, C.bg)

  if MODE == "terminal" then
    local r = Net.login(name, uid)
    if not r then
      S = { player = nil }
      UI.btns = {}
      gpu.setBackground(C.bg); gpu.fill(1, 1, W, H, " ")
      ctext(math.floor(H / 2), "Нет связи с сервером магазина.", C.red, C.bg)
      ctext(math.floor(H / 2) + 2, "Сойдите с плитки и встаньте снова через минуту.", C.dim, C.bg)
      os.sleep(6)
      return
    end
    S.player.owner = r.owner
  end
  local p = getPlayer(S.player.name)
  purgePurchases(p)
  local ok, err = scanME(S.player.name, S.player.owner)   -- единственное сканирование на входе
  render()
  if not ok then
    -- технический текст ошибки видит только владелец
    flash("ME недоступна." .. (S.player.owner and (" " .. tostring(err)) or ""), false)
  elseif pendingCount(p) > 0 then
    flash("У вас есть незабранные ресурсы - кнопка «Незабранное» вверху справа.", true)
  elseif S.player.owner and unreadFeedback() > 0 then
    flash("Новых отзывов: " .. unreadFeedback() .. " (вкладка «Создание» -> «Отзывы»).", true)
  end
end

-- Игрок ушёл с PIM: выгружаем всё, что нужно только на время сеанса.
-- В простое магазин держит в ОЗУ только базу; остатки ME и словари загрузятся заново при следующем входе.
local function onPlayerOff()
  S = { player = nil }
  if MODE == "terminal" then Net.logout() end
  cache.items, cache.byKey, cache.time = {}, {}, nil
  cache.pickMore, cache.pickTotal = false, 0
  detailCache, detailCount = {}, 0
  fpCache, fpCount = {}, 0
  ru.unload()
  gc()
  render()
end

local function onTouch(e)
  if not S.player then return end
  if e[6] and lower(e[6]) ~= lower(S.player.name) then return end
  local x, y = e[3], e[4]
  for i = #UI.btns, 1, -1 do
    local b = UI.btns[i]
    if x >= b.x and x <= b.x + b.w - 1 and y >= b.y and y <= b.y + b.h - 1 then
      b.fn(); return
    end
  end
end

local lastAutoReport = -100
local function reportError(err)
  err = tostring(err)
  local um = err:match("USERMSG:([^\n]*)")
  if um then                                   -- ожидаемая проблема (сеть, чужие правки): без записи в отзывы
    UI.oy = 0
    if S.player then S.msg = um; S.msgOk = false; pcall(render) end
    return
  end
  local oom = err:lower():find("memory", 1, true) ~= nil
  gc()
  pcall(function()
    err = err .. " [free " .. math.floor(computer.freeMemory() / 1024) .. "K/" ..
          math.floor(computer.totalMemory() / 1024) .. "K]"
  end)
  UI.oy = 0
  -- лог не должен разрастаться: больше 100 КБ - начинаем заново
  local okSize, logSize = pcall(fs.size, CONFIG.LOG_PATH)
  local f = io.open(CONFIG.LOG_PATH, (okSize and (tonumber(logSize) or 0) > 102400) and "w" or "a")
  if f then f:write(tostring(os.time()) .. " " .. err:sub(1, 2000) .. "\n"); f:close() end
  local now = computer.uptime()
  if db and now - lastAutoReport > 10 then
    lastAutoReport = now
    if MODE == "terminal" then
      pcall(Net.call, "fbAdd", { player = "[авто-ошибка]", text = err:sub(1, 200) }, 1)
    else
      db.feedback[#db.feedback + 1] = { player = "[авто-ошибка]", text = err:sub(1, 200), time = os.time(), read = false }
      pcall(saveDB)
    end
  end
  if S.player then
    S.msg = "Внутренняя ошибка (записана для владельца)."; S.msgOk = false
    pcall(render)
    -- при нехватке памяти окно с ошибкой не строим: оно само требует памяти (текст всё равно в «Отзывах»)
    if S.player.owner and not oom then   -- владельцу показываем настоящий текст
      pcall(modal, "Ошибка (видно только владельцу)", err:sub(1, 600))
      pcall(render)
    end
  end
end

----------------------------------------------------------------------
-- ЗАПУСК
----------------------------------------------------------------------
local startupPrepared = false     -- подготовку базы делаем один раз за запуск, а не при каждом перезапуске main

-- подготовка авторитетной базы (одиночный режим и сервер)
function Net.prepareDB()
  if startupPrepared then return end
  startupPrepared = true
  -- переводим уже сохранённые названия (комплекты, пополнение, незабранные покупки).
  -- Записи собираем в один массив и сортируем по id предмета: файл словаря каждого мода
  -- читается один раз (раньше они грузились по кругу из-за SHARD_KEEP) - это и тормозило запуск.
  do
    local all = {}
    local function grab(list)
      for _, x in ipairs(list) do if not x.customLabel then all[#all + 1] = x end end
    end
    for _, k in ipairs(db.kits) do grab(k.items) end
    grab(db.topup)
    if db.withdraw then grab({ db.withdraw }) end
    for _, p in pairs(db.players) do
      for _, pu in ipairs(p.purchases or {}) do grab(pu.items) end
    end
    table.sort(all, function(a, b) return tostring(a.name) < tostring(b.name) end)
    for _, x in ipairs(all) do x.label = ruName(x.name, x.damage, x.label) end
    all = nil
  end
  -- чистим игроков без баланса и без покупок: они только раздувают базу (создаются заново при входе)
  do
    local drop = {}
    for key, p in pairs(db.players) do
      if (tonumber(p.balance) or 0) <= 0 and #(p.purchases or {}) == 0 then drop[#drop + 1] = key end
    end
    for _, key in ipairs(drop) do db.players[key] = nil end
  end
  pcall(saveDB)
  ru.unload()        -- словарь нужен был только для этого перевода; дальше грузится лениво, у владельца
end

-- ПК-сервер: без экрана и киоска, только база и ответы терминалам
function Net.serverMain()
  db = loadDB()
  Net.prepareDB()
  modem.open(CONFIG.NET_PORT)
  local n = 0
  for _ in pairs(db.players) do n = n + 1 end
  print("KitShop SERVER запущен. Порт " .. CONFIG.NET_PORT .. ", игроков в базе: " .. n)
  if CONFIG.NET_KEY == "change-me" then print("ВНИМАНИЕ: смените CONFIG.NET_KEY на свой пароль (одинаковый на всех ПК).") end
  if #CONFIG.OWNERS == 0 and #db.owners == 0 then
    print("Владелец не задан. С любого терминала выполните: lua shop.lua owner add ВашНик")
  end
  Net.applyQueue()
  while running do
    Net.applyQueue()
    local r = table.pack(pcall(event.pull, 2, "modem_message"))
    if not r[1] then
      if tostring(r[2]):find("interrupted", 1, true) then running = false; break end
      error(r[2], 0)
    end
    if r[2] == "modem_message" then
      local e = { n = r.n - 1, table.unpack(r, 2, r.n) }
      local ok, err = xpcall(Net.serverHandle, debug.traceback, e)
      if not ok then print(tostring(err)); pcall(reportError, err) end
    end
    memGuard()
  end
  print("KitShop SERVER остановлен.")
end

local function main()
  if MODE == "server" then return Net.serverMain() end
  if MODE == "terminal" then
    db = { owners = {}, ownerUids = {}, kits = {}, nextKitId = 1, topup = {}, players = {}, feedback = {},
           nextPurchaseId = 1, withdraw = false }
    modem.open(CONFIG.NET_PORT + 1)
    if not Net.call("hello", {}, 1) then
      print("ВНИМАНИЕ: сервер магазина не отвечает (порт " .. CONFIG.NET_PORT .. "). Проверьте сервер, кабель и NET_KEY.")
    end
  else
    db = loadDB()
    Net.prepareDB()
    if #CONFIG.OWNERS == 0 and #db.owners == 0 then
      print("ВНИМАНИЕ: владелец не задан. Остановите программу и выполните:")
      print("  lua kitshop.lua owner add ВашНик")
    end
  end
  pcall(gpu.setResolution, CONFIG.SCREEN_W, CONFIG.SCREEN_H)
  W, H = gpu.getResolution()

  -- защита киоска: Ctrl+Alt+C с клавиатуры игрока не должен останавливать программу
  -- (оригинальные обработчики сохранены в ORIG_INT / ORIG_SOFT один раз, при загрузке файла)
  if ARGS[1] ~= "debug" then
    event.shouldInterrupt = function() return false end
    event.shouldSoftInterrupt = function() return false end
  end

  S = { player = nil }
  render()

  while running do
    local timeout = nil
    if S.player then
      if refreshRemaining() > 0 then timeout = 1 end   -- только пока идёт кулдаун
    else
      timeout = 0.7                                    -- анимация заставки
    end
    local e = table.pack(safePull(event.pull, timeout))
    memGuard()                                         -- порог ОЗУ: выгрузить лишнее до обработки события
    local ok, err = xpcall(function()
      local name = e[1]
      if name == "player_on" then onPlayerOn(e)
      elseif name == "player_off" then onPlayerOff()
      elseif name == "touch" then onTouch(e)
      elseif name == nil then
        if S.player then redrawFooter()                -- обновить таймер кнопки
        else idleTick() end                            -- анимация заставки
      end
      if pendingOff then pendingOff = false; onPlayerOff() end
    end, debug.traceback)
    if not ok then reportError(err) end
    if pendingOff then pendingOff = false; pcall(onPlayerOff) end
  end

  event.shouldInterrupt, event.shouldSoftInterrupt = ORIG_INT, ORIG_SOFT
  gpu.setBackground(0x000000); gpu.setForeground(0xFFFFFF)
  gpu.fill(1, 1, W, H, " ")
  print("KitShop остановлен.")
end

----------------------------------------------------------------------
-- АВТОЗАПУСК: строка в /home/.shrc (OpenOS выполняет её при каждой загрузке)
----------------------------------------------------------------------
do   -- служебные команды и запуск: в отдельном блоке, чтобы не упереться в лимит 200 локальных переменных Lua
local RC_PATH   = "/home/.shrc"
local RC_MARK   = "# kitshop-autostart"
local NOAUTO    = "/home/kitshop/noautostart"      -- флаг: владелец отключил автозапуск

local function selfPath()
  local src = tostring(SELF_SRC or ""):gsub("^[@=]", "")
  if src == "" then return nil end
  if src:sub(1, 1) ~= "/" then
    local ok, shell = pcall(require, "shell")
    if ok and shell and shell.resolve then src = shell.resolve(src) end
  end
  return fs.canonical(src)
end

local function readRc()
  local lines = {}
  local f = io.open(RC_PATH, "r")
  if f then
    for l in f:lines() do lines[#lines + 1] = l end
    f:close()
  end
  return lines
end

local function writeRc(lines)
  local f = io.open(RC_PATH, "w")
  if not f then return false end
  f:write(table.concat(lines, "\n"))
  if #lines > 0 then f:write("\n") end
  f:close()
  return true
end

-- включает/выключает автозапуск; возвращает (ok, текст)
local function setAutostart(on, path)
  path = path or selfPath()
  local lines, out = readRc(), {}
  local skip = false
  for _, l in ipairs(lines) do
    if l:find(RC_MARK, 1, true) then skip = true          -- строка-метка и следующая за ней (команда)
    elseif skip then skip = false
    else out[#out + 1] = l end
  end
  if on then
    if not path then return false, "Не удалось определить путь к файлу. Укажите: lua shop.lua autostart on /путь/к/shop.lua" end
    out[#out + 1] = RC_MARK
    out[#out + 1] = path
    pcall(fs.makeDirectory, fs.path(NOAUTO))
    pcall(fs.remove, NOAUTO)
  else
    pcall(fs.makeDirectory, fs.path(NOAUTO))
    local f = io.open(NOAUTO, "w"); if f then f:write("1"); f:close() end
  end
  if not writeRc(out) then return false, "Не удалось записать " .. RC_PATH end
  return true, on and ("Автозапуск включён: " .. path) or "Автозапуск выключен."
end

local function autostartEnabled()
  for _, l in ipairs(readRc()) do
    if l:find(RC_MARK, 1, true) then return true end
  end
  return false
end

-- при обычном запуске сам настраивает автозапуск (если его не отключали командой autostart off)
local function ensureAutostart()
  if fs.exists(NOAUTO) or autostartEnabled() then return end
  local path = selfPath()
  if path and fs.exists(path) then pcall(setAutostart, true, path) end
end

-- команда: lua shop.lua autostart on|off|status [путь]
local function autostartCli()
  local cmd = ARGS[2]
  if cmd == "on" then
    local ok, msg = setAutostart(true, ARGS[3] and fs.canonical(ARGS[3]) or nil)
    print(msg)
  elseif cmd == "off" then
    local _, msg = setAutostart(false)
    print(msg)
  elseif cmd == "status" then
    print(autostartEnabled() and "Автозапуск включён." or "Автозапуск выключен.")
    local rc = readRc()
    for i, l in ipairs(rc) do if l:find(RC_MARK, 1, true) and rc[i + 1] then print("  " .. rc[i + 1]) end end
  else
    print("Использование: lua shop.lua autostart on|off|status [путь]")
  end
end

-- команда: lua kitshop.lua owner add|del|list [Ник]
local function ownerCli()
  local cmd, nick = ARGS[2], ARGS[3]
  if MODE == "terminal" then
    print("Владельцев добавляют только на сервере: lua shop.lua owner add Ник")
    return
  end
  if MODE == "server" and (cmd == "add" or cmd == "del") and nick then
    -- сервер запущен и держит базу в памяти: команду кладём в очередь, он применит её сам
    pcall(fs.makeDirectory, fs.path(CONFIG.CMD_PATH))
    local f = io.open(CONFIG.CMD_PATH, "a")
    if f then f:write(cmd .. "\t" .. nick .. "\n"); f:close() end
    print("Команда принята. Запущенный сервер применит её за пару секунд (если сервер остановлен - при запуске).")
    return
  end
  db = loadDB()
  if cmd == "add" and nick then
    if isOwner(nick) then print("Уже владелец: " .. nick)
    else db.owners[#db.owners + 1] = nick; saveDB(); print("Владелец добавлен: " .. nick) end
  elseif cmd == "del" and nick then
    for i = #db.owners, 1, -1 do
      if lower(db.owners[i]) == lower(nick) then table.remove(db.owners, i) end
    end
    db.ownerUids = db.ownerUids or {}
    db.ownerUids[lower(nick)] = nil          -- сброс привязки к UUID
    saveDB(); print("Удалён из владельцев: " .. nick)
  elseif cmd == "list" then
    for _, o in ipairs(CONFIG.OWNERS) do print(o .. "  (из файла)") end
    for _, o in ipairs(db.owners) do print(o) end
  else
    print("Использование: lua kitshop.lua owner add|del|list [Ник]")
  end
end

-- диагностика: lua kitshop.lua dump [часть названия]
-- печатает все поля первых 10 подходящих предметов из ME (чтобы найти поле NBT/хеша)
local function dumpCli()
  local f = lower(ARGS[2] or "")
  local list = me.getItemsInNetwork()
  local shown = 0
  for _, it in ipairs(list) do
    if f == "" or lower(tostring(it.label) .. " " .. tostring(it.name)):find(f, 1, true) then
      local parts = {}
      for k, v in pairs(it) do
        if type(v) == "table" then
          local sub = {}
          for k2, v2 in pairs(v) do sub[#sub + 1] = tostring(k2) .. "=" .. tostring(v2) end
          table.sort(sub)
          parts[#parts + 1] = tostring(k) .. "={" .. table.concat(sub, ", ") .. "}"
        else
          parts[#parts + 1] = tostring(k) .. "=" .. tostring(v)
        end
      end
      table.sort(parts)
      print(table.concat(parts, "  "))
      print("  -> вариант: [" .. variantOf(it) .. "]")
      shown = shown + 1
      if shown >= 10 then break end
    end
  end
  if shown == 0 then print("Ничего не найдено.") end
end

-- Надзиратель: при любой неожиданной ошибке магазин перезапускается,
-- а не падает в консоль (к которой мог бы получить доступ игрок).
local function supervised()
  local fails = 0
  while running do
    local ok, err = xpcall(main, debug.traceback)
    if ok then
      fails = 0
    else
      fails = fails + 1
      pcall(reportError, err)
      if fails >= 5 then
        -- 5 падений подряд: перезапуск main не помогает. Полная перезагрузка ПК освобождает
        -- всю память, а автозапуск (.shrc) поднимет магазин заново. В консоль не выходим.
        pcall(computer.shutdown, true)
        os.sleep(5)
        return
      end
      gc()
      os.sleep(3)
    end
  end
end

-- диагностика перевода: lua kitshop.lua missing
-- показывает предметы ME, для которых нет русского названия в словаре, и пишет полный список
-- в /home/kitshop/missing.txt (id&&damage<TAB>label<TAB>причина)
local function missingCli()
  local list = me.getItemsInNetwork()
  table.sort(list, function(a, b) return tostring(a.name) < tostring(b.name) end)   -- моды подряд
  local seen, rows = {}, {}
  local total, translated = 0, 0
  for _, it in ipairs(list) do
    if type(it) == "table" and it.name then
      local dmg = math.floor(tonumber(it.damage) or 0)
      local k = tostring(it.name) .. "&&" .. dmg
      if not seen[k] then
        seen[k] = true
        total = total + 1
        if ru.item(it.name, dmg, nil) then
          translated = translated + 1
        else
          local why
          if ru.item(it.name, 0, nil) and dmg ~= 0 then why = "есть только meta 0"
          else why = "id нет в словаре" end
          rows[#rows + 1] = { k = k, label = tostring(it.label), why = why }
        end
      end
    end
  end
  table.sort(rows, function(a, b) return a.k < b.k end)
  local f = io.open("/home/kitshop/missing.txt", "w")
  local byWhy = {}
  for _, r in ipairs(rows) do
    byWhy[r.why] = (byWhy[r.why] or 0) + 1
    if f then f:write(r.k .. "\t" .. r.label .. "\t" .. r.why .. "\n") end
  end
  if f then f:close() end
  print("Типов предметов в ME: " .. total .. ", переведено: " .. translated .. ", без перевода: " .. #rows)
  for why, n in pairs(byWhy) do print("  " .. why .. ": " .. n) end
  print("Первые 25 без перевода:")
  for i = 1, math.min(25, #rows) do print("  " .. rows[i].k .. "  |  " .. rows[i].label .. "  |  " .. rows[i].why) end
  print("Полный список: /home/kitshop/missing.txt")
end

-- проверка связи с сервером: lua shop.lua ping (на терминале)
local function pingCli()
  if MODE ~= "terminal" then print("ping выполняется на терминале (CONFIG.MODE = \"terminal\")."); return end
  local wl = false
  pcall(function() wl = modem.isWireless() end)
  print("Модем: " .. modem.address:sub(1, 8) .. (wl and " (беспроводной)" or " (проводной)") ..
        ", порт " .. CONFIG.NET_PORT .. ", ключ \"" .. CONFIG.NET_KEY .. "\"")
  modem.open(CONFIG.NET_PORT + 1)
  local t0 = computer.uptime()
  local r = Net.call("hello", {}, 3)
  if r and r.ok then print("OK: сервер ответил за " .. string.format("%.2f", computer.uptime() - t0) .. " с")
  else
    print("Сервер не ответил. Проверьте по порядку:")
    print(" 1) на сервере запущен shop.lua (CONFIG.MODE = \"server\"), в его консоли нет ошибок;")
    print(" 2) сервер и терминал соединены кабелем/Relay в одну сеть (или беспроводные карты в радиусе);")
    print(" 3) NET_PORT и NET_KEY одинаковые на обоих ПК;")
    print(" 4) если сервер пишет «неверный NET_KEY» - ключи различаются.")
  end
end

-- диагностика: lua shop.lua methods - список методов ME Interface и пример getAvailableItems
local function methodsCli()
  local ok, m = pcall(component.methods, me.address)
  local names = {}
  if ok and type(m) == "table" then for k in pairs(m) do names[#names + 1] = k end end
  if #names == 0 then for k, v in pairs(me) do if type(v) == "function" or type(v) == "table" then names[#names + 1] = k end end end
  table.sort(names)
  print("Методы me_interface: " .. table.concat(names, ", "))
  if me.getAvailableItems ~= nil then
    local ok2, list = pcall(me.getAvailableItems)
    local n = 0
    if ok2 and type(list) == "table" then
      for _, e in ipairs(list) do
        local f = e.fingerprint
        if type(f) == "table" and tostring(f.id):lower():find("tank", 1, true) then
          local d = me.getItemDetail(f)
          if type(d) == "table" and d.all ~= nil then d = d.all() end
          print(tostring(f.id), tostring(f.dmg), tostring(f.nbt_hash), "fluid=" .. fluidVariant(d or {}))
          n = n + 1; if n >= 15 then break end
        end
      end
    else print("getAvailableItems: ошибка " .. tostring(list)) end
  else print("getAvailableItems нет") end
end

-- диагностика: lua shop.lua kits - что реально сохранено в комплектах (id, damage, var/хеш)
local function kitsCli()
  if MODE == "terminal" then print("Команда kits выполняется на сервере (или в одиночном режиме)."); return end
  db = loadDB()
  for _, k in ipairs(db.kits) do
    print("Комплект #" .. k.id .. " " .. k.name)
    for _, it in ipairs(k.items) do
      print("  " .. tostring(it.label) .. "  " .. it.name .. ":" .. it.damage .. "  x" .. it.qty ..
            "  var=[" .. tostring(it.var or "") .. "]")
    end
  end
end

-- диагностика: lua shop.lua fp [часть id] - все поля предмета в getAvailableItems и getItemsInNetwork
local function fpCli()
  local f = lower(ARGS[2] or "tank")
  local function flat(t)
    local parts = {}
    for k, v in pairs(t) do
      if type(v) == "table" then
        local sub = {}
        for k2, v2 in pairs(v) do sub[#sub + 1] = tostring(k2) .. "=" .. tostring(v2) end
        table.sort(sub); parts[#parts + 1] = tostring(k) .. "={" .. table.concat(sub, ", ") .. "}"
      else parts[#parts + 1] = tostring(k) .. "=" .. tostring(v) end
    end
    table.sort(parts); return table.concat(parts, "  ")
  end
  print("== getAvailableItems ==")
  local ok, list = pcall(me.getAvailableItems)
  local n = 0
  if ok and type(list) == "table" then
    for _, e in ipairs(list) do
      local fp = e.fingerprint
      if type(fp) == "table" and lower(tostring(fp.id)):find(f, 1, true) then
        print(flat(e)); n = n + 1; if n >= 8 then break end
      end
    end
  else print("ошибка: " .. tostring(list)) end
  print("== getItemsInNetwork ==")
  n = 0
  for _, it in ipairs(me.getItemsInNetwork()) do
    if lower(tostring(it.name)):find(f, 1, true) then
      print(flat(it)); n = n + 1; if n >= 8 then break end
    end
  end
end

if ARGS[1] == "ping" then pingCli()
elseif ARGS[1] == "fp" and me then fpCli()
elseif ARGS[1] == "kits" then kitsCli()
elseif ARGS[1] == "methods" then methodsCli()
elseif ARGS[1] == "owner" then ownerCli()
elseif ARGS[1] == "autostart" then autostartCli()
elseif ARGS[1] == "missing" then missingCli()
elseif ARGS[1] == "dump" then dumpCli()
elseif ARGS[1] == "debug" then            -- без автоперезапуска, Ctrl+Alt+C работает
  local ok, err = xpcall(main, debug.traceback)
  if not ok then print(err) end
else
  pcall(ensureAutostart)
  supervised()
end
end
