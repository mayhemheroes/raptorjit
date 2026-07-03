local function fact(n) if n <= 1 then return 1 end return n * fact(n - 1) end
print(fact(10))
local t = { 1, 2, 3 }
for _, v in ipairs(t) do print(v) end
