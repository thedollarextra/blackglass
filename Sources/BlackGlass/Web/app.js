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

  const isPhone = () => window.matchMedia("(max-width: 760px)").matches;
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
    renderTree();
  }

  function renderTree() {
    els.tree.innerHTML = "";
    if (state.searching && state.query.trim()) {
      if (!state.results.length) {
        const empty = document.createElement("div");
        empty.className = "snippet";
        empty.textContent = "No notes found";
        els.tree.appendChild(empty);
        return;
      }
      state.results.forEach((r) => els.tree.appendChild(fileRow(r.path, r.title, r.snippet)));
      return;
    }
    (state.tree || []).forEach((n) => els.tree.appendChild(nodeEl(n, 0)));
    if (state.renamingPath) {
      const input = els.tree.querySelector(".rename-input");
      if (input) {
        input.focus();
        input.select();
      }
    }
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
    return [...els.tree.querySelectorAll("[data-path]")].find((el) => el.getAttribute("data-path") === path);
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
      row.addEventListener("click", () => {
        if (state.renamingPath === node.path) return;
        state.selectedDir = node.path;
        state.path = null;
        setDocumentTitle(node.title);
        els.noteTitle.textContent = node.title;
        els.rawEditor.value = "";
        els.cookedView.innerHTML = "";
        renderTree();
      });
      bindItemMenu(row, { path: node.path, title: node.title, isDirectory: true });
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

    row.addEventListener("click", () => {
      if (state.renamingPath === path) return;
      openNote(path);
    });
    bindItemMenu(row, { path, title, isDirectory: false });

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

  function bindItemMenu(row, item) {
    row.addEventListener("contextmenu", (e) => {
      e.preventDefault();
      showContextMenu(e.clientX, e.clientY, item);
    });
    let timer = null;
    row.addEventListener("touchstart", (e) => {
      if (e.touches.length !== 1) return;
      const t = e.touches[0];
      timer = setTimeout(() => {
        showSheet(item);
        timer = null;
      }, 520);
      row._sx = t.clientX;
      row._sy = t.clientY;
    }, { passive: true });
    row.addEventListener("touchmove", (e) => {
      if (!timer || e.touches.length !== 1) return;
      const t = e.touches[0];
      if (Math.abs(t.clientX - row._sx) > 10 || Math.abs(t.clientY - row._sy) > 10) {
        clearTimeout(timer);
        timer = null;
      }
    }, { passive: true });
    row.addEventListener("touchend", () => {
      if (timer) clearTimeout(timer);
      timer = null;
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
    if (item.isDirectory) {
      add("Expand All", () => expandAllUnder(item.path));
      add("Collapse All", () => collapseAllUnder(item.path));
    }
    add("Rename", () => startRename(item.path, item.title));
    add("Delete", () => deleteNote(item.path, item.isDirectory), true);
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
    if (item.isDirectory) {
      add("Expand All", () => expandAllUnder(item.path));
      add("Collapse All", () => collapseAllUnder(item.path));
    }
    add("Rename", () => startRename(item.path, item.title));
    add("Delete", () => deleteNote(item.path, item.isDirectory), true);
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
    const note = await api("/api/note?path=" + encodeURIComponent(path));
    state.path = path;
    state.selectedDir = null;
    state.title = note.title;
    state.content = note.content;
    setDocumentTitle(note.title);
    els.noteTitle.textContent = note.title;
    els.rawEditor.value = note.content;
    renderCooked();
    renderTree();
    if (isPhone()) closeSidebar();
  }

  function queueSave() {
    state.content = els.rawEditor.value;
    if (state.mode === "cooked") renderCooked();
    clearTimeout(state.saveTimer);
    if (!state.path) return;
    state.saveTimer = setTimeout(async () => {
      await api("/api/note?path=" + encodeURIComponent(state.path), {
        method: "PUT",
        body: JSON.stringify({ content: state.content }),
      });
    }, 300);
  }

  async function renderCooked() {
    if (!state.path) {
      els.cookedView.innerHTML = "<p class='muted'>Select a note</p>";
      return;
    }
    try {
      const data = await api("/api/render?path=" + encodeURIComponent(state.path));
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
    for (let iter = 0; iter < 60; iter++) {
      const vx = nodes.map(() => 0);
      const vy = nodes.map(() => 0);
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
    g.strokeStyle = "rgba(160,160,160,0.4)";
    g.lineWidth = 1;
    (state.graphEdges || []).forEach((e) => {
      const a = idx[e.from], b = idx[e.to];
      if (!a || !b) return;
      g.beginPath();
      g.moveTo(a.x, a.y);
      g.lineTo(b.x, b.y);
      g.stroke();
    });
    (state.graphNodes || []).forEach((n) => {
      g.beginPath();
      g.arc(n.x, n.y, n.unresolved ? 4 : 7, 0, Math.PI * 2);
      g.fillStyle = n.unresolved ? "rgba(160,160,160,0.5)" : (n.path === state.path ? "#0a84ff" : getComputedStyle(document.body).color);
      g.fill();
      if (!n.unresolved) {
        g.fillStyle = getComputedStyle(document.body).color;
        g.font = "11px -apple-system, sans-serif";
        g.textAlign = "center";
        g.fillText(n.title, n.x, n.y + 18);
      }
    });
  }

  async function runSearch() {
    state.query = els.searchInput.value;
    if (!state.query.trim()) {
      state.results = [];
      renderTree();
      return;
    }
    state.results = await api("/api/search?q=" + encodeURIComponent(state.query));
    renderTree();
  }

  function openOmnibar() {
    state.omni = true;
    els.omnibar.hidden = false;
    els.omniInput.value = "";
    state.omniResults = [];
    state.omniIndex = 0;
    els.omniResults.innerHTML = "";
    els.omniInput.focus();
  }

  function closeOmnibar() {
    state.omni = false;
    els.omnibar.hidden = true;
  }

  async function runOmni() {
    state.omniQuery = els.omniInput.value;
    if (!state.omniQuery.trim()) {
      state.omniResults = [];
      renderOmni();
      return;
    }
    state.omniResults = await api("/api/search?q=" + encodeURIComponent(state.omniQuery));
    state.omniIndex = 0;
    renderOmni();
  }

  function renderOmni() {
    els.omniResults.innerHTML = "";
    if (!state.omniResults.length) {
      const empty = document.createElement("div");
      empty.className = "omni-hit";
      empty.textContent = state.omniQuery ? "No notes found" : "Type to search notes";
      els.omniResults.appendChild(empty);
      return;
    }
    state.omniResults.forEach((r, i) => {
      const d = document.createElement("div");
      d.className = "omni-hit" + (i === state.omniIndex ? " sel" : "");
      d.innerHTML = `<div class="t"></div><div class="s"></div>`;
      d.querySelector(".t").textContent = r.title;
      d.querySelector(".s").textContent = r.snippet || r.path;
      d.addEventListener("click", () => selectOmni(i));
      els.omniResults.appendChild(d);
    });
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
        renderOmni();
      }
      if (e.key === "ArrowUp") {
        e.preventDefault();
        state.omniIndex = Math.max(state.omniIndex - 1, 0);
        renderOmni();
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
  window.matchMedia("(max-width: 760px)").addEventListener("change", () => {
    document.getElementById("app").classList.toggle("sidebar-collapsed", !isPhone() && state.sidebarCollapsed);
    syncSidebarButton();
  });
  els.scrim.addEventListener("click", () => { closeSidebar(); hideMenus(); });
  els.newBtn.addEventListener("click", () => newNote().catch(console.error));
  els.refreshBtn.addEventListener("click", () => loadTree().catch(console.error));
  els.searchToggle.addEventListener("click", () => toggleSearch().catch(console.error));
  if (els.graphBtn) els.graphBtn.addEventListener("click", () => toggleGraph().catch(console.error));
  els.searchClose.addEventListener("click", () => toggleSearch().catch(console.error));
  els.searchInput.addEventListener("input", () => runSearch().catch(console.error));
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
    window.addEventListener("resize", () => { if (state.graph) { layoutGraph(); drawGraph(); } });
  }
  els.vaultBtn.addEventListener("click", (e) => {
    e.stopPropagation();
    toggleVaultMenu();
  });
  els.omnibar.addEventListener("click", (e) => {
    if (e.target === els.omnibar) closeOmnibar();
  });
  els.omniInput.addEventListener("input", () => runOmni().catch(console.error));
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
    return window.matchMedia("(prefers-color-scheme: light)").matches ? "light" : "dark";
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
  preventChromeGestures();
  bindSwipe();
  drawEgg();
  setDocumentTitle(null);
  applyAppearance(webThemeOverride() || "system");
  updateThemeButton(webThemeOverride() || "system");
  loadAppearance().catch(console.error);
  window.matchMedia("(prefers-color-scheme: light)").addEventListener("change", () => {
    const current = document.documentElement.getAttribute("data-theme") || "system";
    if (current === "system") applyAppearance("system");
  });
  loadVaults().catch(console.error);
  loadTree().catch(console.error);
})();
