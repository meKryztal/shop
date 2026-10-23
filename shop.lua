-- Использование (в OpenOS):  lua fix.lua /home/shop.lua
-- Делает копию файла (.bak) и исправляет 6 проверок type(...) == "function"
local path = ({...})[1]
if not path then print("Использование: lua fix.lua /путь/к/shop.lua"); return end

local f = assert(io.open(path, "r")); local src = f:read("*a"); f:close()
local bak = assert(io.open(path .. ".bak", "w")); bak:write(src); bak:close()

local rules = {
  { 'if type(me.getAvailableItems) ~= "function" then return base end',
    'if me.getAvailableItems == nil then return base end' },
  { 'if ok3 and type(det) == "table" and type(det.all) == "function" then',
    'if ok3 and type(det) == "table" and det.all ~= nil then' },
  { 'if var == "" or type(me.getAvailableItems) ~= "function" then return fp end',
    'if var == "" or me.getAvailableItems == nil then return fp end' },
  { 'if type(d.all) == "function" then',
    'if d.all ~= nil then' },
  { 'if type(me.getAvailableItems) == "function" then',
    'if me.getAvailableItems ~= nil then' },
  { 'if type(d) == "table" and type(d.all) == "function" then d = d.all() end',
    'if type(d) == "table" and d.all ~= nil then d = d.all() end' },
}

local total = 0
for i, r in ipairs(rules) do
  local from, to, n = 1, nil, 0
  local out = {}
  while true do
    local s, e = src:find(r[1], from, true)
    if not s then break end
    out[#out + 1] = src:sub(from, s - 1); out[#out + 1] = r[2]
    from = e + 1; n = n + 1
  end
  out[#out + 1] = src:sub(from)
  src = table.concat(out)
  print(("Правило %d: заменено %d"):format(i, n))
  total = total + n
end

local w = assert(io.open(path, "w")); w:write(src); w:close()
print("Готово, всего замен: " .. total .. ". Копия: " .. path .. ".bak")
