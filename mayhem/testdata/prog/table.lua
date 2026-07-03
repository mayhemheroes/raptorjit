-- table construction, indexing, length, sum (exercises hot array path -> JIT)
local t = {}
for i = 1, 1000 do t[i] = i * i end
local x = 0
for i = 1, #t do x = x + t[i] end
print(#t, x)
local m = { a = 1, b = 2, c = 3 }
print(m.a + m.b + m.c)
