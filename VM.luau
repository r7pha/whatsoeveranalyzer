local luau = require("@lune/luau")
local fs = require("@lune/fs")

assert(fs.isFile("Input.luau"), "Input.luau expected")

local comp = luau.compile(fs.readFile("Input.luau"))

local env = table.clone(getfenv())

local charset = {}
do
	for c = 48, 57 do
		table.insert(charset, string.char(c))
	end
	for c = 65, 90 do
		table.insert(charset, string.char(c))
	end
	for c = 97, 122 do
		table.insert(charset, string.char(c))
	end
end

local function randomString(length)
	if not length or length <= 0 then
		return ""
	end

	return randomString(length - 1) .. charset[math.random(1, #charset)]
end

local ProxyID = randomString(32)
local penv

local out = "local fenv = getfenv()\n"
local varcount = 0

local registry = {}

local makevar = function(isparam)
	if isparam and isparam[1] then
		return `param_{isparam[2] or varcount}`
	end
	varcount += 1
	return `v{varcount}`
end

local checkreg = function(a)
	for _, v in pairs(registry) do
		if v.callback and v.callback == a and (v.var or v.expr) then
			return v
		end
	end
end

local function parsearg(arg)
	local t = type(arg)
	local reg = checkreg(arg)

	if reg and (reg.var or reg.expr) then
		return (reg.var or reg.expr)
	end

	for i, v in pairs(env) do
		if v == arg then
			return i
		end
	end

	if t == "string" then
		return `"{arg}"`
	elseif t == "number" then
		return `{tostring(arg)}`
	elseif t == "boolean" then
		return `{tostring(arg)}`
	elseif t == "table" then
		local a = ""

		for i, v in pairs(arg) do
			a ..= `[{parsearg(i)}] = {parsearg(v)}, `
		end

		return [[ {]] .. a .. [[} ]]
	elseif t == "function" then
		local a = debug.info(arg, "a")
		local params = ""
		for i = 1, a do
			if i == a then
				params ..= makevar({ true, i })
				continue
			end
			params ..= `{makevar({ true, i })}, `
		end
		local fstr = `function({params})end`
		return fstr
	end

	return `"unknown-type@{t}"`
end

local parseargs = function(args, nigga)
	local f = {}
	for _, v in pairs(args) do
		table.insert(f, parsearg(v))
	end
	local str = ""
	for i, v in pairs(f) do
		if i == #f then
			str ..= v
		else
			str ..= `{v}, `
		end
	end

	return str
end

local makecall = function(name, callback, args, add)
	local hascallback = callback ~= nil
	local astargs = parseargs(args)
	local v = makevar()
	local expr = `{name}({astargs})`
	if add == nil or add == true then
		out ..= `local {hascallback and v or "_"} = {expr}\n`
	end
	table.insert(registry, {
		callback = callback,
		var = v,
		expr = expr,
	})
	return expr, v
end

local function makeobj(pdata, ctype, exporvar)
	local p = newproxy(true)
	local mt = getmetatable(p)

	mt.__index = function(_, k)
		local index = mt.idx[k] or (pdata and pdata[k])
		local expr
		if exporvar then
			expr = `{exporvar}[{parsearg(k)}]`
		end
		if index == nil then
			index = makeobj(nil, nil, exporvar)
		end
		local callback = makeobj(index, ctype, expr or exporvar)
		table.insert(registry, {
			callback = callback,
			expr = expr,
		})
		return callback
	end

	mt.__newindex = function(_, k, v)
		if exporvar then
			out ..= `{exporvar}[{parsearg(k)}] = {parsearg(v)}\n`
		end
		mt.idx[k] = v
	end

	mt.__call = function(_, ...)
		local callback = makeobj(nil, ctype)
		if exporvar then
			makecall(exporvar, callback, { ... })
		end
		return callback
	end

	mt.__len = function(_)
		local callback = math.random(1, 20)
		if exporvar then
			local v = makevar()
			out ..= `local {v} = #{exporvar}\n`
			table.insert(registry, {
				callback = callback,
				var = v,
			})
		end
		return callback
	end

	mt.idx = {}
	mt.__internal = ProxyID
	mt.__type = ctype

	return p
end

env.print = function(...)
	local callback = makeobj()
	makecall("print", callback, { ... })
	return callback
end

env.warn = function(...)
	local callback = makeobj()
	makecall("warn", callback, { ... })
	return callback
end

env.require = function(...)
	local callback = makeobj()
	makecall("require", callback, { ... })
	return callback
end

env.getmetatable = function(t)
	local g = getmetatable(t)

	if g and type(g.__internal) == "string" and g.__internal == ProxyID then
		local callback = makeobj()
		makecall("getmetatable", callback, { t })
		return callback
	end

	makecall("getmetatable", g, { t })
	return g
end

env.getfenv = function(l)
	local callback = penv
	--	makecall("getfenv", callback, {l})
	return callback
end

env.typeof = function(obj)
	local g = getmetatable(obj)

	if g and type(g.__internal) == "string" and g.__internal == ProxyID and type(g.__type) == "string" then
		makecall("typeof", g.__type, { obj })
		return g.__type
	end
	local asd = type(obj)
	makecall("typeof", asd, { obj })
	return asd
end

--[[env.writefile = function(f, c)
    return fs.writeFile(f,c)
end]]

local workspace = makeobj(nil, "Instance", "workspace")

env.game = makeobj(nil, "Instance", "game")
env.workspace = workspace

penv = setmetatable({}, {
	__index = function(_, k)
		local callback = env[k]
		local expr, var
		if callback == nil then
			var = makevar()
			expr = `fenv[{parsearg(k)}]`
			--out ..= `local {var} = {expr}\n`
			callback = makeobj(nil, nil, expr)
		end
		table.insert(registry, {
			callback = callback,
			expr = expr,
			var = var,
		})
		return callback
	end,
	__newindex = function(_, k, v)
		out ..= `fenv[{parsearg(k)}] = {parsearg(v)}\n`
	end,
})

xpcall(function()
	local l = luau.load(comp, {
		environment = env,
	})

	l()
end, function(err)
	print(err)
	out ..= `-- [[ script errored: {tostring(err)} ]]`
end)

fs.writeFile("out.luau", out)

print("execution ended")
