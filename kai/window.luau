--!nonstrict
-- Kai: every Tern session as a workspace, its tabs and panes nested, with agent state.
local view = require("./view")

local TITLE = "Workspaces"
local ABOUT = "Every Tern session as a workspace, with its tabs, panes and agent state."
local GIT_REFRESH_MS = 15000

-- Tern gives every callback 50 ms and disables a hook after one overrun, so clicks and
-- async results never draw inline: they call redraw(), which draws in its own timer.
local rendered = {}
local problem
local git = {} -- folder -> { repo, root, status, branches, at, inflight }

local function report(cx, text)
	problem = tostring(text)
	tern.log.warn("kai: " .. problem)
	cx:toast("error", "Kai", if #problem <= 60 then problem else "See Tern's log for details.")
end

local function records(key)
	local value = tern.kv.get(key)
	return if type(value) == "table" then value else {}
end

local function localHost(cx)
	return cx.hosts:current().kind == "local"
end

-- Whether a session lives on a remote host.
local function isRemote(cx, sessionId)
	local hostId
	for _, s in cx.sessions:list() do
		if s.id == sessionId then hostId = s.host end
	end
	for _, h in cx.hosts:list() do
		if h.id == hostId then return h.kind == "remote" end
	end
	return false
end

-- Agent CLIs recognised in plain terminals, by program name.
local AGENTS = {
	omp = true, pi = true, claude = true, codex = true, opencode = true, gemini = true,
	aider = true, amp = true, ["cursor-agent"] = true, crush = true, goose = true,
}

-- The agent a shell command line runs ("omp", "cd x && claude", "FOO=1 codex"), or nil.
local function agentOf(line)
	for segment in string.gmatch(line, "[^;&|]+") do
		for word in string.gmatch(segment, "%S+") do
			if not string.find(word, "=", 1, true) then
				local name = string.match(word, "([^/]+)$")
				if AGENTS[name] then return name end
				break
			end
		end
	end
	return nil
end

local function tildePath(path)
	local home = tern.getenv("HOME")
	if home and path:sub(1, #home) == home then return "~" .. path:sub(#home + 1) end
	return path
end

local function basename(path)
	return path:match("([^/]+)/*$") or path
end

-- One pane's display state. Native agent blocks report it; agent CLIs in terminals only
-- report progress through `busy`.
local RANK = { waiting = 5, working = 4, running = 3, idle = 2, shell = 1, exited = 0 }
local function paneState(pane, agents)
	local agent = agents[pane.pane]
	if agent then
		local state = if agent.state == "waiting_input" then "waiting" else agent.state
		-- Native agent blocks are omp; optional fields may be tern.json.null, so check types.
		local name = if type(agent.command) == "string" then agentOf(agent.command) or agent.command else "omp"
		if type(agent.model) == "string" and agent.model ~= "" then name = name .. " · " .. agent.model end
		return state, name
	end
	if pane.kind ~= "terminal" and pane.kind ~= "agent" then
		return "none", pane.kind or "block"
	end
	if pane.exited then return "exited", pane.program or "shell" end
	local line = pane.running and pane.running.line
	local cli = line and agentOf(line)
	if cli then return (if pane.busy then "working" else "idle"), cli end
	if line then return "running", pane.program or "shell" end
	return "shell", pane.program or "shell"
end

local function paneTitle(pane, program)
	if pane.title and pane.title ~= "" then return pane.title end
	if pane.running then return pane.running.line end
	if pane.path then return basename(pane.path) end
	return program
end

-- One Workspaces canvas per tab (like every working Tern sidebar), kept as the tab's
-- full-height left column. Returns the set of our panes and tab -> pane, closing
-- duplicates and parked leftovers.
local function ours(cx)
	local set, byTab = {}, {}
	for _, canvas in cx.canvas:list() do
		if canvas.owner == "kai" and canvas.title == TITLE then
			local tab = cx.session:tab_of(canvas.pane)
			if tab and not byTab[tab] then
				byTab[tab], set[canvas.pane] = canvas.pane, true
			elseif cx.session:pane(canvas.pane) then
				cx.layout:close(canvas.pane)
				rendered[canvas.pane] = nil
			end
		end
	end
	return set, byTab
end

local redraw -- defined below
local restartTick -- defined below

-- One overrun (a sleep/wake or load stall is enough) makes Tern disable every timer of this plugin
-- until reload, and tern.timer keeps returning as if nothing happened. The 750 ms tick is the canary:
-- an event arriving while it is long overdue means timers are dead, and from then on deferred work
-- runs in process callbacks, a separate hook.
local lastTick = tern.now()
local timersDead = false

-- True when this call noticed the timers died.
local function checkTimers()
	if timersDead or tern.now() - lastTick < 3000 then return false end
	timersDead = true
	tern.log.warn("kai: Tern disabled this plugin's timers after a budget overrun; deferring through processes until reload")
	restartTick()
	return true
end

local function later(ms, fn)
	checkTimers()
	if timersDead then
		tern.process.run({ "/bin/sleep", string.format("%.3f", ms / 1000) }, { timeout_ms = ms + 5000 },
			function(_result, cx) fn(cx) end)
	else
		tern.timer(ms, fn)
	end
end

local function refreshGit(folder, force)
	local entry = git[folder]
	if entry and (entry.inflight or (not force and tern.now() - entry.at < GIT_REFRESH_MS)) then return end
	entry = entry or {}
	entry.inflight, entry.at = true, tern.now()
	git[folder] = entry
	later(0, function(cx)
		if not cx then entry.inflight = false; return end
		local ok = pcall(function()
			cx.git:repo(folder):next(function(repo, err, nextCx)
				if err or not repo or not nextCx then
					entry.inflight, entry.repo, entry.root, entry.status, entry.branches = false, false, nil, nil, nil
					return
				end
				entry.repo, entry.root = true, repo.root
				local pending = 2
				local function done()
					pending -= 1
					if pending == 0 then
						entry.inflight = false
						redraw()
					end
				end
				nextCx.git:status(repo):next(function(status) entry.status = status; done() end)
				nextCx.git:branches(repo):next(function(branches) entry.branches = branches; done() end)
			end)
		end)
		if not ok then entry.inflight = false end
	end)
end

-- Files view: folders you opened (absolute path -> true). Folder contents come from an async
-- `ls -1Ap` (a trailing "/" marks folders), cached per folder, so a draw never touches the disk.
local expanded = {}
local listing = {} -- folder -> { entries = {{name, dir}}, at } or { pending = true }
local FILE_LIMIT = 300
local LIST_TTL_MS = 10000
local HIDDEN = { [".git/"] = true, [".DS_Store"] = true }

local function listDir(dir)
	local hit = listing[dir]
	if hit and (hit.pending or tern.now() - hit.at < LIST_TTL_MS) then return hit.entries end
	local stale = hit and hit.entries
	listing[dir] = { pending = true, entries = stale }
	tern.process.run({ "/bin/ls", "-1Ap", dir }, { timeout_ms = 5000 }, function(result)
		local entries = {}
		if result and result.status == 0 then
			for line in string.gmatch(result.stdout or "", "[^\n]+") do
				if not HIDDEN[line] then
					local isDir = line:sub(-1) == "/"
					table.insert(entries, { name = if isDir then line:sub(1, -2) else line, dir = isDir })
				end
			end
			table.sort(entries, function(a, b)
				if a.dir ~= b.dir then return a.dir end
				return a.name:lower() < b.name:lower()
			end)
		end
		listing[dir] = { entries = entries, at = tern.now() }
		if redraw then redraw() end
	end)
	return stale
end

-- Monorepos: repos nested under a workspace (independent clones or submodules), found with one
-- `find` and cached, so a workspace opened at the root still shows every repo its agents touch.
local nested = {} -- folder -> { repos = { absolute path }, at } or { pending = true, repos }
local submodules = {} -- repo root -> true when its .git is a file (a submodule's gitdir pointer)
local NESTED_TTL_MS = 60000
local NESTED_MAX = 30
local PRUNE = { "node_modules", ".build", "build", "dist", "target", "Library", "Temp", "obj", ".venv", "vendor", "Pods", "DerivedData" }

local function nestedRepos(folder)
	if folder == "/" or folder == tern.getenv("HOME") then return nil end
	local hit = nested[folder]
	if hit and (hit.pending or tern.now() - hit.at < NESTED_TTL_MS) then return hit.repos end
	local stale = hit and hit.repos
	nested[folder] = { pending = true, repos = stale }
	local argv = { "/usr/bin/find", folder, "-maxdepth", "4", "(" }
	for i, name in PRUNE do
		if i > 1 then table.insert(argv, "-o") end
		table.insert(argv, "-name")
		table.insert(argv, name)
	end
	for _, arg in { ")", "-prune", "-o", "-name", ".git", "-print" } do table.insert(argv, arg) end
	-- find exits non-zero on an unreadable folder; what it printed still holds.
	tern.process.run(argv, { timeout_ms = 10000 }, function(result)
		local repos = {}
		for line in string.gmatch(result and result.stdout or "", "[^\n]+") do
			local dir = line:match("^(.*)/%.git$")
			if dir and dir ~= folder and #repos < NESTED_MAX then
				table.insert(repos, dir)
				-- Listing a file raises: a .git file marks a submodule (or a linked worktree).
				submodules[dir] = not pcall(tern.fs.list, line) or nil
			end
		end
		table.sort(repos)
		nested[folder] = { repos = repos, at = tern.now() }
		if redraw then redraw() end
	end)
	return stale
end

-- The tree under `root` from cached listings; nil while the root's first listing runs.
local function fileTree(root)
	local count = 0
	local function walk(dir)
		local entries = listDir(dir)
		if not entries then return nil end
		local out = {}
		for _, e in entries do
			count += 1
			if count > FILE_LIMIT then break end
			local node = { name = e.name, path = dir .. "/" .. e.name, dir = e.dir }
			if e.dir then
				node.open = expanded[node.path] == true
				if node.open then node.children = walk(node.path) or {} end
			end
			table.insert(out, node)
		end
		return out
	end
	local tree = walk(root)
	return tree, count > FILE_LIMIT
end

-- What the user picked up to move: { kind = "ws"|"tab"|"pane", id, ws, tab, name }.
local moving = nil

-- A tab's leaves in layout order (left-to-right, top-to-bottom), as pane id -> index.
local function leafIndex(cx, tab)
	local layout = cx.session:layout(tab)
	local index, n = {}, 0
	local function walk(tree)
		if not tree then return end
		if tree.pane then n += 1; index[tree.pane] = n; return end
		walk(tree[1]); walk(tree[2])
	end
	walk(layout and layout.root)
	return index
end

-- An agent's last reply as one short line (fields may be tern.json.null).
local function lastLine(text)
	if type(text) ~= "string" then return nil end
	-- Harness placeholders ("[System: …]") say nothing about the agent's work.
	if text:match("^%s*%[System:") then return nil end
	local line = text:gsub("[*_`#>]", ""):gsub("%s+", " "):match("^%s*(.-)%s*$")
	if line == "" then return nil end
	if #line > 90 then line = line:sub(1, (utf8.offset(line, 88) or 89) - 1) .. "…" end
	return line
end

-- "~/Desktop/Work/A/B" -> "A › B": the two folders that name the place.
local function crumb(path)
	local home = tern.getenv("HOME")
	if path == home then return "~" end
	local parts = {}
	for part in string.gmatch(path, "[^/]+") do table.insert(parts, part) end
	if #parts >= 2 then return parts[#parts - 1] .. " › " .. parts[#parts] end
	return parts[1] or path
end

-- Agent/command state per pane last time we looked, and what finished while you were elsewhere.
local lastState = {} -- pane -> state
-- pane -> "done" | "failed"; saved, so a plugin reload keeps what you haven't seen yet.
local unseen = (function()
	local saved = tern.kv.get("unseen")
	local out = {}
	if type(saved) == "table" then
		for k, v in saved do
			local id = tonumber(k)
			if id then out[id] = v end
		end
	end
	return out
end)()
local unseenKey = ""
local filter = nil -- the sidebar filter text, or nil
local attention = {} -- panes that need you, most urgent first: { ws, pane }
local visibleOrder = {} -- workspace ids in sidebar order
local statusKey = ""
local statusInfo = { name = "Workspaces", waiting = 0 }

local function notify(cx, kind, title)
	local text = if kind == "done" then "Finished" elseif kind == "failed" then "Command failed" else "Waiting for you"
	pcall(function() cx:toast(if kind == "failed" then "error" else "info", title, text) end)
	if tern.kv.get("sound") == true then
		local sound = if kind == "waiting" then "Ping" elseif kind == "failed" then "Basso" else "Glass"
		tern.process.run({ "/usr/bin/afplay", "/System/Library/Sounds/" .. sound .. ".aiff" }, { timeout_ms = 5000 }, function() end)
	end
end

-- Pull requests per repo root, from `gh` (best effort: no gh, no badge), refreshed every 2 min.
local prs = {} -- root -> { at, inflight, byBranch }
local PR_TTL_MS = 120000
local CHILD_ENV = { PATH = "/opt/homebrew/bin:/usr/local/bin:" .. (tern.getenv("PATH") or "/usr/bin:/bin") }
local GH = (function()
	for _, p in { "/opt/homebrew/bin/gh", "/usr/local/bin/gh" } do
		if tern.fs.exists(p) then return p end
	end
	return nil
end)()

local function prFor(root, branch)
	if not GH or not root or not branch then return nil end
	local entry = prs[root]
	if not entry or (not entry.inflight and tern.now() - entry.at > PR_TTL_MS) then
		entry = entry or { byBranch = {} }
		entry.inflight, entry.at = true, tern.now()
		prs[root] = entry
		tern.process.run({ GH, "pr", "list", "--state", "all", "--limit", "40", "--json", "number,state,isDraft,headRefName,url" },
			{ timeout_ms = 15000, cwd = root, env = CHILD_ENV }, function(result)
				entry.inflight = false
				if result and result.status == 0 then
					local ok, list = pcall(tern.json.decode, result.stdout or "[]")
					if ok and type(list) == "table" then
						local by = {}
						for _, pr in list do
							if type(pr) == "table" and type(pr.headRefName) == "string" and not by[pr.headRefName] then
								by[pr.headRefName] = {
									number = pr.number, url = pr.url,
									state = if pr.isDraft == true and pr.state == "OPEN" then "draft" else string.lower(pr.state or ""),
								}
							end
						end
						entry.byBranch = by
						if redraw then redraw() end
					end
				end
			end)
	end
	return entry.byBranch[branch]
end

local function ticketOf(branch)
	return branch and string.match(branch, "%f[%w](%u[%u%d]*%-%d+)%f[%W]")
end

-- A repo's status as its group shows it: untracked folders that are nested repos are dropped (they
-- get groups of their own), and a submodule's pointer change is marked as such.
local function annotate(status, root, roots)
	local rels = {}
	for _, r in roots do
		if r:sub(1, #root + 1) == root .. "/" then rels[r:sub(#root + 2)] = r end
	end
	if next(rels) == nil then return status end
	local function isNested(path)
		path = path:gsub("/$", "")
		for rel in rels do
			if path == rel or path:sub(1, #rel + 1) == rel .. "/" then return true end
		end
		return false
	end
	local function mark(list)
		local out = {}
		for _, f in list do
			if f.unstaged == "untracked" and isNested(f.path) then continue end
			if rels[f.path] and submodules[rels[f.path]] then
				f = table.clone(f)
				f.submodule = true
			end
			table.insert(out, f)
		end
		return out
	end
	return { staged = mark(status.staged), unstaged = mark(status.unstaged), conflicts = status.conflicts }
end

local function countChanges(st)
	local seen, n = {}, 0
	for _, list in { st.staged, st.unstaged, st.conflicts } do
		for _, f in list do
			if not seen[f.path] then seen[f.path], n = true, n + 1 end
		end
	end
	return n
end

-- The repos a workspace reaches: the one its folder is in, then those nested below that repo's root
-- (or below the folder when it is in none). Status and branches ride along only for `view`.
local function repoGroups(folder, entry, view)
	local base = if entry and entry.repo then entry.root else folder
	local roots, entries = {}, {}
	if entry and entry.repo then
		table.insert(roots, entry.root)
		entries[entry.root] = entry
	end
	-- Only once the first git read answered, so the root is known before looking below it.
	if entry and entry.repo ~= nil then
		for _, r in (nestedRepos(base) or {}) do
			refreshGit(r)
			if not (git[r] and git[r].repo == false) then
				table.insert(roots, r)
				entries[r] = git[r]
			end
		end
	end
	local groups = {}
	for _, r in roots do
		local e = entries[r]
		local g = {
			root = r, name = if r == base then (r:match("([^/]+)$") or r) else r:sub(#base + 2),
			count = 0, ahead = 0, behind = 0, submodule = submodules[r],
		}
		local st = e and e.status
		if st then st = annotate(st, r, roots) end
		if st then g.count = countChanges(st) end
		for _, b in (e and e.branches or {}) do
			if b.current then g.branch, g.ahead, g.behind = b.name, b.ahead or 0, b.behind or 0 end
		end
		if view == "changes" then g.status = st end
		if view == "refs" then g.branches = e and e.branches end
		table.insert(groups, g)
	end
	return groups, base
end

local SIZE_IDS = { compact = true, standard = true, spacious = true }

-- The version in plugin.toml, the one `tern plugin list` shows too (relative paths are the plugin dir).
local VERSION = (function()
	local ok, manifest = pcall(tern.fs.read, "plugin.toml")
	return ok and manifest:match('\nversion%s*=%s*"([^"]+)"') or nil
end)()

local function model(cx)
	local own = ours(cx)
	local agents = {}
	for _, agent in cx.agents:list() do agents[agent.pane] = agent end
	local focused = cx.session:focused()

	local panesByTab = {}
	for _, pane in cx.session:panes() do
		if pane.tab and not pane.parked and not own[pane.pane] then
			panesByTab[pane.tab] = panesByTab[pane.tab] or {}
			table.insert(panesByTab[pane.tab], pane)
		end
	end
	local tabsById = {}
	for _, tab in cx.session:tabs() do tabsById[tab.id] = tab end

	local current = cx.sessions:current()
	-- Hosts by id, and each session's host: one header per machine once more than one is attached.
	local hosts, hostOrder, sessionHost = {}, {}, {}
	for _, h in cx.hosts:list() do
		hosts[h.id] = h
		table.insert(hostOrder, h.id)
	end
	for _, s in cx.sessions:list() do sessionHost[s.id] = s.host end
	local openState = records("open")
	local tabOpen = records("tab-open")
	local workspaces = {}
	local waitingList, failedList, doneList = {}, {}, {}
	local icebox = records("icebox")
	for _, session in cx.session:sessions() do
		local key = tostring(session.id)
		local workspace = {
			id = session.id, name = session.name, current = session.id == current.id,
			locked = session.locked, tabCount = #session.tabs, tabs = {}, waiting = 0, working = 0, unseen = 0,
		}
		local folder
		for _, tabId in session.tabs do
			local info = tabsById[tabId]
			local panes = panesByTab[tabId] or {}
			local order = leafIndex(cx, tabId)
			table.sort(panes, function(a, b) return (order[a.pane] or 1e9) < (order[b.pane] or 1e9) end)
			local tab = {
				id = tabId, panes = {}, position = info and info.position or 1,
				current = workspace.current and focused ~= nil and cx.session:tab_of(focused) == tabId,
			}
			local best, lead = nil, nil
			for _, pane in panes do
				local state, program = paneState(pane, agents)
				if state == "waiting" then workspace.waiting += 1 end
				if state == "working" then workspace.working += 1 end
				if RANK[state] and (not best or RANK[state] > RANK[best]) then best = state end
				if not folder and pane.cwd and pane.cwd ~= "" then folder = pane.cwd end
				local prev = lastState[pane.pane]
				lastState[pane.pane] = state
				local label = paneTitle(pane, program)
				if pane.pane == focused or tab.current then
					unseen[pane.pane] = nil
				elseif prev == "working" and state ~= "working" and state ~= "waiting" then
					unseen[pane.pane] = "done"
					notify(cx, "done", label)
				elseif prev == "running" and state ~= "running" and pane.last and pane.last.status ~= 0 then
					unseen[pane.pane] = "failed"
					notify(cx, "failed", label)
				elseif prev and prev ~= "waiting" and state == "waiting" then
					notify(cx, "waiting", label)
				end
				if unseen[pane.pane] then workspace.unseen += 1; tab.unseen = true end
				if state == "waiting" then table.insert(waitingList, { ws = session.id, pane = pane.pane })
				elseif unseen[pane.pane] == "failed" then table.insert(failedList, { ws = session.id, pane = pane.pane })
				elseif unseen[pane.pane] == "done" then table.insert(doneList, { ws = session.id, pane = pane.pane }) end
				local row = {
					id = pane.pane, state = state, program = program, unseen = unseen[pane.pane],
					title = paneTitle(pane, program), cwd = tildePath(pane.cwd or ""), path = pane.cwd or "",
					focused = pane.pane == focused, native = agents[pane.pane] ~= nil,
					lastMessage = lastLine(agents[pane.pane] and agents[pane.pane].last_message),
					model = agents[pane.pane] and type(agents[pane.pane].model) == "string" and agents[pane.pane].model or nil,
				}
				if not lead or (info and pane.pane == info.pane) then lead = row end
				table.insert(tab.panes, row)
			end
			if #panes > 0 then
				tab.state = if best == "waiting" or best == "working" then best else nil
				tab.color = info and info.color
				tab.name = if info and info.name and info.name ~= "" then info.name
					elseif lead then lead.title else "Tab " .. tostring(info and info.position or "")
				local stored = tabOpen[tostring(tabId)]
				tab.open = if stored == nil then true else stored
				table.insert(workspace.tabs, tab)
			end
		end
		folder = folder or (tern.getenv("HOME") or "/")
		workspace.fullPath = folder
		workspace.path = tildePath(folder)
		workspace.crumb = crumb(folder)
		local stored = openState[key]
		workspace.open = if stored == nil then true else stored
		workspace.gen = tonumber(tern.kv.get("gen")) or 0
		workspace.iced = icebox[key] == true
		local style = records("ws-style")[key]
		if type(style) == "table" then workspace.icon, workspace.tone = style.icon, style.tone end
		local host = hosts[sessionHost[session.id] or 0]
		workspace.host = host and host.id
		-- A remote session's folder is on another machine: local git, ls and gh would read the
		-- wrong disk, so its Files, Changes and Refs open Tern's own panels on that host instead.
		workspace.remote = host ~= nil and host.kind == "remote"
		workspace.view = if workspace.remote then "agents" else (records("ws-view")[key] or "agents")
		if not workspace.remote then
			local entry = git[folder]
			refreshGit(folder)
			local groups, base = repoGroups(folder, entry, if workspace.open then workspace.view else nil)
			workspace.root = base
			workspace.repo = #groups > 0
			if #groups > 0 then
				local total, ahead, behind = 0, 0, 0
				for _, g in groups do total, ahead, behind = total + g.count, ahead + g.ahead, behind + g.behind end
				workspace.changeCount, workspace.ahead, workspace.behind = total, ahead, behind
			end
			-- Branch, ticket and PR come from the repo the folder is in, not from nested ones.
			if entry and entry.repo and groups[1] then workspace.branch = groups[1].branch end
			if workspace.branch then
				workspace.pr = prFor(workspace.root, workspace.branch)
				workspace.ticket = ticketOf(workspace.branch)
			end
			if #groups == 1 then
				workspace.status, workspace.branches = groups[1].status, groups[1].branches
			elseif #groups > 1 then
				workspace.repos = groups
			end
			if workspace.open and workspace.view == "files" then
				workspace.files, workspace.filesMore = fileTree(workspace.root)
			end
		end
		local keep = true
		if filter then
			local q = filter:lower()
			local function hit(text) return type(text) == "string" and text:lower():find(q, 1, true) ~= nil end
			if not (hit(workspace.name) or hit(workspace.fullPath)) then
				local kept = {}
				for _, t in workspace.tabs do
					local match = hit(t.name)
					for _, p in t.panes do
						if hit(p.title) or hit(p.program) then match = true end
					end
					if match then table.insert(kept, t) end
				end
				workspace.tabs = kept
				keep = #kept > 0
			end
			workspace.open = true
		end
		if keep then table.insert(workspaces, workspace) end
	end
	-- Workspaces follow the order you arranged; new ones go last, in Tern's order.
	local rank = {}
	for i, id in (records("ws-order")) do rank[tostring(id)] = i end
	for i, w in workspaces do w.tern = i end
	table.sort(workspaces, function(a, b)
		local ra, rb = rank[tostring(a.id)], rank[tostring(b.id)]
		if ra and rb then return ra < rb end
		if ra or rb then return ra ~= nil end
		return a.tern < b.tern
	end)
	-- The Ice Box: parked workspaces sink to the bottom and hide unless shown (the current one stays).
	local showIce = tern.kv.get("show-icebox") == true
	local active, iced, iceCount = {}, {}, 0
	for _, w in workspaces do
		if w.iced then
			iceCount += 1
			if showIce or w.current then table.insert(iced, w) end
		else
			table.insert(active, w)
		end
	end
	for _, w in iced do table.insert(active, w) end
	workspaces = active
	-- Each machine's workspaces sit together (in your order) under its header, even with one host.
	local hostRows = nil
	if #hostOrder > 0 then
		local byHost = {}
		for _, w in workspaces do
			local h = w.host or -1
			byHost[h] = byHost[h] or {}
			table.insert(byHost[h], w)
		end
		workspaces, hostRows = {}, {}
		for _, id in hostOrder do
			local h = hosts[id]
			table.insert(hostRows, {
				id = id, name = h.name, state = h.state, rtt = h.rtt_ms, remote = h.kind == "remote",
				current = h.current, error = h.detail and h.detail.error, count = #(byHost[id] or {}),
			})
			for _, w in (byHost[id] or {}) do table.insert(workspaces, w) end
		end
		for _, w in (byHost[-1] or {}) do table.insert(workspaces, w) end
	end

	-- Save the unseen marks when they change, dropping panes that no longer exist.
	local keep, parts = {}, {}
	for id, v in unseen do
		if lastState[id] then
			keep[tostring(id)] = v
			table.insert(parts, tostring(id) .. v)
		else
			unseen[id] = nil
		end
	end
	table.sort(parts)
	local uk = table.concat(parts, ",")
	if uk ~= unseenKey then
		unseenKey = uk
		tern.kv.set("unseen", if #parts > 0 then keep else nil)
	end

	attention = {}
	for _, list in { waitingList, failedList, doneList } do
		for _, x in list do table.insert(attention, x) end
	end
	visibleOrder = {}
	local waitingTotal = 0
	for _, w in workspaces do
		table.insert(visibleOrder, w.id)
		waitingTotal += w.waiting
	end
	statusInfo = { name = current.name, waiting = waitingTotal }
	local sk = current.name .. "|" .. tostring(waitingTotal)
	if sk ~= statusKey then
		statusKey = sk
		pcall(tern.chrome.refresh)
	end
	return {
		workspaces = workspaces, moving = moving, filter = filter, hosts = hostRows,
		iceCount = iceCount, showIce = showIce, sound = tern.kv.get("sound") == true,
		size = if SIZE_IDS[tern.kv.get("size")] then tern.kv.get("size") else "standard",
		version = VERSION,
	}
end

-- Only the panel in the shown tab is redrawn; the others go stale and catch up when their tab is
-- shown (focus events draw), so Tern lays out one copy of the tree per change, not one per tab.
local function draw(cx)
	local _, byTab = ours(cx)
	local focused = cx.session:focused()
	local pane = focused and byTab[cx.session:tab_of(focused)]
	if not pane then return end
	-- A just-opened canvas only accepts updates once canvas:list() reports it.
	local listed = false
	for _, canvas in cx.canvas:list() do
		if canvas.pane == pane then listed = true end
	end
	if not listed then return end
	local data = model(cx)
	local signature = tern.json.encode(data)
	if rendered[pane] == signature then return end
	cx.canvas:set(pane, { view = view.render(data) })
	rendered[pane] = signature
end

local drawQueued = false
function redraw()
	checkTimers() -- unsticks a draw queued behind timers that died
	if drawQueued then return end
	drawQueued = true
	later(0, function(cx)
		drawQueued = false
		if not cx then return end
		local ok, err = pcall(draw, cx)
		if not ok and problem ~= tostring(err) then report(cx, err) end
	end)
end

local DEFAULT_SHARE = 0.22
local share = tonumber(tern.kv.get("panel-share")) or DEFAULT_SHARE
local wantPanel = tern.kv.get("panel-open") ~= false
local sized = {} -- tab -> the panel ratio we last left it at, to notice a dragged divider
local rebuilding = {} -- tab -> true while its layout is being rebuilt around the panel

local function leaves(tree, skip, out)
	out = out or {}
	if not tree then return out end
	if tree.pane then
		if tree.pane ~= skip then table.insert(out, tree.pane) end
		return out
	end
	leaves(tree[1], skip, out)
	leaves(tree[2], skip, out)
	return out
end

local function firstLeaf(tree, skip)
	return leaves(tree, skip)[1]
end

-- The leaf touching a subtree's right and bottom edges.
local function lastLeaf(tree)
	while tree and not tree.pane do tree = tree[2] end
	return tree and tree.pane
end

-- The tree without `skip`: its parent split collapses into the sibling.
local function prune(tree, skip)
	if not tree then return nil end
	if tree.pane then return if tree.pane == skip then nil else tree end
	local a, b = prune(tree[1], skip), prune(tree[2], skip)
	if a and b then return { split = tree.split, ratio = tree.ratio, a, b } end
	return a or b
end

local function nodeAt(tree, path)
	for _, i in path do tree = tree and tree[i] end
	return tree
end

local function leftShare(cx, tab, pane)
	local layout = cx.session:layout(tab)
	local root = layout and layout.root
	if root and root.split == "right" and root[1] and root[1].pane == pane then return root.ratio end
	return nil
end

-- Steers a split's ratio by resizing a leaf on its divider: step, measure, correct.
-- Tern resizes in cells, so the cells-per-ratio factor is learned from the first step.
-- `sign` is -1 when the leaf sits after the divider (growing it shrinks the ratio).
local function steer(cx, leaf, dir, want, measure, sign)
	sign = sign or 1
	local r = measure()
	if not (want and r and leaf) then return end
	local step = math.floor((want - r) * 150 + 0.5)
	for _ = 1, 8 do
		if math.abs(r - want) < 0.006 or step == 0 then return end
		cx.layout:resize(leaf, dir, sign * step)
		local after = measure()
		if not after or after == r then return end
		step = math.floor((want - after) * step / (after - r) + 0.5)
		r = after
	end
end

local function sizeTo(cx, tab, pane, want)
	steer(cx, pane, "right", want, function() return leftShare(cx, tab, pane) end)
	sized[tab] = leftShare(cx, tab, pane)
end

-- Rebuilds `tree` leaf by leaf: each split moves its second side's first leaf beside its
-- first side's first leaf, then both sides expand in place.
local function expand(cx, node)
	if not node or node.pane then return end
	cx.layout:move(firstLeaf(node[2]), firstLeaf(node[1]), node.split, { focus = false })
	expand(cx, node[1])
	expand(cx, node[2])
end

local function restoreRatios(cx, tab, node, path)
	if not node or node.pane then return end
	local function measure()
		local layout = cx.session:layout(tab)
		local now = layout and nodeAt(layout.root, path)
		return now and not now.pane and now.ratio or nil
	end
	-- Tern moves "the nearest divider", which from a leaf's side may be another one;
	-- if the first side didn't move this divider, push from the second side.
	steer(cx, lastLeaf(node[1]), node.split, node.ratio, measure)
	local r = measure()
	if r and node.ratio and math.abs(r - node.ratio) > 0.01 then
		steer(cx, firstLeaf(node[2]), if node.split == "right" then "left" else "up", node.ratio, measure, -1)
	end
	local first, second = table.clone(path), table.clone(path)
	table.insert(first, 1)
	table.insert(second, 2)
	restoreRatios(cx, tab, node[1], first)
	restoreRatios(cx, tab, node[2], second)
end

-- Tern can only place a pane beside a leaf, so a tab that is already split can't take a
-- full-height column directly. Its other panes step out to a scratch tab, the panel goes
-- left of the one that stays, and the layout is rebuilt to its right with the same shape
-- and ratios. Programs keep running; the scratch tab closes once empty.
local function rebuild(cx, tab, pane)
	local layout = cx.session:layout(tab)
	local tree = layout and prune(layout.root, pane)
	if not tree then return end
	local list = leaves(tree)
	local session
	for _, info in cx.session:tabs() do
		if info.id == tab then session = info.session end
	end
	if #list > 1 then
		local scratch = cx.layout:move_to_new_tab(list[2], session, { focus = false })
		if not scratch then return end
		for i = 3, #list do cx.layout:move_to_tab(list[i], scratch, { focus = false }) end
	end
	cx.layout:move(pane, list[1], "left", { focus = false })
	expand(cx, tree)
	if layout.focus and layout.focus ~= pane and cx.session:pane(layout.focus) then cx.layout:focus(layout.focus) end
	return tree
end

-- Makes the panel the tab's full-height left column; true once it is.
local function ensureRail(cx, tab, pane)
	if rebuilding[tab] then return false end
	if leftShare(cx, tab, pane) then return true end
	local layout = cx.session:layout(tab)
	if not layout then return false end
	local others = leaves(layout.root, pane)
	if #others == 0 then return false end
	if #others == 1 then
		cx.layout:move(pane, others[1], "left", { focus = false })
		return leftShare(cx, tab, pane) ~= nil
	end
	-- Several panes: rebuild in callbacks of their own (each has a 50 ms budget).
	rebuilding[tab] = true
	later(0, function(c)
		if not c then rebuilding[tab] = nil; return end
		local ok, result = pcall(rebuild, c, tab, pane)
		if not ok then report(c, result) end
		later(0, function(c2)
			rebuilding[tab] = nil
			if not c2 then return end
			pcall(function()
				sizeTo(c2, tab, pane, share)
				if ok and result then restoreRatios(c2, tab, result, { 2 }) end
			end)
			redraw()
		end)
	end)
	return false
end

local function shownTab(cx)
	local focused = cx.session:focused()
	return focused and cx.session:tab_of(focused)
end

local function setWantPanel(want)
	wantPanel = want
	tern.kv.set("panel-open", want)
end

-- Opens the shown tab's panel (canvas:open lands beside the focused pane).
local function mount(cx, tab)
	local data = model(cx)
	local pane, err = cx.canvas:open({
		title = TITLE, about = ABOUT, view = view.render(data), how = "beside", focus = false,
	})
	if not pane then report(cx, err or "Could not open the Workspaces panel"); return nil end
	rendered[pane] = tern.json.encode(data)
	if cx.session:tab_of(pane) ~= tab then cx.layout:move_to_tab(pane, tab, { focus = false }) end
	if ensureRail(cx, tab, pane) then sizeTo(cx, tab, pane, share) end
	return pane
end

-- A tab whose last pane closed keeps only our panel; close it so the tab goes too.
local function closeOrphans(cx)
	local _, byTab = ours(cx)
	for tab, pane in byTab do
		local layout = cx.session:layout(tab)
		if layout and not rebuilding[tab] and #leaves(layout.root, pane) == 0 and #layout.floats == 0 then
			cx.layout:close(pane)
			rendered[pane], sized[tab] = nil, nil
		end
	end
end

-- Gives the shown tab its panel, full height and at the shared width.
local function follow(cx, tab)
	closeOrphans(cx)
	if not wantPanel then return end
	tab = tab or shownTab(cx)
	if not tab then return end
	local _, byTab = ours(cx)
	local pane = byTab[tab]
	if not pane then
		mount(cx, tab)
		return
	end
	if not ensureRail(cx, tab, pane) then return end
	local r = leftShare(cx, tab, pane)
	-- You dragged this tab's divider: that width becomes every tab's.
	if r and sized[tab] and math.abs(r - sized[tab]) > 0.01 then
		share = math.clamp(r, 0.1, 0.5)
		tern.kv.set("panel-share", share)
	end
	if r and math.abs(r - share) > 0.01 then sizeTo(cx, tab, pane, share) else sized[tab] = r end
end

local function togglePanel(cx)
	local own = ours(cx)
	if wantPanel and next(own) ~= nil then
		setWantPanel(false)
		for pane in own do
			cx.layout:close(pane)
			rendered[pane] = nil
		end
		sized = {}
		return
	end
	setWantPanel(true)
	follow(cx)
end

-- Focuses a pane, switching to its session first when it lives in another one.
local function reveal(cx, target)
	local sessionId, paneId = string.match(target or "", "^(%d+):(%d+)$")
	sessionId, paneId = tonumber(sessionId), tonumber(paneId)
	if not paneId then return end
	if sessionId and cx.sessions:current().id ~= sessionId then cx.sessions:switch(sessionId) end
	if cx.session:pane(paneId) then cx.layout:focus(paneId) end
end

-- macOS folder picker; the start folder is passed as an argument, never spliced into the script.
local CHOOSE_FOLDER = {
	"on run argv",
	'POSIX path of (choose folder with prompt "Choose a folder for the new workspace" default location (POSIX file (item 1 of argv)))',
	"end run",
}
local picking = false
local function newWorkspace(cx)
	if not localHost(cx) then return end
	if picking then return end
	picking = true
	local argv = { "/usr/bin/osascript" }
	for _, line in CHOOSE_FOLDER do
		table.insert(argv, "-e")
		table.insert(argv, line)
	end
	local start = tern.kv.get("picker-start")
	if type(start) ~= "string" or not tern.fs.exists(start) then start = tern.getenv("HOME") or "/" end
	table.insert(argv, start)
	tern.process.run(argv, { timeout_ms = 30 * 60 * 1000 }, function(result, nextCx)
		picking = false
		if not nextCx or result.status ~= 0 then return end -- cancelled or timed out
		local path = (result.stdout or ""):match("^%s*(.-)%s*$")
		if #path > 1 then path = path:gsub("/+$", "") end
		if path == "" then return end
		tern.kv.set("picker-start", path:match("^(.*)/[^/]+$") or path)
		local ok, err = pcall(function() nextCx.sessions:create({ name = basename(path), cwd = path }) end)
		if not ok then report(nextCx, err) end
		redraw()
	end)
end

-- Context menus. Tern reports the entry's label as the action; the target comes from the
-- clicked node's key path: ".w<session>", ".t<tab>", ".p<pane>".
local M = view.M
local COLORS = { "red", "orange", "yellow", "green", "teal", "blue", "purple", "pink" }

local function targetOf(node)
	node = node or ""
	return tonumber(node:match("%.w(%d+)")), tonumber(node:match("%.t(%d+)")), tonumber(node:match("%.p(%d+)"))
end

local function sessionInfo(cx, id)
	for _, session in cx.session:sessions() do
		if session.id == id then return session end
	end
	return nil
end

-- A tab's panes, without our own panel.
local function tabPanes(cx, tab)
	local own, list = ours(cx), {}
	for _, pane in cx.session:panes() do
		if pane.tab == tab and not pane.parked and not own[pane.pane] then table.insert(list, pane) end
	end
	return list
end

local function sessionFolder(cx, id)
	local session = sessionInfo(cx, id)
	for _, tab in (session and session.tabs or {}) do
		for _, pane in tabPanes(cx, tab) do
			if pane.cwd and pane.cwd ~= "" then return pane.cwd end
		end
	end
	return tern.getenv("HOME") or "/"
end

local function showSession(cx, id)
	if id and cx.sessions:current().id ~= id then cx.sessions:switch(id) end
end


local function askText(cx, opts, fn)
	cx:prompt(opts):next(function(value, _err, nextCx)
		if nextCx and value ~= nil then
			local ok, err = pcall(fn, nextCx, value)
			if not ok then report(nextCx, err) end
			redraw()
		end
	end)
end

-- Picks another workspace, then runs fn(cx, sessionId).
local function pickWorkspace(cx, except, fn)
	local items = {}
	for _, session in cx.session:sessions() do
		if session.id ~= except then table.insert(items, { label = session.name, id = session.id }) end
	end
	if #items == 0 then cx:toast("info", "Kai", "No other workspace to move to."); return end
	cx:pick({ placeholder = "Move to workspace", icon = "sidebar", action = "move", items = items })
		:next(function(item, _err, nextCx)
			if nextCx and item then
				local ok, err = pcall(fn, nextCx, item.id)
				if not ok then report(nextCx, err) end
				redraw()
			end
		end)
end

local function openInFinder(path)
	if path and path ~= "" then tern.process.run({ "/usr/bin/open", path }, { timeout_ms = 10000 }, function() end) end
end

-- Section folds are Tern's own local state; to set them from a menu, store the wanted
-- state and bump the generation, which remounts every section with it.
local function bumpGen()
	tern.kv.set("gen", (tonumber(tern.kv.get("gen")) or 0) + 1)
end

local function setAll(key, ids, value)
	local all = records(key)
	for _, id in ids do all[tostring(id)] = value end
	tern.kv.set(key, all)
	bumpGen()
end

local PANE_ACTS, TAB_ACTS = {}, {}
for _, k in { "focus", "splitRight", "splitDown", "toNewTab", "toWs", "copyTitle", "interrupt", "stop", "closePane", "copyPath", "finder" } do
	PANE_ACTS[M[k]] = true
end
for _, k in { "goTab", "renameTab", "colorTab", "newPane", "even", "tabUp", "tabDown", "tabToWs", "closeTab" } do
	TAB_ACTS[M[k]] = true
end

-- Icons offered for a workspace (Tern's own set) and the names of the tile colors.
local WS_ICONS = {
	"terminal", "code", "braces", "bug", "rocket", "flame", "bolt", "sparkle", "brain", "lightbulb",
	"server", "database", "cpu", "globe", "cloud", "box", "layers", "kanban", "doc", "note",
	"folder", "branch", "wrench", "gear", "gauge", "activity", "chart", "shield", "key", "lock",
	"users", "user", "message", "bell", "pin", "tag", "star", "moon", "sun", "cart",
	"app-omp", "app-claude", "app-codex", "app-rust", "app-go", "app-node", "app-bun", "app-python", "app-docker", "app-vim",
}
local TONE_NAMES = { accent = "Accent", info = "Blue", success = "Green", warning = "Amber", error = "Red", user = "Pen" }

local quickAction -- defined below

local function menuAction(cx, act, node)
	local ws, tab, pane = targetOf(node)
	if pane and not tab then tab = cx.session:tab_of(pane) end
	local paneInfo = pane and cx.session:pane(pane)
	local tabInfo
	if tab then
		for _, info in cx.session:tabs() do
			if info.id == tab then tabInfo = info end
		end
	end
	local session = ws and sessionInfo(cx, ws)

	-- Header
	if act == M.newWs then newWorkspace(cx)
	elseif act == M.sizeCompact or act == M.sizeStandard or act == M.sizeSpacious then
		local id = if act == M.sizeCompact then "compact" elseif act == M.sizeSpacious then "spacious" else "standard"
		tern.kv.set("size", if id == "standard" then nil else id)
	elseif act == M.sound or act == M.noSound then
		tern.kv.set("sound", act == M.sound or nil)
		cx:toast("info", "Kai", if act == M.sound then "Sounds on" else "Sounds off")
	elseif act == M.expandAll or act == M.collapseAll then
		local ids = {}
		for _, s in cx.session:sessions() do table.insert(ids, s.id) end
		setAll("open", ids, act == M.expandAll)

	-- Host
	elseif act == M.addHost then cx:command("add_remote_host")
	elseif act == M.switchHost or act == M.newOnHost or act == M.disconnectHost then
		local host = tonumber((node or ""):match("%.h(%d+)"))
		if not host then return end
		if act == M.disconnectHost then cx.hosts:disconnect(host); return end
		if cx.hosts:current().id ~= host then cx.hosts:switch(host) end
		if act == M.newOnHost then cx.sessions:create({}) end

	-- Pane
	elseif pane and PANE_ACTS[act] then
		if not paneInfo then return end
		if act == M.focus then reveal(cx, tostring(ws) .. ":" .. tostring(pane))
		elseif act == M.splitRight or act == M.splitDown then
			showSession(cx, ws)
			cx.layout:split(pane, if act == M.splitRight then "right" else "down", { cwd = paneInfo.cwd })
		elseif act == M.toNewTab then cx.layout:move_to_new_tab(pane, ws)
		elseif act == M.toWs then pickWorkspace(cx, ws, function(c, id) c.layout:move_to_new_tab(pane, id, { focus = false }) end)
		elseif act == M.copyPath then cx:copy(paneInfo.cwd or ""); cx:toast("info", "Path copied", paneInfo.cwd)
		elseif act == M.finder then openInFinder(paneInfo.cwd)
		elseif act == M.copyTitle then cx:copy(paneInfo.title or ""); cx:toast("info", "Title copied", paneInfo.title)
		elseif act == M.interrupt then cx.agents:interrupt(pane)
		elseif act == M.stop then cx.agents:stop(pane)
		elseif act == M.closePane then cx.layout:close(pane)
		end

	-- Tab
	elseif tab and TAB_ACTS[act] then
		if not tabInfo then return end
		local name = if tabInfo.name and tabInfo.name ~= "" then tabInfo.name else tabInfo.title
		if act == M.goTab then
			local panes = tabPanes(cx, tab)
			local target = if not ours(cx)[tabInfo.pane] then tabInfo.pane else (panes[1] and panes[1].pane)
			if target then reveal(cx, tostring(ws) .. ":" .. tostring(target)) end
		elseif act == M.renameTab then
			askText(cx, { value = name, placeholder = "Tab name (blank resets)", icon = "pencil", action = "rename" },
				function(c, value) c.layout:name_tab(tab, value) end)
		elseif act == M.colorTab then
			local items = { { label = "None", current = tabInfo.color == nil } }
			for _, color in COLORS do
				table.insert(items, { label = color:sub(1, 1):upper() .. color:sub(2), color = color, current = tabInfo.color == color })
			end
			cx:pick({ placeholder = "Tab color", icon = "palette", action = "set", items = items })
				:next(function(item, _err, nextCx)
					if nextCx and item then nextCx.layout:color_tab(tab, item.color); redraw() end
				end)
		elseif act == M.newPane then
			local panes = tabPanes(cx, tab)
			local target = if not ours(cx)[tabInfo.pane] then tabInfo.pane else (panes[1] and panes[1].pane)
			if target then
				showSession(cx, ws)
				cx.layout:split(target, "right", { cwd = tabInfo.cwd ~= "" and tabInfo.cwd or nil })
			end
		elseif act == M.even then
			cx.layout:even(tab)
			sized[tab] = nil -- the panel goes back to its width next time the tab is shown
			if shownTab(cx) == tab then follow(cx, tab) end
		elseif act == M.tabUp then cx.layout:order_tab(tab, tabInfo.position - 1)
		elseif act == M.tabDown then cx.layout:order_tab(tab, tabInfo.position + 1)
		elseif act == M.tabToWs then
			pickWorkspace(cx, ws, function(c, id)
				local panes = tabPanes(c, tab)
				if #panes == 0 then return end
				local newTab = c.layout:move_to_new_tab(panes[1].pane, id, { focus = false })
				for i = 2, #panes do
					if newTab then c.layout:move_to_tab(panes[i].pane, newTab, { focus = false }) end
				end
			end)
		elseif act == M.closeTab then
			local _, byTab = ours(cx)
			for _, p in tabPanes(cx, tab) do cx.layout:close(p.pane) end
			if byTab[tab] then cx.layout:close(byTab[tab]) end
		end

	-- Workspace
	elseif ws then
		if not session then return end
		if act == M.switch then showSession(cx, ws)
		elseif act == M.newTab then
			showSession(cx, ws)
			cx.layout:new_tab({ cwd = sessionFolder(cx, ws) })
		elseif act == M.renameWs then
			askText(cx, { value = session.name, placeholder = "Workspace name", icon = "pencil", action = "rename" },
				function(c, value)
					if value:match("%S") then c.sessions:rename(ws, value) end
				end)
		elseif act == M.wsIcon or act == M.wsColor then
			local styles = records("ws-style")
			local current = styles[tostring(ws)] or {}
			local items
			if act == M.wsIcon then
				items = { { label = "Initial letter", detail = "default", current = current.icon == nil } }
				for _, name in WS_ICONS do
					table.insert(items, { label = name, icon = name, value = name, current = current.icon == name })
				end
			else
				items = { { label = "Automatic", detail = "from the name", current = current.tone == nil } }
				for _, tone in view.TILE_TONES do
					table.insert(items, { label = TONE_NAMES[tone], icon = "palette", value = tone, current = current.tone == tone })
				end
			end
			cx:pick({ placeholder = if act == M.wsIcon then "Workspace icon" else "Workspace color",
				icon = if act == M.wsIcon then "sparkle" else "palette", action = "set", items = items })
				:next(function(item, _err, nextCx)
					if not nextCx or not item then return end
					local all = records("ws-style")
					local entry = all[tostring(ws)] or {}
					if act == M.wsIcon then entry.icon = item.value else entry.tone = item.value end
					all[tostring(ws)] = if next(entry) == nil then nil else entry
					tern.kv.set("ws-style", all)
					redraw()
				end)
		elseif act == M.iceIn or act == M.iceOut then
			local ice = records("icebox")
			ice[tostring(ws)] = if act == M.iceIn then true else nil
			tern.kv.set("icebox", ice)
		elseif act == M.linear then
			askText(cx, { value = tern.kv.get("linear-workspace") or "", placeholder = "Linear workspace slug (linear.app/<slug>)", icon = "link", action = "save" },
				function(_, value) tern.kv.set("linear-workspace", if value:match("%S") then value:match("^%s*(.-)%s*$") else nil) end)
		elseif act == M.lock then cx.sessions:lock(ws)
		elseif act == M.unlock then cx.sessions:unlock(ws)
		elseif act == M.copyPath then
			local path = sessionFolder(cx, ws)
			cx:copy(path); cx:toast("info", "Path copied", path)
		elseif act == M.finder then openInFinder(sessionFolder(cx, ws))
		elseif act == M.expandTabs or act == M.collapseTabs then setAll("tab-open", session.tabs, act == M.expandTabs)
		elseif act == M.collapseOthers then
			local all = {}
			for _, s in cx.session:sessions() do all[tostring(s.id)] = s.id == ws end
			tern.kv.set("open", all)
			bumpGen()
		elseif act == M.closeWs then cx.sessions:close(ws)
		end
	end
end

local function unhex(value)
	if not value or #value % 2 ~= 0 then return nil end
	return (string.gsub(value, "..", function(h) return string.char(tonumber(h, 16)) end))
end

local function refreshAllGit()
	for folder in git do refreshGit(folder, true) end
end

-- Runs a git change on the repo holding `path`, then rereads every workspace's git state.
local function withRepo(cx, path, fn)
	cx.git:repo(path):next(function(repo, err, nextCx)
		if not repo or not nextCx then if nextCx then report(nextCx, err or "Not a git repository") end; return end
		fn(nextCx, repo, path:sub(#repo.root + 2))
	end)
end

local function settle(op)
	op:next(function(_, err, nextCx)
		if err and nextCx then report(nextCx, err) end
		refreshAllGit()
		redraw()
	end)
end

-- Actions from the Files, Changes and Refs views; true when handled.
local function viewAction(cx, act, value, label, node)
	if act == "view" then
		local ws, which = string.match(value or "", "^(%d+):(%a+)$")
		if not ws then return true end
		-- A remote workspace's files and git live on its machine: show it there in Tern's own panels.
		if which ~= "agents" and isRemote(cx, tonumber(ws)) then
			showSession(cx, tonumber(ws))
			cx:command(if which == "files" then "focus_files" else "new_git_block")
			return true
		end
		local views = records("ws-view")
		views[ws] = which
		tern.kv.set("ws-view", views)
		if which ~= "agents" then
			local folder = sessionFolder(cx, tonumber(ws))
			refreshGit(folder, true)
			local found = nested[git[folder] and git[folder].root or folder]
			for _, r in (found and found.repos or {}) do refreshGit(r, true) end
		end
		redraw()
		return true
	elseif act == "dir" then
		local path = unhex(value)
		if path then
			expanded[path] = not expanded[path] or nil
		end
		redraw()
		return true
	elseif act == "file" then
		local path = unhex(value)
		if path then cx:open(path) end
		return true
	end
	local file = unhex((node or ""):match("%.f(%x+)$") or (node or ""):match("%.f(%x+)%."))
	local branch = unhex((node or ""):match("%.b(%x+)$"))
	if file then
		if label == M.openFile then cx:open(file)
		elseif label == M.copyPath then cx:copy(file); cx:toast("info", "Path copied", file)
		elseif label == M.finder then tern.process.run({ "/usr/bin/open", "-R", file }, { timeout_ms = 10000 }, function() end)
		elseif label == M.stage or label == M.unstage then
			local dir = file:match("^(.*)/[^/]+$") or file
			withRepo(cx, dir, function(c, repo)
				local rel = file:sub(#repo.root + 2)
				settle(if label == M.stage then c.git:stage(repo, { rel }) else c.git:unstage(repo, { rel }))
			end)
		else return false end
		return true
	elseif branch and label == M.checkout then
		-- In a monorepo the branch row sits in its repo's group, keyed by that repo's root.
		local root = unhex((node or ""):match("%.g(%x+)%."))
		local ws = tonumber((node or ""):match("%.w(%d+)"))
		withRepo(cx, root or sessionFolder(cx, ws), function(c, repo) settle(c.git:checkout(repo, branch)) end)
		return true
	end
	return false
end

-- Hover buttons, header controls and badges; true when handled.
function quickAction(cx, act, value)
	if act == "newtab" then
		local ws = tonumber(value)
		if ws then
			showSession(cx, ws)
			cx.layout:new_tab({ cwd = sessionFolder(cx, ws) })
		end
	elseif act == "close" then
		local kind, id = string.match(value or "", "^(%a+):(%d+)$")
		id = tonumber(id)
		if kind == "pane" and id and cx.session:pane(id) then
			cx.layout:close(id)
		elseif kind == "tab" and id then
			local _, byTab = ours(cx)
			for _, p in tabPanes(cx, id) do cx.layout:close(p.pane) end
			if byTab[id] then cx.layout:close(byTab[id]) end
		end
	elseif act == "addhost" then
		cx:command("add_remote_host")
	elseif act == "host" then
		local id = tonumber(value)
		if id and cx.hosts:current().id ~= id then cx.hosts:switch(id) end
		redraw()
	elseif act == "url" then
		local url = unhex(value)
		if url and url ~= "" then cx:open(url) end
	elseif act == "ticket" then
		local ws = tonumber(value)
		local branch = nil
		local folder = ws and sessionFolder(cx, ws)
		local entry = folder and git[folder]
		for _, b in (entry and entry.branches or {}) do
			if b.current then branch = b.name end
		end
		local id = ticketOf(branch)
		local slug = tern.kv.get("linear-workspace")
		if not id then return true end
		if type(slug) == "string" and slug ~= "" then
			cx:open("https://linear.app/" .. slug .. "/issue/" .. id)
		else
			askText(cx, { placeholder = "Linear workspace slug (linear.app/<slug>)", icon = "link", action = "open" }, function(c, v)
				local s2 = v:match("^%s*(.-)%s*$")
				if s2 ~= "" then
					tern.kv.set("linear-workspace", s2)
					c:open("https://linear.app/" .. s2 .. "/issue/" .. id)
				end
			end)
		end
	elseif act == "icebox" then
		tern.kv.set("show-icebox", tern.kv.get("show-icebox") ~= true)
	elseif act == "filter" then
		askText(cx, { value = filter or "", placeholder = "Filter workspaces, tabs and panes", icon = "search", action = "filter" },
			function(_, v)
				local q = v:match("^%s*(.-)%s*$")
				filter = if q ~= "" then q else nil
			end)
	elseif act == "clearfilter" then
		filter = nil
	else
		return false
	end
	redraw()
	return true
end

-- Picking up and placing rows. Tern canvases send clicks only (no drag events), so a move is
-- pick (grip or "Move…") then click a "Move here" slot; any other click cancels.
local function tabInfoOf(cx, tab)
	for _, info in cx.session:tabs() do
		if info.id == tab then return info end
	end
	return nil
end

local function pick(cx, kind, id)
	if kind == "ws" then
		local session = sessionInfo(cx, id)
		if session then moving = { kind = "ws", id = id, name = session.name } end
	elseif kind == "tab" then
		local info = tabInfoOf(cx, id)
		if info then
			-- The tab's own title is often our panel's; name it by its first real pane instead.
			local first = tabPanes(cx, id)[1]
			local name = if info.name and info.name ~= "" then info.name elseif first then first.title else "tab"
			moving = { kind = "tab", id = id, ws = info.session, name = name }
		end
	elseif kind == "pane" then
		local info, tab = cx.session:pane(id), cx.session:tab_of(id)
		if info and tab then moving = { kind = "pane", id = id, tab = tab, name = info.title ~= "" and info.title or "pane" } end
	end
end

-- Workspaces in the order the sidebar shows them.
local function workspaceOrder(cx)
	local rank = {}
	for i, id in (records("ws-order")) do rank[tostring(id)] = i end
	local list = {}
	for i, session in cx.session:sessions() do table.insert(list, { id = session.id, tern = i }) end
	table.sort(list, function(a, b)
		local ra, rb = rank[tostring(a.id)], rank[tostring(b.id)]
		if ra and rb then return ra < rb end
		if ra or rb then return ra ~= nil end
		return a.tern < b.tern
	end)
	local ids = {}
	for _, x in list do table.insert(ids, x.id) end
	return ids
end

-- Places the picked row before `target` (an id of the same kind), or last when target is 0.
local function place(cx, target)
	local m = moving
	if not m then return end
	if m.kind == "ws" then
		local ids = workspaceOrder(cx)
		local from = table.find(ids, m.id)
		if not from then return end
		table.remove(ids, from)
		local at = if target == 0 then #ids + 1 else table.find(ids, target)
		if not at then return end
		table.insert(ids, at, m.id)
		tern.kv.set("ws-order", ids)
	elseif m.kind == "tab" then
		local tabs = {}
		for _, info in cx.session:tabs() do
			if info.session == m.ws then table.insert(tabs, info) end
		end
		table.sort(tabs, function(a, b) return a.position < b.position end)
		local from, to
		for i, info in tabs do
			if info.id == m.id then from = info.position end
			if info.id == target then to = info.position end
		end
		if not from then return end
		if target == 0 then to = #tabs elseif not to then return elseif from < to then to -= 1 end
		cx.layout:order_tab(m.id, to)
	elseif m.kind == "pane" then
		local layout = cx.session:layout(m.tab)
		if not layout then return end
		local own = ours(cx)
		local list = {}
		for _, pane in leaves(layout.root) do
			if not own[pane] then table.insert(list, pane) end
		end
		local s = table.find(list, m.id)
		local t = if target == 0 then #list + 1 else table.find(list, target)
		if not (s and t) then return end
		-- Swap step by step so every other pane keeps its relative order.
		if s < t then
			for k = s + 1, t - 1 do cx.layout:move(m.id, list[k], "swap", { focus = false }) end
		else
			for k = s - 1, t, -1 do cx.layout:move(m.id, list[k], "swap", { focus = false }) end
		end
	end
end

tern.on("canvas_action", function(ev, cx)
	if ev.owner and ev.owner ~= "kai" then return nil end
	if ev.title and ev.title ~= TITLE then return nil end
	local act, value = ev.act, ev.value
	if value == nil then act, value = string.match(ev.act, "^([^=]+)=?(.*)$") end
	-- While a row is picked up, only a drop slot or Cancel acts; anything else cancels the move.
	if moving and act ~= "drop" and act ~= "pick" then
		moving = nil
		redraw()
		return true
	end
	if quickAction(cx, act, value) then return true end
	if viewAction(cx, act, value, ev.act, ev.node) then return true end
	if act == "pick" then
		local kind, id = string.match(value or "", "^(%a+):(%d+)$")
		local ok, err = pcall(pick, cx, kind, tonumber(id))
		if not ok then report(cx, err) end
		redraw()
	elseif act == "drop" then
		local ok, err = pcall(place, cx, tonumber(value) or 0)
		if not ok then report(cx, err) end
		moving = nil
		redraw()
	elseif ev.act == M.moveWs or ev.act == M.moveTab or ev.act == M.movePane then
		local ws, tab, pane = targetOf(ev.node)
		if ev.act == M.movePane and pane then pick(cx, "pane", pane)
		elseif ev.act == M.moveTab and (tab or pane) then pick(cx, "tab", tab or cx.session:tab_of(pane))
		elseif ev.act == M.moveWs and ws then pick(cx, "ws", ws) end
		redraw()
	elseif act == "new" then newWorkspace(cx)
	elseif act == "switch" then
		local id = tonumber(value)
		if id and cx.sessions:current().id ~= id then cx.sessions:switch(id) end
		redraw()
	elseif act == "pane" then reveal(cx, value); redraw()
	else
		local known = false
		for _, label in M do
			if label == ev.act then known = true end
		end
		if not known then return false end
		local ok, err = pcall(menuAction, cx, ev.act, ev.node)
		if not ok then report(cx, err) end
		redraw()
	end
	return true
end)

tern.command({ id = "toggle", title = "Show or hide Workspaces", icon = "sidebar", keys = { "cmd+\\" }, run = togglePanel })

tern.chrome.status(function()
	local seg = { text = statusInfo.name, icon = "sidebar", command = "plugin.kai.toggle" }
	if statusInfo.waiting > 0 then
		return { seg, { text = tostring(statusInfo.waiting) .. " waiting", icon = "bell", tone = "accent", command = "plugin.kai.attention" } }
	end
	return { seg }
end)

local function gotoWorkspace(cx, i)
	-- Before the first draw after a reload, fall back to the saved order.
	local order = if #visibleOrder > 0 then visibleOrder else workspaceOrder(cx)
	local id = order[i]
	if id then showSession(cx, id); redraw() end
end

-- The next pane that needs you: a waiting agent, then a failed command, then a finished agent.
local function nextAttention(cx)
	local x = attention[1]
	if not x then
		cx:toast("info", "Kai", "Nothing needs you")
		return
	end
	reveal(cx, tostring(x.ws) .. ":" .. tostring(x.pane))
	redraw()
end

-- ⌘⌃1…9: the workspace at that place in the sidebar.
for i = 1, 9 do
	tern.command({
		id = "goto_" .. tostring(i), title = "Workspaces: go to " .. tostring(i), icon = "sidebar",
		keys = { "cmd+ctrl+" .. tostring(i) },
		run = function(cx) gotoWorkspace(cx, i) end,
	})
end

tern.command({
	id = "attention", title = "Workspaces: next needing attention", icon = "bell", keys = { "cmd+ctrl+0" },
	run = nextAttention,
})

tern.command({
	id = "filter", title = "Workspaces: filter", icon = "search", keys = { "cmd+ctrl+f" },
	run = function(cx) quickAction(cx, "filter", nil) end,
})

-- Carly: "open my atlas-api workspace", "make a workspace in ~/code/api".
tern.carly.export("open_workspace", {
	sig = "(name_or_path: string) -> string",
	doc = "Shows the Tern session (Kai workspace) whose name contains name_or_path, case-insensitively; if none matches and name_or_path is an existing folder, creates a session there. Returns what it did.",
}, function(query, cx)
	if type(query) ~= "string" or query == "" then return "Give a workspace name or a folder path." end
	local q = query:lower()
	for _, session in cx.session:sessions() do
		if session.name:lower():find(q, 1, true) then
			showSession(cx, session.id)
			return "Switched to workspace " .. session.name
		end
	end
	local path = query:gsub("^~", tern.getenv("HOME") or "~")
	if tern.fs.exists(path) then
		local created = cx.sessions:create({ name = basename(path), cwd = path })
		return "Created workspace " .. created.name
	end
	return "No workspace matches " .. query
end)

tern.carly.context(function()
	return "Kai workspaces sidebar: use plugins.kai.open_workspace(name_or_path) to switch to or create a workspace."
end)

-- Splitting while the sidebar has focus splits the tab's content instead of the sidebar.
for _, dir in { "right", "down" } do
	tern.override("split_" .. dir, function(cx)
		local focused = cx.session:focused()
		if not focused or not ours(cx)[focused] then return false end
		local tab = cx.session:tab_of(focused)
		local layout = tab and cx.session:layout(tab)
		local target = layout and lastLeaf(layout.root)
		if not target or target == focused then return false end
		local info = cx.session:pane(target)
		cx.layout:split(target, dir, { cwd = info and info.cwd ~= "" and info.cwd or nil })
		return true
	end)
end

local function followAndDraw(cx, tab)
	checkTimers()
	local ok, err = pcall(function()
		follow(cx, tab)
		draw(cx)
	end)
	if not ok then tern.log.warn("kai: " .. tostring(err)) end
end

-- Each chain carries its generation, so a restarted chain never runs beside a late original.
local tickGen = 0
local function tick(gen, cx)
	if gen ~= tickGen then return end
	lastTick = tern.now()
	if cx then
		local ok, err = pcall(function()
			follow(cx)
			redraw()
		end)
		if not ok and problem ~= tostring(err) then report(cx, err) end
	end
	later(750, function(c) tick(gen, c) end)
end

-- Starts a fresh tick chain and drops work that was waiting on a timer that will never fire.
function restartTick()
	tickGen += 1
	drawQueued = false
	table.clear(rebuilding)
	for _, entry in git do entry.inflight = false end
	local gen = tickGen
	later(0, function(c) tick(gen, c) end)
end

tern.on("window_start", function(cx) followAndDraw(cx) end)
tern.on("focus", function(ev, cx) followAndDraw(cx, ev.tab) end)
for _, name in { "tab_created", "tab_closed", "pane_created", "pane_closed" } do
	tern.on(name, function(_ev, cx) followAndDraw(cx) end)
end
for _, name in { "title", "cwd", "command_started", "command_finished" } do
	tern.on(name, function(_ev, _cx) redraw() end)
end
restartTick()
