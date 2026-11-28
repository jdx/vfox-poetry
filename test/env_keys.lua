-- Checks which directory EnvKeys looks for pyproject.toml in, and that Poetry
-- runs in that same directory.

package.preload["file"] = function()
    return {
        join_path = function(...)
            return table.concat({ ... }, "/")
        end,
    }
end

PLUGIN = {}
RUNTIME = { osType = "linux" }
dofile("hooks/env_keys.lua")

local real_getenv = os.getenv

-- Runs EnvKeys with `files` as the only existing files and `env` as the
-- environment. Returns the paths it opened and the commands it ran.
local function run(pyproject, env, files)
    local opened, commands = {}, {}
    io.open = function(path)
        table.insert(opened, path)
        if files[path] then
            return { close = function() end }
        end
        return nil
    end
    io.popen = function(command)
        table.insert(commands, command)
        return {
            read = function()
                if command:find("which python3", 1, true) then
                    return "/mise/python/bin/python3"
                end
                return "/venvs/app"
            end,
            close = function() end,
        }
    end
    os.execute = function(command)
        table.insert(commands, command)
        return 0
    end
    os.getenv = function(name)
        return env[name]
    end
    local keys = PLUGIN:EnvKeys({ path = "/poetry", options = { pyproject = pyproject } })
    os.getenv = real_getenv
    return keys, opened, commands
end

local function has_key(keys, name)
    for _, k in ipairs(keys) do
        if k.key == name then
            return true
        end
    end
    return false
end

local function poetry_commands(commands)
    local out = {}
    for _, c in ipairs(commands) do
        if c:find("/poetry/bin/poetry", 1, true) then
            table.insert(out, c)
        end
    end
    return out
end

-- A relative pyproject with no project root or PWD (mise withholds both from
-- an untrusted directory): nothing to resolve it against, so no file is
-- checked and Poetry never runs. A relative PWD does not count either.
for _, env in ipairs({ {}, { PWD = "src/app" } }) do
    local keys, opened, commands = run("pyproject.toml", env, { ["pyproject.toml"] = true })
    assert(#opened == 0, "a relative pyproject was checked without a project root: " .. tostring(opened[1]))
    assert(#poetry_commands(commands) == 0, "Poetry ran without a project root")
    assert(not has_key(keys, "VIRTUAL_ENV"), "a virtualenv was activated without a project root")
    assert(has_key(keys, "POETRY_HOME"), "the Poetry install itself must still be on the environment")
end

-- With no project root, a relative pyproject is resolved against PWD, the
-- directory mise runs in, and Poetry runs there too.
do
    local keys, opened, commands = run("pyproject.toml", { PWD = "/src/app" }, { ["/src/app/pyproject.toml"] = true })
    assert(opened[1] == "/src/app/pyproject.toml", "pyproject not resolved against PWD: " .. tostring(opened[1]))
    local poetry = poetry_commands(commands)
    assert(#poetry > 0, "Poetry did not run")
    for _, c in ipairs(poetry) do
        assert(c:find("cd '/src/app/' && ", 1, true) == 1, "Poetry ran outside PWD: " .. c)
    end
    assert(has_key(keys, "VIRTUAL_ENV"), "virtualenv not activated")
end

-- The project root wins over PWD.
do
    local _, opened = run("pyproject.toml", { MISE_PROJECT_ROOT = "/src/app", PWD = "/elsewhere" }, {})
    assert(opened[1] == "/src/app/pyproject.toml", "PWD used over the project root: " .. tostring(opened[1]))
end

-- A relative pyproject with a project root: checked and run in that root.
do
    local keys, opened, commands = run(
        "sub/pyproject.toml",
        { MISE_PROJECT_ROOT = "/src/app" },
        { ["/src/app/sub/pyproject.toml"] = true }
    )
    assert(opened[1] == "/src/app/sub/pyproject.toml", "pyproject not resolved against the root: " .. opened[1])
    local poetry = poetry_commands(commands)
    assert(#poetry > 0, "Poetry did not run")
    for _, c in ipairs(poetry) do
        assert(c:find("cd '/src/app/sub/' && ", 1, true) == 1, "Poetry ran outside the project: " .. c)
    end
    assert(has_key(keys, "VIRTUAL_ENV"), "virtualenv not activated")
end

-- A project root with a trailing separator does not get a doubled one.
do
    local _, opened = run("pyproject.toml", { MISE_PROJECT_ROOT = "/src/app/" }, {})
    assert(opened[1] == "/src/app/pyproject.toml", "unexpected path: " .. opened[1])
end

-- Outside Windows a trailing backslash is part of the directory name, so a
-- separator is still added after it.
do
    local _, opened = run("pyproject.toml", { MISE_PROJECT_ROOT = "/src/app\\" }, {})
    assert(opened[1] == "/src/app\\/pyproject.toml", "unexpected path: " .. opened[1])
end

-- On Windows a trailing backslash is a separator.
do
    RUNTIME.osType = "windows"
    local _, opened = run("pyproject.toml", { MISE_PROJECT_ROOT = "C:\\src\\app\\" }, {})
    RUNTIME.osType = "linux"
    assert(opened[1] == "C:\\src\\app\\pyproject.toml", "unexpected path: " .. opened[1])
end

-- Absolute paths are used as written, whatever the project root.
for _, path in ipairs({ "/abs/app/pyproject.toml", "C:\\app\\pyproject.toml", "C:/app/pyproject.toml" }) do
    local keys, opened, commands = run(path, { MISE_PROJECT_ROOT = "/src/app" }, { [path] = true })
    assert(opened[1] == path, "absolute pyproject was rewritten: " .. opened[1])
    local dir = path:match("^(.*[/\\])")
    local poetry = poetry_commands(commands)
    assert(#poetry > 0, "Poetry did not run for " .. path)
    for _, c in ipairs(poetry) do
        assert(c:find("cd '" .. dir .. "' && ", 1, true) == 1, "Poetry ran outside " .. dir .. ": " .. c)
    end
    assert(has_key(keys, "VIRTUAL_ENV"), "virtualenv not activated for " .. path)
end

print("env_keys: ok")
