local MAP_BLOCKSIZE = core.MAP_BLOCKSIZE or 16
local city_jobs = {}

local function city_cube_has_nodes(minp, maxp)
    local vm = core.get_voxel_manip(minp, maxp)
    local data = vm:get_data()
    local air = core.CONTENT_AIR or core.get_content_id("air")
    local ignore = core.CONTENT_IGNORE or core.get_content_id("ignore")
    local has_nodes = false

    for i = 1, #data do
        if data[i] ~= air and data[i] ~= ignore then
            has_nodes = true
            break
        end
    end

    vm:close()
    return has_nodes
end

-- Mapgen chunks have an offset of -floor(chunksize / 2) mapblocks.
-- Keep this equivalent to EmergeManager::getContainingChunk().
local function city_chunk_min(node, chunksize)
    local block = math.floor(node / MAP_BLOCKSIZE)
    local offset = -math.floor(chunksize / 2)
    local chunk = math.floor((block - offset) / chunksize) * chunksize + offset
    return chunk * MAP_BLOCKSIZE
end

local function city_base_height(min_x, max_x, min_z, max_z)
    local center_x = math.floor((min_x + max_x) / 2)
    local center_z = math.floor((min_z + max_z) / 2)
    local get_height = core.get_ground_level or core.get_spawn_level
    local height

    -- Use the lowest of a 3x3 sample so a mountain slope does not make us
    -- start above lower terrain (and any buildings) in the same mapgen chunk.
    for _, x in ipairs({min_x, center_x, max_x}) do
        for _, z in ipairs({min_z, center_z, max_z}) do
            local sample = get_height(x, z)
            if sample and (not height or sample < height) then
                height = sample
            end
        end
    end

    return height
end

local function city_onion_position(shell, index)
    if shell == 0 then
        return 0, 0
    end

    local side = shell * 2
    if index < side then
        return -shell + index, -shell
    end
    index = index - side
    if index < side then
        return shell, -shell + index
    end
    index = index - side
    if index < side then
        return shell - index, shell
    end
    index = index - side
    return -shell, shell - index
end

local function city_finish(state)
    city_jobs[state.name] = nil
    local dt = math.floor((core.get_us_time() - state.start_time) / 1000)
    local message = "City generation done: " .. state.completed .. " chunks in " .. dt .. "ms"
    if state.failed > 0 then
        message = message .. " (" .. state.failed .. " failed)"
    end
    core.chat_send_player(state.name, message .. ".")
end

local city_emerge_next

local function city_chunk_done(state, failed)
    state.completed = state.completed + 1
    if failed then
        state.failed = state.failed + 1
    end

    if state.completed >= state.next_progress and state.completed < state.total then
        local percent = math.floor(state.completed * 100 / state.total)
        core.chat_send_player(state.name,
            "City generation: " .. percent .. "% (" .. state.completed .. "/" .. state.total .. " chunks, ring " ..
                state.shell .. "/" .. state.max_shell .. ").")
        state.next_progress = state.next_progress + state.progress_step
    end

    if state.shell == 0 then
        state.shell = 1
        state.index = 0
    else
        state.index = state.index + 1
        if state.index >= state.shell * 8 then
            state.shell = state.shell + 1
            state.index = 0
        end
    end

    if state.shell > state.max_shell then
        city_finish(state)
    else
        core.after(0, city_emerge_next, state)
    end
end

local function city_emerge_cube(state, horizontal_min, min_y, inspect, retry)
    local minp = {
        x = horizontal_min.x,
        y = min_y,
        z = horizontal_min.z,
    }
    local maxp = {
        x = minp.x + state.chunk_nodes.x - 1,
        y = minp.y + state.chunk_nodes.y - 1,
        z = minp.z + state.chunk_nodes.z - 1,
    }
    local failed = false

    core.emerge_area(minp, maxp, function(blockpos, action, remaining)
        if action == core.EMERGE_CANCELLED or action == core.EMERGE_ERRORED then
            failed = true
        end
        if remaining > 0 then
            return
        end

        if failed then
            if retry < 2 then
                core.after(0, city_emerge_cube, state, horizontal_min, min_y, inspect, retry + 1)
            else
                city_chunk_done(state, true)
            end
            return
        end

        if inspect and not city_cube_has_nodes(minp, maxp) then
            city_chunk_done(state, false)
            return
        end

        core.after(0, city_emerge_cube, state, horizontal_min, min_y + state.chunk_nodes.y, true, 0)
    end)
end

city_emerge_next = function(state)
    local dx, dz = city_onion_position(state.shell, state.index)
    local horizontal_min = {
        x = state.center_min.x + dx * state.chunk_nodes.x,
        z = state.center_min.z + dz * state.chunk_nodes.z,
    }
    local max_x = horizontal_min.x + state.chunk_nodes.x - 1
    local max_z = horizontal_min.z + state.chunk_nodes.z - 1
    local base_height = city_base_height(horizontal_min.x, max_x, horizontal_min.z, max_z)

    if not base_height then
        city_chunk_done(state, true)
        return
    end

    local min_y = city_chunk_min(base_height, state.chunksize.y)
    city_emerge_cube(state, horizontal_min, min_y, false, 0)
end

core.register_chatcommand("emerge_radius_city", {
    params = "radius",
    description = "Generate mapgen chunks outwards in 2D rings and upwards through city structures.",
    privs = {
        server = true,
    },
    func = function(name, params)
        local s_radius = params:match("^%s*(%d+)%s*$")
        if not s_radius then
            return false, "Usage: /emerge_radius_city radius"
        end

        local player = core.get_player_by_name(name)
        if not player then
            return false, "Player not found."
        end

        if city_jobs[name] then
            return false, "A city generation job is already running for you."
        end

        local pos = player:get_pos()
        local center_x = math.floor(pos.x)
        local center_z = math.floor(pos.z)
        local radius = tonumber(s_radius)
        local chunksize = core.get_mapgen_chunksize()
        local chunk_nodes = {
            x = chunksize.x * MAP_BLOCKSIZE,
            y = chunksize.y * MAP_BLOCKSIZE,
            z = chunksize.z * MAP_BLOCKSIZE,
        }
        local center_min = {
            x = city_chunk_min(center_x, chunksize.x),
            z = city_chunk_min(center_z, chunksize.z),
        }
        local min_x = city_chunk_min(center_x - radius, chunksize.x)
        local max_x = city_chunk_min(center_x + radius, chunksize.x)
        local min_z = city_chunk_min(center_z - radius, chunksize.z)
        local max_z = city_chunk_min(center_z + radius, chunksize.z)
        local max_shell = math.max(math.abs((min_x - center_min.x) / chunk_nodes.x),
            math.abs((max_x - center_min.x) / chunk_nodes.x), math.abs((min_z - center_min.z) / chunk_nodes.z),
            math.abs((max_z - center_min.z) / chunk_nodes.z))
        local total = (max_shell * 2 + 1) ^ 2
        local progress_step = math.max(1, math.floor(total / 100))
        local state = {
            name = name,
            chunksize = chunksize,
            chunk_nodes = chunk_nodes,
            center_min = center_min,
            max_shell = max_shell,
            shell = 0,
            index = 0,
            total = total,
            completed = 0,
            failed = 0,
            progress_step = progress_step,
            next_progress = progress_step,
            start_time = core.get_us_time(),
        }

        city_jobs[name] = state
        city_emerge_next(state)
        return true,
            "Started city generation of " .. total .. " mapgen chunks (" .. chunk_nodes.x .. "x" .. chunk_nodes.y .. "x" ..
                chunk_nodes.z .. " nodes each), center first."
    end,
})
