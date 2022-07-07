local display = require "mason.core.ui.display"
local Ui = require "mason.core.ui"
local a = require "mason.core.async"
local control = require "mason.core.async.control"
local _ = require "mason.core.functional"
local palette = require "mason.ui.palette"
local indexer = require "mason.core.package.indexer"
local Package = require "mason.core.package"
local settings = require "mason.settings"
local notify = require "mason.notify"

local Header = require "mason.ui.components.header"
local Footer = require "mason.ui.components.footer"
local Help = require "mason.ui.components.help"
local Tabs = require "mason.ui.components.tabs"
local Main = require "mason.ui.components.main"
local LanguageFilter = require "mason.ui.components.language-filter"

local Semaphore = control.Semaphore

---@param state InstallerUiState
local function GlobalKeybinds(state)
    return Ui.Node {
        Ui.Keybind("?", "TOGGLE_HELP", nil, true),
        Ui.Keybind("q", "CLOSE_WINDOW", nil, true),
        Ui.When(not state.view.language_filter, Ui.Keybind("<Esc>", "CLOSE_WINDOW", nil, true)),
        Ui.When(state.view.language_filter, Ui.Keybind("<Esc>", "CLEAR_LANGUAGE_FILTER", nil, true)),
        Ui.Keybind(settings.current.ui.keymaps.apply_language_filter, "LANGUAGE_FILTER", nil, true),
        Ui.Keybind(settings.current.ui.keymaps.update_all_packages, "UPDATE_ALL_PACKAGES", nil, true),

        Ui.Keybind("1", "SET_VIEW", "All", true),
        Ui.Keybind("2", "SET_VIEW", "LSP", true),
        Ui.Keybind("3", "SET_VIEW", "DAP", true),
        Ui.Keybind("4", "SET_VIEW", "Linter", true),
        Ui.Keybind("5", "SET_VIEW", "Formatter", true),
    }
end

---@class UiPackageState
---@field is_terminated boolean
---@field latest_spawn string|nil
---@field tailed_output string[]
---@field short_tailed_output string[]
---@field linked_executables table<string, string>
---@field version string|nil
---@field is_checking_version boolean
---@field lsp_settings_schema table|nil
---@field new_version NewPackageVersion|nil
---@field is_checking_new_version boolean
---@field expanded_json_schemas table<string, boolean>
---@field expanded_json_schema_keys table<string, table<string, boolean>>

---@class InstallerUiState
local INITIAL_STATE = {
    stats = {
        ---@type string | nil
        used_disk_space = nil,
    },
    view = {
        is_showing_help = false,
        is_current_settings_expanded = false,
        language_filter = nil,
        current = "All",
        has_changed = false,
        ship_indentation = 0,
        ship_exclamation = "",
    },
    header = {
        title_prefix = "", -- for animation
    },
    packages = {
        new_versions_check = {
            is_checking = false,
            current = 0,
            total = 0,
            percentage_complete = 0,
        },
        ---@type table<string, boolean>
        visible = {},
        ---@type string|nil
        expanded = nil,
        ---@type table<string, UiPackageState>
        states = {},
        ---@type Package[]
        installed = {},
        ---@type Package[]
        installing = {},
        ---@type Package[]
        failed = {},
        ---@type Package[]
        queued = {},
        ---@type Package[]
        uninstalled = {},
    },
}

---@generic T
---@param list T[]
---@param item T
---@return T
local function remove(list, item)
    for i, v in ipairs(list) do
        if v == item then
            table.remove(list, i)
            return list
        end
    end
    return list
end

local window = display.new_view_only_win("Installer Info", "mason.nvim")
local packages = _.sort_by(_.prop "name", indexer.get_all_packages())

window.view(
    ---@param state InstallerUiState
    function(state)
        return Ui.Node {
            GlobalKeybinds(state),
            Header(state),
            Tabs(state),
            Ui.When(state.view.is_showing_help, function()
                return Help(state)
            end),
            Ui.When(not state.view.is_showing_help, function()
                return Ui.Node {
                    LanguageFilter(state),
                    Main(state),
                }
            end),
            Footer(state),
        }
    end
)

local mutate_state, get_state = window.state(INITIAL_STATE)

---@param package Package
---@param group string
---@param tail boolean|nil @Whether to insert at the end.
local function mutate_package_grouping(package, group, tail)
    mutate_state(function(state)
        remove(state.packages.installing, package)
        remove(state.packages.queued, package)
        remove(state.packages.uninstalled, package)
        remove(state.packages.installed, package)
        remove(state.packages.failed, package)
        if tail then
            table.insert(state.packages[group], package)
        else
            table.insert(state.packages[group], 1, package)
        end
    end)
end

---@param mutate_fn fun(state: InstallerUiState)
local function mutate_package_visibility(mutate_fn)
    mutate_state(function(state)
        mutate_fn(state)
        local view_predicate = {
            ["All"] = _.T,
            ["LSP"] = _.prop_satisfies(_.any(_.equals(Package.Cat.LSP)), "categories"),
            ["DAP"] = _.prop_satisfies(_.any(_.equals(Package.Cat.DAP)), "categories"),
            ["Linter"] = _.prop_satisfies(_.any(_.equals(Package.Cat.Linter)), "categories"),
            ["Formatter"] = _.prop_satisfies(_.any(_.equals(Package.Cat.Formatter)), "categories"),
        }
        local language_predicate = _.if_else(
            _.always(state.view.language_filter),
            _.prop_satisfies(_.any(_.equals(state.view.language_filter)), "languages"),
            _.T
        )
        for __, package in ipairs(packages) do
            state.packages.visible[package.name] = _.all_pass(
                { view_predicate[state.view.current], language_predicate },
                package.spec
            )
        end
    end)
end

---@param handle InstallHandle
local function setup_handle(handle)
    ---@param new_state InstallHandleState
    local function handle_state_change(new_state)
        if new_state == "QUEUED" then
            mutate_package_grouping(handle.package, "queued", true)
        elseif new_state == "ACTIVE" then
            mutate_package_grouping(handle.package, "installing", true)
        end
    end

    local function handle_spawninfo_change()
        mutate_state(function(state)
            state.packages.states[handle.package.name].latest_spawn = handle
                :peek_spawninfo_stack()
                :map(tostring)
                :or_else(nil)
        end)
    end

    ---@param chunk string
    local function handle_output(chunk)
        mutate_state(function(state)
            -- TODO: improve this
            local pkg_state = state.packages.states[handle.package.name]
            for idx, line in ipairs(vim.split(chunk, "\n")) do
                if idx == 1 and pkg_state.tailed_output[#pkg_state.tailed_output] then
                    pkg_state.tailed_output[#pkg_state.tailed_output] = pkg_state.tailed_output[#pkg_state.tailed_output]
                        .. line
                else
                    pkg_state.tailed_output[#pkg_state.tailed_output + 1] = line
                end
            end
            pkg_state.short_tailed_output = {
                pkg_state.tailed_output[#pkg_state.tailed_output - 1] or "",
                pkg_state.tailed_output[#pkg_state.tailed_output] or "",
            }
        end)
    end

    local function handle_terminate()
        mutate_state(function(state)
            state.packages.states[handle.package.name].is_terminated = handle.is_terminated
            if handle:is_queued() then
                -- This is really already handled by the "install:failed" handler, but for UX reasons we handle
                -- terminated, queued, handlers here. The reason for this is that a queued handler, which is
                -- aborted, will not fail its installation until it acquires a semaphore permit, leading to a weird
                -- UX that may be perceived as non-functional.
                mutate_package_grouping(handle.package, handle.package:is_installed() and "installed" or "uninstalled")
            end
        end)
    end

    handle:on("terminate", handle_terminate)
    handle:on("state:change", handle_state_change)
    handle:on("spawninfo:change", handle_spawninfo_change)
    handle:on("stdout", handle_output)
    handle:on("stderr", handle_output)

    -- hydrate initial state
    handle_state_change(handle.state)
    handle_terminate()
    handle_spawninfo_change()
    mutate_state(function(state)
        state.packages.states[handle.package.name].tailed_output = {}
    end)
end

---@param package Package
local function hydrate_detailed_package_state(package)
    mutate_state(function(state)
        state.packages.states[package.name].is_checking_version = true
        -- initialize expanded keys table
        state.packages.states[package.name].expanded_json_schema_keys["lsp"] = state.packages.states[package.name].expanded_json_schema_keys["lsp"]
            or {}
        state.packages.states[package.name].lsp_settings_schema = package:get_lsp_settings_schema():or_else(nil)
    end)

    package:get_installed_version(function(success, version_or_err)
        mutate_state(function(state)
            state.packages.states[package.name].is_checking_version = false
            if success then
                state.packages.states[package.name].version = version_or_err
            end
        end)
    end)

    package:get_receipt():if_present(
        ---@param receipt InstallReceipt
        function(receipt)
            mutate_state(function(state)
                state.packages.states[package.name].linked_executables = receipt.executables
            end)
        end
    )
end

local function create_initial_package_state()
    return {
        latest_spawn = nil,
        tailed_output = {},
        short_tailed_output = {},
        version = nil,
        is_checking_version = false,
        new_version = nil,
        is_checking_new_version = false,
        expanded_json_schemas = {},
        expanded_json_schema_keys = {},
    }
end

for _, package in ipairs(packages) do
    -- hydrate initial state
    mutate_state(function(state)
        state.packages.states[package.name] = create_initial_package_state()
        state.packages.visible[package.name] = true
    end)
    mutate_package_grouping(package, package:is_installed() and "installed" or "uninstalled", true)

    package:get_handle():if_present(setup_handle)
    package:on("handle", setup_handle)

    package:on("install:success", function()
        if get_state().packages.expanded == package.name then
            vim.schedule(function()
                hydrate_detailed_package_state(package)
            end)
        end
        mutate_package_grouping(package, "installed")
        mutate_state(function(state)
            local pkg_state = state.packages.states[package.name]
            pkg_state.new_version = nil
            pkg_state.version = nil
            pkg_state.tailed_output = {}
            pkg_state.short_tailed_output = {}
        end)
        vim.schedule_wrap(notify)(("%q was successfully installed."):format(package.name))
    end)

    package:on(
        "install:failed",
        ---@param handle InstallHandle
        function(handle)
            if handle.is_terminated then
                -- If installation was explicitly terminated - restore to "pristine" state
                mutate_package_grouping(package, package:is_installed() and "installed" or "uninstalled")
            else
                mutate_package_grouping(package, "failed")
            end
        end
    )

    package:on("uninstall:success", function()
        mutate_package_grouping(package, "uninstalled")
        mutate_state(function(state)
            state.packages.states[package.name] = create_initial_package_state()
        end)
    end)
end

local help_animation
do
    local help_command = ":help"
    local help_command_len = #help_command
    help_animation = Ui.animation {
        function(tick)
            mutate_state(function(state)
                state.header.title_prefix = help_command:sub(help_command_len - tick, help_command_len)
            end)
        end,
        range = { 0, help_command_len },
        delay_ms = 80,
    }
end

local ship_animation = Ui.animation {
    function(tick)
        mutate_state(function(state)
            state.view.ship_indentation = tick
            if tick > -5 then
                state.view.ship_exclamation = "https://github.com/sponsors/williamboman"
            elseif tick > -27 then
                state.view.ship_exclamation = "Sponsor mason.nvim development!"
            else
                state.view.ship_exclamation = ""
            end
        end)
    end,
    range = { -35, 5 },
    delay_ms = 250,
}

local function toggle_help()
    mutate_state(function(state)
        state.view.is_showing_help = not state.view.is_showing_help
        if state.view.is_showing_help then
            help_animation()
            ship_animation()
        end
    end)
end

local function set_view(event)
    local view = event.payload
    mutate_package_visibility(function(state)
        state.view.current = view
        state.view.has_changed = true
    end)
end

local function terminate_package_handle(event)
    ---@type Package
    local package = event.payload
    package:get_handle():if_present(
        ---@param handle InstallHandle
        function(handle)
            vim.schedule_wrap(notify)(("Cancelling installation of %q."):format(package.name))
            handle:terminate()
        end
    )
end

local function install_package(event)
    ---@type Package
    local package = event.payload
    package:install()
end

local function uninstall_package(event)
    ---@type Package
    local package = event.payload
    package:uninstall()
    vim.schedule_wrap(notify)(("%q was successfully uninstalled."):format(package.name))
end

local function dequeue_package(event)
    ---@type Package
    local package = event.payload
    package:get_handle():if_present(
        ---@param handle InstallHandle
        function(handle)
            if not handle:is_closed() then
                handle:terminate()
            end
        end
    )
end

local function toggle_expand_package(event)
    ---@type Package
    local package = event.payload
    mutate_state(function(state)
        if state.packages.expanded == package.name then
            state.packages.expanded = nil
        else
            hydrate_detailed_package_state(package)
            state.packages.expanded = package.name
        end
    end)
end

---@async
---@param package Package
local function check_new_package_version(package)
    mutate_state(function(state)
        state.packages.states[package.name].is_checking_new_version = true
    end)
    a.wait(function(resolve, reject)
        package:check_new_version(function(success, new_version)
            mutate_state(function(state)
                state.packages.states[package.name].is_checking_new_version = false
                if success then
                    state.packages.states[package.name].new_version = new_version
                end
            end)
            if success then
                resolve(new_version)
            else
                reject(new_version)
            end
        end)
    end)
end

---@async
local function check_new_visible_package_versions()
    local state = get_state()
    if state.packages.new_versions_check.is_checking then
        return
    end
    local installed_visible_packages = _.compose(
        _.filter(
            ---@param package Package
            function(package)
                return package
                    :get_handle()
                    :map(function(handle)
                        return handle:is_closed()
                    end)
                    :or_else(true)
            end
        ),
        _.filter(function(package)
            return state.packages.visible[package.name]
        end)
    )(state.packages.installed)

    if #installed_visible_packages == 0 then
        return
    end

    mutate_state(function(state)
        state.packages.new_versions_check.is_checking = true
        state.packages.new_versions_check.current = 0
        state.packages.new_versions_check.total = #installed_visible_packages
        state.packages.new_versions_check.percentage_complete = 0
    end)

    local sem = Semaphore.new(5)
    a.wait_all(_.map(function(package)
        return function()
            local permit = sem:acquire()
            pcall(check_new_package_version, package)
            mutate_state(function(state)
                state.packages.new_versions_check.current = state.packages.new_versions_check.current + 1
                state.packages.new_versions_check.percentage_complete = state.packages.new_versions_check.current
                    / state.packages.new_versions_check.total
            end)
            permit:forget()
        end
    end, installed_visible_packages))

    a.sleep(800)
    mutate_state(function(state)
        state.packages.new_versions_check.is_checking = false
        state.packages.new_versions_check.current = 0
        state.packages.new_versions_check.total = 0
        state.packages.new_versions_check.percentage_complete = 0
    end)
end

local function toggle_json_schema(event)
    local package, schema_id = event.payload.package, event.payload.schema_id
    mutate_state(function(state)
        state.packages.states[package.name].expanded_json_schemas[schema_id] =
            not state.packages.states[package.name].expanded_json_schemas[schema_id]
    end)
end

local function toggle_json_schema_keys(event)
    local package, schema_id, key = event.payload.package, event.payload.schema_id, event.payload.key
    mutate_state(function(state)
        state.packages.states[package.name].expanded_json_schema_keys[schema_id][key] =
            not state.packages.states[package.name].expanded_json_schema_keys[schema_id][key]
    end)
end

local function filter()
    vim.ui.select(_.sort_by(_.identity, _.keys(Package.Lang)), {
        prompt = "Select language:",
    }, function(choice)
        if not choice or choice == "" then
            return
        end
        mutate_package_visibility(function(state)
            state.view.language_filter = choice
        end)
    end)
end

local function clear_filter()
    mutate_package_visibility(function(state)
        state.view.language_filter = nil
    end)
end

local function toggle_expand_current_settings()
    mutate_state(function(state)
        state.view.is_current_settings_expanded = not state.view.is_current_settings_expanded
    end)
end

local function update_all_packages()
    local state = get_state()
    _.each(
        function(pkg)
            pkg:install(pkg)
        end,
        _.filter(function(pkg)
            return state.packages.states[pkg.name].new_version
        end, state.packages.installed)
    )
end

local effects = {
    ["CHECK_NEW_PACKAGE_VERSION"] = a.scope(_.compose(_.partial(pcall, check_new_package_version), _.prop "payload")),
    ["CHECK_NEW_VISIBLE_PACKAGE_VERSIONS"] = a.scope(check_new_visible_package_versions),
    ["CLEAR_LANGUAGE_FILTER"] = clear_filter,
    ["CLOSE_WINDOW"] = window.close,
    ["DEQUEUE_PACKAGE"] = dequeue_package,
    ["INSTALL_PACKAGE"] = install_package,
    ["LANGUAGE_FILTER"] = filter,
    ["SET_VIEW"] = set_view,
    ["TERMINATE_PACKAGE_HANDLE"] = terminate_package_handle,
    ["TOGGLE_EXPAND_CURRENT_SETTINGS"] = toggle_expand_current_settings,
    ["TOGGLE_EXPAND_PACKAGE"] = toggle_expand_package,
    ["TOGGLE_HELP"] = toggle_help,
    ["TOGGLE_JSON_SCHEMA"] = toggle_json_schema,
    ["TOGGLE_JSON_SCHEMA_KEY"] = toggle_json_schema_keys,
    ["UNINSTALL_PACKAGE"] = uninstall_package,
    ["UPDATE_ALL_PACKAGES"] = update_all_packages,
}

window.init {
    effects = effects,
    highlight_groups = palette.highlight_groups,
}

return window
