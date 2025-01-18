-- Dependencies
local popup = require("nui.popup")
local menu = require("nui.menu")
local layout = require("nui.layout")
local input = require("nui.input")
local split = require("nui.split")
local tree = require("nui.tree")
local event = require("nui.utils.autocmd").event

-- Constants
local SPRING_METADATA_URL = "https://start.spring.io/metadata/client"
local DEFAULT_VALUES = {
	build_type = "maven",
	language = "java",
	java_version = "21",
	boot_version = "3.3.1.RELEASE",
	packaging = "jar",
	dependencies = "devtools,web,data-jpa,h2,thymeleaf",
	group_id = "com.example",
	artifact_id = "demo",
}

-- Cache for metadata
local metadata_cache = {
	data = nil,
	timestamp = 0,
	ttl = 3600, -- 1 hour cache
}

-- Utility functions
local function is_cache_valid()
	return metadata_cache.data and (os.time() - metadata_cache.timestamp) < metadata_cache.ttl
end

local function safe_request(url)
	if url == SPRING_METADATA_URL and is_cache_valid() then
		return { stdout = vim.fn.json_encode(metadata_cache.data) }
	end

	local status, request = pcall(function()
		return vim.system({ "curl", "-s", url }, { text = true }):wait()
	end)

	if not status then
		vim.notify("Error making request to " .. url .. ": " .. request, vim.log.levels.ERROR)
		return nil
	end

	if url == SPRING_METADATA_URL then
		local decoded = safe_json_decode(request.stdout)
		if decoded then
			metadata_cache.data = decoded
			metadata_cache.timestamp = os.time()
		end
	end

	return request
end

local function safe_json_decode(data)
	local status, decoded = pcall(vim.fn.json_decode, data)

	if not status then
		vim.notify("Error decoding JSON: " .. decoded, vim.log.levels.ERROR)
		return nil
	end

	return decoded
end

-- Form Component
local Form = {}
Form.__index = Form

function Form.new(fields, options)
	local self = setmetatable({}, Form)
	self.fields = fields
	self.values = {}
	self.options = options or {}
	self.current_field = 1
	return self
end

function Form:mount()
	self.popup = popup({
		enter = true,
		border = {
			style = "rounded",
			text = {
				top = self.options.title or "Form",
				top_align = "center",
			},
		},
		position = "50%",
		size = {
			width = 60,
			height = #self.fields * 3 + 2,
		},
		buf_options = {
			modifiable = true,
			readonly = false,
		},
	})

	self.popup:mount()
	self:render_fields()
	self:setup_keymaps()
end

function Form:render_fields()
	local lines = {}
	for i, field in ipairs(self.fields) do
		table.insert(lines, field.label .. ":")
		table.insert(lines, field.default or "")
		table.insert(lines, "")
	end

	vim.api.nvim_buf_set_lines(self.popup.bufnr, 0, -1, false, lines)
end

function Form:setup_keymaps()
	self.popup:map("n", "<CR>", function()
		self:next_field()
	end, { noremap = true })

	self.popup:map("n", "<Esc>", function()
		self:close()
	end, { noremap = true })
end

function Form:next_field()
	local current_value = vim.api.nvim_get_current_line()
	self.values[self.fields[self.current_field].id] = current_value

	if self.current_field == #self.fields then
		self:submit()
	else
		self.current_field = self.current_field + 1
		vim.api.nvim_win_set_cursor(self.popup.winid, { self.current_field * 3 - 1, 0 })
	end
end

function Form:submit()
	if self.options.on_submit then
		self.options.on_submit(self.values)
	end
	self:close()
end

function Form:close()
	self.popup:unmount()
end

-- Dependencies Selector Component
local DependencySelector = {}
DependencySelector.__index = DependencySelector

function DependencySelector.new(dependencies, options)
	local self = setmetatable({}, DependencySelector)
	self.dependencies = dependencies
	self.options = options or {}
	self.selected = {}
	return self
end

function DependencySelector:mount()
	-- Create main split
	self.split = split({
		relative = "editor",
		position = "left",
		size = 40,
		enter = true,
	})

	-- Create tree for dependencies
	local tree_items = {}
	for _, group in ipairs(self.dependencies) do
		local children = {}
		for _, dep in ipairs(group.values) do
			table.insert(children, {
				text = dep.name,
				id = dep.id,
				description = dep.description,
			})
		end

		table.insert(tree_items, {
			text = group.name,
			children = children,
		})
	end

	self.tree = tree.Tree({
		bufnr = self.split.bufnr,
		nodes = tree_items,
		prepare_node = function(node)
			local text = node.text
			if node.id and self.selected[node.id] then
				text = "* " .. text
			end
			return text
		end,
	})

	-- Setup keymaps
	self:setup_keymaps()

	self.split:mount()
	self.tree:render()
end

function DependencySelector:setup_keymaps()
	self.split:map("n", "<Space>", function()
		local node = self.tree:get_node()
		if node.id then
			self.selected[node.id] = not self.selected[node.id]
			self.tree:render()
		end
	end, { noremap = true })

	self.split:map("n", "<CR>", function()
		self:submit()
	end, { noremap = true })

	self.split:map("n", "<Esc>", function()
		self:close()
	end, { noremap = true })
end

function DependencySelector:submit()
	local selected_deps = {}
	for id, _ in pairs(self.selected) do
		table.insert(selected_deps, id)
	end

	if self.options.on_submit then
		self.options.on_submit(table.concat(selected_deps, ","))
	end
	self:close()
end

function DependencySelector:close()
	self.split:unmount()
end

-- Project Creation Logic
local function handle_dependencies_selection(spring_data, callback)
	local selector = DependencySelector.new(spring_data.dependencies.values, {
		on_submit = callback,
	})
	selector:mount()
end

local function create_project(config)
	local command = string.format(
		"spring init --boot-version=%s --java-version=%s --build=%s --dependencies=%s "
			.. "--groupId=%s --artifactId=%s --name=%s --package-name=%s %s",
		config.boot_version,
		config.java_version,
		config.build_type,
		config.dependencies,
		config.group_id,
		config.artifact_id,
		config.name,
		config.package_name,
		config.name
	)

	-- Show progress indicator
	vim.notify("Creating project...", vim.log.levels.INFO)

	-- Execute command asynchronously
	vim.fn.jobstart(command, {
		on_exit = function(_, code)
			if code ~= 0 then
				vim.notify("Error creating project", vim.log.levels.ERROR)
				return
			end

			-- Change to project directory and open main Java file
			vim.fn.chdir(config.name)

			-- Use LazyVim's telescope integration to find and open main file
			require("telescope.builtin").find_files({
				prompt_title = "Find Main Java File",
				cwd = vim.fn.getcwd() .. "/src/main/java",
				file_ignore_patterns = { "^target/" },
			})

			-- Open file explorer (using Neo-tree if available in LazyVim)
			if pcall(require, "neo-tree") then
				vim.cmd("Neotree focus")
			end

			vim.notify("Project created successfully!", vim.log.levels.INFO)
		end,
		stdout_buffered = true,
		stderr_buffered = true,
	})
end

-- Main Function
local function springboot_new_project()
	local request = safe_request(SPRING_METADATA_URL)
	if not request then
		return
	end

	local spring_data = safe_json_decode(request.stdout)
	if not spring_data then
		return
	end

	-- Create a configuration object to store all selections
	local config = {
		build_type = DEFAULT_VALUES.build_type,
		language = DEFAULT_VALUES.language,
		java_version = DEFAULT_VALUES.java_version,
		boot_version = DEFAULT_VALUES.boot_version,
		packaging = DEFAULT_VALUES.packaging,
		dependencies = DEFAULT_VALUES.dependencies,
		group_id = DEFAULT_VALUES.group_id,
		artifact_id = DEFAULT_VALUES.artifact_id,
	}

	-- Project Details Form
	local form = Form.new({
		{ id = "name", label = "Project Name", default = DEFAULT_VALUES.artifact_id },
		{ id = "group_id", label = "Group ID", default = DEFAULT_VALUES.group_id },
		{ id = "artifact_id", label = "Artifact ID", default = DEFAULT_VALUES.artifact_id },
		{
			id = "package_name",
			label = "Package Name",
			default = DEFAULT_VALUES.group_id .. "." .. DEFAULT_VALUES.artifact_id,
		},
	}, {
		title = "Project Details",
		on_submit = function(values)
			config.name = values.name
			config.group_id = values.group_id
			config.artifact_id = values.artifact_id
			config.package_name = values.package_name

			-- Show dependency selector after form submission
			handle_dependencies_selection(spring_data, function(deps)
				config.dependencies = deps
				create_project(config)
			end)
		end,
	})

	form:mount()
end

-- Plugin setup function
local M = {}

function M.setup(opts)
	opts = opts or {}
	-- Merge default options with user options
	DEFAULT_VALUES = vim.tbl_deep_extend("force", DEFAULT_VALUES, opts)
end

-- Register command with LazyVim
local function init()
	vim.api.nvim_create_user_command("SpringBootNewProject", springboot_new_project, {})

	-- Add Telescope integration
	if pcall(require, "telescope") then
		require("telescope").setup({
			extensions = {
				spring_initializer = {
					-- Additional telescope configuration
				},
			},
		})
	end
end

M.init = init

return M
