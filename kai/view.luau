-- Pure render: model -> Tern-native nodes (section, item, icon, badge). styles.css only spaces them.
local ui = tern.ui
local View = {}

-- Paths ride in node keys hex-encoded, so window.luau can recover them from a menu's node id.
local function hex(value)
	return (string.gsub(value, ".", function(c) return string.format("%02x", string.byte(c)) end))
end


-- Right-click menus. Tern reports the clicked entry's label as the action, so these
-- labels are the action names window.luau dispatches on; the target comes from the node path.
local M = {
	switch = "Switch to Workspace", newTab = "New Tab in Workspace", renameWs = "Rename Workspace…",
	lock = "Lock Workspace", unlock = "Unlock Workspace", copyPath = "Copy Path", finder = "Reveal in Finder",
	expandTabs = "Expand All Tabs", collapseTabs = "Collapse All Tabs", collapseOthers = "Collapse Other Workspaces",
	closeWs = "Close Workspace",
	goTab = "Go to Tab", renameTab = "Rename Tab…", colorTab = "Set Tab Color…", newPane = "New Pane in Tab",
	even = "Even Out Panes", tabUp = "Move Tab Up", tabDown = "Move Tab Down", tabToWs = "Move Tab to Workspace…",
	closeTab = "Close Tab",
	focus = "Focus Pane", splitRight = "Split Right", splitDown = "Split Down", toNewTab = "Move to New Tab",
	toWs = "Move to Workspace…", copyTitle = "Copy Title", interrupt = "Interrupt Agent", stop = "Stop Agent",
	closePane = "Close Pane",
	moveWs = "Move Workspace…", moveTab = "Move Tab…", movePane = "Move Pane…",
	wsIcon = "Set Icon…", wsColor = "Set Color…", iceIn = "Move to Ice Box", iceOut = "Remove from Ice Box",
	sound = "Turn Sounds On", noSound = "Turn Sounds Off", linear = "Set Linear Workspace…",
	stage = "Stage", unstage = "Unstage", checkout = "Checkout", openFile = "Open",
	newWs = "New Workspace…", expandAll = "Expand All Workspaces", collapseAll = "Collapse All Workspaces",
	addHost = "Add Remote Host…", switchHost = "Switch to Host", newOnHost = "New Session on Host…",
	disconnectHost = "Disconnect Host",
	sizeCompact = "Compact Size", sizeStandard = "Standard Size", sizeSpacious = "Spacious Size",
}
View.M = M

function View.workspaceMenu(workspace)
	local menu = {}
	if not workspace.current then table.insert(menu, M.switch) end
	for _, item in {
		M.newTab, M.renameWs, M.wsIcon, M.wsColor, M.moveWs, if workspace.locked then M.unlock else M.lock,
		M.copyPath, M.finder, M.expandTabs, M.collapseTabs, M.collapseOthers,
	} do table.insert(menu, item) end
	table.insert(menu, if workspace.iced then M.iceOut else M.iceIn)
	if workspace.ticket then table.insert(menu, M.linear) end
	if not workspace.locked then table.insert(menu, M.closeWs) end
	return menu
end

function View.tabMenu(workspace, tab)
	local menu = { M.goTab, M.renameTab, M.moveTab, M.colorTab, M.newPane }
	if #tab.panes > 1 then table.insert(menu, M.even) end
	if tab.position > 1 then table.insert(menu, M.tabUp) end
	if tab.position < workspace.tabCount then table.insert(menu, M.tabDown) end
	table.insert(menu, M.tabToWs)
	table.insert(menu, M.closeTab)
	return menu
end

function View.paneMenu(pane, inSplitTab)
	local menu = {}
	if not pane.focused then table.insert(menu, M.focus) end
	if inSplitTab then table.insert(menu, M.movePane) end
	for _, item in { M.splitRight, M.splitDown, M.toNewTab, M.toWs, M.copyPath, M.finder, M.copyTitle } do
		table.insert(menu, item)
	end
	if pane.native then
		if pane.state == "working" or pane.state == "waiting" then table.insert(menu, M.interrupt) end
		table.insert(menu, M.stop)
	end
	table.insert(menu, M.closePane)
	return menu
end

-- A single-pane tab is one row, so its menu carries both the tab's and the pane's entries.
local function merged(a, b)
	local seen, out = {}, {}
	for _, list in { a, b } do
		for _, item in list do
			if not seen[item] then seen[item] = true; table.insert(out, item) end
		end
	end
	return out
end

local APP_ICONS = {
	omp = "app-omp", claude = "app-claude", codex = "app-codex", pi = "pi-mark",
	python = "app-python", python3 = "app-python", node = "app-node", bun = "app-bun", deno = "app-deno",
	vim = "app-vim", nvim = "app-vim", hx = "app-helix", htop = "app-htop", btop = "app-btop",
	docker = "app-docker", go = "app-go", cargo = "app-rust", ruby = "app-ruby", java = "app-java",
}
local KIND_ICONS = {
	browser = "globe", file = "doc", git = "branch", database = "database", notebook = "code",
	board = "kanban", canvas = "canvas", procs = "activity", screen = "monitor", profile = "gauge",
	carly = "sparkle", plugin = "puzzle",
}
local STATE = {
	waiting = { tone = "accent", value = "waiting", style = "accent" },
	working = { tone = "success", value = "working", style = "success" },
	idle = { tone = "muted", value = "idle", style = "muted" },
	running = { tone = "warning", value = "running", style = "warning" },
	exited = { tone = "error", value = "exited", style = "error" },
	shell = { tone = "muted" },
	none = { tone = "muted" },
}

local function iconOf(pane)
	local app = APP_ICONS[(pane.program:match("^(%S+)") or "")]
	if app then return app end
	if pane.kind and KIND_ICONS[pane.kind] then return KIND_ICONS[pane.kind] end
	return "terminal"
end

-- The move being placed (set per render), so rows can dim and drop slots can appear.
local mv = nil
-- The canvas path of the root list (the size wrapper "s", then the list "kai"), and the path of
-- the section workspaces sit in: the root, or their host's section when hosts are shown.
local ROOT = "main.s.kai."
local parent = ROOT

-- Tern's own move glyph, shown on hover; clicking it picks the row up.
local function grip(value, what)
	return ui.node("icon", {
		key = "grip", name = "grip", role = "kai.grip",
		title = "Move " .. what, aria = "Move " .. what, actions = { click = "pick=" .. value },
	})
end

-- A small hover-only button (same visibility as the grip).
local function quick(key, icon, action, title)
	return ui.node("icon", { key = key, name = icon, role = "kai.grip", title = title, aria = title, actions = { click = action } })
end

-- Tern's tab colors, as the nearest theme tone.
local COLOR_TONE = {
	red = "error", orange = "warning", yellow = "warning", green = "success",
	teal = "success", blue = "info", purple = "accent", pink = "user",
}
local function colorDot(color)
	if not color then return nil end
	return ui.el("div", { key = "color", role = "kai.colorDot", tone = COLOR_TONE[color] or "muted", title = color })
end

local function dropSlot(key, target)
	return ui.node("item", {
		key = key, label = "Move here", icon = "corner-down-right", tone = "accent", role = "kai.drop",
		actions = { click = "drop=" .. tostring(target) },
	})
end

local function indexOf(list, id)
	for i, x in ipairs(list) do
		if x.id == id then return i end
	end
	return nil
end

-- A slot before position i is useful unless it would leave the moved row where it is.
local function slotAt(src, i)
	return src ~= nil and i ~= src and i ~= src + 1
end

local function rowRole(focused)
	return if focused then "kai.rowFocused" else "kai.row"
end

-- What sits at a row's right edge: Tern's own spinner while an agent works, a pulsing dot while
-- one waits for you, a short word for other states, nothing when idle at a shell.
local function indicator(pane)
	if pane.unseen == "failed" then
		return ui.node("icon", { key = "st", name = "x-circle", tone = "error", title = "Command failed while you were away" })
	elseif pane.unseen == "done" then
		return ui.node("icon", { key = "st", name = "check", tone = "success", title = "Finished while you were away" })
	elseif pane.state == "working" then
		return ui.node("spinner", { key = "st", style = "dots", tone = "success", aria = "Working", title = "Working" })
	elseif pane.state == "waiting" then
		return ui.el("div", { key = "st", role = "kai.pulse", title = "Waiting for you", aria = "Waiting for you" })
	end
	local look = STATE[pane.state]
	if look and look.value and pane.state ~= "idle" then
		return ui.node("text", { key = "st", spans = { ui.span(look.value, look.style) } })
	end
	return nil
end

-- `label` lets a single-pane tab row show the tab's own (possibly renamed) name.
local function paneRow(workspace, pane, menu, key, label, pick, what, moved, color)
	local look = STATE[pane.state] or STATE.none
	local tip = { pane.title }
	if pane.model then table.insert(tip, pane.program .. " · " .. pane.model) end
	table.insert(tip, pane.cwd)
	local children = {
		ui.node("item", {
			key = "i", grow = 1,
			label = label or pane.title,
			detail = if pane.lastMessage then pane.lastMessage else (pane.program:match("^(%S+)") or pane.program),
			icon = iconOf(pane),
			tone = look.tone,
			title = table.concat(tip, "\n"),
			actions = { click = "pane=" .. tostring(workspace.id) .. ":" .. tostring(pane.id), menu = menu },
		}),
	}
	local dot = colorDot(color)
	if dot then table.insert(children, 1, dot) end
	local ind = indicator(pane)
	if ind then table.insert(children, ind) end
	table.insert(children, quick("close", "x", "close=pane:" .. tostring(pane.id), "Close"))
	table.insert(children, grip(pick, what))
	return ui.node("row", { key = key, role = rowRole(pane.focused), mark = if moved then "drop" else nil }, children)
end

local function tabSection(workspace, wkey, tab)
	local items = {}
	local src = mv and mv.kind == "pane" and mv.tab == tab.id and indexOf(tab.panes, mv.id) or nil
	for i, pane in ipairs(tab.panes) do
		if slotAt(src, i) then table.insert(items, dropSlot("d" .. tostring(i), pane.id)) end
		table.insert(items, paneRow(workspace, pane, View.paneMenu(pane, true), "p" .. tostring(pane.id), nil,
			"pane:" .. tostring(pane.id), "pane", src ~= nil and pane.id == mv.id))
	end
	if slotAt(src, #tab.panes + 1) then table.insert(items, dropSlot("dend", 0)) end

	local look = STATE[tab.state or "none"] or STATE.none
	local spans = { ui.span(tab.name), ui.span("  " .. tostring(#tab.panes), "muted") }
	if tab.state == "waiting" or tab.state == "working" then
		table.insert(spans, ui.span("  " .. tab.state, look.style))
	end
	local key = "t" .. tostring(tab.id) .. "_" .. tostring(workspace.gen)
	local moved = mv and mv.kind == "tab" and mv.id == tab.id
	return ui.node("section", {
		key = key,
		head = parent .. wkey .. "." .. key .. ".head", collapsible = true, collapsed = not tab.open,
		role = "kai.tab", mark = if moved then "drop" else nil,
		actions = { menu = View.tabMenu(workspace, tab) },
	}, {
		ui.node("row", { key = "head", role = "kai.tabHead" }, (function()
			local parts = {}
			local dot = colorDot(tab.color)
			if dot then table.insert(parts, dot) end
			table.insert(parts, ui.node("text", { key = "name", spans = spans, grow = 1 }))
			if tab.unseen then table.insert(parts, ui.node("icon", { key = "un", name = "check", tone = "success", title = "Finished while you were away" })) end
			table.insert(parts, quick("close", "x", "close=tab:" .. tostring(tab.id), "Close tab"))
			table.insert(parts, grip("tab:" .. tostring(tab.id), "tab"))
			return parts
		end)()),
		ui.node("col", { key = "l", role = "kai.list" }, items),
	})
end

local function badge(key, text, tone, title)
	return ui.node("badge", { key = key, text = text, tone = tone, title = title })
end

local TILE_TONES = { "accent", "info", "success", "warning", "error", "user" }
View.TILE_TONES = TILE_TONES

-- A colored initial, picked from the name so a workspace keeps its color.
local function tile(workspace)
	local name = if workspace.name ~= "" then workspace.name else "?"
	local first = string.sub(name, 1, (utf8.offset(name, 2) or #name + 1) - 1)
	local hash = 0
	for i = 1, #name do hash = (hash * 31 + string.byte(name, i)) % 997 end
	local tone = workspace.tone or TILE_TONES[hash % #TILE_TONES + 1]
	if workspace.icon then
		return ui.node("row", { key = "tile", role = "kai.tile", tone = tone }, {
			ui.node("icon", { key = "ic", name = workspace.icon, tone = tone }),
		})
	end
	return ui.node("text", { key = "tile", role = "kai.tile", tone = tone, text = string.upper(first) })
end

local function plural(n, word)
	return tostring(n) .. " " .. word .. (if n == 1 then "" else "s")
end

-- The head is a child (drawn in the section's head row): tile, name over a short path (and a
-- one-line summary while folded), status pills at the right edge.
local function workspaceHead(workspace)
	local lines = {
		ui.node("text", { key = "name", spans = { ui.span(workspace.name, "strong") } }),
		ui.node("text", { key = "path", spans = { ui.span(workspace.crumb, "muted") }, title = workspace.fullPath }),
	}
	if not workspace.open then
		local bits = { plural(#workspace.tabs, "tab") }
		if workspace.waiting > 0 then table.insert(bits, tostring(workspace.waiting) .. " waiting") end
		if workspace.working > 0 then table.insert(bits, tostring(workspace.working) .. " working") end
		if workspace.branch then table.insert(bits, workspace.branch) end
		table.insert(lines, ui.node("text", { key = "sum", role = "kai.summary", spans = { ui.span(table.concat(bits, " · "), "muted") } }))
	end
	local children = { tile(workspace), ui.node("col", { key = "text", role = "kai.wsText", grow = 1, shrink = 1 }, lines) }
	if workspace.open then
		if workspace.waiting > 0 then
			table.insert(children, badge("waiting", tostring(workspace.waiting) .. " waiting", "accent", "Agents waiting for you"))
		end
		if workspace.working > 0 then
			table.insert(children, badge("working", tostring(workspace.working) .. " working", "success", "Agents working"))
		end
	end
	if workspace.ticket then
		table.insert(children, ui.node("badge", { key = "ticket", text = workspace.ticket, tone = "accent",
			title = "Open " .. workspace.ticket .. " in Linear", actions = { click = "ticket=" .. tostring(workspace.id) } }))
	end
	if workspace.pr then
		local PR_TONE = { open = "success", draft = "muted", merged = "accent", closed = "error" }
		table.insert(children, ui.node("badge", { key = "pr", text = "#" .. tostring(workspace.pr.number), tone = PR_TONE[workspace.pr.state] or "muted",
			title = "PR #" .. tostring(workspace.pr.number) .. " · " .. workspace.pr.state .. ". Click to open on GitHub",
			actions = { click = "url=" .. hex(workspace.pr.url or "") } }))
	end
	if workspace.locked then table.insert(children, ui.node("icon", { key = "lock", name = "lock", tone = "muted", title = "Locked" })) end
	if workspace.iced then table.insert(children, ui.node("icon", { key = "ice", name = "box", tone = "muted", title = "In the Ice Box" })) end
	table.insert(children, quick("newtab", "plus", "newtab=" .. tostring(workspace.id), "New tab here"))
	table.insert(children, grip("ws:" .. tostring(workspace.id), "workspace"))
	return ui.node("row", { key = "head", role = "kai.wsHead" }, children)
end


local VIEWS = {
	{ id = "agents", icon = "users", title = "Agents" },
	{ id = "files", icon = "files", title = "Files" },
	{ id = "changes", icon = "diff", title = "Changes" },
	{ id = "refs", icon = "branch", title = "Refs" },
}

-- Each view's count, shown on its button so a card's state reads without opening it.
local function viewCount(workspace, id)
	if id == "agents" then
		if workspace.waiting > 0 then return tostring(workspace.waiting), "accent" end
		if workspace.working > 0 then return tostring(workspace.working), "success" end
		if workspace.unseen > 0 then return "✓" .. tostring(workspace.unseen), "success" end
	elseif id == "changes" then
		if (workspace.changeCount or 0) > 0 then return tostring(workspace.changeCount), "warning" end
	elseif id == "refs" then
		local bits = {}
		if (workspace.ahead or 0) > 0 then table.insert(bits, "↑" .. tostring(workspace.ahead)) end
		if (workspace.behind or 0) > 0 then table.insert(bits, "↓" .. tostring(workspace.behind)) end
		if #bits > 0 then return table.concat(bits, ""), "info" end
	end
	return nil
end

local function viewBar(workspace)
	local buttons = {}
	for _, v in VIEWS do
		local parts = { ui.node("icon", { key = "ic", name = v.icon }) }
		local count, tone = viewCount(workspace, v.id)
		if count then table.insert(parts, ui.node("text", { key = "n", role = "kai.viewCount", tone = tone, text = count })) end
		table.insert(buttons, ui.node("row", {
			key = v.id, title = v.title, aria = v.title, grow = 1,
			role = if workspace.view == v.id then "kai.viewOn" else "kai.view",
			actions = { click = "view=" .. tostring(workspace.id) .. ":" .. v.id },
		}, parts))
	end
	return ui.node("row", { key = "views", role = "kai.views" }, buttons)
end

local function note(key, text)
	return ui.node("text", { key = key, role = "kai.note", spans = { ui.span(text, "muted") } })
end

local function fileRows(entries, rel)
	local rows = {}
	for _, e in entries do
		local k = "f" .. hex(e.path)
		if e.dir then
			table.insert(rows, ui.node("item", {
				key = k, label = e.name, icon = if e.open then "folder-open" else "folder", role = "kai.fileRow",
				actions = { click = "dir=" .. hex(e.path), menu = { M.copyPath, M.finder } },
			}))
			if e.open and e.children and #e.children > 0 then
				table.insert(rows, ui.node("col", { key = k .. "_k", role = "kai.indent" }, fileRows(e.children)))
			end
		else
			table.insert(rows, ui.node("item", {
				key = k, label = e.name, icon = "file", role = "kai.fileRow",
				actions = { click = "file=" .. hex(e.path), menu = { M.openFile, M.copyPath, M.finder } },
			}))
		end
	end
	return rows
end

local LETTER = { untracked = "A", added = "A", modified = "M", deleted = "D", renamed = "R", copied = "C", typechange = "T" }
local LETTER_TONE = { A = "success", M = "warning", D = "error", R = "info", C = "info", T = "warning" }

local function changeRows(root, files, side, menu)
	local rows = {}
	for _, f in files do
		local letter = LETTER[f[side] or ""] or "M"
		local name = f.path:match("([^/]+)$") or f.path
		local dir = f.path:match("^(.*)/[^/]+$")
		-- A submodule row is its pointer: the parent records a different commit than it had.
		if f.submodule then dir = "submodule" end
		table.insert(rows, ui.node("item", {
			key = "f" .. hex(root .. "/" .. f.path), label = name, detail = dir,
			icon = if f.submodule then "folder" else "file", role = "kai.fileRow",
			value = { ui.span(letter, LETTER_TONE[letter] or "muted") },
			title = if f.submodule then f.path .. "\nSubmodule: its checked-out commit differs from the one recorded here" else f.path,
			actions = { click = "file=" .. hex(root .. "/" .. f.path), menu = { menu, M.openFile, M.copyPath } },
		}))
	end
	return rows
end

local function heading(key, label, n)
	return ui.node("text", { key = key, role = "kai.heading", spans = { ui.span(string.upper(label), "muted"), ui.span("  " .. tostring(n), "muted") } })
end

-- Unstaged (conflicts first) and staged files of one repo.
local function statusBlock(root, st)
	local unstaged = {}
	for _, f in st.conflicts do table.insert(unstaged, f) end
	for _, f in st.unstaged do table.insert(unstaged, f) end
	local out = { heading("uh", "Unstaged", #unstaged) }
	if #unstaged > 0 then
		table.insert(out, ui.node("col", { key = "u", role = "kai.list" }, changeRows(root, unstaged, "unstaged", M.stage)))
	end
	table.insert(out, heading("sh", "Staged", #st.staged))
	if #st.staged > 0 then
		table.insert(out, ui.node("col", { key = "s", role = "kai.list" }, changeRows(root, st.staged, "staged", M.unstage)))
	else
		table.insert(out, note("snone", "Stage files to include them in the next commit"))
	end
	return out
end

local function drift(ahead, behind)
	local bits = {}
	if (ahead or 0) > 0 then table.insert(bits, "↑" .. tostring(ahead)) end
	if (behind or 0) > 0 then table.insert(bits, "↓" .. tostring(behind)) end
	return if #bits > 0 then table.concat(bits, " ") else nil
end

-- Local branches, then remote ones under their remote, of one repo.
local function refsBlock(branches)
	local locals, remotes = {}, {}
	for _, b in branches do
		if b.remote then
			remotes[b.remote] = remotes[b.remote] or {}
			table.insert(remotes[b.remote], b)
		else
			table.insert(locals, b)
		end
	end
	local function branchRow(b, label)
		return ui.node("item", {
			key = "b" .. hex(b.name), label = label or b.name,
			icon = if b.current then "check" else "branch", tone = if b.current then "success" else nil,
			value = drift(b.ahead, b.behind),
			role = "kai.fileRow", title = b.name .. (if b.upstream then "\n→ " .. b.upstream else ""),
			actions = { menu = if b.current then nil else { M.checkout } },
		})
	end
	local out = { heading("bh", "Branches", #locals) }
	local rows = {}
	for _, b in locals do table.insert(rows, branchRow(b)) end
	table.insert(out, ui.node("col", { key = "b", role = "kai.list" }, rows))
	local names = {}
	for remote in remotes do table.insert(names, remote) end
	table.sort(names)
	if #names > 0 then
		local n = 0
		for _, r in names do n += #remotes[r] end
		table.insert(out, heading("rh", "Remotes", n))
		for _, r in names do
			local rrows = {}
			for _, b in remotes[r] do table.insert(rrows, branchRow(b, b.name:sub(#r + 2))) end
			table.insert(out, ui.node("text", { key = "r" .. hex(r), role = "kai.remote", spans = { ui.span(r) } }))
			table.insert(out, ui.node("col", { key = "rl" .. hex(r), role = "kai.indent" }, rrows))
		end
	end
	return out
end

-- One repo of a monorepo: a foldable section headed by its path, branch and count or drift.
local function repoSection(wkey, group, value, collapsed, body)
	local key = "g" .. hex(group.root)
	local spans = { ui.span(group.name) }
	if group.submodule then table.insert(spans, ui.span("  submodule", "muted")) end
	if group.branch then table.insert(spans, ui.span("  " .. group.branch, "muted")) end
	return ui.node("section", {
		key = key, head = parent .. wkey .. "." .. key .. ".head", collapsible = true, collapsed = collapsed,
		role = "kai.tab", title = group.root,
	}, {
		ui.node("row", { key = "head", role = "kai.tabHead" }, {
			ui.node("icon", { key = "ic", name = "folder", tone = "muted" }),
			ui.node("text", { key = "name", spans = spans, grow = 1 }),
			value or ui.node("text", { key = "v", text = "" }),
		}),
		ui.node("col", { key = "l" }, body),
	})
end

-- Several repos (a monorepo): Changes lists those with changes and names the clean ones;
-- Refs lists every repo, the workspace's own open and the nested ones folded.
local function reposBody(workspace, wkey)
	local out = {}
	if workspace.view == "changes" then
		local clean = {}
		for _, g in workspace.repos do
			if not g.status then
				table.insert(out, repoSection(wkey, g, nil, false, { note("loading", "Loading…") }))
			elseif g.count == 0 then
				table.insert(clean, g.name)
			else
				local count = ui.node("text", { key = "v", role = "kai.viewCount", tone = "warning", text = tostring(g.count) })
				table.insert(out, repoSection(wkey, g, count, false, statusBlock(g.root, g.status)))
			end
		end
		if #clean > 0 then
			table.insert(out, ui.node("text", { key = "clean", role = "kai.note", title = table.concat(clean, "\n"),
				spans = { ui.span(plural(#clean, "clean repo") .. ": " .. table.concat(clean, ", "), "muted") } }))
		end
		return out
	end
	for i, g in workspace.repos do
		local d = drift(g.ahead, g.behind)
		local value = d and ui.node("text", { key = "v", role = "kai.viewCount", tone = "info", text = d }) or nil
		local body = if g.branches then refsBlock(g.branches) else { note("loading", "Loading…") }
		table.insert(out, repoSection(wkey, g, value, i > 1, body))
	end
	return out
end

-- Tern's Files, Changes and Refs panels, redrawn from the same data with Tern's own parts.
local function viewBody(workspace, wkey)
	if workspace.view == "files" then
		if not workspace.files then return { note("loading", "Loading…") } end
		if #workspace.files == 0 then return { note("empty", "Empty folder") } end
		local rows = fileRows(workspace.files)
		if workspace.filesMore then table.insert(rows, note("more", "More files not shown")) end
		return { ui.node("col", { key = "files", role = "kai.list" }, rows) }
	end
	if not workspace.repo then return { note("norepo", "Not a git repository") } end
	if workspace.repos then return reposBody(workspace, wkey) end
	if workspace.view == "changes" then
		if not workspace.status then return { note("loading", "Loading…") } end
		return statusBlock(workspace.root, workspace.status)
	end
	if not workspace.branches then return { note("loading", "Loading…") } end
	return refsBlock(workspace.branches)
end

local function workspaceSection(workspace)
	local key = "w" .. tostring(workspace.id) .. "_" .. tostring(workspace.gen)

	-- Single-pane tabs are rows of one column; a tab with several panes is its own section.
	local body, run, n = {}, {}, 0
	local function flush()
		if #run == 0 then return end
		n += 1
		table.insert(body, ui.node("col", { key = "l" .. tostring(n), role = "kai.list" }, run))
		run = {}
	end
	local src = mv and mv.kind == "tab" and mv.ws == workspace.id and indexOf(workspace.tabs, mv.id) or nil
	for i, tab in ipairs(workspace.tabs) do
		if slotAt(src, i) then table.insert(run, dropSlot("d" .. tostring(tab.id), tab.id)) end
		if #tab.panes == 1 then
			local pane = tab.panes[1]
			table.insert(run, paneRow(workspace, pane, merged(View.tabMenu(workspace, tab), View.paneMenu(pane, false)),
				"t" .. tostring(tab.id) .. ".p" .. tostring(pane.id), tab.name,
				"tab:" .. tostring(tab.id), "tab", src ~= nil and tab.id == mv.id, tab.color))
		else
			flush()
			table.insert(body, tabSection(workspace, key, tab))
		end
	end
	if slotAt(src, #workspace.tabs + 1) then table.insert(run, dropSlot("dend", 0)) end
	flush()
	if #body == 0 then table.insert(body, ui.text({ ui.span("No tabs", "muted") })) end
	if workspace.view ~= "agents" then body = viewBody(workspace, key) end
	table.insert(body, 1, viewBar(workspace))
	table.insert(body, 1, workspaceHead(workspace))

	local moved = mv and mv.kind == "ws" and mv.id == workspace.id
	return ui.node("section", {
		key = key,
		head = parent .. key .. ".head", collapsible = true, collapsed = not workspace.open,
		role = "kai.workspace", mark = if moved then "drop" else nil,
		actions = { menu = View.workspaceMenu(workspace) },
	}, body)
end

local HOST_STATE = {
	connected = { tone = "success", text = nil },
	connecting = { tone = "warning", text = "connecting" },
	reconnecting = { tone = "warning", text = "reconnecting" },
	stalled = { tone = "warning", text = "stalled" },
	verify = { tone = "warning", text = "verify key" },
	failed = { tone = "error", text = "failed" },
}


-- A machine: a foldable section headed like the view labels (state dot, the host's own name,
-- latency or link state, workspace count, + to add a host), holding its workspaces.
local function hostSection(h, body)
	local look = HOST_STATE[h.state] or HOST_STATE.connecting
	local spans = { ui.span(string.upper(h.name), if h.current then nil else "muted") }
	if look.text then
		table.insert(spans, ui.span(" · " .. look.text, look.tone))
	elseif h.remote and h.rtt then
		table.insert(spans, ui.span(" · " .. tostring(math.floor(h.rtt + 0.5)) .. " ms", "muted"))
	end
	local menu = { M.switchHost, M.newOnHost, M.addHost }
	if h.remote then table.insert(menu, M.disconnectHost) end
	local key = "h" .. tostring(h.id)
	if #body == 0 then table.insert(body, note("none", "No sessions")) end
	return ui.node("section", {
		key = key, head = ROOT .. key .. ".head", collapsible = true, collapsed = false,
		role = "kai.host", actions = { menu = menu },
	}, {
		ui.node("row", {
			key = "head", role = "kai.hostHead",
			title = h.name .. (if h.remote then " (remote)" else " (this machine)") .. (if h.error then "\n" .. h.error else ""),
		}, {
			ui.node("text", { key = "dot", spans = { ui.span("●", look.tone) }, role = "kai.hostDot" }),
			ui.node("text", { key = "name", spans = spans, grow = 1, role = "kai.hostName",
				actions = { click = "host=" .. tostring(h.id) } }),
			ui.node("text", { key = "n", text = tostring(h.count), tone = "muted" }),
			ui.node("icon", { key = "add", name = "plus", tone = "muted", title = "Add remote host", aria = "Add remote host",
				actions = { click = "addhost" } }),
		}),
		ui.node("col", { key = "l", role = "kai.hostBody" }, body),
	})
end

local SIZES = { compact = M.sizeCompact, standard = M.sizeStandard, spacious = M.sizeSpacious }

-- The header menu, plus the two sizes not in use.
local function sizeMenu(model, menu)
	for _, id in { "compact", "standard", "spacious" } do
		if id ~= model.size then table.insert(menu, SIZES[id]) end
	end
	return menu
end

function View.render(model)
	mv = model.moving
	local children = {
		ui.node("row", { key = "header", role = "kai.header",
			actions = { menu = sizeMenu(model, { M.newWs, M.expandAll, M.collapseAll, if model.sound then M.noSound else M.sound }) } }, {
			ui.node("text", { key = "title", text = "WORKSPACES", tone = "muted", grow = 1 }),
			ui.node("icon", { key = "filter", name = "search", tone = if model.filter then "accent" else "muted",
				title = "Filter workspaces, tabs and panes", aria = "Filter", actions = { click = "filter" } }),
			model.iceCount > 0 and ui.node("row", { key = "ice", role = if model.showIce then "kai.iceOn" else "kai.ice",
				title = (if model.showIce then "Hide" else "Show") .. " the Ice Box", actions = { click = "icebox" } }, {
				ui.node("icon", { key = "ic", name = "box" }),
				ui.node("text", { key = "n", text = tostring(model.iceCount) }),
			}) or ui.node("text", { key = "ice", text = "" }),
			ui.node("icon", { key = "new", name = "plus", tone = "muted", title = "New workspace from a folder", aria = "New workspace", actions = { click = "new" } }),
		}),
	}
	if model.filter then
		table.insert(children, ui.node("row", { key = "filtering", role = "kai.movingBar" }, {
			ui.node("text", { key = "what", grow = 1, spans = { ui.span("Filter ", "muted"), ui.span(model.filter, "strong") } }),
			ui.node("item", { key = "clear", label = "Clear", icon = "x", actions = { click = "clearfilter" } }),
		}))
		if #model.workspaces == 0 then
			table.insert(children, ui.node("text", { key = "nomatch", role = "kai.note", spans = { ui.span("Nothing matches", "muted") } }))
		end
	end
	if mv then
		table.insert(children, ui.node("row", { key = "moving", role = "kai.movingBar" }, {
			ui.node("text", { key = "what", grow = 1, spans = { ui.span("Moving ", "muted"), ui.span(mv.name, "strong") } }),
			ui.node("item", { key = "cancel", label = "Cancel", icon = "x", actions = { click = "cancelmove" } }),
		}))
	end
	local src = mv and mv.kind == "ws" and indexOf(model.workspaces, mv.id) or nil
	-- Workspaces with their drop slots, into the host section they belong to (or the root).
	local byHost, loose = {}, children
	for i, workspace in ipairs(model.workspaces) do
		local into = loose
		if model.hosts and workspace.host ~= nil then
			byHost[workspace.host] = byHost[workspace.host] or {}
			into = byHost[workspace.host]
		end
		parent = if into == loose then ROOT else ROOT .. "h" .. tostring(workspace.host) .. ".l."
		if slotAt(src, i) then table.insert(into, dropSlot("d" .. tostring(workspace.id), workspace.id)) end
		table.insert(into, workspaceSection(workspace))
	end
	parent = ROOT
	if model.hosts then
		for _, h in model.hosts do
			table.insert(children, hostSection(h, byHost[h.id] or {}))
		end
	end
	if slotAt(src, #model.workspaces + 1) then table.insert(children, dropSlot("dend", 0)) end
	if model.version then
		table.insert(children, ui.node("text", { key = "version", role = "kai.version",
			spans = { ui.span("Kai " .. model.version, "muted") } }))
	end
	-- The size wrapper only carries a role: styles.css tightens spacing beneath kai.compact/kai.standard.
	return ui.node("col", { key = "s", role = "kai." .. model.size }, {
		ui.node("col", { key = "kai", role = "kai.root" }, children),
	})
end

return View
