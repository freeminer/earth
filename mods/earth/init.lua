local MAP_BLOCKSIZE = core.MAP_BLOCKSIZE or 16
local CITY_HEARTBEAT_INTERVAL = 60
local CITY_SLOW_CUBE_SECONDS = 10
local CITY_DEFAULT_WORKERS = 4
local CITY_MAX_WORKERS = 8
local city_jobs = {}

local function city_job_active(state)
    return city_jobs[state.name] == state
end

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
    return get_height(center_x, center_z)
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

local function city_take_next_task(state)
    if state.shell > state.max_shell then
        return nil
    end

    local shell = state.shell
    local ring_size = shell == 0 and 1 or shell * 8
    if state.index >= ring_size then
        return nil
    end

    local dx, dz = city_onion_position(shell, state.index)
    state.index = state.index + 1

    return {
        shell = shell,
        dx = dx,
        dz = dz,
        operation = 0,
        done = false,
    }
end

local function city_finish(state)
    if not city_job_active(state) then
        return
    end
    city_jobs[state.name] = nil
    local dt = math.floor((core.get_us_time() - state.start_time) / 1000)
    local message = "City generation done: " .. state.completed .. " chunks in " .. dt .. "ms"
    if state.failed > 0 then
        message = message .. " (" .. state.failed .. " failed)"
    end
    core.log("action", "[earth] " .. message .. " for " .. state.name)
    core.chat_send_player(state.name, message .. ".")
end

local city_fill_workers

local function city_chunk_done(state, task, failed)
    if not city_job_active(state) or task.done then
        return
    end

    task.done = true
    state.in_flight = state.in_flight - 1
    state.completed = state.completed + 1
    if failed then
        state.failed = state.failed + 1
    end

    if state.completed >= state.next_progress and state.completed < state.total then
        local percent = math.floor(state.completed * 100 / state.total)
        local message = "City generation: " .. percent .. "% (" .. state.completed .. "/" .. state.total ..
                            " chunks, ring " .. task.shell .. "/" .. state.max_shell .. ", " .. state.in_flight ..
                            " in flight, " .. state.failed .. " failed)."
        local elapsed = math.floor((core.get_us_time() - state.start_time) / 1000000)
        core.log("action", "[earth] " .. message .. " Elapsed: " .. elapsed .. "s")
        core.chat_send_player(state.name, message)
        state.next_progress_percent = percent + 1
        state.next_progress = math.ceil(state.total * state.next_progress_percent / 100)
    end

    if state.completed >= state.total and state.in_flight == 0 then
        city_finish(state)
    else
        core.after(0, city_fill_workers, state)
    end
end

local function city_emerge_cube(state, task, min_y, inspect, retry)
    if not city_job_active(state) then
        return
    end

    local minp = {
        x = task.horizontal_min.x,
        y = min_y,
        z = task.horizontal_min.z,
    }
    local maxp = {
        x = minp.x + state.chunk_nodes.x - 1,
        y = minp.y + state.chunk_nodes.y - 1,
        z = minp.z + state.chunk_nodes.z - 1,
    }
    local failed = false
    local settled = false
    local started = core.get_us_time()
    local callbacks = 0
    local last_remaining = "none"
    local actions = {
        generated = 0,
        memory = 0,
        disk = 0,
        cancelled = 0,
        errored = 0,
        other = 0,
    }
    task.operation = task.operation + 1
    local operation = task.operation

    -- Report a slow emerge without starting another request for this worker's
    -- vertical column. Other workers may process separate chunks in the ring.
    local function heartbeat()
        core.after(CITY_HEARTBEAT_INTERVAL, function()
            if settled or not city_job_active(state) or task.operation ~= operation then
                return
            end
            local elapsed = math.floor((core.get_us_time() - started) / 1000000)
            core.log("warning",
                "[earth] City cube still emerging after " .. elapsed .. "s: " .. core.pos_to_string(minp) .. " to " ..
                    core.pos_to_string(maxp) .. ", callbacks=" .. callbacks .. ", remaining=" ..
                    tostring(last_remaining) .. ", actions generated/memory/disk/cancelled/errored/other=" ..
                    actions.generated .. "/" .. actions.memory .. "/" .. actions.disk .. "/" .. actions.cancelled .. "/" ..
                    actions.errored .. "/" .. actions.other)
            heartbeat()
        end)
    end
    heartbeat()

    local function count_action(action)
        if action == core.EMERGE_GENERATED then
            actions.generated = actions.generated + 1
        elseif action == core.EMERGE_FROM_MEMORY then
            actions.memory = actions.memory + 1
        elseif action == core.EMERGE_FROM_DISK then
            actions.disk = actions.disk + 1
        elseif action == core.EMERGE_CANCELLED then
            actions.cancelled = actions.cancelled + 1
        elseif action == core.EMERGE_ERRORED then
            actions.errored = actions.errored + 1
        else
            actions.other = actions.other + 1
        end
    end

    local function emerge_callback(blockpos, action, remaining)
        if settled or not city_job_active(state) or task.operation ~= operation then
            return
        end
        callbacks = callbacks + 1
        last_remaining = remaining
        count_action(action)
        if action == core.EMERGE_CANCELLED or action == core.EMERGE_ERRORED then
            failed = true
        end
        if remaining > 0 then
            return
        end
        settled = true
        local elapsed = (core.get_us_time() - started) / 1000000

        if failed or elapsed >= CITY_SLOW_CUBE_SECONDS then
            local level = failed and "warning" or "action"
            core.log(level,
                "[earth] City cube emerge completed in " .. string.format("%.1f", elapsed) .. "s: " ..
                    core.pos_to_string(minp) .. " to " .. core.pos_to_string(maxp) .. ", callbacks=" .. callbacks ..
                    ", actions generated/memory/disk/cancelled/errored/other=" .. actions.generated .. "/" ..
                    actions.memory .. "/" .. actions.disk .. "/" .. actions.cancelled .. "/" .. actions.errored .. "/" ..
                    actions.other)
        end

        if failed then
            if retry < 2 then
                core.after(0, city_emerge_cube, state, task, min_y, inspect, retry + 1)
            else
                city_chunk_done(state, task, true)
            end
            return
        end

        if inspect then
            local ok, has_nodes = pcall(city_cube_has_nodes, minp, maxp)
            if not ok then
                core.log("error", "[earth] Could not inspect city cube: " .. tostring(has_nodes))
                city_chunk_done(state, task, true)
                return
            end
            if not has_nodes then
                city_chunk_done(state, task, false)
                return
            end
        end

        core.after(0, city_emerge_cube, state, task, min_y + state.chunk_nodes.y, true, 0)
    end

    local queued, error_message = pcall(core.emerge_area, minp, maxp, emerge_callback)
    if not queued and city_job_active(state) and task.operation == operation then
        settled = true
        core.log("error", "[earth] Could not queue city cube: " .. tostring(error_message))
        city_chunk_done(state, task, true)
    end
end

local function city_start_task(state, task)
    if not city_job_active(state) then
        return
    end

    task.horizontal_min = {
        x = state.center_min.x + task.dx * state.chunk_nodes.x,
        z = state.center_min.z + task.dz * state.chunk_nodes.z,
    }
    local max_x = task.horizontal_min.x + state.chunk_nodes.x - 1
    local max_z = task.horizontal_min.z + state.chunk_nodes.z - 1
    local ok, base_height = pcall(city_base_height, task.horizontal_min.x, max_x, task.horizontal_min.z, max_z)

    if not ok then
        core.log("error", "[earth] Could not determine city chunk height: " .. tostring(base_height))
        city_chunk_done(state, task, true)
        return
    elseif not base_height then
        city_chunk_done(state, task, true)
        return
    end

    local min_y = city_chunk_min(base_height, state.chunksize.y)
    city_emerge_cube(state, task, min_y, false, 0)
end

city_fill_workers = function(state)
    if not city_job_active(state) then
        return
    end

    local ring_size = state.shell == 0 and 1 or state.shell * 8
    if state.in_flight == 0 and state.index >= ring_size then
        state.shell = state.shell + 1
        state.index = 0
    end

    while city_job_active(state) and state.in_flight < state.workers do
        local task = city_take_next_task(state)
        if not task then
            break
        end
        state.in_flight = state.in_flight + 1
        city_start_task(state, task)
    end

    if state.completed >= state.total and state.in_flight == 0 then
        city_finish(state)
    end
end

core.register_chatcommand("emerge_city", {
    params = "radius [workers]",
    description = "Generate mapgen chunks outwards in 2D rings and upwards through city structures.",
    privs = {
        -- server = true,
    },
    func = function(name, params)
        local s_radius, s_workers = params:match("^%s*(%d+)%s*(%d*)%s*$")
        if not s_radius then
            return false, "Usage: /emerge_radius_city radius [workers]"
        end

        local player = core.get_player_by_name(name)
        if not player then
            return false, "Player not found."
        end

        local replaced = city_jobs[name] ~= nil

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
        local requested_workers = tonumber(s_workers)
        if not requested_workers then
            requested_workers = tonumber(core.settings:get("emerge_radius_city_workers")) or CITY_DEFAULT_WORKERS
        end
        requested_workers = math.max(1, math.min(CITY_MAX_WORKERS, math.floor(requested_workers)))
        local queue_limit = tonumber(core.settings:get("emergequeue_limit_total")) or 1024
        local blocks_per_cube = chunksize.x * chunksize.y * chunksize.z
        local queue_workers = math.max(1, math.floor(queue_limit / blocks_per_cube))
        local workers = math.min(requested_workers, queue_workers)
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
        local state = {
            name = name,
            chunksize = chunksize,
            chunk_nodes = chunk_nodes,
            center_min = center_min,
            max_shell = max_shell,
            shell = 0,
            index = 0,
            workers = workers,
            in_flight = 0,
            total = total,
            completed = 0,
            failed = 0,
            next_progress_percent = 1,
            next_progress = math.ceil(total / 100),
            start_time = core.get_us_time(),
        }

        city_jobs[name] = state
        city_fill_workers(state)
        local message = "Started city generation of " .. total .. " mapgen chunks (" .. chunk_nodes.x .. "x" ..
                            chunk_nodes.y .. "x" .. chunk_nodes.z .. " nodes each), center first, " .. workers ..
                            " workers."
        if replaced then
            message = "Replaced the previous city generation job. " .. message
        end
        core.log("action", "[earth] " .. message .. " Player=" .. name .. ", center=" .. core.pos_to_string({
            x = center_x,
            y = pos.y,
            z = center_z,
        }) .. ", radius=" .. radius .. ", workers requested/active=" .. requested_workers .. "/" .. workers ..
            ", blocks_per_cube=" .. blocks_per_cube .. ", emergequeue_limit_total=" .. queue_limit ..
            ", num_emerge_threads=" .. tostring(core.settings:get("num_emerge_threads") or "auto"))
        return true, message
    end,
})
