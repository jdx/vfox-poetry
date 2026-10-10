local function shell_quote(value)
    return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

PLUGIN = {}
RUNTIME = { osType = "linux" }
dofile("hooks/post_install.lua")

local function assert_safe_path(root_path)
    local commands = {}
    local removed_path

    io.open = function()
        return { write = function() end, close = function() end }
    end
    os.execute = function(command)
        table.insert(commands, command)
        return 0
    end
    os.remove = function(path)
        removed_path = path
    end

    PLUGIN:PostInstall({
        rootPath = root_path,
        sdkInfo = { poetry = { version = "2.0.0" } },
    })

    local script_path = root_path .. "/install_poetry.sh"
    assert(
        commands[1] == "chmod +x " .. shell_quote(script_path) .. " && " .. shell_quote(script_path),
        "installer script path was not safely quoted"
    )
    assert(removed_path == script_path, "installer script was not removed with os.remove")
end

assert_safe_path("/tmp/poetry install")
assert_safe_path("/tmp/poetry; harmless-marker")
assert_safe_path("/tmp/poetry O'Brien")
