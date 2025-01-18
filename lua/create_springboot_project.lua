-- Dependencies
local fzf = require("fzf-lua")

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

local function validate_dependencies(deps)
	if deps == "" then
		return DEFAULT_VALUES.dependencies
	end
	return deps
end

local function validate_input(input, default)
	return input ~= "" and input or default
end

local function validate_spring_executable()
	local result = vim.fn.system("which spring"):gsub("%s+", "")
	if result == "" then
		vim.notify("'spring' command not found. Please install Spring CLI.", vim.log.levels.ERROR)
		return false
	end
	return true
end

-- Project Creation Logic
local function create_project(config)
	if not validate_spring_executable() then
		return
	end

	config.dependencies = validate_dependencies(config.dependencies)

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

	vim.notify("Creating project...", vim.log.levels.INFO)

	vim.fn.jobstart(command, {
		on_exit = function(_, code)
			if code ~= 0 then
				vim.notify("Error creating project", vim.log.levels.ERROR)
				return
			end

			vim.fn.chdir(config.name)

			fzf.files({
				prompt = "Find Main Java File",
				cwd = vim.fn.getcwd() .. "/src/main/java",
				file_ignore_patterns = { "^target/" },
			})

			vim.notify("Project created successfully!", vim.log.levels.INFO)
		end,
		stdout_buffered = true,
		stderr_buffered = true,
	})
end

local function springboot_new_project()
	local request = safe_request(SPRING_METADATA_URL)
	if not request then
		return
	end

	local spring_data = safe_json_decode(request.stdout)
	if not spring_data then
		return
	end

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

	vim.ui.input({ prompt = "Project Name (default: demo): " }, function(input)
		config.name = validate_input(input, DEFAULT_VALUES.artifact_id)
		vim.ui.input({ prompt = "Group ID (default: com.example): " }, function(input)
			config.group_id = validate_input(input, DEFAULT_VALUES.group_id)
			vim.ui.input({ prompt = "Artifact ID (default: demo): " }, function(input)
				config.artifact_id = validate_input(input, DEFAULT_VALUES.artifact_id)
				vim.ui.input({ prompt = "Package Name (default: com.example.demo): " }, function(input)
					config.package_name = validate_input(input, config.group_id .. "." .. config.artifact_id)
					create_project(config)
				end)
			end)
		end)
	end)
end

local M = {}

function M.setup(opts)
	opts = opts or {}
	DEFAULT_VALUES = vim.tbl_deep_extend("force", DEFAULT_VALUES, opts)
end

local function init()
	vim.api.nvim_create_user_command("SpringBootNewProject", springboot_new_project, {})
end

M.init = init

return M
