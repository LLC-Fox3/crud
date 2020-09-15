local errors = require('errors')
local json = require('json')

local select_plan = {}

local SelectPlanError = errors.new_class('SelectPlan', {capture_stack = false})

local function get_index_name_for_condition(space_indexes, space_format, condition)
    for i= 0, #space_indexes do
        local index = space_indexes[i]
        if index.name == condition.operand then
            return index.name
        end
    end

    for i = 0, #space_indexes do
        local index = space_indexes[i]
        local first_part_fieldno = index.parts[1].fieldno
        local first_part_name = space_format[first_part_fieldno].name
        if first_part_name == condition.operand then
            return index.name
        end
    end
end

local function only_one_value_is_needed(scanner, primary_index)
    if scanner.value == nil then
        return false
    end
    if scanner.index_name == primary_index.name then
        if scanner.iter == box.index.EQ or scanner.iter == box.index.REQ then
            if #primary_index.parts == #scanner.value then
                return true -- fully specified primary key
            end
        end
    end
    return false
end

--[[
    Function returns true if main query iteration can be stopped by fired opposite condition.

    For e.g.
    - iteration goes using `'id' > 10`
    - opposite condition `'id' < 100` becomes false
    - in such case we can exit from iteration
]]
local function is_early_exit_possible(scanner, condition)
    if scanner.index_name ~= condition.operand then
        return false
    end

    local condition_iter = condition:get_tarantool_iter()
    if scanner.iter == box.index.REQ or scanner.iter == box.index.LT or scanner.iter == box.index.LE then
        if condition_iter == box.index.GT or condition_iter == box.index.GE then
            return true
        end
    elseif scanner.iter == box.index.EQ or scanner.iter == box.index.GT or scanner.iter == box.index.GE then
        if condition_iter == box.index.LT or condition_iter == box.index.LE then
            return true
        end
    end

    return false
end

local function get_select_scanner(space_indexes, space_format, conditions)
    if conditions == nil then -- also cdata<NULL>
        conditions = {}
    end

    local scan_index_name = nil
    local scan_iter = nil
    local scan_value = nil
    local scan_condition_num = nil

    -- search index to iterate over
    for i, condition in ipairs(conditions) do
        scan_index_name = get_index_name_for_condition(space_indexes, space_format, condition)

        if scan_index_name ~= nil then
            scan_iter = condition:get_tarantool_iter()
            scan_value = condition.values
            scan_condition_num = i
            break
        end
    end

    local primary_index = space_indexes[0]

    -- default iteration index is primary index
    if scan_index_name == nil then
        scan_index_name = primary_index.name
        scan_iter = box.index.GE -- default iteration is `next greater than previous`
        scan_value = {}
    end

    local scanner = {
        index_name = scan_index_name,
        iter = scan_iter,
        value = scan_value,
        condition_num = scan_condition_num,
    }

    if only_one_value_is_needed(scanner, primary_index) then
        scanner.iter = box.index.REQ
    end

    return scanner
end

local function get_index_fieldnos(index)
    local index_fieldnos = {}

    for _, part in ipairs(index.parts) do
        table.insert(index_fieldnos, part.fieldno)
    end

    return index_fieldnos
end

local function get_values_types(space_format, fieldnos)
    local values_types = {}

    for _, fieldno in ipairs(fieldnos) do
        local field_format = space_format[fieldno]
        assert(field_format ~= nil)

        table.insert(values_types, field_format.type)
    end

    return values_types
end

local function get_values_opts(index, fieldnos)
    local values_opts = {}
    for _, fieldno in ipairs(fieldnos) do
        local is_nullable = true
        local collation

        if index ~= nil then
            local index_part

            for _, part in ipairs(index.parts) do
                if part.fieldno == fieldno then
                    index_part = part
                    break
                end
            end

            assert(index_part ~= nil)

            is_nullable = index_part.is_nullable
            collation = index_part.collation
        end

        table.insert(values_opts, {
            is_nullable = is_nullable,
            collation = collation,
        })
    end

    return values_opts
end

local function get_index_by_name(space_indexes, index_name)
    for _, index in ipairs(space_indexes) do
        if index.name == index_name then
            return index
        end
    end
end

local function get_filter_conditions(space_indexes, space_format, conditions, scanner)
    local fieldnos_by_names = {}

    for i, field_format in ipairs(space_format) do
        fieldnos_by_names[field_format.name] = i
    end

    local filter_conditions = {}

    for i, condition in ipairs(conditions) do
        if i ~= scanner.condition_num then
            -- Index check (including one and multicolumn)
            local fieldnos

            local index = get_index_by_name(space_indexes, condition.operand)
            if index ~= nil then
                fieldnos = get_index_fieldnos(index)
            elseif fieldnos_by_names[condition.operand] ~= nil then
                fieldnos = {
                    fieldnos_by_names[condition.operand],
                }
            else
                return nil, string.format('No field or index is found for condition %s', json.encode(condition))
            end

            table.insert(filter_conditions, {
                fieldnos = fieldnos,
                operator = condition.operator,
                values = condition.values,
                types = get_values_types(space_format, fieldnos),
                early_exit_is_possible = is_early_exit_possible(scanner, condition),
                values_opts = get_values_opts(index, fieldnos)
            })
        end
    end

    return filter_conditions
end

local function validate_conditions(conditions, space_indexes, space_format)
    local field_names = {}
    for _, field_format in ipairs(space_format) do
        field_names[field_format.name] = true
    end

    local index_names = {}
    for _, index in ipairs(space_indexes) do
        index_names[index.name] = true
    end

    for _, condition in ipairs(conditions) do
        if index_names[condition.operand] == nil and field_names[condition.operand] == nil then
            return false, SelectPlanError:new("No field or index %q found", condition.operand)
        end
    end

    return true
end

function select_plan.new(space_obj, conditions)
    local space_indexes = space_obj.index
    local space_format = space_obj:format()

    local ok, err = validate_conditions(conditions, space_indexes, space_format)
    if not ok then
        return nil, SelectPlanError:new('Passed bad conditions: %s', err)
    end

    local scanner = get_select_scanner(space_indexes, space_format, conditions)
    local filter_conditions = get_filter_conditions(space_indexes, space_format, conditions, scanner)

    return {
        scanner = scanner,
        filter_conditions = filter_conditions,
    }
end

return select_plan
