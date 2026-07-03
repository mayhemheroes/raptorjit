-- recursive function calls (exercises the call path + frame handling)
local function fib(n)
  if n < 2 then return n end
  return fib(n - 1) + fib(n - 2)
end
for i = 1, 15 do io.write(fib(i), " ") end
print()
