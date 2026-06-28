-- examples/example.lua
-- Sample Lua script to test the obfuscator

local VERSION = "1.0.0"
local MAX_RETRIES = 3

local function greet(name, times)
  times = times or 1
  for i = 1, times do
    print("Hello, " .. name .. "! (iteration " .. i .. ")")
  end
end

local function factorial(n)
  if n <= 1 then return 1 end
  return n * factorial(n - 1)
end

local function isPrime(n)
  if n < 2 then return false end
  for i = 2, math.floor(math.sqrt(n)) do
    if n % i == 0 then return false end
  end
  return true
end

local function findPrimes(limit)
  local result = {}
  for i = 2, limit do
    if isPrime(i) then
      result[#result + 1] = i
    end
  end
  return result
end

local config = {
  debug = false,
  maxItems = 100,
  prefix = "obf_",
  nested = {
    value = 42,
    name = "nested config",
  }
}

local function processItems(items, callback)
  local processed = 0
  for _, item in ipairs(items) do
    if type(callback) == "function" then
      callback(item)
      processed = processed + 1
    end
  end
  return processed
end

-- Main execution
greet("World", 2)

local primes = findPrimes(50)
print("Primes up to 50: " .. table.concat(primes, ", "))

print("10! = " .. tostring(factorial(10)))

local items = {"apple", "banana", "cherry", "date"}
local count = processItems(items, function(item)
  print("Processing: " .. item)
end)
print("Processed " .. count .. " items")

print("Version: " .. VERSION)
