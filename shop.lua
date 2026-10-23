--[[
  KitShop - магазин КОМПЛЕКТОВ для OpenComputers + OpenPeripheral PIM + AE2 ME Interface

  Игрок встаёт на PIM -> авторизация -> одно сканирование ME -> три вкладки
  (у владельца) или две (у клиента):
    Квесты/Комплекты | Пополнение | Создание (только владелец)

  Всё хранится локально в файле базы (CONFIG.DB_PATH): балансы, покупки,
  незабранные ресурсы, комплекты, ресурсы пополнения, отзывы.

  Экран рассчитан на 160x50 (подстраивается под реальное разрешение).
]]

local component = require("component")
local computer  = require("computer")
local event     = require("event")
local fs        = require("filesystem")
local ser       = require("serialization")
local unicode   = require("unicode")

local ARGS = { ... }               -- аргументы командной строки

----------------------------------------------------------------------
-- НАСТРОЙКИ
----------------------------------------------------------------------
local CONFIG = {
  OWNERS   = {},                    -- необязательно: ники прямо в файле.
                                    -- Основной способ: lua kitshop.lua owner add Ник
  CURRENCY = "эм",                  -- название валюты на экране

  DB_PATH  = "/home/kitshop/db.dat",
  LOG_PATH = "/home/kitshop/error.log",

  -- Стороны. По умолчанию как в pimmarket: ME Interface стоит ПОД PIM.
  ME_EXPORT_SIDE = "up",            -- откуда ME Interface выдаёт предметы (в сторону PIM)
  PIM_PUSH_SIDE  = "down",          -- куда PIM принимает предметы игрока (в ME Interface)

  REFRESH_COOLDOWN = 60,            -- кнопка "Обновить" не чаще раза в N секунд
  SCREEN_W = 160, SCREEN_H = 50,     -- желаемое разрешение (подстроится под экран)

  PICK_MAX = 300,                   -- сколько предметов ME показывать в списке выбора (дальше - поиском)

  FEEDBACK_COOLDOWN = 30,           -- пауза между отзывами одного игрока, сек
  FEEDBACK_MAX_LEN  = 200,
  FEEDBACK_KEEP     = 100,          -- сколько последних отзывов хранить
}

----------------------------------------------------------------------
-- ОБОРУДОВАНИЕ
----------------------------------------------------------------------
if not component.isAvailable("me_interface") then
  error("Не найден компонент me_interface (ME Interface должен быть подключён к компьютеру)")
end
if not component.isAvailable("pim") then
  error("Не найден компонент pim (OpenPeripheral PIM)")
end
local gpu = component.gpu
local me  = component.me_interface
local pim = component.pim

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
local function itemKey(name, dmg) return tostring(name) .. "&&" .. tostring(math.floor(tonumber(dmg) or 0)) end

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
  return { owners = {}, ownerUids = {}, kits = {}, nextKitId = 1, topup = {}, players = {}, feedback = {}, nextPurchaseId = 1 }
end

local function loadDB()
  if fs.exists(CONFIG.DB_PATH) then
    local f = io.open(CONFIG.DB_PATH, "r")
    if f then
      local data = f:read("*a"); f:close()
      local t = ser.unserialize(data)
      if type(t) == "table" then
        for k, v in pairs(defaultDB()) do if t[k] == nil then t[k] = v end end
        return t
      end
      -- файл повреждён: не затираем, а откладываем в сторону
      pcall(fs.copy, CONFIG.DB_PATH, CONFIG.DB_PATH .. ".bad")
    end
  end
  return defaultDB()
end

local function saveDB()
  pcall(fs.makeDirectory, fs.path(CONFIG.DB_PATH))
  local tmp = CONFIG.DB_PATH .. ".tmp"
  local f = assert(io.open(tmp, "w"))
  f:write(ser.serialize(db))
  f:close()
  fs.remove(CONFIG.DB_PATH)
  fs.rename(tmp, CONFIG.DB_PATH)
end

local function getPlayer(name)
  local k = lower(name)
  local p = db.players[k]
  if not p then
    p = { name = name, balance = 0, purchases = {} }
    db.players[k] = p
    saveDB()
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
local function reservedMap()
  local r = {}
  for _, p in pairs(db.players) do
    for _, pu in ipairs(p.purchases or {}) do
      for _, it in ipairs(pu.items) do
        if it.qty > 0 then
          local k = itemKey(it.name, it.damage)
          r[k] = (r[k] or 0) + it.qty
        end
      end
    end
  end
  return r
end

local function unreadFeedback()
  local n = 0
  for _, f in ipairs(db.feedback) do if not f.read then n = n + 1 end end
  return n
end

----------------------------------------------------------------------
-- ME: кэш остатков (сканируется при входе игрока и по кнопке "Обновить")
----------------------------------------------------------------------
-- cache.byKey  - остатки только нужных магазину предметов
-- cache.items  - список для выбора предметов (ТОЛЬКО у владельца, только в окне выбора,
--                максимум CONFIG.PICK_MAX штук, фильтруется поиском)
local cache = { items = {}, byKey = {}, time = nil, pickMore = false, pickTotal = 0 }

-- какие предметы нужны магазину: комплекты, ресурсы пополнения, неотданные покупки
local function wantedNames()
  local w = {}
  for _, k in ipairs(db.kits) do for _, it in ipairs(k.items) do w[it.name] = true end end
  for _, t in ipairs(db.topup) do w[t.name] = true end
  for _, p in pairs(db.players) do
    for _, pu in ipairs(p.purchases or {}) do
      for _, it in ipairs(pu.items) do w[it.name] = true end
    end
  end
  return w
end

-- Лёгкий скан при входе: запоминаем остатки только нужных предметов.
local function scanME()
  return pcall(function()
    local list = me.getItemsInNetwork()
    if type(list) ~= "table" then error("ME вернула " .. type(list)) end
    local want, by = wantedNames(), {}
    for _, it in ipairs(list) do
      local name = type(it) == "table" and it.name
      if name and want[name] then
        local dmg = math.floor(tonumber(it.damage) or 0)
        local size = tonumber(it.size) or 0
        local k = itemKey(name, dmg)
        local e = by[k]
        if e then e.size = e.size + size
        else
          by[k] = { key = k, name = name, damage = dmg, label = tostring(it.label or name),
                    size = size, maxSize = tonumber(it.maxSize) or 64 }
        end
      end
    end
    list = nil
    cache.byKey, cache.time = by, computer.uptime()
  end)
end

-- Список для выбора предметов (владелец). Хранит только совпавшие с поиском
-- и не больше PICK_MAX штук - на огромной ME это не съедает память.
local function pickerScan(filter)
  cache.items = {}
  collectgarbage()
  return pcall(function()
    local list = me.getItemsInNetwork()
    if type(list) ~= "table" then error("ME вернула " .. type(list)) end
    local f = lower(filter or "")
    local out, total = {}, 0
    for _, it in ipairs(list) do
      local name = type(it) == "table" and it.name
      if name then
        local label = tostring(it.label or name)
        if f == "" or lower(label .. " " .. name):find(f, 1, true) then
          total = total + 1
          if #out < CONFIG.PICK_MAX then
            out[#out + 1] = { name, math.floor(tonumber(it.damage) or 0), label,
                              tonumber(it.size) or 0, tonumber(it.maxSize) or 64 }
          end
        end
      end
    end
    list = nil
    table.sort(out, function(a, b)
      if a[3] ~= b[3] then return a[3] < b[3] end
      if a[1] ~= b[1] then return a[1] < b[1] end
      return a[2] < b[2]
    end)
    cache.items, cache.pickTotal, cache.pickMore = out, total, total > #out
  end)
end

-- точный запрос по одному предмету (дёшево, используется при покупке/выдаче)
local function meCount(name, damage)
  local ok, list = pcall(me.getItemsInNetwork, { name = name, damage = damage })
  if not ok or type(list) ~= "table" then return nil end
  local total = 0
  for _, it in ipairs(list) do
    if it.name == name and math.floor(tonumber(it.damage) or 0) == damage then
      total = total + (tonumber(it.size) or 0)
    end
  end
  return total
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
    m = math.min(m, math.floor(avail(itemKey(it.name, it.damage)) / it.qty))
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
         tonumber(st.max_size or st.maxSize) or 64
end

-- читает 36 слотов: slots[s] = false (пусто) | {name,damage,qty,max} | nil (ошибка чтения)
local function readSlots()
  local slots = {}
  for s = 1, 36 do
    local ok, st = pcall(pim.getStackInSlot, s)
    if ok then
      if st then
        local n, d, q, mx = stackInfo(st)
        slots[s] = { name = n, damage = d, qty = q, max = mx }
      else
        slots[s] = false
      end
    end
  end
  return slots
end

local function countIn(slots, name, damage)
  local c = 0
  for s = 1, 36 do
    local st = slots[s]
    if st and st.name == name and st.damage == damage then c = c + st.qty end
  end
  return c
end

-- сколько штук предмета ещё влезет в инвентарь (пустые слоты + недобитые стаки)
local function spaceIn(slots, name, damage, maxSize)
  local space = 0
  for s = 1, 36 do
    local st = slots[s]
    if st == false then
      space = space + maxSize
    elseif st and st.name == name and st.damage == damage then
      space = space + math.max(0, maxSize - st.qty)
    end
  end
  return space
end

local function invMap(slots)
  local m = {}
  for s = 1, 36 do
    local st = slots[s]
    if st then
      local k = itemKey(st.name, st.damage)
      m[k] = (m[k] or 0) + st.qty
    end
  end
  return m
end

----------------------------------------------------------------------
-- ЭКРАН: примитивы и сетка
--
--   колонка 1 и колонка W - пустые поля; содержимое занимает 2 .. W-1
--   строки: 1 шапка | 2-3 вкладки | 4 сообщение | 5-6 управление |
--           7 инфо | 8+ список (карточки по 2 строки + 1 пропуск) | H-1..H подвал
----------------------------------------------------------------------
local W, H = 160, 50
local C = {
  bg = 0x101010, panel = 0x1e1e1e, panel2 = 0x2d2d2d, bar = 0x0a0a0a,
  text = 0xdddddd, dim = 0x888888, accent = 0x68f029, gold = 0xf2b233,
  red = 0xff5555, blue = 0x2f5fb3, green = 0x2f7d1a, disabled = 0x262626,
  tabOn = 0x3a7d1e, tabOff = 0x2a2a2a, dlg = 0x202020,
}
local UI = { btns = {}, tag = nil }

local LIST_Y = 8        -- начало списка карточек на обычных экранах
local SUB_Y  = 11       -- начало списка на вкладке «Создание»
local BW     = 18       -- стандартная ширина кнопки в карточке
local BW2    = 14       -- ширина кнопок, когда их две в ряд

local function fill(x, y, w, h, bg)
  if w <= 0 or h <= 0 then return end
  gpu.setBackground(bg)
  gpu.fill(x, y, w, h, " ")
end

local function text(x, y, s, fg, bg)
  gpu.setBackground(bg or C.bg)
  gpu.setForeground(fg or C.text)
  gpu.set(x, y, s)
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
    UI.btns[#UI.btns + 1] = { x = x, y = y, w = w, h = h, fn = o.fn, tag = UI.tag }
  end
end

-- кнопка, прижатая к правому краю содержимого (последняя колонка = W-1).
-- off - отступ от правого края; возвращает отступ для следующей кнопки слева.
local function rb(y, off, w, label, o)
  addBtn(W - off - w, y, w, 2, label, o)
  return off + w + 1
end

-- карточка на всю ширину содержимого; reserve - сколько колонок справа занято кнопками
local function card(y, title, sub, subColor, reserve)
  reserve = reserve or (BW + 2)
  local tw = math.max(1, W - reserve - 4)
  fill(2, y, W - 2, 2, C.panel)
  text(3, y, pad(title, tw), C.accent, C.panel)
  text(3, y + 1, pad(sub, tw), subColor or C.dim, C.panel)
end

----------------------------------------------------------------------
-- СОСТОЯНИЕ
----------------------------------------------------------------------
local S = { player = nil }
local pendingOff = false
local running = true
local render, nav, flash, status   -- объявлены заранее

local function drawMessage()
  fill(1, 4, W, 1, C.bg)
  if S.msg and S.msg ~= "" then
    text(2, 4, pad(S.msg, W - 2), S.msgOk == false and C.red or C.accent, C.bg)
  end
end

status = function(msg) S.msg = msg; S.msgOk = true; drawMessage() end
flash  = function(msg, ok) S.msg = msg; S.msgOk = (ok ~= false); render() end
nav = function(fields, msg, ok)
  for k, v in pairs(fields or {}) do S[k] = v end
  S.page = 1; S.confirm = nil; S.backFn = nil
  S.msg = msg or ""; S.msgOk = (ok ~= false)
  render()
end

----------------------------------------------------------------------
-- ВВОД С КЛАВИАТУРЫ + МОДАЛЬНОЕ ОКНО
----------------------------------------------------------------------
local function prompt(title, initial, maxLen)
  maxLen = maxLen or 60
  local bw = math.min(W - 4, 80)
  local bh = 7
  local bx, by = math.floor((W - bw) / 2) + 1, math.floor((H - bh) / 2) + 1
  local buf = initial or ""
  local function draw()
    fill(bx, by, bw, bh, C.dlg)
    text(bx + 2, by + 1, pad(title, bw - 4), C.gold, C.dlg)
    fill(bx + 2, by + 3, bw - 4, 1, 0x000000)
    local shown, room = buf, bw - 8
    if unicode.len(shown) > room then shown = unicode.sub(shown, unicode.len(shown) - room + 1) end
    text(bx + 3, by + 3, shown .. "_", C.accent, 0x000000)
    text(bx + 2, by + 5, pad("Enter - принять, Esc - отмена", bw - 4), C.dim, C.dlg)
  end
  draw()
  while true do
    local e = table.pack(event.pullMultiple("key_down", "player_off"))
    if e[1] == "player_off" then pendingOff = true; return nil end
    local who = e[5]
    if not who or not S.player or lower(who) == lower(S.player.name) then
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
  local n = tonumber((s:gsub(",", ".")))
  if not n or n ~= n or n < 0 then return nil end
  if integer then n = math.floor(n) end
  return n
end

local function modal(title, body)
  local bw = math.min(W - 4, 100)
  local lines = wrap(body, bw - 4)
  local bh = #lines + 5
  local bx, by = math.floor((W - bw) / 2) + 1, math.max(2, math.floor((H - bh) / 2) + 1)
  fill(bx, by, bw, bh, C.dlg)
  text(bx + 2, by + 1, pad(title, bw - 4), C.gold, C.dlg)
  for i, l in ipairs(lines) do text(bx + 2, by + 2 + i, l, C.text, C.dlg) end
  text(bx + 2, by + bh - 1, pad("Коснитесь экрана, чтобы закрыть", bw - 4), C.dim, C.dlg)
  while true do
    local e = table.pack(event.pullMultiple("touch", "key_down", "player_off"))
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
  S.inv = invMap(readSlots())
end

local function verifyStock(kit)
  local res = reservedMap()
  for _, it in ipairs(kit.items) do
    local real = meCount(it.name, it.damage)
    if real == nil then return false, "ME-сеть недоступна. Попробуйте позже." end
    local k = itemKey(it.name, it.damage)
    if cache.byKey[k] then cache.byKey[k].size = real end
    if real - (res[k] or 0) < it.qty then
      return false, "Комплект только что закончился: не хватает «" .. it.label .. "»."
    end
  end
  return true
end

local function doBuy(kit)
  local p = getPlayer(S.player.name)
  if #kit.items == 0 then return flash("Комплект пуст.", false) end
  if round2(p.balance) < round2(kit.price) then
    return flash("Не хватает средств: нужно " .. fmt(kit.price) .. ", на балансе " .. fmt(p.balance) ..
                 ". Загляните во вкладку «Пополнение».", false)
  end
  status("Проверяю наличие ресурсов...")
  local ok, err = verifyStock(kit)
  if not ok then return flash(err, false) end

  p.balance = round2(p.balance - kit.price)
  local pu = { id = db.nextPurchaseId, kit = kit.name, items = {} }
  db.nextPurchaseId = db.nextPurchaseId + 1
  for _, it in ipairs(kit.items) do
    pu.items[#pu.items + 1] = { name = it.name, damage = it.damage, label = it.label, qty = it.qty }
  end
  p.purchases[#p.purchases + 1] = pu
  saveDB()
  nav({ view = "purchase", purchaseId = pu.id },
      "Оплачено! Заберите ресурсы кнопками «Забрать» (можно по одному, можно позже).", true)
end

local function doClaim(pu, it)
  if it.qty <= 0 then return end
  local key = itemKey(it.name, it.damage)
  local maxSize = (cache.byKey[key] and cache.byKey[key].maxSize) or 64

  status("Проверяю место в инвентаре...")
  local slots = readSlots()
  local space = spaceIn(slots, it.name, it.damage, maxSize)
  if space <= 0 then
    return flash("Нет места в инвентаре. Освободите слот и нажмите «Забрать» ещё раз.", false)
  end
  local real = meCount(it.name, it.damage)
  if real == nil then return flash("ME-сеть недоступна. Попробуйте позже.", false) end
  if real <= 0 then
    return flash("Ресурса сейчас нет в ME. Напишите владельцу через «Обратная связь».", false)
  end

  local deliver = math.min(it.qty, space, real)
  local before = countIn(slots, it.name, it.damage)

  -- сначала списываем в базе (чтобы при сбое питания выдача не удвоилась)
  it.qty = it.qty - deliver
  saveDB()

  status("Выдаю...")
  local fp, left = { id = it.name, dmg = it.damage }, deliver
  while left > 0 do
    local chunk = math.min(left, maxSize)
    local ok, res = pcall(me.exportItem, fp, CONFIG.ME_EXPORT_SIDE, chunk)
    if not ok then break end
    local moved = tonumber(res) or (type(res) == "table" and tonumber(res.size)) or nil
    if moved == 0 then break end
    left = left - chunk
  end

  -- реально выданное считаем по разнице в инвентаре, остаток возвращаем в долг магазина
  local after = countIn(readSlots(), it.name, it.damage)
  local given = math.max(0, math.min(deliver, after - before))
  if given < deliver then it.qty = it.qty + (deliver - given) end
  if cache.byKey[key] then cache.byKey[key].size = math.max(0, cache.byKey[key].size - given) end
  saveDB()

  if given == 0 then
    return flash("Не удалось выдать «" .. it.label .. "». Попробуйте ещё раз.", false)
  elseif it.qty > 0 then
    return flash("Выдано " .. given .. " из " .. (given + it.qty) .. " («" .. it.label ..
                 "»). Освободите место и нажмите «Забрать» снова.", true)
  end
  flash("Выдано: " .. it.label .. " x" .. given, true)
end

local function doDeposit(e, amount)
  status("Читаю инвентарь...")
  local before = readSlots()
  local have = countIn(before, e.name, e.damage)
  local want = amount and math.min(amount, have) or have
  if want <= 0 then return flash("В инвентаре нет «" .. e.label .. "».", false) end

  status("Принимаю ресурсы...")
  local left = want
  for s = 1, 36 do
    if left <= 0 then break end
    local st = before[s]
    if st and st.name == e.name and st.damage == e.damage then
      local take = math.min(st.qty, left)
      if pcall(pim.pushItem, CONFIG.PIM_PUSH_SIDE, s, take) then left = left - take end
    end
  end

  local afterSlots = readSlots()
  local after = countIn(afterSlots, e.name, e.damage)
  local moved = math.max(0, math.min(want, have - after))
  S.inv = invMap(afterSlots)
  if moved <= 0 then return flash("Не удалось принять предметы (возможно, ME переполнена).", false) end

  local p = getPlayer(S.player.name)
  local gain = round2(moved * e.price)
  p.balance = round2(p.balance + gain)
  local c = cache.byKey[itemKey(e.name, e.damage)]
  if c then c.size = c.size + moved end
  saveDB()
  flash("Принято " .. moved .. " шт. «" .. e.label .. "». Зачислено: " .. fmt(gain) .. " " .. CONFIG.CURRENCY, true)
end

local function doRefresh()
  if refreshRemaining() > 0 then return end
  status("Сканирую ME-сеть...")
  local ok, err = scanME()
  if ok and S.player and S.player.owner and S.view == "pick" then
    ok, err = pickerScan(S.filter)
  end
  if ok then flash("Список обновлён.", true)
  else flash("Не удалось просканировать ME: " .. tostring(err), false) end
end

-- открыть окно выбора предмета из ME (только владелец)
local function openPicker(mode)
  status("Загружаю список ME...")
  local ok, err = pickerScan("")
  if ok then
    nav({ view = "pick", pickMode = mode, filter = "" })
  else
    nav({ view = "pick", pickMode = mode, filter = "" }, "Не удалось получить список ME: " .. tostring(err), false)
  end
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
  db.feedback[#db.feedback + 1] = { player = S.player.name, text = trim(txt), time = os.time(), read = false }
  while #db.feedback > CONFIG.FEEDBACK_KEEP do table.remove(db.feedback, 1) end
  saveDB()
  flash("Спасибо! Сообщение отправлено владельцу.", true)
end

----------------------------------------------------------------------
-- ЭКРАНЫ
----------------------------------------------------------------------
-- сколько карточек влезает: от строки y0 до подвала, шаг 3
local function paged(count, y0)
  local per = math.max(1, math.floor((H - 2 - y0) / 3))
  local pages = math.max(1, math.ceil(count / per))
  if S.page > pages then S.page = pages end
  if S.page < 1 then S.page = 1 end
  S.pages = pages
  local first = (S.page - 1) * per + 1
  return first, math.min(count, first + per - 1)
end

local function drawIdle()
  local bw, bh = 44, 11
  local bx, by = math.floor((W - bw) / 2) + 1, math.floor((H - bh) / 2) + 1
  fill(bx, by, bw, bh, C.panel)
  local function ctr(row, s, fg)
    text(bx + math.floor((bw - unicode.len(s)) / 2), by + row, s, fg, C.panel)
  end
  ctr(3, "КомплектМаркет", C.accent)
  ctr(6, "Встаньте на PIM", C.text)
end

local function switchTab(t)
  S.tab = t; S.view = "list"; S.csub = "kits"; S.page = 1
  S.msg = ""; S.confirm = nil; S.filter = ""
  if t == "topup" then scanInventory() end
  render()
end

local function drawHeader()
  fill(1, 1, W, 1, C.bar)
  text(2, 1, "КомплектМаркет", C.accent, C.bar)
  local bal = "Баланс: " .. fmt(getPlayer(S.player.name).balance) .. " " .. CONFIG.CURRENCY
  local balW = unicode.len(bal)
  text(W - balW, 1, bal, C.gold, C.bar)
  local who = S.player.name .. (S.player.owner and " [владелец]" or "")
  text(20, 1, pad(who, math.max(1, W - balW - 22)), C.text, C.bar)

  local tabs = { { "kits", "Квесты/Комплекты" }, { "topup", "Пополнение" } }
  if S.player.owner then tabs[#tabs + 1] = { "create", "Создание" } end
  local n = #tabs
  local tw = math.floor(W / n)
  for i, t in ipairs(tabs) do
    local on = (S.tab == t[1])
    local x = (i - 1) * tw + 1
    local w = (i == n) and (W - x + 1) or tw
    addBtn(x, 2, w, 2, t[2],
      { bg = on and C.tabOn or C.tabOff, fg = on and 0xffffff or C.dim, fn = function() switchTab(t[1]) end })
  end
end

local function drawFooter()
  local y = H - 1
  fill(1, y, W, 2, C.bar)
  addBtn(2, y, 14, 2, "Назад", { disabled = not S.backFn, fn = S.backFn })
  addBtn(18, y, 6, 2, "<", { disabled = S.page <= 1, fn = function() S.page = S.page - 1; render() end })
  text(26, y, pad("стр " .. S.page .. "/" .. (S.pages or 1), 11), C.dim, C.bar)
  addBtn(38, y, 6, 2, ">", { disabled = S.page >= (S.pages or 1), fn = function() S.page = S.page + 1; render() end })
  local rem = refreshRemaining()
  addBtn(46, y, 24, 2, rem > 0 and ("Обновить (" .. rem .. "с)") or "Обновить",
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
  text(2, 5, pad(kit.name, W - 34), C.accent, C.bg)
  text(2, 6, pad("Цена: " .. fmt(kit.price) .. " " .. CONFIG.CURRENCY .. "   В наличии: " .. stock .. " шт", W - 34),
       stock > 0 and C.text or C.red, C.bg)
  rb(5, 0, 30, "Купить за " .. fmt(kit.price),
    { disabled = stock <= 0, bg = C.tabOn, fn = function() doBuy(kit) end })

  local first, last = paged(#kit.items, LIST_Y)
  for i = first, last do
    local it = kit.items[i]
    local y = LIST_Y + (i - first) * 3
    local a = avail(itemKey(it.name, it.damage))
    card(y, it.label .. "   x" .. it.qty, "В наличии: " .. a .. (a >= it.qty and "" or "   (не хватает)"),
         a >= it.qty and C.dim or C.red, 0)
  end
  S.backFn = function() nav({ view = "list" }) end
  return true
end

local function screenPurchase(p)
  local pu = findPurchase(p, S.purchaseId)
  if not pu then S.view = "mine"; return false end
  text(2, 5, pad("Покупка #" .. pu.id .. ": " .. pu.kit, W - 2), C.accent, C.bg)
  text(2, 6, "Забирайте ресурсы по одному. Нужно свободное место в инвентаре.", C.dim, C.bg)
  local first, last = paged(#pu.items, LIST_Y)
  for i = first, last do
    local it = pu.items[i]
    local y = LIST_Y + (i - first) * 3
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
  text(2, 5, "Незабранные покупки", C.accent, C.bg)
  text(2, 6, "Здесь то, что вы оплатили, но ещё не забрали.", C.dim, C.bg)
  local first, last = paged(#p.purchases, LIST_Y)
  if #p.purchases == 0 then text(2, LIST_Y, "Пока ничего нет.", C.dim, C.bg) end
  for i = first, last do
    local pu = p.purchases[i]
    local y = LIST_Y + (i - first) * 3
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
  text(2, 5, "Комплектов: " .. #list, C.accent, C.bg)
  text(2, 6, "Остатки ME: " .. ageText(), C.dim, C.bg)
  rb(5, 0, 30, "Незабранное: " .. pend,
    { disabled = (pend == 0), bg = C.gold, fg = 0x000000, fn = function() nav({ view = "mine" }) end })

  local first, last = paged(#list, LIST_Y)
  if #list == 0 then text(2, LIST_Y, "Владелец ещё не добавил комплекты.", C.dim, C.bg) end
  for i = first, last do
    local k = list[i]
    local y = LIST_Y + (i - first) * 3
    local stock = kitStock(k, avail)
    card(y, k.name, "Цена: " .. fmt(k.price) .. " " .. CONFIG.CURRENCY .. "   Ресурсов: " .. #k.items ..
                     "   В наличии: " .. stock .. " шт", stock > 0 and C.text or C.red)
    rb(y, 0, BW, stock > 0 and "Перейти" or "Нет в наличии",
      { disabled = stock <= 0, bg = C.tabOn, fn = function() nav({ view = "kit", kitId = k.id }) end })
  end
end

---------------------------------------------------------- вкладка: пополнение
local function screenTopup()
  local p = getPlayer(S.player.name)
  text(2, 5, "Положите ресурсы в инвентарь и нажмите «Внести всё» или «Ввести число».", C.accent, C.bg)
  text(2, 6, "Баланс: " .. fmt(p.balance) .. " " .. CONFIG.CURRENCY, C.gold, C.bg)
  rb(5, 0, 30, "Проверить инвентарь", { fn = function() scanInventory(); render() end })

  local list = db.topup
  local first, last = paged(#list, LIST_Y)
  if #list == 0 then text(2, LIST_Y, "Владелец ещё не добавил ресурсы для пополнения.", C.dim, C.bg) end
  local reserve = BW * 2 + 1 + 2
  for i = first, last do
    local e = list[i]
    local y = LIST_Y + (i - first) * 3
    local have = (S.inv or {})[itemKey(e.name, e.damage)] or 0
    card(y, e.label .. "  -  " .. fmt(e.price) .. " " .. CONFIG.CURRENCY .. " за шт",
         "У вас в инвентаре: " .. have .. " шт", have > 0 and C.text or C.dim, reserve)
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
  local subs = { { "kits", "Комплекты" }, { "topup", "Ресурсы пополнения" },
                 { "feedback", "Отзывы" .. (unread > 0 and (" (" .. unread .. ")") or "") } }
  local exitW, gap = 14, 1
  local region = (W - 2) - exitW - gap            -- ширина под три вкладки (колонки 2 .. W-1-exitW-gap)
  local bw = math.floor((region - gap * 2) / 3)
  for i, s in ipairs(subs) do
    local on = (S.csub == s[1])
    addBtn(2 + (i - 1) * (bw + gap), 5, bw, 2, s[2],
      { bg = on and C.blue or C.panel2, fn = function() nav({ csub = s[1], view = "list", filter = "" }) end })
  end
  local exitArmed = (S.confirm == "exit")
  rb(5, 0, exitW, exitArmed and "Точно?" or "Выход",
    { bg = exitArmed and C.red or C.panel2, fn = function()
      if S.confirm == "exit" then running = false else S.confirm = "exit"; render() end
    end })
end

local function screenKitEdit()
  local kit = findKit(S.kitId)
  if not kit then S.view = "list"; return false end
  local n, gap = 4, 1
  local bw = math.floor(((W - 2) - gap * (n - 1)) / n)
  local function bx(i) return 2 + (i - 1) * (bw + gap) end
  local lastW = (W - 1) - bx(n) + 1
  local armed = (S.confirm == "del" .. kit.id)
  addBtn(bx(1), 5, bw, 2, "Название", { fn = function()
    local nm = prompt("Название комплекта:", kit.name, 40)
    if nm and trim(nm) ~= "" then kit.name = trim(nm); saveDB() end
    render()
  end })
  addBtn(bx(2), 5, bw, 2, "Цена: " .. fmt(kit.price), { fn = function()
    local v = askNumber("Цена комплекта (" .. CONFIG.CURRENCY .. "):", fmt(kit.price), false)
    if v then kit.price = round2(v); saveDB() end
    render()
  end })
  addBtn(bx(3), 5, bw, 2, "+ Ресурс", { bg = C.tabOn, fn = function() openPicker("kit") end })
  addBtn(bx(4), 5, lastW, 2, armed and "Точно удалить?" or "Удалить комплект",
    { bg = armed and C.red or C.panel2, fn = function()
      if S.confirm == "del" .. kit.id then
        local _, idx = findKit(kit.id)
        table.remove(db.kits, idx); saveDB()
        nav({ view = "list" }, "Комплект удалён.", true)
      else S.confirm = "del" .. kit.id; render() end
    end })

  text(2, 7, pad("Комплект: " .. kit.name .. "   Цена: " .. fmt(kit.price) .. " " .. CONFIG.CURRENCY ..
       "   Склад: " .. kitStock(kit, availFn()) .. " шт", W - 2), C.accent, C.bg)
  local y0 = LIST_Y + 1
  local first, last = paged(#kit.items, y0)
  if #kit.items == 0 then text(2, y0, "Пусто. Нажмите «+ Ресурс», чтобы выбрать предмет из ME.", C.dim, C.bg) end
  local reserve = BW2 * 2 + 1 + 2
  for i = first, last do
    local it = kit.items[i]
    local y = y0 + (i - first) * 3
    local c = cache.byKey[itemKey(it.name, it.damage)]
    card(y, it.label .. "   x" .. it.qty, "В ME: " .. (c and c.size or 0) .. "   " .. it.name .. ":" .. it.damage,
         nil, reserve)
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

-- e = { name, damage, label, size, maxSize }
local function pickItem(e)
  local name, dmg, label, size, mx = e[1], e[2], e[3], e[4], e[5]
  local k = itemKey(name, dmg)
  if not cache.byKey[k] then
    cache.byKey[k] = { key = k, name = name, damage = dmg, label = label, size = size, maxSize = mx }
  end
  if S.pickMode == "kit" then
    local kit = findKit(S.kitId)
    if not kit then return nav({ view = "list" }) end
    local q = askNumber("Сколько «" .. label .. "» в комплекте?", "1", true)
    if not q or q < 1 then return render() end
    local found = false
    for _, it in ipairs(kit.items) do
      if it.name == name and it.damage == dmg then it.qty = it.qty + q; found = true end
    end
    if not found then kit.items[#kit.items + 1] = { name = name, damage = dmg, label = label, qty = q } end
    saveDB()
    flash("Добавлено: " .. label .. " x" .. q .. ". Выберите ещё или нажмите «Назад».", true)
  else
    local price = askNumber("Цена за 1 шт «" .. label .. "» (" .. CONFIG.CURRENCY .. "):", "1", false)
    if not price then return render() end
    local found = false
    for _, t in ipairs(db.topup) do
      if t.name == name and t.damage == dmg then t.price = round2(price); found = true end
    end
    if not found then db.topup[#db.topup + 1] = { name = name, damage = dmg, label = label, price = round2(price) } end
    saveDB()
    flash("Ресурс пополнения сохранён: " .. label .. " по " .. fmt(price), true)
  end
end

local function applyPickFilter(f)
  S.filter = f; S.page = 1
  status("Ищу в ME...")
  local ok, err = pickerScan(S.filter)
  if not ok then return flash("Не удалось получить список ME: " .. tostring(err), false) end
  render()
end

local function screenPick()
  local hasFilter = S.filter and S.filter ~= ""
  addBtn(2, 5, 44, 2, "Поиск: " .. (hasFilter and S.filter or "(нажмите)"), { fn = function()
    local f = prompt("Поиск по названию:", S.filter or "", 40)
    if f then applyPickFilter(trim(f)) else render() end
  end })
  addBtn(48, 5, 16, 2, "Сбросить", { disabled = not hasFilter, fn = function() applyPickFilter("") end })
  local info = "Найдено: " .. cache.pickTotal .. (cache.pickMore and ("  (показаны первые " .. #cache.items .. ", уточните поиск)") or "")
  text(66, 5, pad(info, W - 66), C.dim, C.bg)
  text(66, 6, pad("Данные ME: " .. ageText(), W - 66), C.dim, C.bg)

  local list = cache.items
  local first, last = paged(#list, LIST_Y)
  if #list == 0 then
    if hasFilter then text(2, LIST_Y, "Ничего не найдено.", C.dim, C.bg)
    else text(2, LIST_Y, "Список ME пуст или недоступен. Нажмите «Обновить» внизу.", C.red, C.bg) end
  end
  for i = first, last do
    local e = list[i]
    local y = LIST_Y + (i - first) * 3
    card(y, e[3], "В ME: " .. e[4] .. "   " .. e[1] .. ":" .. e[2])
    rb(y, 0, BW, "Выбрать", { bg = C.tabOn, fn = function() pickItem(e) end })
  end
  S.backFn = function()
    cache.items = {}                       -- освобождаем память
    if S.pickMode == "kit" then nav({ view = "edit", filter = "" })
    else nav({ view = "list", csub = "topup", filter = "" }) end
  end
end

local function screenCreate()
  if S.view == "edit" and screenKitEdit() then return end
  if S.view == "pick" then return screenPick() end
  S.view = "list"
  subBar()

  if S.csub == "kits" then
    addBtn(2, 8, 28, 2, "+ Новый комплект", { bg = C.tabOn, fn = function()
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
      local y = SUB_Y + (i - first) * 3
      card(y, k.name, "Цена: " .. fmt(k.price) .. " " .. CONFIG.CURRENCY .. "   Ресурсов: " .. #k.items ..
                      "   Склад: " .. kitStock(k, avail) .. " шт")
      rb(y, 0, BW, "Изменить", { bg = C.tabOn, fn = function() nav({ view = "edit", kitId = k.id }) end })
    end

  elseif S.csub == "topup" then
    addBtn(2, 8, 28, 2, "+ Добавить ресурс", { bg = C.tabOn, fn = function() openPicker("topup") end })
    text(32, 8, "Что игрок может сдать, чтобы пополнить баланс.", C.dim, C.bg)
    local first, last = paged(#db.topup, SUB_Y)
    if #db.topup == 0 then text(2, SUB_Y, "Ресурсов пополнения пока нет.", C.dim, C.bg) end
    local reserve = BW2 * 2 + 1 + 2
    for i = first, last do
      local e = db.topup[i]
      local y = SUB_Y + (i - first) * 3
      card(y, e.label, "Цена за 1 шт: " .. fmt(e.price) .. " " .. CONFIG.CURRENCY, nil, reserve)
      local off = rb(y, 0, BW2, "Убрать", { fn = function() table.remove(db.topup, i); saveDB(); render() end })
      rb(y, off, BW2, "Цена", { fn = function()
        local v = askNumber("Новая цена за 1 шт «" .. e.label .. "»:", fmt(e.price), false)
        if v then e.price = round2(v); saveDB() end
        render()
      end })
    end

  else -- отзывы
    local armed = (S.confirm == "clearfb")
    addBtn(2, 8, 28, 2, armed and "Точно очистить?" or "Очистить все", { disabled = #db.feedback == 0,
      bg = armed and C.red or C.panel2, fn = function()
        if S.confirm == "clearfb" then db.feedback = {}; saveDB(); nav({ csub = "feedback", view = "list" }, "Отзывы очищены.", true)
        else S.confirm = "clearfb"; render() end
      end })
    text(32, 8, "Сообщения игроков и автоматические отчёты об ошибках.", C.dim, C.bg)
    local n = #db.feedback
    local first, last = paged(n, SUB_Y)
    if n == 0 then text(2, SUB_Y, "Отзывов пока нет.", C.dim, C.bg) end
    local changed = false
    local reserve = BW2 * 2 + 1 + 2
    for i = first, last do
      local idx = n - i + 1                 -- новые сверху
      local f = db.feedback[idx]
      local y = SUB_Y + (i - first) * 3
      card(y, (f.read and "" or "* ") .. dateStr(f.time) .. "  " .. f.player, f.text,
           f.read and C.dim or C.text, reserve)
      if not f.read then f.read = true; changed = true end
      local off = rb(y, 0, BW2, "Удалить", { fn = function() table.remove(db.feedback, idx); saveDB(); render() end })
      rb(y, off, BW2, "Читать", { fn = function() modal(f.player .. "  " .. dateStr(f.time), f.text); render() end })
    end
    if changed then saveDB() end
  end
end

----------------------------------------------------------------------
-- ОТРИСОВКА
----------------------------------------------------------------------
render = function()
  UI.btns = {}
  gpu.setBackground(C.bg)
  gpu.fill(1, 1, W, H, " ")
  if not S.player then return drawIdle() end
  S.backFn = nil
  S.pages = 1
  drawHeader()
  drawMessage()
  if S.tab == "kits" then screenKits()
  elseif S.tab == "topup" then screenTopup()
  elseif S.tab == "create" and S.player.owner then screenCreate()
  else S.tab = "kits"; screenKits() end
  drawFooter()
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
  S = { player = { name = name, uid = uid, owner = isOwner(name, uid) },
        tab = "kits", view = "list", csub = "kits", page = 1, pages = 1,
        msg = "", msgOk = true, inv = {}, filter = "" }
  UI.btns = {}
  cache.items = {}
  gpu.setBackground(C.bg); gpu.fill(1, 1, W, H, " ")
  ctext(math.floor(H / 2), "Здравствуйте, " .. S.player.name .. "!", C.accent, C.bg)
  ctext(math.floor(H / 2) + 2, "Загружаю данные...", C.dim, C.bg)

  local p = getPlayer(S.player.name)
  purgePurchases(p)
  local ok, err = scanME()                 -- единственное "тяжёлое" сканирование на входе
  render()
  if not ok then flash("ME недоступна: " .. tostring(err), false)
  elseif pendingCount(p) > 0 then
    flash("У вас есть незабранные ресурсы - кнопка «Незабранное» вверху справа.", true)
  elseif S.player.owner and unreadFeedback() > 0 then
    flash("Новых отзывов: " .. unreadFeedback() .. " (вкладка «Создание» -> «Отзывы»).", true)
  end
end

local function onPlayerOff()
  S = { player = nil }
  cache.items = {}
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
  local f = io.open(CONFIG.LOG_PATH, "a")
  if f then f:write(tostring(os.time()) .. " " .. err .. "\n"); f:close() end
  local now = computer.uptime()
  if db and now - lastAutoReport > 10 then
    lastAutoReport = now
    db.feedback[#db.feedback + 1] = { player = "[авто-ошибка]", text = err:sub(1, 200), time = os.time(), read = false }
    pcall(saveDB)
  end
  if S.player then
    S.msg = "Внутренняя ошибка (записана для владельца)."; S.msgOk = false
    pcall(render)
    if S.player.owner then   -- владельцу показываем настоящий текст
      pcall(modal, "Ошибка (видно только владельцу)", err:sub(1, 600))
      pcall(render)
    end
  end
end

----------------------------------------------------------------------
-- ЗАПУСК
----------------------------------------------------------------------
local function main()
  db = loadDB()
  if #CONFIG.OWNERS == 0 and #db.owners == 0 then
    print("ВНИМАНИЕ: владелец не задан. Остановите программу и выполните:")
    print("  lua kitshop.lua owner add ВашНик")
  end
  pcall(gpu.setResolution, CONFIG.SCREEN_W, CONFIG.SCREEN_H)
  W, H = gpu.getResolution()

  -- защита киоска: Ctrl+Alt+C с клавиатуры игрока не должен останавливать программу
  local origInterrupt = event.shouldInterrupt
  if ARGS[1] ~= "debug" then event.shouldInterrupt = function() return false end end

  S = { player = nil }
  render()

  while running do
    local timeout = nil
    if S.player and refreshRemaining() > 0 then timeout = 1 end   -- только пока идёт кулдаун
    local e = table.pack(event.pull(timeout))
    local ok, err = xpcall(function()
      local name = e[1]
      if name == "player_on" then onPlayerOn(e)
      elseif name == "player_off" then onPlayerOff()
      elseif name == "touch" then onTouch(e)
      elseif name == nil and S.player then redrawFooter() end      -- обновить таймер кнопки
      if pendingOff then pendingOff = false; onPlayerOff() end
    end, debug.traceback)
    if not ok then reportError(err) end
    if pendingOff then pendingOff = false; pcall(onPlayerOff) end
  end

  event.shouldInterrupt = origInterrupt
  gpu.setBackground(0x000000); gpu.setForeground(0xFFFFFF)
  gpu.fill(1, 1, W, H, " ")
  print("KitShop остановлен.")
end

-- команда: lua kitshop.lua owner add|del|list [Ник]
local function ownerCli()
  db = loadDB()
  local cmd, nick = ARGS[2], ARGS[3]
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

-- Надзиратель: при любой неожиданной ошибке магазин перезапускается,
-- а не падает в консоль (к которой мог бы получить доступ игрок).
local function supervised()
  while running do
    local ok, err = xpcall(main, debug.traceback)
    if not ok then
      pcall(reportError, err)
      os.sleep(3)
    end
  end
end

if ARGS[1] == "owner" then ownerCli()
elseif ARGS[1] == "debug" then            -- без автоперезапуска, Ctrl+Alt+C работает
  local ok, err = xpcall(main, debug.traceback)
  if not ok then print(err) end
else supervised() end
