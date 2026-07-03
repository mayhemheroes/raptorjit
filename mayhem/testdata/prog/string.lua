-- string library: methods, format, rep, sub, length, gsub
print(("hello world"):upper())
print(string.rep("ab", 5))
print(string.format("%d-%x-%.2f", 255, 255, 3.14159))
print(#"test", ("abcdef"):sub(2, 4))
print(("a,b,c,d"):gsub(",", "/"))
