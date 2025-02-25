local errors = require('errors')

local stash = require('crud.common.stash')
local utils = require('crud.common.utils')
local sharding = require('crud.common.sharding')
local select_executor = require('crud.select.executor')
local select_filters = require('crud.compare.filters')
local dev_checks = require('crud.common.dev_checks')
local schema = require('crud.common.schema')

local SelectError = errors.new_class('SelectError')

local select_module

local select_module_compat_info = stash.get(stash.name.select_module_compat_info)
local has_merger = (utils.tarantool_supports_external_merger() and
    package.search('tuple.merger')) or utils.tarantool_has_builtin_merger()
if has_merger then
    select_module = require('crud.select.compat.select')
    select_module_compat_info.has_merger = true
else
    select_module = require('crud.select.compat.select_old')
    select_module_compat_info.has_merger = false
end

function checkers.vshard_call_mode(p)
    return p == 'write' or p == 'read'
end

local function select_on_storage(space_name, index_id, conditions, opts)
    dev_checks('string', 'number', '?table', {
        scan_value = 'table',
        after_tuple = '?table',
        tarantool_iter = 'number',
        limit = 'number',
        scan_condition_num = '?number',
        field_names = '?table',
        sharding_key_hash = '?number',
        sharding_func_hash = '?number',
        skip_sharding_hash_check = '?boolean',
        yield_every = '?number',
        fetch_latest_metadata = '?boolean',
    })

    local cursor = {}
    if opts.fetch_latest_metadata then
        local replica_schema_version
        if box.info.schema_version ~= nil then
            replica_schema_version = box.info.schema_version
        else
            replica_schema_version = box.internal.schema_version()
        end
        cursor.storage_info = {
            replica_uuid = box.info().uuid,
            replica_schema_version = replica_schema_version,
        }
    end

    local space = box.space[space_name]
    if space == nil then
        return cursor, SelectError:new("Space %q doesn't exist", space_name)
    end

    local index = space.index[index_id]
    if index == nil then
        return cursor, SelectError:new("Index with ID %s doesn't exist", index_id)
    end

    local _, err = sharding.check_sharding_hash(space_name,
                                                opts.sharding_func_hash,
                                                opts.sharding_key_hash,
                                                opts.skip_sharding_hash_check)

    if err ~= nil then
        return nil, err
    end

    local filter_func, err = select_filters.gen_func(space, conditions, {
        tarantool_iter = opts.tarantool_iter,
        scan_condition_num = opts.scan_condition_num,
    })
    if err ~= nil then
        return cursor, SelectError:new("Failed to generate tuples filter: %s", err)
    end

    -- execute select
    local resp, err = select_executor.execute(space, index, filter_func, {
        scan_value = opts.scan_value,
        after_tuple = opts.after_tuple,
        tarantool_iter = opts.tarantool_iter,
        limit = opts.limit,
        yield_every = opts.yield_every,
    })
    if err ~= nil then
        return cursor, SelectError:new("Failed to execute select: %s", err)
    end

    if resp.tuples_fetched < opts.limit or opts.limit == 0 then
        cursor.is_end = true
    else
        local last_tuple = resp.tuples[#resp.tuples]
        cursor.after_tuple = last_tuple
    end

    cursor.stats = {
        tuples_lookup = resp.tuples_lookup,
        tuples_fetched = resp.tuples_fetched,
    }

    -- getting tuples with user defined fields (if `fields` option is specified)
    -- and fields that are needed for comparison on router (primary key + scan key)
    local filtered_tuples = schema.filter_tuples_fields(resp.tuples, opts.field_names)

    local result = {cursor, filtered_tuples}

    local select_module_compat_info = stash.get(stash.name.select_module_compat_info)
    if not select_module_compat_info.has_merger then
        if opts.fetch_latest_metadata then
            result[3] = cursor.storage_info.replica_schema_version
        end
    end

    return unpack(result)
end

function select_module.init()
   _G._crud.select_on_storage = select_on_storage
end

return select_module
