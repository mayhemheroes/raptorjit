-- numeric for loop large enough to trigger JIT trace compilation
local s = 0
for i = 1, 200000 do s = s + i end
print(s)
local p = 1
for i = 1, 10 do p = p * 2 end
print(p)
