(() => {
  "use strict";

  const state = {
    tree: [],
    vaults: [],
    path: null,
    selectedDir: null,
    title: "",
    content: "",
    mode: "uncooked",
    searching: false,
    searchAlwaysVisible: false,
    query: "",
    results: [],
    saveTimer: null,
    sidebarOpen: false,
    sidebarCollapsed: false,
    renamingPath: null,
    omni: false,
    omniQuery: "",
    omniResults: [],
    omniIndex: 0,
    collapsed: new Set(),
    /// Rows picked out for a bulk action, by path. The open note and the
    /// selected folder are tracked separately and drawn the same way; this is
    /// only what a shift- or cmd-click has gathered.
    selection: new Set(),
    selectionAnchor: null,
    graph: false,
    graphNodes: [],
    graphEdges: [],
  };

  const ICONS = {
    search: '<svg class="sf" viewBox="0 0 24 24"><circle cx="11" cy="11" r="6.25"/><path d="M16.2 16.2L21 21"/></svg>',
    compose: '<svg class="sf" viewBox="0 0 24 24"><rect x="3.5" y="3.5" width="13" height="17" rx="2"/><path d="M14.5 16.5l6-6 2 2-6 6h-2v-2z"/><path d="M18.2 12.8l2 2"/></svg>',
    refresh: '<svg class="sf" viewBox="0 0 24 24"><path d="M20 12a8 8 0 1 1-2.2-5.5"/><path d="M20 4.5V8h-3.5"/></svg>',
    "xmark-circle": '<svg class="sf" viewBox="0 0 24 24"><circle cx="12" cy="12" r="9" fill="currentColor" stroke="none"/><path d="M9.2 9.2l5.6 5.6M14.8 9.2l-5.6 5.6" fill="none" stroke="var(--bg)" stroke-width="1.9"/></svg>',
    menu: '<svg class="sf" viewBox="0 0 24 24"><path d="M4 7h16M4 12h16M4 17h16"/></svg>',
    sidebar: '<svg class="sf" viewBox="0 0 24 24"><rect x="3.5" y="4.5" width="17" height="15" rx="2"/><path d="M9.5 4.5v15"/></svg>',
    vault: '<svg class="sf" viewBox="0 0 24 24"><path d="M3.5 8.5h11l2 2.5H20.5v8.5a1.5 1.5 0 0 1-1.5 1.5H5a1.5 1.5 0 0 1-1.5-1.5z"/><path d="M3.5 8.5l2.2-3.7A1.5 1.5 0 0 1 7 4h7.2a1.5 1.5 0 0 1 1.3.75L17 8.5"/><circle cx="17.5" cy="16.2" r="3.1"/><path d="M17.5 14.7v1.1l.8.8" stroke-width="1.4"/></svg>',
    chevrons: '<svg class="sf sf-sm" viewBox="0 0 24 24"><path d="M7 9l5-4 5 4M7 15l5 4 5-4"/></svg>',
    chevronRight: '<svg class="sf sf-sm" viewBox="0 0 24 24"><path d="M9 5l7 7-7 7"/></svg>',
    chevronDown: '<svg class="sf sf-sm" viewBox="0 0 24 24"><path d="M5 9l7 7 7-7"/></svg>',
    folder: '<svg class="sf" viewBox="0 0 24 24"><path d="M3.5 8.5h11l2 2.5H20.5v8.5a1.5 1.5 0 0 1-1.5 1.5H5a1.5 1.5 0 0 1-1.5-1.5z"/><path d="M3.5 8.5l2.2-3.7A1.5 1.5 0 0 1 7 4h7.2a1.5 1.5 0 0 1 1.3.75L17 8.5"/></svg>',
    folderFill: '<svg class="sf filled" viewBox="0 0 24 24"><path d="M3.2 8.2h11.1l1.7 2.3H20.5a.8.8 0 0 1 .8.8v8.2a1.8 1.8 0 0 1-1.8 1.8H4.5A1.8 1.8 0 0 1 2.7 19.5V9.7a1.5 1.5 0 0 1 1.5-1.5z"/><path d="M3.4 8.2l2.1-3.5A1.5 1.5 0 0 1 6.8 4h7.1c.5 0 1 .26 1.28.69L17 8.2"/></svg>',
    doc: '<svg class="sf" viewBox="0 0 24 24"><path d="M7 3.5h7.2L19.5 9v11.5a1.5 1.5 0 0 1-1.5 1.5H7A1.5 1.5 0 0 1 5.5 20.5v-15A2 2 0 0 1 7 3.5z"/><path d="M14.2 3.5V8.8h5.3"/><path d="M8.5 13h7M8.5 16.5h5"/></svg>',
    check: '<svg class="sf" viewBox="0 0 24 24"><path d="M5 12.5l5 5 9-10"/></svg>',
    graph: '<svg class="sf" viewBox="0 0 24 24"><circle cx="6" cy="7" r="2.2"/><circle cx="18" cy="8" r="2.2"/><circle cx="8" cy="18" r="2.2"/><circle cx="17" cy="17" r="2.2"/><path d="M8 8.6l8.2 7.2M8.2 16.4l7.6-7.2M7.8 9.2l.6 6.6"/></svg>',
    sun: '<svg class="sf" viewBox="0 0 24 24"><circle cx="12" cy="12" r="4.2"/><path d="M12 2.8v2.6M12 18.6v2.6M4.2 12H6.8M17.2 12h2.6M6.3 6.3l1.8 1.8M15.9 15.9l1.8 1.8M17.7 6.3l-1.8 1.8M8.1 15.9l-1.8 1.8"/></svg>',
    moon: '<svg class="sf" viewBox="0 0 24 24"><path d="M20.2 14.8A8.5 8.5 0 1 1 9.2 3.8a7 7 0 0 0 11 11z"/></svg>',
    auto: '<svg class="sf" viewBox="0 0 24 24"><circle cx="12" cy="12" r="8.3"/><path d="M12 3.7a8.3 8.3 0 0 1 0 16.6z" fill="currentColor" stroke="none"/></svg>',
  };

  function iconHTML(name) {
    return ICONS[name] || "";
  }

  function iconEl(name) {
    const span = document.createElement("span");
    span.className = "icon";
    span.innerHTML = iconHTML(name);
    return span;
  }

  function hydrateIcons(root = document) {
    root.querySelectorAll("[data-icon]").forEach((el) => {
      const name = el.getAttribute("data-icon");
      if (!name || !ICONS[name]) return;
      el.innerHTML = ICONS[name];
    });
  }

  const $ = (id) => document.getElementById(id);
  const els = {
    sidebar: $("sidebar"),
    scrim: $("scrim"),
    tree: $("tree"),
    searchBar: $("searchBar"),
    searchInput: $("searchInput"),
    searchClose: $("searchClose"),
    searchToggle: $("searchToggle"),
    graphBtn: $("graphBtn"),
    graph: $("graph"),
    graphCanvas: $("graphCanvas"),
    vaultBtn: $("vaultBtn"),
    vaultMenu: $("vaultMenu"),
    themeBtn: $("themeBtn"),
    sidebarResizer: $("sidebarResizer"),
    newBtn: $("newBtn"),
    refreshBtn: $("refreshBtn"),
    menuBtn: $("menuBtn"),
    noteTitle: $("noteTitle"),
    eggBtn: $("eggBtn"),
    eggSvg: $("eggSvg"),
    rawEditor: $("rawEditor"),
    cookedView: $("cookedView"),
    editorPane: $("editorPane"),
    omnibar: $("omnibar"),
    omniInput: $("omniInput"),
    omniResults: $("omniResults"),
    ctxMenu: $("ctxMenu"),
    sheet: $("sheet"),
    sheetCard: $("sheetCard"),
  };

  // One MediaQueryList each rather than one per call: `isPhone()` runs on
  // every touch start, sidebar toggle and note open, and each `matchMedia`
  // call allocates a fresh list and re-evaluates the query.
  const phoneQuery = window.matchMedia("(max-width: 760px)");
  const lightQuery = window.matchMedia("(prefers-color-scheme: light)");
  const isPhone = () => phoneQuery.matches;
  const isTypingTarget = (el) =>
    el && (el.tagName === "INPUT" || el.tagName === "TEXTAREA" || el.isContentEditable);

  async function api(path, opts = {}) {
    const res = await fetch(path, {
      ...opts,
      headers: { "Content-Type": "application/json", ...(opts.headers || {}) },
    });
    const text = await res.text();
    let data = text;
    try { data = JSON.parse(text); } catch { /* raw */ }
    if (!res.ok) throw new Error((data && data.error) || text || res.statusText);
    return data;
  }

  function openSidebar() {
    state.sidebarOpen = true;
    els.sidebar.classList.add("open");
    els.scrim.hidden = false;
  }
  function closeSidebar() {
    state.sidebarOpen = false;
    els.sidebar.classList.remove("open");
    els.scrim.hidden = true;
  }

  function syncSidebarButton() {
    if (!els.menuBtn) return;
    if (isPhone()) {
      els.menuBtn.setAttribute("aria-label", "Open notes");
      els.menuBtn.title = "Open notes";
      return;
    }
    const hidden = state.sidebarCollapsed;
    els.menuBtn.setAttribute("aria-label", hidden ? "Show sidebar" : "Hide sidebar");
    els.menuBtn.title = hidden ? "Show sidebar" : "Hide sidebar";
    els.menuBtn.classList.toggle("active", hidden);
  }

  function toggleSidebarPane() {
    if (isPhone()) {
      if (state.sidebarOpen) closeSidebar();
      else openSidebar();
      return;
    }
    state.sidebarCollapsed = !state.sidebarCollapsed;
    document.getElementById("app").classList.toggle("sidebar-collapsed", state.sidebarCollapsed);
    syncSidebarButton();
  }

  function parentDir(path) {
    if (!path) return "";
    const i = path.lastIndexOf("/");
    return i === -1 ? "" : path.slice(0, i);
  }

  function newNoteDirectory() {
    if (state.selectedDir) return state.selectedDir;
    if (state.path) return parentDir(state.path);
    return "";
  }

  async function loadVaults() {
    try {
      state.vaults = await api("/api/vaults");
      const active = state.vaults.find((v) => v.active) || state.vaults[0];
      const name = (active && active.name) || "Notebook";
      const label = document.getElementById("vaultName");
      if (label) label.textContent = name;
      else els.vaultBtn.textContent = name;
    } catch {
      const v = await api("/api/vault").catch(() => null);
      const name = (v && v.name) || "Notebook";
      const label = document.getElementById("vaultName");
      if (label) label.textContent = name;
      else els.vaultBtn.textContent = name;
    }
  }

  async function loadTree() {
    state.tree = await api("/api/tree");
    pruneSelection();
    renderTree();
  }

  function renderTree() {
    // Built off-document and attached in one go: appending row by row to the
    // live tree made the browser lay out after every row, which on a few
    // thousand notes is most of what a refresh costs.
    const frag = document.createDocumentFragment();
    if (state.searching && state.query.trim()) {
      if (!state.results.length) {
        const empty = document.createElement("div");
        empty.className = "snippet";
        empty.textContent = "No notes found";
        frag.appendChild(empty);
      } else {
        state.results.forEach((r) => frag.appendChild(fileRow(r.path, r.title, r.snippet)));
      }
      els.tree.innerHTML = "";
      els.tree.appendChild(frag);
      return;
    }
    (state.tree || []).forEach((n) => frag.appendChild(nodeEl(n, 0)));
    els.tree.innerHTML = "";
    els.tree.appendChild(frag);
    if (state.renamingPath) {
      const input = els.tree.querySelector(".rename-input");
      if (input) {
        input.focus();
        input.select();
      }
    }
  }

  // Rows in the order they are drawn. Read from the DOM rather than walked
  // from `state.tree`, because a shift-range means the rows you can actually
  // see between two clicks — collapsed folders hide their children from it.
  function visibleRowPaths() {
    return Array.from(els.tree.querySelectorAll(".row[data-path]"))
      .map((row) => row.getAttribute("data-path"));
  }

  function selectedPaths() {
    // Always top-to-bottom, so a multi-item drop lands in the order the rows
    // were shown in rather than whatever order the set happens to iterate.
    return visibleRowPaths().filter((p) => state.selection.has(p));
  }

  function selectOnly(path) {
    state.selection = new Set([path]);
    state.selectionAnchor = path;
    syncTreeSelection();
  }

  function toggleSelected(path) {
    if (state.selection.has(path)) state.selection.delete(path);
    else state.selection.add(path);
    state.selectionAnchor = path;
    syncTreeSelection();
  }

  function selectRangeTo(path) {
    const rows = visibleRowPaths();
    const anchor = rows.includes(state.selectionAnchor) ? state.selectionAnchor : path;
    const from = rows.indexOf(anchor);
    const to = rows.indexOf(path);
    if (from < 0 || to < 0) return;
    const lo = Math.min(from, to);
    const hi = Math.max(from, to);
    state.selection = new Set(rows.slice(lo, hi + 1));
    syncTreeSelection();
  }

  function clearSelection() {
    if (!state.selection.size && !state.selectionAnchor) return;
    state.selection.clear();
    state.selectionAnchor = null;
    syncTreeSelection();
  }

  // A modifier click only changes the selection — it must not also open the
  // note under the pointer, which is the whole point of holding the key.
  function handledAsSelectionClick(path, e) {
    if (e.metaKey || e.ctrlKey) {
      toggleSelected(path);
      return true;
    }
    if (e.shiftKey) {
      selectRangeTo(path);
      return true;
    }
    return false;
  }

  // Paths whose parent isn't also selected. Deleting a folder takes its
  // children with it, so acting on both would fail on the second one.
  function outermost(paths) {
    return paths.filter((p) => !paths.some((q) => q !== p && p.startsWith(q + "/")));
  }

  // A move or a reload can leave the selection naming rows that are gone.
  function pruneSelection() {
    if (!state.selection.size) return;
    const live = new Set();
    const walk = (nodes) => (nodes || []).forEach((n) => {
      live.add(n.path);
      walk(n.children);
    });
    walk(state.tree);
    state.selection.forEach((p) => { if (!live.has(p)) state.selection.delete(p); });
    if (state.selectionAnchor && !live.has(state.selectionAnchor)) state.selectionAnchor = null;
  }

  // Moves the highlight and nothing else. Opening a note or picking a folder
  // used to call `renderTree()`, which threw away and rebuilt every row —
  // and every row's four event listeners — to change one class.
  function syncTreeSelection() {
    els.tree.querySelectorAll(".row.selected").forEach((el) => el.classList.remove("selected"));
    const marked = new Set(state.selection);
    [state.path, state.selectedDir].forEach((p) => { if (p) marked.add(p); });
    marked.forEach((p) => {
      const row = rowForPath(p);
      if (row) row.classList.add("selected");
    });
  }

  function ancestorDirs(path) {
    if (!path) return [];
    const parts = path.split("/").filter(Boolean);
    const dirs = [];
    for (let i = 1; i < parts.length; i++) {
      dirs.push(parts.slice(0, i).join("/"));
    }
    return dirs;
  }

  function expandToPath(path) {
    if (!path) return;
    state.collapsed.delete(path);
    ancestorDirs(path).forEach((dir) => state.collapsed.delete(dir));
  }

  function rowForPath(path) {
    // Scanned in place — the spread this used to do copied every row in the
    // tree into a throwaway array before looking at the first one.
    const rows = els.tree.querySelectorAll("[data-path]");
    for (let i = 0; i < rows.length; i++) {
      if (rows[i].getAttribute("data-path") === path) return rows[i];
    }
    return null;
  }

  function revealSelectionInTree() {
    const path = state.path || state.selectedDir;
    if (path) expandToPath(path);
    renderTree();
    if (!path) return;
    requestAnimationFrame(() => {
      const row = rowForPath(path);
      if (row) row.scrollIntoView({ block: "center", inline: "nearest", behavior: "smooth" });
    });
  }

  function nodeEl(node, depth) {
    if (node.isDirectory) {
      const wrap = document.createElement("div");
      const row = document.createElement("div");
      row.className = "row dir" + (state.selectedDir === node.path ? " selected" : "");
      row.dataset.path = node.path;
      row.style.marginLeft = depth ? `${depth * 14}px` : "0";
      const collapsed = state.collapsed.has(node.path);
      const chev = document.createElement("span");
      chev.className = "chevron";
      chev.innerHTML = iconHTML(collapsed ? "chevronRight" : "chevronDown");
      const icon = iconEl(collapsed ? "folder" : "folderFill");
      row.append(chev, icon);

      const kids = document.createElement("div");
      kids.hidden = collapsed;

      if (state.renamingPath === node.path) {
        const input = document.createElement("input");
        input.className = "rename-input";
        input.value = node.title;
        input.addEventListener("click", (e) => e.stopPropagation());
        input.addEventListener("keydown", (e) => {
          if (e.key === "Enter") {
            e.preventDefault();
            commitRename(node.path, input.value, false);
          } else if (e.key === "Escape") {
            e.preventDefault();
            cancelRename();
          }
        });
        input.addEventListener("blur", () => {
          if (state.renamingPath === node.path) commitRename(node.path, input.value, false);
        });
        row.appendChild(input);
      } else {
        const label = document.createElement("span");
        label.className = "label";
        label.textContent = node.title;
        row.appendChild(label);
      }

      chev.addEventListener("click", (e) => {
        e.stopPropagation();
        if (state.collapsed.has(node.path)) state.collapsed.delete(node.path);
        else state.collapsed.add(node.path);
        const nowCollapsed = state.collapsed.has(node.path);
        kids.hidden = nowCollapsed;
        chev.innerHTML = iconHTML(nowCollapsed ? "chevronRight" : "chevronDown");
        icon.innerHTML = iconHTML(nowCollapsed ? "folder" : "folderFill");
      });
      row.addEventListener("click", (e) => {
        if (state.renamingPath === node.path) return;
        if (handledAsSelectionClick(node.path, e)) return;
        selectOnly(node.path);
        state.selectedDir = node.path;
        state.path = null;
        setDocumentTitle(node.title);
        els.noteTitle.textContent = node.title;
        els.rawEditor.value = "";
        els.cookedView.innerHTML = "";
        syncTreeSelection();
      });
      const dirItem = {
        path: node.path,
        title: node.title,
        isDirectory: true,
        manualOrder: !!node.manualOrder,
      };
      bindItemMenu(row, dirItem);
      bindItemDrag(row, dirItem);
      (node.children || []).forEach((c) => kids.appendChild(nodeEl(c, depth + 1)));
      wrap.append(row, kids);
      return wrap;
    }
    return fileRow(node.path, node.title, null, depth);
  }

  function fileRow(path, title, snippet, depth) {
    const row = document.createElement("div");
    row.className = "row" + (state.path === path ? " selected" : "");
    row.dataset.path = path;
    if (depth) row.style.marginLeft = `${depth * 14}px`;
    // Reserves the disclosure chevron's width so this file's icon lines up
    // with a sibling folder's icon at the same depth, instead of sitting one
    // column to its left.
    const spacer = document.createElement("span");
    spacer.className = "chevron-spacer";
    row.appendChild(spacer);
    row.appendChild(iconEl("doc"));

    if (state.renamingPath === path) {
      const input = document.createElement("input");
      input.className = "rename-input";
      input.value = title;
      input.addEventListener("click", (e) => e.stopPropagation());
      input.addEventListener("keydown", (e) => {
        if (e.key === "Enter") {
          e.preventDefault();
          commitRename(path, input.value, true);
        } else if (e.key === "Escape") {
          e.preventDefault();
          cancelRename();
        }
      });
      input.addEventListener("blur", () => {
        if (state.renamingPath === path) commitRename(path, input.value, false);
      });
      row.appendChild(input);
    } else {
      const label = document.createElement("span");
      label.className = "label";
      label.textContent = title;
      row.appendChild(label);
    }

    row.addEventListener("click", (e) => {
      if (state.renamingPath === path) return;
      if (handledAsSelectionClick(path, e)) return;
      selectOnly(path);
      openNote(path);
    });
    const fileItem = { path, title, isDirectory: false };
    bindItemMenu(row, fileItem);
    if (!snippet) bindItemDrag(row, fileItem);

    if (snippet) {
      const wrap = document.createElement("div");
      const sn = document.createElement("div");
      sn.className = "snippet";
      sn.textContent = snippet;
      wrap.append(row, sn);
      return wrap;
    }
    return row;
  }

  // Right-click only. The touch long press used to live here too, but it has
  // to decide between opening the menu and picking the row up, so it moved
  // into `bindItemDrag` where that state is.
  async function deleteSelected() {
    // Only the outermost paths: deleting a folder takes its children with it,
    // and the request for a child would then be deleting something gone.
    const paths = outermost(selectedPaths());
    if (!paths.length) return;
    const covers = (p) => paths.some((q) => p === q || p.startsWith(q + "/"));
    if (!confirm("Move " + paths.length + " item" + (paths.length === 1 ? "" : "s") + " to Trash?")) return;
    if (pendingSave && covers(pendingSave.path)) dropPendingSave();
    for (const path of paths) {
      await api("/api/note?path=" + encodeURIComponent(path), { method: "DELETE" });
    }
    if (state.path && covers(state.path)) {
      state.path = null;
      setDocumentTitle(null);
      els.noteTitle.textContent = "Select a note";
      els.rawEditor.value = "";
      els.cookedView.innerHTML = "";
    }
    if (state.selectedDir && covers(state.selectedDir)) state.selectedDir = null;
    clearSelection();
    await loadTree();
  }

  /// Whether a menu opened on `item` should act on the whole selection.
  function actsOnSelection(item) {
    return state.selection.size > 1 && state.selection.has(item.path);
  }

  function bindItemMenu(row, item) {
    row.addEventListener("contextmenu", (e) => {
      e.preventDefault();
      showContextMenu(e.clientX, e.clientY, item);
    });
  }

  function showContextMenu(x, y, item) {
    hideMenus();
    const m = els.ctxMenu;
    m.hidden = false;
    m.innerHTML = "";
    const add = (label, fn, danger) => {
      const b = document.createElement("button");
      b.textContent = label;
      if (danger) b.className = "danger";
      b.addEventListener("click", () => { hideMenus(); fn(); });
      m.appendChild(b);
    };
    if (actsOnSelection(item)) {
      // Renaming several things at once means nothing, so the multi-selection
      // menu offers only what applies to all of them.
      add("Delete " + state.selection.size + " Items", () => deleteSelected(), true);
    } else {
      if (item.isDirectory) {
        add("Expand All", () => expandAllUnder(item.path));
        add("Collapse All", () => collapseAllUnder(item.path));
        if (item.manualOrder) add("Sort by Name", () => clearManualOrder(item.path));
      }
      add("Rename", () => startRename(item.path, item.title));
      add("Delete", () => deleteNote(item.path, item.isDirectory), true);
    }
    requestAnimationFrame(() => {
      const r = m.getBoundingClientRect();
      m.style.left = Math.min(x, window.innerWidth - r.width - 8) + "px";
      m.style.top = Math.min(y, window.innerHeight - r.height - 8) + "px";
    });
  }

  function showSheet(item) {
    hideMenus();
    els.sheet.hidden = false;
    els.sheetCard.innerHTML = "";
    const add = (label, fn, danger) => {
      const b = document.createElement("button");
      b.textContent = label;
      if (danger) b.className = "danger";
      b.addEventListener("click", () => { hideMenus(); fn(); });
      els.sheetCard.appendChild(b);
    };
    if (actsOnSelection(item)) {
      add("Delete " + state.selection.size + " Items", () => deleteSelected(), true);
    } else {
      if (item.isDirectory) {
        add("Expand All", () => expandAllUnder(item.path));
        add("Collapse All", () => collapseAllUnder(item.path));
        if (item.manualOrder) add("Sort by Name", () => clearManualOrder(item.path));
      }
      add("Rename", () => startRename(item.path, item.title));
      add("Delete", () => deleteNote(item.path, item.isDirectory), true);
    }
    add("Cancel", () => {});
  }

  function hideMenus() {
    els.ctxMenu.hidden = true;
    els.sheet.hidden = true;
    els.vaultMenu.hidden = true;
  }

  function startRename(path, title) {
    state.renamingPath = path;
    renderTree();
  }

  function cancelRename() {
    state.renamingPath = null;
    renderTree();
  }

  async function commitRename(path, title, focusEditor) {
    if (state.renamingPath !== path && !focusEditor) return;
    state.renamingPath = null;
    try {
      // Ahead of the rename, so a queued write can't recreate the old
      // filename a moment after the file moves.
      await flushSave().catch(console.error);
      const res = await api("/api/note", {
        method: "PATCH",
        body: JSON.stringify({ path, title }),
      });
      await loadTree();
      if (res.path && res.isDirectory) {
        state.selectedDir = res.path;
        setDocumentTitle(res.title);
        els.noteTitle.textContent = res.title;
      } else if (res.path) {
        await openNote(res.path);
        if (focusEditor) focusEditorPane();
      }
    } catch (err) {
      console.error(err);
      await loadTree();
    }
  }

  async function expandAllUnder(path) {
    try {
      const data = await api("/api/note/collapse", { method: "POST", body: JSON.stringify({ path }) });
      (data.paths || []).forEach((p) => state.collapsed.delete(p));
      renderTree();
    } catch (err) { console.error(err); }
  }

  async function collapseAllUnder(path) {
    try {
      const data = await api("/api/note/collapse", { method: "POST", body: JSON.stringify({ path }) });
      (data.paths || []).forEach((p) => state.collapsed.add(p));
      renderTree();
    } catch (err) { console.error(err); }
  }

  async function deleteNote(path, isDirectory) {
    const msg = isDirectory
      ? "Move this folder and everything inside it to Trash?"
      : "Move this note to Trash?";
    if (!confirm(msg)) return;
    // Otherwise a save queued seconds ago fires after the delete and writes
    // the file straight back.
    if (pendingSave && (pendingSave.path === path
        || (isDirectory && pendingSave.path.startsWith(path + "/")))) {
      dropPendingSave();
    }
    await api("/api/note?path=" + encodeURIComponent(path), { method: "DELETE" });
    if (state.path === path || (isDirectory && state.path && state.path.startsWith(path + "/"))) {
      state.path = null;
      setDocumentTitle(null);
      els.noteTitle.textContent = "Select a note";
      els.rawEditor.value = "";
      els.cookedView.innerHTML = "";
    }
    if (state.selectedDir === path) state.selectedDir = null;
    await loadTree();
  }

  function focusEditorPane() {
    setMode("uncooked");
    els.rawEditor.focus();
  }

  async function openNote(path) {
    // Land whatever is still queued for the note we're leaving before its
    // buffer is overwritten below.
    await flushSave().catch(console.error);
    const note = await api("/api/note?path=" + encodeURIComponent(path));
    state.path = path;
    state.selectedDir = null;
    state.title = note.title;
    state.content = note.content;
    setDocumentTitle(note.title);
    els.noteTitle.textContent = note.title;
    els.rawEditor.value = note.content;
    renderCooked();
    syncTreeSelection();
    if (isPhone()) closeSidebar();
  }

  // The queued write is bound to the note it came from. The timer used to read
  // `state.path` and `state.content` at the moment it fired, so switching
  // notes inside the 300ms window PUT the *new* note's text back to the new
  // note and silently dropped the edit to the old one.
  let pendingSave = null;

  function queueSave() {
    state.content = els.rawEditor.value;
    if (state.mode === "cooked") renderCooked();
    clearTimeout(state.saveTimer);
    if (!state.path) return;
    pendingSave = { path: state.path, content: state.content };
    state.saveTimer = setTimeout(() => {
      state.saveTimer = null;
      flushSave().catch(console.error);
    }, 300);
  }

  async function flushSave() {
    if (!pendingSave) return;
    const { path, content } = pendingSave;
    pendingSave = null;
    clearTimeout(state.saveTimer);
    state.saveTimer = null;
    await api("/api/note?path=" + encodeURIComponent(path), {
      method: "PUT",
      body: JSON.stringify({ content }),
    });
  }

  function dropPendingSave() {
    clearTimeout(state.saveTimer);
    state.saveTimer = null;
    pendingSave = null;
  }

  // Renders are in flight across note switches, and the slower one used to
  // win — painting the wrong note, then paying for its KaTeX and Mermaid
  // passes on top.
  let cookedSeq = 0;

  async function renderCooked() {
    if (!state.path) {
      cookedSeq++;
      els.cookedView.innerHTML = "<p class='muted'>Select a note</p>";
      return;
    }
    const seq = ++cookedSeq;
    try {
      const data = await api("/api/render?path=" + encodeURIComponent(state.path));
      if (seq !== cookedSeq) return;
      els.cookedView.innerHTML = data.html || "";
      bindWikiClicks(els.cookedView);
      try {
        if (window.mermaid) window.mermaid.run({ querySelector: ".mermaid" });
      } catch (e) { /* optional */ }
      try {
        if (window.katex) {
          els.cookedView.querySelectorAll(".math-inline").forEach((el) => {
            window.katex.render(el.getAttribute("data-latex") || el.textContent, el, { throwOnError: false, displayMode: false });
          });
          els.cookedView.querySelectorAll(".math-block").forEach((el) => {
            window.katex.render(el.getAttribute("data-latex") || el.textContent, el, { throwOnError: false, displayMode: true });
          });
        }
      } catch (e) { /* optional */ }
    } catch {
      if (seq !== cookedSeq) return;
      els.cookedView.innerHTML = markdownToHtml(els.rawEditor.value);
    }
  }

  function bindWikiClicks(root) {
    root.querySelectorAll("a.wikilink").forEach((a) => {
      a.addEventListener("click", (e) => {
        e.preventDefault();
        const path = a.getAttribute("data-path");
        const target = a.getAttribute("data-target");
        if (path) openNote(path).catch(console.error);
        else if (target) {
          api("/api/note", { method: "POST", body: JSON.stringify({ name: target }) })
            .then((created) => created && created.path && openNote(created.path))
            .catch(console.error);
        }
      });
    });
  }

  function markdownToHtml(src) {
    const escaped = src.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
    const lines = escaped.split("\n");
    let html = "";
    let inCode = false;
    for (const line of lines) {
      if (line.startsWith("```")) {
        if (inCode) { html += "</code></pre>"; inCode = false; }
        else { html += "<pre><code>"; inCode = true; }
        continue;
      }
      if (inCode) { html += line + "\n"; continue; }
      if (/^### /.test(line)) html += `<h3>${inline(line.slice(4))}</h3>`;
      else if (/^## /.test(line)) html += `<h2>${inline(line.slice(3))}</h2>`;
      else if (/^# /.test(line)) html += `<h1>${inline(line.slice(2))}</h1>`;
      else if (/^[-*] /.test(line)) html += `<p>• ${inline(line.slice(2))}</p>`;
      else if (!line.trim()) html += "<p></p>";
      else html += `<p>${inline(line)}</p>`;
    }
    if (inCode) html += "</code></pre>";
    return html;
  }
  function inline(s) {
    return s
      .replace(/`([^`]+)`/g, "<code>$1</code>")
      .replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>")
      .replace(/\*([^*]+)\*/g, "<em>$1</em>");
  }

  function setMode(mode) {
    state.mode = mode;
    els.eggBtn.dataset.mode = mode;
    const cooked = mode === "cooked";
    els.rawEditor.hidden = cooked;
    els.cookedView.hidden = !cooked;
    els.eggBtn.title = cooked ? "Cooked — rendered" : "Uncooked — raw text";
    drawEgg();
    if (cooked) renderCooked();
    else els.rawEditor.focus();
  }

  function drawEgg() {
    const svg = els.eggSvg;
    if (state.mode === "uncooked") {
      svg.innerHTML = '<ellipse cx="12" cy="13" rx="6.2" ry="8" fill="#f4ead0" stroke="#8a7048" stroke-width="1"/><ellipse cx="10" cy="9.5" rx="2.2" ry="2.6" fill="#fff" opacity=".7"/>';
    } else {
      svg.innerHTML = '<path d="M4 14c0-4 3-8 8-8s9 3 9 8-4 8-9 7-8-3-8-7z" fill="#fff" stroke="#ccc"/><circle cx="13" cy="13" r="4.2" fill="#f0a020"/><circle cx="12" cy="11.5" r="1.3" fill="#fff" opacity=".75"/>';
    }
  }

  async function newNote() {
    const body = { name: "Untitled" };
    const dir = newNoteDirectory();
    if (dir) body.directory = dir;
    const created = await api("/api/note", { method: "POST", body: JSON.stringify(body) });
    await loadTree();
    if (created && created.path) {
      state.path = created.path;
      state.selectedDir = null;
      state.renamingPath = created.path;
      await openNote(created.path);
      state.renamingPath = created.path;
      renderTree();
    }
  }

  async function openSearch() {
    state.searching = true;
    els.searchBar.hidden = false;
    els.searchToggle.classList.add("active");
    els.searchInput.focus();
  }

  async function closeSearch() {
    if (!state.searching || state.searchAlwaysVisible) return;
    state.searching = false;
    els.searchBar.hidden = true;
    els.searchToggle.classList.remove("active");
    state.query = "";
    els.searchInput.value = "";
    state.results = [];
    // Retires both a debounced keystroke and any request still in flight, so
    // neither can repaint the tree with results for a closed search.
    clearTimeout(searchTimer);
    searchTimer = null;
    searchSeq++;
    revealSelectionInTree();
  }

  async function toggleSearch() {
    if (state.searching) closeSearch();
    else openSearch();
  }

  async function toggleGraph() {
    if (state.graph) closeGraph();
    else await openGraph();
  }

  function closeGraph() {
    state.graph = false;
    if (els.graph) els.graph.hidden = true;
    if (els.graphBtn) els.graphBtn.classList.remove("active");
  }

  async function openGraph() {
    state.graph = true;
    if (els.graph) els.graph.hidden = false;
    if (els.graphBtn) els.graphBtn.classList.add("active");
    try {
      const data = await api("/api/graph");
      state.graphNodes = data.nodes || [];
      state.graphEdges = data.edges || [];
      layoutGraph();
      drawGraph();
    } catch (e) {
      console.error(e);
    }
  }

  // Whichever search is currently open, as a set of matching paths — or null
  // when nothing is being searched. Mirrors the Mac app, where either search
  // dims the graph and the absence of one leaves it at full strength.
  function graphMatches() {
    if (state.omni && state.omniQuery.trim()) {
      return new Set((state.omniResults || []).map((r) => r.path));
    }
    if (state.searching && state.query.trim()) {
      return new Set((state.results || []).map((r) => r.path));
    }
    return null;
  }

  function layoutGraph() {
    const nodes = state.graphNodes;
    const n = nodes.length;
    const w = (els.graphCanvas && els.graphCanvas.parentElement.clientWidth) || 600;
    const h = (els.graphCanvas && els.graphCanvas.parentElement.clientHeight) || 400;
    nodes.forEach((node, i) => {
      const a = (i / Math.max(n, 1)) * Math.PI * 2;
      node.x = w / 2 + Math.cos(a) * Math.min(w, h) * 0.28;
      node.y = h / 2 + Math.sin(a) * Math.min(w, h) * 0.28;
    });
    const idx = Object.fromEntries(nodes.map((node, i) => [node.id, i]));
    // Allocated once and zeroed per pass — this used to build two fresh arrays
    // on each of the 60 iterations.
    const vx = new Array(n).fill(0);
    const vy = new Array(n).fill(0);
    for (let iter = 0; iter < 60; iter++) {
      vx.fill(0);
      vy.fill(0);
      for (let i = 0; i < n; i++) {
        for (let j = i + 1; j < n; j++) {
          const dx = nodes[j].x - nodes[i].x;
          const dy = nodes[j].y - nodes[i].y;
          const d2 = Math.max(dx * dx + dy * dy, 25);
          const f = 1400 / d2;
          const d = Math.sqrt(d2);
          vx[i] -= (dx / d) * f; vy[i] -= (dy / d) * f;
          vx[j] += (dx / d) * f; vy[j] += (dy / d) * f;
        }
      }
      (state.graphEdges || []).forEach((e) => {
        const ia = idx[e.from], ib = idx[e.to];
        if (ia == null || ib == null) return;
        const dx = nodes[ib].x - nodes[ia].x;
        const dy = nodes[ib].y - nodes[ia].y;
        const dist = Math.sqrt(dx * dx + dy * dy) + 0.01;
        const f = (dist - 80) * 0.03;
        vx[ia] += (dx / dist) * f; vy[ia] += (dy / dist) * f;
        vx[ib] -= (dx / dist) * f; vy[ib] -= (dy / dist) * f;
      });
      nodes.forEach((node, i) => {
        node.x = Math.min(w - 30, Math.max(30, node.x + vx[i] * 0.5));
        node.y = Math.min(h - 30, Math.max(30, node.y + vy[i] * 0.5));
      });
    }
  }

  function drawGraph() {
    const canvas = els.graphCanvas;
    if (!canvas) return;
    const parent = canvas.parentElement;
    const dpr = window.devicePixelRatio || 1;
    const w = parent.clientWidth;
    const h = parent.clientHeight;
    canvas.width = w * dpr;
    canvas.height = h * dpr;
    canvas.style.width = w + "px";
    canvas.style.height = h + "px";
    const g = canvas.getContext("2d");
    g.setTransform(dpr, 0, 0, dpr, 0, 0);
    g.clearRect(0, 0, w, h);
    const idx = Object.fromEntries((state.graphNodes || []).map((n) => [n.id, n]));
    const matches = graphMatches();
    const hit = (path) => !matches || matches.has(path);
    g.lineWidth = 1;
    (state.graphEdges || []).forEach((e) => {
      const a = idx[e.from], b = idx[e.to];
      if (!a || !b) return;
      // Recessive rather than hidden: the shape of the vault is what makes
      // the matches worth looking at.
      g.strokeStyle = hit(e.from) && hit(e.to)
        ? "rgba(160,160,160,0.4)"
        : "rgba(160,160,160,0.1)";
      g.beginPath();
      g.moveTo(a.x, a.y);
      g.lineTo(b.x, b.y);
      g.stroke();
    });
    // Read once. `getComputedStyle` was being called twice per node inside the
    // loop, each one a forced style resolve, and the font and alignment were
    // re-set just as often to the same values.
    const textColor = getComputedStyle(document.body).color;
    g.font = "11px -apple-system, sans-serif";
    g.textAlign = "center";
    (state.graphNodes || []).forEach((n) => {
      const dim = !hit(n.path) && n.path !== state.path;
      g.globalAlpha = dim ? 0.22 : 1;
      g.beginPath();
      g.arc(n.x, n.y, n.unresolved ? 4 : 7, 0, Math.PI * 2);
      g.fillStyle = n.unresolved ? "rgba(160,160,160,0.5)" : (n.path === state.path ? "#0a84ff" : textColor);
      g.fill();
      // A dimmed node keeps its dot but loses its label: at vault scale the
      // labels are most of the ink, and leaving them all up is what stops a
      // search from reading as a narrowing.
      if (!n.unresolved && !dim) {
        g.fillStyle = textColor;
        g.fillText(n.title, n.x, n.y + 18);
      }
      g.globalAlpha = 1;
    });
  }

  // Every search hits the Mac app's index on its main actor, so a request per
  // keystroke is the wrong shape for a phone typing over the LAN. Coalesce the
  // keystrokes, and discard any answer a later one has already superseded —
  // responses can and do come back out of order.
  let searchSeq = 0;
  let searchTimer = null;

  function scheduleSearch() {
    clearTimeout(searchTimer);
    searchTimer = setTimeout(() => {
      searchTimer = null;
      runSearch().catch(console.error);
    }, 120);
  }

  async function runSearch() {
    const seq = ++searchSeq;
    state.query = els.searchInput.value;
    if (!state.query.trim()) {
      state.results = [];
      renderTree();
      if (state.graph) drawGraph();
      return;
    }
    const results = await api("/api/search?q=" + encodeURIComponent(state.query));
    if (seq !== searchSeq) return;
    state.results = results;
    renderTree();
    if (state.graph) drawGraph();
  }

  let omniSeq = 0;
  let omniTimer = null;

  function openOmnibar() {
    state.omni = true;
    els.omnibar.hidden = false;
    els.omniInput.value = "";
    state.omniQuery = "";
    state.omniResults = [];
    state.omniIndex = 0;
    clearTimeout(omniTimer);
    omniTimer = null;
    omniSeq++;
    els.omniResults.innerHTML = "";
    els.omniInput.focus();
  }

  function closeOmnibar() {
    state.omni = false;
    els.omnibar.hidden = true;
    clearTimeout(omniTimer);
    omniTimer = null;
    omniSeq++;
  }

  function scheduleOmni() {
    clearTimeout(omniTimer);
    omniTimer = setTimeout(() => {
      omniTimer = null;
      runOmni().catch(console.error);
    }, 120);
  }

  async function runOmni() {
    const seq = ++omniSeq;
    state.omniQuery = els.omniInput.value;
    if (!state.omniQuery.trim()) {
      state.omniResults = [];
      renderOmni();
      if (state.graph) drawGraph();
      return;
    }
    const results = await api("/api/search?q=" + encodeURIComponent(state.omniQuery));
    if (seq !== omniSeq) return;
    state.omniResults = results;
    state.omniIndex = 0;
    renderOmni();
    if (state.graph) drawGraph();
  }

  function renderOmni() {
    const frag = document.createDocumentFragment();
    if (!state.omniResults.length) {
      const empty = document.createElement("div");
      empty.className = "omni-hit";
      empty.textContent = state.omniQuery ? "No notes found" : "Type to search notes";
      frag.appendChild(empty);
    } else {
      state.omniResults.forEach((r, i) => {
        const d = document.createElement("div");
        d.className = "omni-hit" + (i === state.omniIndex ? " sel" : "");
        d.innerHTML = `<div class="t"></div><div class="s"></div>`;
        d.querySelector(".t").textContent = r.title;
        d.querySelector(".s").textContent = r.snippet || r.path;
        d.addEventListener("click", () => selectOmni(i));
        frag.appendChild(d);
      });
    }
    els.omniResults.innerHTML = "";
    els.omniResults.appendChild(frag);
  }

  // Arrow keys only move the highlight; re-running `renderOmni` for that threw
  // away and rebuilt every hit, and its click listener, per keypress.
  function syncOmniSelection() {
    if (!state.omniResults.length) return;
    const hits = els.omniResults.children;
    for (let i = 0; i < hits.length; i++) {
      hits[i].classList.toggle("sel", i === state.omniIndex);
    }
  }

  async function selectOmni(i) {
    const r = state.omniResults[i];
    if (!r) return;
    closeOmnibar();
    await openNote(r.path);
    revealSelectionInTree();
    focusEditorPane();
  }

  function toggleVaultMenu() {
    if (!els.vaultMenu.hidden) {
      els.vaultMenu.hidden = true;
      return;
    }
    hideMenus();
    els.vaultMenu.hidden = false;
    els.vaultMenu.innerHTML = "";
    (state.vaults || []).forEach((v) => {
      const b = document.createElement("button");
      b.innerHTML = `<span class="label"></span>${v.active ? iconHTML("check") : ""}`;
      b.querySelector(".label").textContent = v.name;
      if (v.active) b.className = "active";
      b.addEventListener("click", async () => {
        els.vaultMenu.hidden = true;
        await api("/api/vault/select", { method: "POST", body: JSON.stringify({ id: v.id }) });
        state.path = null;
        state.selectedDir = null;
        setDocumentTitle(null);
        els.noteTitle.textContent = "Select a note";
        els.rawEditor.value = "";
        await loadVaults();
        await loadTree();
      });
      els.vaultMenu.appendChild(b);
    });
  }

  function bindSwipe() {
    let startX = 0, startY = 0, tracking = false;
    document.addEventListener("touchstart", (e) => {
      if (!isPhone() || e.touches.length !== 1) return;
      const t = e.touches[0];
      startX = t.clientX;
      startY = t.clientY;
      tracking = startX <= 24 || state.sidebarOpen;
    }, { passive: true });
    document.addEventListener("touchmove", (e) => {
      if (!tracking || e.touches.length !== 1) return;
      // A note being carried across the sidebar is not a swipe at it.
      if (drag.active) return;
      const t = e.touches[0];
      const dx = t.clientX - startX;
      const dy = t.clientY - startY;
      if (Math.abs(dy) > Math.abs(dx)) return;
      if (!state.sidebarOpen && dx > 40) openSidebar();
      if (state.sidebarOpen && dx < -40) closeSidebar();
    }, { passive: true });
    document.addEventListener("touchend", () => { tracking = false; }, { passive: true });
  }

  function preventChromeGestures() {
    ["gesturestart", "gesturechange", "gestureend"].forEach((ev) => {
      document.addEventListener(ev, (e) => e.preventDefault());
    });
    document.addEventListener("touchmove", (e) => {
      if (e.touches.length > 1) e.preventDefault();
    }, { passive: false });
  }

  function onKey(e) {
    const meta = e.metaKey || e.ctrlKey;
    if (state.omni) {
      if (e.key === "Escape") { e.preventDefault(); closeOmnibar(); return; }
      if (e.key === "ArrowDown") {
        e.preventDefault();
        state.omniIndex = Math.min(state.omniIndex + 1, Math.max(0, state.omniResults.length - 1));
        syncOmniSelection();
      }
      if (e.key === "ArrowUp") {
        e.preventDefault();
        state.omniIndex = Math.max(state.omniIndex - 1, 0);
        syncOmniSelection();
      }
      if (e.key === "Enter") { e.preventDefault(); selectOmni(state.omniIndex); }
      return;
    }
    if (e.key === "Escape") {
      hideMenus();
      if (state.graph) { e.preventDefault(); closeGraph(); return; }
      if (state.searching) {
        e.preventDefault();
        closeSearch();
      }
      return;
    }
    if (e.ctrlKey && !e.metaKey && !e.altKey && e.key.toLowerCase() === "f") {
      e.preventDefault();
      openSearch();
      return;
    }
    if (!meta) return;
    const k = e.key.toLowerCase();
    if (k === "n") { e.preventDefault(); newNote().catch(console.error); }
    else if (k === "f") { e.preventDefault(); openSearch(); }
    else if (k === "k") { e.preventDefault(); openOmnibar(); }
    else if (k === "e") { e.preventDefault(); setMode(state.mode === "uncooked" ? "cooked" : "uncooked"); }
  }

  els.menuBtn.addEventListener("click", toggleSidebarPane);
  syncSidebarButton();
  phoneQuery.addEventListener("change", () => {
    document.getElementById("app").classList.toggle("sidebar-collapsed", !isPhone() && state.sidebarCollapsed);
    syncSidebarButton();
  });
  els.scrim.addEventListener("click", () => { closeSidebar(); hideMenus(); });
  els.newBtn.addEventListener("click", () => newNote().catch(console.error));
  els.refreshBtn.addEventListener("click", () => loadTree().catch(console.error));
  els.searchToggle.addEventListener("click", () => toggleSearch().catch(console.error));
  if (els.graphBtn) els.graphBtn.addEventListener("click", () => toggleGraph().catch(console.error));
  els.searchClose.addEventListener("click", () => toggleSearch().catch(console.error));
  els.searchInput.addEventListener("input", scheduleSearch);
  els.searchInput.addEventListener("keydown", (e) => {
    if (e.key === "Enter" && state.results[0]) openNote(state.results[0].path);
  });
  els.rawEditor.addEventListener("input", queueSave);
  els.rawEditor.addEventListener("mousedown", () => {
    if (state.renamingPath) {
      const input = els.tree.querySelector(".rename-input");
      if (input) commitRename(state.renamingPath, input.value, true);
    }
  });
  els.eggBtn.addEventListener("click", () => setMode(state.mode === "uncooked" ? "cooked" : "uncooked"));
  if (els.graphCanvas) {
    els.graphCanvas.addEventListener("click", (e) => {
      const rect = els.graphCanvas.getBoundingClientRect();
      const x = e.clientX - rect.left;
      const y = e.clientY - rect.top;
      const hit = (state.graphNodes || []).find((n) => {
        const dx = n.x - x, dy = n.y - y;
        return dx * dx + dy * dy < 196;
      });
      if (hit && !hit.unresolved && hit.path) {
        closeGraph();
        openNote(hit.path).catch(console.error);
      }
    });
    // The force layout is O(n²) over 60 passes, and mobile Safari fires
    // `resize` for every URL-bar nudge and keyboard show — running it
    // synchronously per event is what makes the graph feel stuck.
    let graphResizeTimer = null;
    window.addEventListener("resize", () => {
      if (!state.graph) return;
      clearTimeout(graphResizeTimer);
      graphResizeTimer = setTimeout(() => {
        graphResizeTimer = null;
        if (!state.graph) return;
        layoutGraph();
        drawGraph();
      }, 150);
    });
  }
  els.vaultBtn.addEventListener("click", (e) => {
    e.stopPropagation();
    toggleVaultMenu();
  });
  els.omnibar.addEventListener("click", (e) => {
    if (e.target === els.omnibar) closeOmnibar();
  });
  els.omniInput.addEventListener("input", scheduleOmni);
  els.sheet.addEventListener("click", (e) => {
    if (e.target === els.sheet) hideMenus();
  });
  document.addEventListener("click", (e) => {
    if (!els.vaultMenu.contains(e.target) && e.target !== els.vaultBtn) {
      els.vaultMenu.hidden = true;
    }
    if (!els.ctxMenu.hidden && !els.ctxMenu.contains(e.target)) {
      els.ctxMenu.hidden = true;
    }
  });
  document.addEventListener("keydown", onKey);

  function setDocumentTitle(title) {
    document.title = title ? `${title} — BlackGlass` : "BlackGlass";
  }

  function resolvedTheme(mode) {
    if (mode === "light" || mode === "dark") return mode;
    return lightQuery.matches ? "light" : "dark";
  }

  function applyAppearance(mode) {
    const value = mode === "light" || mode === "dark" || mode === "system" ? mode : "system";
    document.documentElement.setAttribute("data-theme", value);
    const meta = document.querySelector('meta[name="theme-color"]');
    if (meta) meta.setAttribute("content", resolvedTheme(value) === "light" ? "#ffffff" : "#1c1c1e");
  }

  // The bottom-bar toggle cycles auto → light → dark → auto for *this
  // browser only*, stored client-side — the Mac app's own appearance
  // setting (read once as the initial default below) is a separate surface
  // and shouldn't be forced to match whatever a phone or other computer
  // happens to be set to.
  const THEME_STORAGE_KEY = "ln-web-theme";
  const THEME_CYCLE = ["system", "light", "dark"];
  const THEME_ICON = { system: "auto", light: "sun", dark: "moon" };
  const THEME_LABEL = { system: "Auto", light: "Light", dark: "Dark" };

  function webThemeOverride() {
    try {
      const v = localStorage.getItem(THEME_STORAGE_KEY);
      return THEME_CYCLE.includes(v) ? v : null;
    } catch { return null; }
  }

  function updateThemeButton(mode) {
    if (!els.themeBtn) return;
    els.themeBtn.innerHTML = iconHTML(THEME_ICON[mode] || "auto");
    els.themeBtn.title = "Appearance: " + (THEME_LABEL[mode] || "Auto");
  }

  function setWebTheme(mode) {
    try { localStorage.setItem(THEME_STORAGE_KEY, mode); } catch { /* private browsing */ }
    applyAppearance(mode);
    updateThemeButton(mode);
  }

  function cycleTheme() {
    const current = document.documentElement.getAttribute("data-theme") || "system";
    const next = THEME_CYCLE[(THEME_CYCLE.indexOf(current) + 1) % THEME_CYCLE.length];
    setWebTheme(next);
  }

  function applySearchAlwaysVisible(on) {
    state.searchAlwaysVisible = !!on;
    if (els.searchToggle) els.searchToggle.hidden = state.searchAlwaysVisible;
    if (state.searchAlwaysVisible) {
      state.searching = true;
      els.searchBar.hidden = false;
    }
  }

  async function loadAppearance() {
    const override = webThemeOverride();
    if (override) {
      applyAppearance(override);
      updateThemeButton(override);
    }
    try {
      const data = await api("/api/appearance");
      if (!override) {
        applyAppearance(data.appearance);
        updateThemeButton(data.appearance);
      }
      applySearchAlwaysVisible(data.searchAlwaysVisible);
    } catch {
      if (!override) {
        applyAppearance("system");
        updateThemeButton("system");
      }
    }
  }

  // ---- Tree drag and drop -------------------------------------------------
  //
  // Pointer events rather than the native HTML5 drag API: one code path then
  // covers a mouse on the desktop and a long press on a phone, which
  // `dragstart` never fires for. Dropping files *in* from the desktop is the
  // one thing that must use the native API — only it carries the payload —
  // and that lives in `bindExternalDrop` at the bottom.

  const drag = {
    item: null,
    paths: [],
    row: null,
    pointerId: null,
    startX: 0,
    startY: 0,
    lifted: false,
    moved: false,
    active: false,
    index: null,
    ghost: null,
    line: null,
    target: null,
    into: null,
    liftTimer: null,
    springPath: null,
    springTimer: null,
    scrollTimer: null,
    scrollBy: 0,
  };

  const DRAG_SLOP = 5;        // px of movement before a press becomes a drag
  const LIFT_MS = 500;        // touch: hold this long to pick a row up
  const SPRING_MS = 620;      // hover a closed folder this long and it opens
  const EDGE_PX = 28;         // auto-scroll band at the top and bottom

  // Frozen when a drag starts: every row needs to know its folder and its
  // neighbours to turn a drop position into "before this sibling", and the
  // tree can't change while a finger is down on it.
  function buildDragIndex() {
    const map = new Map();
    const walk = (nodes, parent) => {
      nodes.forEach((node, i) => {
        map.set(node.path, { node, parent, siblings: nodes, i });
        if (node.children) walk(node.children, node.path);
      });
    };
    walk(state.tree || [], "");
    return map;
  }

  function rowUnderPoint(x, y) {
    const el = document.elementFromPoint(x, y);
    if (!el) return null;
    const row = el.closest ? el.closest(".row[data-path]") : null;
    return row && els.tree.contains(row) ? row : null;
  }

  // Which folder a drop lands in, and which sibling it lands in front of.
  // `null` for "the end of that folder".
  function dropTarget(x, y) {
    const box = els.tree.getBoundingClientRect();
    if (x < box.left || x > box.right || y < box.top || y > box.bottom) return null;

    const row = rowUnderPoint(x, y);
    if (!row) return { destination: "", before: null, kind: "root" };

    const path = row.getAttribute("data-path");
    const entry = drag.index.get(path);
    if (!entry) return null;

    const rect = row.getBoundingClientRect();
    // A folder's middle band drops *into* it; its top and bottom edges still
    // reorder around it, so a folder can be both a container and a neighbour.
    if (row.classList.contains("dir")) {
      const edge = Math.min(10, rect.height * 0.3);
      if (y > rect.top + edge && y < rect.bottom - edge) {
        return { destination: path, before: null, kind: "into", row };
      }
    }
    const after = y > rect.top + rect.height / 2;
    const next = entry.siblings[entry.i + 1];
    return {
      destination: entry.parent,
      before: after ? (next ? next.path : null) : path,
      kind: "between",
      row,
      after,
    };
  }

  function targetAllowed(target) {
    if (!target || !drag.paths.length) return false;
    for (const src of drag.paths) {
      // Nothing can be dropped inside itself, and a folder can't be dropped
      // into its own subtree.
      const entry = drag.index.get(src);
      const isDirectory = entry ? entry.node.isDirectory : false;
      if (isDirectory
          && (target.destination === src || target.destination.startsWith(src + "/"))) {
        return false;
      }
      // Landing in front of one of the rows being carried is meaningless.
      if (target.before === src) return false;
    }
    if (drag.paths.length > 1) return true;
    const entry = drag.index.get(drag.paths[0]);
    if (!entry) return true;
    if (target.destination !== entry.parent) return true;
    // Same folder: refuse the positions it already occupies, so a stray drag
    // doesn't pin an otherwise name-sorted folder into a manual order.
    if (target.kind === "into") return false;
    const next = entry.siblings[entry.i + 1];
    return target.before !== (next ? next.path : null);
  }

  function bindItemDrag(row, item) {
    row.addEventListener("pointerdown", (e) => {
      if (drag.active || state.renamingPath) return;
      // Search results aren't tree rows — there is no folder to drop into.
      if (state.searching && state.query.trim()) return;
      if (e.pointerType === "mouse" && e.button !== 0) return;

      drag.item = item;
      drag.row = row;
      drag.pointerId = e.pointerId;
      drag.startX = e.clientX;
      drag.startY = e.clientY;
      drag.moved = false;
      // A mouse is picked up immediately and only becomes a drag once it
      // travels; a finger has to hold still first, or every attempt to scroll
      // the tree would pick a note up instead.
      drag.lifted = e.pointerType === "mouse";
      clearTimeout(drag.liftTimer);
      if (e.pointerType !== "mouse") {
        drag.liftTimer = setTimeout(() => {
          drag.liftTimer = null;
          if (drag.row !== row || drag.moved) return;
          drag.lifted = true;
          row.classList.add("lifted");
          if (navigator.vibrate) navigator.vibrate(8);
        }, LIFT_MS);
      }
    });

    row.addEventListener("pointermove", (e) => {
      if (drag.row !== row || e.pointerId !== drag.pointerId) return;
      const far = Math.abs(e.clientX - drag.startX) > DRAG_SLOP
        || Math.abs(e.clientY - drag.startY) > DRAG_SLOP;
      if (!far) return;
      if (!drag.lifted) {
        // Moved before the hold completed: this was a scroll, not a pick-up.
        drag.moved = true;
        cancelPress();
        return;
      }
      if (!drag.active) startDrag(e);
      if (drag.active) updateDrag(e.clientX, e.clientY);
    });

    const finish = (e) => {
      if (drag.row !== row) return;
      const wasActive = drag.active;
      const lifted = drag.lifted && !drag.moved;
      if (wasActive) {
        commitDrag();
      } else if (lifted && e.pointerType !== "mouse") {
        // Held still and let go: the long press was asking for the menu.
        cancelPress();
        showSheet(item);
      } else {
        cancelPress();
      }
    };
    row.addEventListener("pointerup", finish);
    row.addEventListener("pointercancel", () => { if (drag.row === row) endDrag(); });
  }

  function cancelPress() {
    clearTimeout(drag.liftTimer);
    drag.liftTimer = null;
    if (drag.row) drag.row.classList.remove("lifted");
    if (!drag.active) {
      drag.item = null;
      drag.row = null;
      drag.pointerId = null;
      drag.lifted = false;
    }
  }

  function startDrag(e) {
    clearTimeout(drag.liftTimer);
    drag.liftTimer = null;
    drag.active = true;
    drag.index = buildDragIndex();
    // Dragging a row that is part of a multi-selection carries the whole
    // selection; dragging anything else carries just that row, and leaves the
    // selection alone rather than silently redefining it mid-gesture.
    drag.paths = state.selection.has(drag.item.path) && state.selection.size > 1
      ? selectedPaths()
      : [drag.item.path];
    try { drag.row.setPointerCapture(drag.pointerId); } catch { /* gone */ }
    drag.row.classList.remove("lifted");
    drag.row.classList.add("drag-source");
    document.body.classList.add("dragging-row");

    const ghost = document.createElement("div");
    ghost.className = "drag-ghost";
    ghost.textContent = drag.paths.length > 1
      ? drag.paths.length + " items"
      : drag.item.title;
    document.body.appendChild(ghost);
    drag.ghost = ghost;

    const line = document.createElement("div");
    line.className = "drop-line";
    line.hidden = true;
    document.body.appendChild(line);
    drag.line = line;
  }

  function updateDrag(x, y) {
    if (drag.ghost) {
      drag.ghost.style.left = x + "px";
      drag.ghost.style.top = y + "px";
    }
    const target = dropTarget(x, y);
    drag.target = targetAllowed(target) ? target : null;
    paintTarget();
    armSpring(target);
    armAutoScroll(y);
  }

  function paintTarget() {
    const target = drag.target;
    const into = target && target.kind === "into" ? target.row : null;
    if (drag.into !== into) {
      if (drag.into) drag.into.classList.remove("drop-into");
      if (into) into.classList.add("drop-into");
      drag.into = into;
    }
    const line = drag.line;
    if (!line) return;
    if (!target || target.kind === "into") {
      line.hidden = true;
      return;
    }
    const treeBox = els.tree.getBoundingClientRect();
    let top;
    let left = treeBox.left + 8;
    if (target.kind === "root") {
      top = Math.min(treeBox.bottom - 1, treeBox.top + els.tree.scrollHeight - els.tree.scrollTop);
    } else {
      const rect = target.row.getBoundingClientRect();
      top = target.after ? rect.bottom : rect.top;
      // Sits under the row's own icon, so the indent shows which folder the
      // note is about to land in rather than just where it goes vertically.
      left = rect.left;
    }
    line.hidden = false;
    line.style.top = Math.round(Math.max(treeBox.top, Math.min(treeBox.bottom, top))) + "px";
    line.style.left = Math.round(left) + "px";
    line.style.width = Math.round(treeBox.right - 8 - left) + "px";
  }

  // Spring-loaded folders: rest on a closed one and it opens, so a note can
  // be carried into a folder several levels down in one gesture.
  function armSpring(target) {
    const path = target && target.kind === "into" && state.collapsed.has(target.destination)
      ? target.destination
      : null;
    if (path === drag.springPath) return;
    clearTimeout(drag.springTimer);
    drag.springPath = path;
    if (!path) return;
    drag.springTimer = setTimeout(() => {
      if (drag.springPath !== path || !drag.active) return;
      springOpen(path);
    }, SPRING_MS);
  }

  // Opens the folder in place. A full `renderTree()` here would throw away
  // the row the pointer is currently captured by, which ends the drag.
  function springOpen(path) {
    state.collapsed.delete(path);
    const row = rowForPath(path);
    if (!row) return;
    const kids = row.nextElementSibling;
    if (kids) kids.hidden = false;
    const chev = row.querySelector(".chevron");
    if (chev) chev.innerHTML = iconHTML("chevronDown");
    const icon = row.querySelector(".icon");
    if (icon) icon.innerHTML = iconHTML("folderFill");
  }

  function armAutoScroll(y) {
    const box = els.tree.getBoundingClientRect();
    if (y < box.top + EDGE_PX) drag.scrollBy = -Math.ceil((box.top + EDGE_PX - y) / 3);
    else if (y > box.bottom - EDGE_PX) drag.scrollBy = Math.ceil((y - (box.bottom - EDGE_PX)) / 3);
    else drag.scrollBy = 0;

    if (drag.scrollBy && !drag.scrollTimer) {
      drag.scrollTimer = setInterval(() => {
        if (!drag.active || !drag.scrollBy) return;
        els.tree.scrollTop += drag.scrollBy;
        paintTarget();
      }, 16);
    } else if (!drag.scrollBy && drag.scrollTimer) {
      clearInterval(drag.scrollTimer);
      drag.scrollTimer = null;
    }
  }

  function commitDrag() {
    const paths = drag.paths.slice();
    const target = drag.target;
    endDrag();
    // Suppresses the click the pointer sequence is about to synthesise, which
    // would otherwise open whichever note the drag happened to end on. Armed
    // even for a drop that goes nowhere, since that click is still coming.
    swallowNextClick();
    if (!paths.length || !target) return;
    moveItems(paths, target).catch((err) => {
      console.error(err);
      toast(err.message || "Move failed");
    });
  }

  function endDrag() {
    clearTimeout(drag.liftTimer);
    clearTimeout(drag.springTimer);
    if (drag.scrollTimer) clearInterval(drag.scrollTimer);
    if (drag.ghost) drag.ghost.remove();
    if (drag.line) drag.line.remove();
    if (drag.into) drag.into.classList.remove("drop-into");
    if (drag.row) {
      drag.row.classList.remove("drag-source", "lifted");
      try { drag.row.releasePointerCapture(drag.pointerId); } catch { /* gone */ }
    }
    document.body.classList.remove("dragging-row");
    drag.item = null;
    drag.paths = [];
    drag.row = null;
    drag.pointerId = null;
    drag.lifted = false;
    drag.moved = false;
    drag.active = false;
    drag.index = null;
    drag.ghost = null;
    drag.line = null;
    drag.target = null;
    drag.into = null;
    drag.liftTimer = null;
    drag.springTimer = null;
    drag.springPath = null;
    drag.scrollTimer = null;
    drag.scrollBy = 0;
  }

  function swallowNextClick() {
    const eat = (e) => {
      e.stopPropagation();
      e.preventDefault();
    };
    document.addEventListener("click", eat, { capture: true, once: true });
    // Nothing guarantees a click actually follows — a drag that ended over
    // the editor produces none — so the listener can't be left armed.
    setTimeout(() => document.removeEventListener("click", eat, { capture: true }), 350);
  }

  async function moveItems(paths, target) {
    // A queued autosave still names the old path; firing it after the move
    // would write the note straight back where it came from.
    await flushSave();
    const res = await api("/api/tree/move", {
      method: "POST",
      body: JSON.stringify({
        paths,
        destination: target.destination,
        before: target.before,
      }),
    });
    applyRemap((res && res.moved) || {});
    await loadTree();
  }

  // Follows everything the client holds by path across a move: the open note,
  // the selected folder, the rename in progress, and every collapsed folder.
  function applyRemap(moved) {
    const at = (p) => (p && Object.prototype.hasOwnProperty.call(moved, p) ? moved[p] : p);
    if (state.path) state.path = at(state.path);
    if (state.selectedDir) state.selectedDir = at(state.selectedDir);
    if (state.renamingPath) state.renamingPath = at(state.renamingPath);
    if (state.collapsed.size) state.collapsed = new Set([...state.collapsed].map(at));
    if (state.selection.size) state.selection = new Set([...state.selection].map(at));
    if (state.selectionAnchor) state.selectionAnchor = at(state.selectionAnchor);
  }

  async function clearManualOrder(path) {
    try {
      await api("/api/tree/order/clear", { method: "POST", body: JSON.stringify({ path }) });
      await loadTree();
    } catch (err) {
      console.error(err);
      toast(err.message || "Could not restore name order");
    }
  }

  // ---- Dropping files in from the desktop ---------------------------------

  const IMPORTABLE = new Set(["md", "markdown", "txt"]);
  // Base64 inflates by a third and the server refuses a request over 64 MB,
  // so uploads go in batches. One dropped folder splitting across two batches
  // would land as "Notes" and "Notes 2", which this is comfortably large
  // enough to avoid for any realistic folder of Markdown.
  const UPLOAD_BATCH_BYTES = 24 * 1024 * 1024;

  const extensionOf = (name) => {
    const dot = name.lastIndexOf(".");
    return dot < 0 ? "" : name.slice(dot + 1).toLowerCase();
  };

  function bindExternalDrop() {
    const tree = els.tree;
    if (!tree) return;
    let depth = 0;
    let lit = null;
    const carriesFiles = (e) => {
      const types = (e.dataTransfer && e.dataTransfer.types) || [];
      return Array.prototype.indexOf.call(types, "Files") !== -1;
    };
    const light = (row) => {
      if (lit === row) return;
      if (lit) lit.classList.remove("drop-into");
      if (row) row.classList.add("drop-into");
      lit = row;
    };
    const clear = () => {
      depth = 0;
      tree.classList.remove("drop-external");
      light(null);
    };
    const folderUnder = (x, y) => {
      const row = rowUnderPoint(x, y);
      return row && row.classList.contains("dir") ? row : null;
    };

    tree.addEventListener("dragenter", (e) => {
      if (!carriesFiles(e)) return;
      e.preventDefault();
      depth += 1;
      tree.classList.add("drop-external");
    });
    tree.addEventListener("dragover", (e) => {
      if (!carriesFiles(e)) return;
      e.preventDefault();
      e.dataTransfer.dropEffect = "copy";
      light(folderUnder(e.clientX, e.clientY));
    });
    tree.addEventListener("dragleave", (e) => {
      if (!carriesFiles(e)) return;
      depth -= 1;
      if (depth <= 0) clear();
    });
    tree.addEventListener("drop", (e) => {
      if (!carriesFiles(e)) return;
      e.preventDefault();
      const row = folderUnder(e.clientX, e.clientY);
      const destination = row ? row.getAttribute("data-path") : "";
      clear();
      // Both of these have to be read now: `dataTransfer` is emptied the
      // moment this handler yields, so awaiting first loses the drop.
      const entries = e.dataTransfer.items
        ? Array.from(e.dataTransfer.items)
            .map((i) => (i.webkitGetAsEntry ? i.webkitGetAsEntry() : null))
            .filter(Boolean)
        : [];
      const flat = Array.from(e.dataTransfer.files || []);
      importDropped(entries, flat, destination).catch((err) => {
        console.error(err);
        toast(err.message || "Import failed");
      });
    });
  }

  // Walks a dropped folder so it keeps its shape on the way in, the way the
  // native sidebar's Finder drop does.
  function readEntry(entry, prefix) {
    return new Promise((resolve) => {
      if (entry.isFile) {
        entry.file(
          (file) => resolve([{ path: prefix + entry.name, file }]),
          () => resolve([])
        );
        return;
      }
      if (!entry.isDirectory) return resolve([]);
      const reader = entry.createReader();
      const found = [];
      const step = () => {
        reader.readEntries((batch) => {
          // `readEntries` hands back at most a hundred at a time and signals
          // the end with an empty batch, so it has to be drained in a loop.
          if (!batch.length) {
            Promise.all(found.map((child) => readEntry(child, prefix + entry.name + "/")))
              .then((nested) => resolve([].concat.apply([], nested)));
            return;
          }
          found.push.apply(found, batch);
          step();
        }, () => resolve([]));
      };
      step();
    });
  }

  function fileToBase64(file) {
    return new Promise((resolve, reject) => {
      const reader = new FileReader();
      reader.onload = () => {
        const text = String(reader.result);
        resolve(text.slice(text.indexOf(",") + 1));
      };
      reader.onerror = () => reject(reader.error || new Error("Unreadable file"));
      reader.readAsDataURL(file);
    });
  }

  async function importDropped(entries, flat, destination) {
    let found;
    if (entries.length) {
      const nested = await Promise.all(entries.map((entry) => readEntry(entry, "")));
      found = [].concat.apply([], nested);
    } else {
      found = flat.map((file) => ({ path: file.name, file }));
    }
    if (!found.length) return;

    // Filtered before anything is read: a dropped folder of photos should
    // cost nothing, not a base64 pass over every one of them.
    const usable = found.filter((f) => IMPORTABLE.has(extensionOf(f.path)));
    if (!usable.length) {
      toast("Nothing imported — Markdown and text files only");
      return;
    }

    let imported = 0;
    let batch = [];
    let bytes = 0;
    const flush = async () => {
      if (!batch.length) return;
      const res = await api("/api/import", {
        method: "POST",
        body: JSON.stringify({ destination, files: batch }),
      });
      imported += (res && res.imported) || 0;
      batch = [];
      bytes = 0;
    };
    for (const f of usable) {
      const data = await fileToBase64(f.file);
      if (bytes && bytes + data.length > UPLOAD_BATCH_BYTES) await flush();
      batch.push({ path: f.path, data });
      bytes += data.length;
    }
    await flush();

    const skipped = found.length - imported;
    toast(
      imported
        ? "Imported " + imported + " file" + (imported === 1 ? "" : "s")
          + (skipped > 0 ? ", skipped " + skipped : "")
        : "Nothing imported"
    );
    await loadTree();
  }

  let toastTimer = null;
  function toast(message) {
    let el = document.getElementById("toast");
    if (!el) {
      el = document.createElement("div");
      el.id = "toast";
      el.className = "toast";
      document.body.appendChild(el);
    }
    el.textContent = message;
    el.classList.add("show");
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => el.classList.remove("show"), 2600);
  }

  // Click-drag the strip at the sidebar's right edge to resize it, clamped
  // to the same 220–320px range the CSS already constrains it to.
  function bindSidebarResize() {
    const handle = els.sidebarResizer;
    if (!handle) return;
    const MIN = 220, MAX = 320;
    handle.addEventListener("pointerdown", (e) => {
      if (isPhone()) return;
      e.preventDefault();
      handle.setPointerCapture(e.pointerId);
      handle.classList.add("dragging");
      const startX = e.clientX;
      const startWidth = els.sidebar.getBoundingClientRect().width;
      const onMove = (ev) => {
        const width = Math.min(MAX, Math.max(MIN, startWidth + (ev.clientX - startX)));
        els.sidebar.style.width = width + "px";
      };
      const onUp = () => {
        handle.classList.remove("dragging");
        handle.removeEventListener("pointermove", onMove);
        handle.removeEventListener("pointerup", onUp);
        try {
          localStorage.setItem("ln-sidebar-width", els.sidebar.style.width);
        } catch { /* private browsing */ }
      };
      handle.addEventListener("pointermove", onMove);
      handle.addEventListener("pointerup", onUp);
    });
  }

  function restoreSidebarWidth() {
    try {
      const saved = localStorage.getItem("ln-sidebar-width");
      if (saved) els.sidebar.style.width = saved;
    } catch { /* private browsing */ }
  }

  if (els.themeBtn) els.themeBtn.addEventListener("click", cycleTheme);
  bindSidebarResize();
  restoreSidebarWidth();

  hydrateIcons();
  bindExternalDrop();
  // Non-passive, so a drag in progress can actually refuse the scroll. The
  // tree's `touch-action: pan-y` can't be changed once a gesture has started.
  els.tree.addEventListener("click", (e) => {
    const onRow = e.target && e.target.closest && e.target.closest(".row[data-path]");
    if (!onRow) clearSelection();
  });
  els.tree.addEventListener("touchmove", (e) => {
    if (drag.active) e.preventDefault();
  }, { passive: false });
  document.addEventListener("keydown", (e) => {
    if (e.key === "Escape" && drag.active) endDrag();
  });
  preventChromeGestures();
  bindSwipe();
  drawEgg();
  setDocumentTitle(null);
  applyAppearance(webThemeOverride() || "system");
  updateThemeButton(webThemeOverride() || "system");
  loadAppearance().catch(console.error);
  lightQuery.addEventListener("change", () => {
    const current = document.documentElement.getAttribute("data-theme") || "system";
    if (current === "system") applyAppearance("system");
  });
  loadVaults().catch(console.error);
  loadTree().catch(console.error);
})();
