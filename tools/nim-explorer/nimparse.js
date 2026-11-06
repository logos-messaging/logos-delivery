/* Nim repository analyser: lexical import/type extraction plus graph analyses.
 * Runs unchanged in the browser (window.NimParse) and in node (module.exports).
 * It is a static approximation: it does not expand templates/macros. */
(function (root) {
  "use strict";

  // ---------------------------------------------------------------- lexing

  const IDENT_CH = /[A-Za-z0-9_]/;

  /** Blank comments (and optionally string/char literals), keeping length and newlines. */
  function strip(src, blankStrings) {
    const n = src.length;
    const out = src.split("");
    const blank = (a, b) => {
      for (let k = a; k < b && k < n; k++) if (out[k] !== "\n") out[k] = " ";
    };
    let i = 0;
    while (i < n) {
      const c = src[i];
      if (c === "#") {
        let open = null, close = null;
        if (src[i + 1] === "[") (open = "#["), (close = "]#");
        else if (src[i + 1] === "#" && src[i + 2] === "[") (open = "##["), (close = "]##");
        if (open) {
          let depth = 1, j = i + open.length;
          while (j < n && depth > 0) {
            if (src.startsWith(open, j)) { depth++; j += open.length; }
            else if (src.startsWith(close, j)) { depth--; j += close.length; }
            else j++;
          }
          blank(i, j);
          i = j;
        } else {
          let j = src.indexOf("\n", i);
          if (j < 0) j = n;
          blank(i, j);
          i = j;
        }
      } else if (c === '"') {
        let j;
        if (src.startsWith('"""', i)) {
          j = src.indexOf('"""', i + 3);
          j = j < 0 ? n : j + 3;
          while (j < n && src[j] === '"') j++;
        } else {
          const raw = i > 0 && IDENT_CH.test(src[i - 1]);
          j = i + 1;
          while (j < n && src[j] !== "\n") {
            if (!raw && src[j] === "\\") { j += 2; continue; }
            if (src[j] === '"') {
              if (raw && src[j + 1] === '"') { j += 2; continue; }
              j++;
              break;
            }
            j++;
          }
        }
        if (blankStrings) blank(i + 1, j - 1);
        i = j;
      } else if (c === "'" && !(i > 0 && IDENT_CH.test(src[i - 1]))) {
        const m = /^'(\\.[^'\n]{0,6}|[^\\'\n])'/.exec(src.slice(i, i + 12));
        if (m) {
          if (blankStrings) blank(i + 1, i + m[0].length - 1);
          i += m[0].length;
        } else i++;
      } else i++;
    }
    return out.join("");
  }

  const indentOf = (l) => l.length - l.trimStart().length;

  // ---------------------------------------------------------------- imports

  function parseImportBody(s) {
    s = s.replace(/\{\.[^}]*\.\}/g, " ");
    const n = s.length;
    let pos = 0;
    const ws = () => { while (pos < n && /\s/.test(s[pos])) pos++; };
    const segRe = /[^\s,\[\]\/]+/y;
    function parseList(prefix) {
      const out = [];
      for (;;) {
        ws();
        if (pos >= n || s[pos] === "]") break;
        const before = pos;
        out.push(...parseItem(prefix));
        ws();
        if (s[pos] === ",") pos++;
        else if (pos === before) pos++;
        else if (s[pos] !== "]" && pos < n) {
          // `except ...` / unknown tail: skip it
          const w = /\w+/y; w.lastIndex = pos;
          const m = w.exec(s);
          if (m && m[0] === "except") { pos = n; break; }
          pos++;
        }
      }
      return out;
    }
    function parseItem(prefix) {
      const out = [];
      let cur = prefix;
      for (;;) {
        ws();
        if (s[pos] === "[") {
          pos++;
          out.push(...parseList(cur));
          ws();
          if (s[pos] === "]") pos++;
          cur = null;
          break;
        }
        segRe.lastIndex = pos;
        const m = segRe.exec(s);
        if (!m) break;
        pos += m[0].length;
        cur += m[0];
        ws();
        if (s[pos] === "/") { cur += "/"; pos++; continue; }
        break;
      }
      if (cur !== null && cur !== prefix) out.push(cur);
      ws();
      const kw = /(as|except)\b/y; kw.lastIndex = pos;
      const k = kw.exec(s);
      if (k) {
        pos += k[0].length;
        if (k[1] === "as") { ws(); segRe.lastIndex = pos; const m = segRe.exec(s); if (m) pos += m[0].length; }
        else pos = n;
      }
      return out;
    }
    return parseList("").map((p) => p.replace(/"/g, "").replace(/\/+$/, "").replace(/\.nim$/, "")).filter((p) => /[\w]/.test(p));
  }

  /** Returns [{kind:'import'|'export'|'include', spec, conditional, line}] */
  function parseImports(keepText) {
    const blanked = strip(keepText, true);
    const bl = blanked.split("\n");
    const kl = strip(keepText, false).split("\n");
    const stmts = [];
    const kwRe = /^(\s*)(import|export|include|from)\b(.*)$/;
    for (let i = 0; i < bl.length; i++) {
      const m = kwRe.exec(bl[i]);
      if (!m) continue;
      const indent = m[1].length;
      const kw = m[2];
      let body = kl[i].slice(indent + kw.length);
      let depth = 0;
      const count = (t) => { for (const ch of t) { if (ch === "[") depth++; else if (ch === "]") depth--; } };
      count(body);
      let j = i;
      let last = body.trim();
      let first = true;
      while (j + 1 < bl.length && (depth > 0 || last.endsWith(",") || last.endsWith("/") || (first && last === ""))) {
        j++;
        if (bl[j].trim() === "") continue;
        if (indentOf(bl[j]) <= indent && depth <= 0 && !last.endsWith(",") && !last.endsWith("/") && !(first && last === "")) break;
        body += " " + kl[j].trim();
        count(kl[j]);
        last = kl[j].trim();
        first = false;
      }
      if (kw === "from") {
        const fm = /^\s*(.+?)\s+import\b/.exec(body);
        if (!fm) continue;
        for (const spec of parseImportBody(fm[1])) stmts.push({ kind: "import", spec, conditional: indent > 0, line: i + 1 });
      } else {
        for (const spec of parseImportBody(body)) stmts.push({ kind: kw, spec, conditional: indent > 0, line: i + 1 });
      }
      i = j;
    }
    return stmts;
  }

  // ---------------------------------------------------------------- types

  const ENTRY_RE = /^(\s*)(`[^`]+`|[A-Za-z_]\w*)(\*)?\s*(\[[^=\n]*?\])?\s*(\{\.[^}]*\.\})?\s*=\s*(.*)$/;
  const BROKER_RE = /^(\s*)(RequestBroker|EventBroker|MultiRequestBroker|SignalBroker)\b/;

  function typeRefs(expr) {
    const set = new Set();
    for (const m of expr.matchAll(/[A-Za-z_]\w*/g)) set.add(m[0]);
    return set;
  }

  function parseFieldLines(lines) {
    const fields = [];
    const re = /^(?:case\s+)?([A-Za-z_`][\w`]*\*?(?:\s*,\s*[A-Za-z_`][\w`]*\*?)*)\s*(?:\{\.[^}]*\.\})?\s*:\s*(.+)$/;
    for (const raw of lines) {
      const l = raw.trim();
      if (!l || /^(of|else|elif|when|discard)\b/.test(l)) continue;
      const m = re.exec(l);
      if (!m) continue;
      const typ = m[2].replace(/\s=\s.*$/, "").trim();
      for (const nm of m[1].split(",")) fields.push({ name: nm.trim().replace(/\*$/, ""), type: typ });
    }
    return fields;
  }

  /** Extract type definitions from comment/string-blanked source. */
  function parseTypes(blankedText) {
    const lines = blankedText.split("\n");
    const defs = [];
    let broker = null; // {indent,name}
    for (let i = 0; i < lines.length; i++) {
      const line = lines[i];
      if (line.trim() === "") continue;
      const bm = BROKER_RE.exec(line);
      if (bm) broker = { indent: bm[1].length, name: bm[2] };
      else if (broker && indentOf(line) <= broker.indent) broker = null;

      const tm = /^(\s*)type\b\s*(.*)$/.exec(line);
      if (!tm) continue;
      const kwIndent = tm[1].length;
      const rest = tm[2];
      if (rest !== "" && !ENTRY_RE.test(" " + rest)) continue;
      const sameLine = rest !== "";
      let entryIndent = sameLine ? Infinity : null;
      let j = i;
      let cur = null;
      const flush = () => { if (cur) { defs.push(finishDef(cur)); cur = null; } };
      const open = (em, at) => {
        flush();
        cur = {
          name: em[2].replace(/`/g, ""),
          exported: !!em[3],
          head: em[6].trim(),
          cont: [],
          line: at + 1,
          broker: broker && kwIndent > broker.indent ? broker.name : null,
        };
      };
      if (sameLine) open(ENTRY_RE.exec(" " + rest), i);
      for (;;) {
        j++;
        if (j >= lines.length) break;
        const text = lines[j];
        if (text.trim() === "") continue;
        const ind = indentOf(text);
        if (ind <= kwIndent) break;
        if (entryIndent === null) entryIndent = ind;
        const em = ind === entryIndent ? ENTRY_RE.exec(text) : null;
        if (em) open(em, j);
        else if (cur) cur.cont.push(text);
      }
      flush();
      i = Math.max(i, j - 1);
    }
    return defs;
  }

  function finishDef(d) {
    let h = d.head;
    let isRef = false;
    const rm = /^(ref|ptr)\s+(?=object\b|tuple\b|enum\b)/.exec(h);
    if (rm) { isRef = true; h = h.slice(rm[0].length); }
    const def = { name: d.name, exported: d.exported, line: d.line, kind: "alias", base: null, fields: [], members: [], refs: [], broker: d.broker };
    const body = [h.replace(/^\w+\s*/, ""), ...d.cont];
    if (/^object\b/.test(h)) {
      def.kind = isRef ? "ref object" : "object";
      const bm = /^object\s*\(?\s*of\s+([\w.]+)/.exec(h);
      if (bm) def.base = bm[1];
      def.fields = parseFieldLines(bm ? d.cont : body.slice(0));
    } else if (/^enum\b/.test(h)) {
      def.kind = "enum";
      for (const l of body.join(",").split(",")) {
        const m = /^\s*([A-Za-z_]\w*)/.exec(l);
        if (m) def.members.push(m[1]);
      }
    } else if (/^tuple\b/.test(h)) {
      def.kind = "tuple";
      const inline = /^tuple\s*\[(.*)\]/.exec(h);
      if (inline) {
        const parts = []; let depth = 0, curp = "";
        for (const ch of inline[1]) {
          if (ch === "[" || ch === "(") depth++;
          if (ch === "]" || ch === ")") depth--;
          if ((ch === "," || ch === ";") && depth === 0) { parts.push(curp); curp = ""; } else curp += ch;
        }
        parts.push(curp);
        def.fields = parseFieldLines(parts);
      } else def.fields = parseFieldLines(d.cont);
    } else if (/^distinct\b/.test(h)) {
      def.kind = "distinct";
      def.base = h.replace(/^distinct\s+/, "");
    } else if (/^concept\b/.test(h)) {
      def.kind = "concept";
    } else if (/^(proc|func|iterator)\b/.test(h)) {
      def.kind = "proc";
      def.base = h + " " + d.cont.join(" ");
    } else {
      def.kind = isRef || /^(ref|ptr)\b/.test(h) ? "ref" : "alias";
      def.base = h + " " + d.cont.join(" ");
    }
    // reference edges (names only; resolved against the repo later)
    const own = d.name;
    const edges = [];
    const add = (expr, kind) => { for (const r of typeRefs(expr)) if (r !== own) edges.push({ name: r, kind }); };
    if (def.kind === "object" || def.kind === "ref object") { if (def.base) add(def.base, "inherits"); }
    else if (def.base) add(def.base, def.kind === "proc" ? "uses" : "alias");
    for (const f of def.fields) add(f.type, /^(var\s+)?(proc|func|iterator)\b/.test(f.type) ? "uses" : "has");
    const seen = new Set();
    def.refs = edges.filter((e) => { const k = e.name + "|" + e.kind; if (seen.has(k)) return false; seen.add(k); return true; });
    return def;
  }

  // ---------------------------------------------------------------- graph algorithms

  /** Tarjan SCC. nodes: ids, adj: Map id->Set(id). Returns array of arrays. */
  function tarjan(nodes, adj) {
    let index = 0;
    const idx = new Map(), low = new Map(), onStack = new Set(), stack = [];
    const comps = [];
    function visit(v) {
      idx.set(v, index); low.set(v, index); index++;
      stack.push(v); onStack.add(v);
      for (const w of adj.get(v) || []) {
        if (!idx.has(w)) { visit(w); low.set(v, Math.min(low.get(v), low.get(w))); }
        else if (onStack.has(w)) low.set(v, Math.min(low.get(v), idx.get(w)));
      }
      if (low.get(v) === idx.get(v)) {
        const comp = [];
        let w;
        do { w = stack.pop(); onStack.delete(w); comp.push(w); } while (w !== v);
        comps.push(comp);
      }
    }
    for (const v of nodes) if (!idx.has(v)) visit(v);
    return comps;
  }

  /** Eades-Lin-Smyth ordering; returns Map id->position. Back edges (pos[u] > pos[v]) are the cut candidates. */
  function greedyOrder(nodes, adj) {
    const out = new Map(), inn = new Map();
    const set = new Set(nodes);
    for (const v of nodes) { out.set(v, new Set()); inn.set(v, new Set()); }
    for (const v of nodes) for (const w of adj.get(v) || []) if (set.has(w) && w !== v) { out.get(v).add(w); inn.get(w).add(v); }
    const left = [], right = [];
    const remaining = new Set(nodes);
    const remove = (v) => {
      remaining.delete(v);
      for (const w of out.get(v)) inn.get(w).delete(v);
      for (const w of inn.get(v)) out.get(w).delete(v);
    };
    while (remaining.size) {
      let moved = true;
      while (moved) {
        moved = false;
        for (const v of [...remaining]) {
          if (!remaining.has(v)) continue;
          if (out.get(v).size === 0) { right.push(v); remove(v); moved = true; }
          else if (inn.get(v).size === 0) { left.push(v); remove(v); moved = true; }
        }
      }
      if (!remaining.size) break;
      let best = null, bd = -Infinity;
      for (const v of remaining) { const d = out.get(v).size - inn.get(v).size; if (d > bd) { bd = d; best = v; } }
      left.push(best); remove(best);
    }
    const order = [...left, ...right.reverse()];
    const pos = new Map();
    order.forEach((v, i) => pos.set(v, i));
    return pos;
  }

  function shortestPath(adj, from, to, allowed) {
    const prev = new Map([[from, null]]);
    const q = [from];
    while (q.length) {
      const v = q.shift();
      if (v === to) break;
      for (const w of adj.get(v) || []) if (allowed.has(w) && !prev.has(w)) { prev.set(w, v); q.push(w); }
    }
    if (!prev.has(to)) return null;
    const path = [];
    for (let v = to; v !== null; v = prev.get(v)) path.push(v);
    return path.reverse();
  }

  function pageRank(nodes, adj, iters = 40, d = 0.85) {
    const n = nodes.length;
    let pr = new Map(nodes.map((v) => [v, 1 / n]));
    for (let k = 0; k < iters; k++) {
      const next = new Map(nodes.map((v) => [v, (1 - d) / n]));
      let dangling = 0;
      for (const v of nodes) {
        const outs = adj.get(v);
        if (!outs || outs.size === 0) { dangling += pr.get(v); continue; }
        const share = (d * pr.get(v)) / outs.size;
        for (const w of outs) next.set(w, next.get(w) + share);
      }
      for (const v of nodes) next.set(v, next.get(v) + (d * dangling) / n);
      pr = next;
    }
    return pr;
  }

  // ---------------------------------------------------------------- repo analysis

  const EXCLUDE_DEFAULT = /(^|\/)(nimbledeps|vendor|nimcache|node_modules|build|nimblepkg|\.[^/]+)\//;

  const dirname = (p) => (p.includes("/") ? p.slice(0, p.lastIndexOf("/")) : "");
  function normalize(p) {
    const out = [];
    for (const s of p.split("/")) {
      if (s === "" || s === ".") continue;
      if (s === "..") { if (!out.length) return null; out.pop(); } else out.push(s);
    }
    return out.join("/");
  }

  function dirAt(path, depth) {
    const parts = dirname(path).split("/").filter(Boolean);
    return parts.slice(0, depth).join("/") || "(root)";
  }

  /**
   * files: [{path, text}] ; opts: {exclude: RegExp|null, includeTests: bool}
   * Returns the model consumed by the UI.
   */
  function analyze(files, opts) {
    opts = opts || {};
    const exclude = opts.exclude === undefined ? EXCLUDE_DEFAULT : opts.exclude;
    const nimFiles = files.filter((f) => f.path.endsWith(".nim") && !(exclude && exclude.test(f.path)));
    const fileSet = new Set(nimFiles.map((f) => f.path));

    // roots for package-style imports
    const roots = new Set(["", "src"]);
    for (const f of files) {
      if (f.path.endsWith(".nimble")) {
        const m = /srcDir\s*=\s*"([^"]*)"/.exec(f.text);
        if (m) roots.add(normalize(m[1]) || "");
      }
      if (/(^|\/)(config\.nims|nim\.cfg|[\w.-]+\.nims)$/.test(f.path)) {
        for (const m of f.text.matchAll(/(?:--path[:=]|switch\("path",\s*)"?([^"\s)]+)/g)) {
          const p = normalize(dirname(f.path) + "/" + m[1]);
          if (p !== null) roots.add(p);
        }
      }
    }
    for (const f of nimFiles) { const top = f.path.split("/")[0]; if (f.path.includes("/")) roots.add(top); }

    const tryFile = (p) => {
      if (p === null) return null;
      if (fileSet.has(p + ".nim")) return p;
      const last = p.split("/").pop();
      if (fileSet.has(p + "/" + last + ".nim")) return p + "/" + last;
      return null;
    };
    function resolve(spec, fromDir) {
      if (spec.startsWith(".")) return tryFile(normalize(fromDir + "/" + spec));
      let r = tryFile(normalize(fromDir + "/" + spec));
      if (r) return r;
      for (const rt of roots) { r = tryFile(normalize(rt + "/" + spec)); if (r) return r; }
      return null;
    }
    const externalName = (spec) => {
      const seg = spec.split("/").filter((s) => s && s !== "." && s !== "..");
      if (seg[0] === "pkg" && seg[1]) return seg[1];
      return seg[0] || spec;
    };

    const modules = new Map();
    const unresolved = [];
    const typeDefs = [];
    const nameIndex = new Map();

    for (const f of nimFiles) {
      const id = f.path.replace(/\.nim$/, "");
      const blanked = strip(f.text, true);
      const loc = blanked.split("\n").filter((l) => l.trim() !== "").length;
      const m = {
        id, path: f.path, dir: dirname(id), name: id.split("/").pop(), loc,
        imports: new Map(), externals: new Map(), types: [],
        entry: /\bisMainModule\b/.test(blanked),
        idents: null,
      };
      const dir = dirname(f.path);
      for (const st of parseImports(f.text)) {
        const target = resolve(st.spec, dir);
        if (target) {
          if (target === id) continue;
          let e = m.imports.get(target);
          if (!e) m.imports.set(target, (e = { to: target, kinds: new Set(), conditional: true, line: st.line }));
          e.kinds.add(st.kind);
          if (!st.conditional) e.conditional = false;
        } else if (st.kind === "export") {
          // symbol export, not a module
        } else if (st.spec.startsWith(".")) {
          unresolved.push({ from: id, spec: st.spec, line: st.line });
        } else {
          const pkg = externalName(st.spec);
          m.externals.set(pkg, (m.externals.get(pkg) || 0) + 1);
        }
      }
      for (const d of parseTypes(blanked)) {
        d.module = id;
        d.id = id + ":" + d.name;
        typeDefs.push(d);
        m.types.push(d);
        if (!nameIndex.has(d.name)) nameIndex.set(d.name, []);
        nameIndex.get(d.name).push(d);
      }
      m.idents = new Set(blanked.match(/[A-Za-z_]\w*/g) || []);
      modules.set(id, m);
    }
    // `export` of a module that is not also imported still creates visibility
    const ids = [...modules.keys()];

    // visibility closure through re-exports
    const reexports = new Map();
    for (const m of modules.values()) {
      const s = new Set();
      for (const e of m.imports.values()) if (e.kinds.has("export") || e.kinds.has("include")) s.add(e.to);
      reexports.set(m.id, s);
    }
    const closureCache = new Map();
    function closure(id, seen = new Set()) {
      if (closureCache.has(id)) return closureCache.get(id);
      const out = new Set([id]);
      if (seen.has(id)) return out;
      seen.add(id);
      for (const r of reexports.get(id) || []) for (const x of closure(r, seen)) out.add(x);
      if (seen.size === 1 || true) closureCache.set(id, out);
      return out;
    }
    const visible = new Map();
    for (const m of modules.values()) {
      const v = new Set([m.id]);
      for (const e of m.imports.values()) for (const x of closure(e.to)) v.add(x);
      visible.set(m.id, v);
    }

    // type edges
    const typeEdges = [];
    const typeUsers = new Map(typeDefs.map((d) => [d.id, new Set()]));
    for (const d of typeDefs) {
      const vis = visible.get(d.module);
      for (const r of d.refs) {
        const cands = (nameIndex.get(r.name) || []).filter((c) => c.id !== d.id && (vis.has(c.module)));
        if (!cands.length) continue;
        const same = cands.filter((c) => c.module === d.module);
        const pick = same.length ? same[0] : cands[0];
        typeEdges.push({ from: d.id, to: pick.id, kind: r.kind, ambiguous: !same.length && cands.length > 1 });
        typeUsers.get(pick.id).add(d.module);
      }
    }
    // identifier-level usage of exported types by importing modules
    const edgeWeight = new Map();
    for (const m of modules.values()) {
      for (const e of m.imports.values()) {
        const target = modules.get(e.to);
        let w = 1;
        for (const t of target.types) {
          if (t.exported && m.idents.has(t.name)) { w++; typeUsers.get(t.id).add(m.id); }
        }
        edgeWeight.set(m.id + ">" + e.to, w);
        e.weight = w;
      }
    }

    // module graph
    const adj = new Map(), radj = new Map();
    for (const id of ids) { adj.set(id, new Set()); radj.set(id, new Set()); }
    for (const m of modules.values()) for (const e of m.imports.values()) { adj.get(m.id).add(e.to); radj.get(e.to).add(m.id); }

    const sccsRaw = tarjan(ids, adj).filter((c) => c.length > 1);
    const sccs = sccsRaw
      .map((comp, k) => {
        const set = new Set(comp);
        const pos = greedyOrder(comp, adj);
        const back = [];
        for (const u of comp) for (const v of adj.get(u)) {
          if (set.has(v) && pos.get(u) >= pos.get(v)) {
            const cyc = shortestPath(adj, v, u, set);
            back.push({ from: u, to: v, weight: edgeWeight.get(u + ">" + v) || 1, cycle: cyc ? [...cyc, v] : null, kinds: [...modules.get(u).imports.get(v).kinds] });
          }
        }
        back.sort((a, b) => a.weight - b.weight);
        return { id: k, modules: comp.sort(), backEdges: back };
      })
      .sort((a, b) => b.modules.length - a.modules.length);
    sccs.forEach((s, i) => (s.id = i));
    const inCycle = new Map();
    for (const s of sccs) for (const id of s.modules) inCycle.set(id, s.id);
    const cutKey = new Set();
    for (const s of sccs) for (const b of s.backEdges) cutKey.add(b.from + ">" + b.to);

    // metrics
    const pr = pageRank(ids, adj);
    // level = longest dependency chain below (0 = leaf)
    const level = new Map();
    const condComp = new Map();
    for (const s of sccs) for (const id of s.modules) condComp.set(id, "scc" + s.id);
    const lvlVisit = (id, stack = new Set()) => {
      if (level.has(id)) return level.get(id);
      if (stack.has(id)) return 0;
      stack.add(id);
      let l = 0;
      for (const w of adj.get(id)) {
        if (condComp.has(id) && condComp.get(id) === condComp.get(w)) continue;
        l = Math.max(l, 1 + lvlVisit(w, stack));
      }
      stack.delete(id);
      level.set(id, l);
      return l;
    };
    for (const id of ids) lvlVisit(id);

    const out = [];
    for (const m of modules.values()) {
      const fanOut = adj.get(m.id).size, fanIn = radj.get(m.id).size;
      out.push({
        id: m.id, path: m.path, dir: m.dir, name: m.name, loc: m.loc,
        fanIn, fanOut, instability: fanIn + fanOut ? fanOut / (fanIn + fanOut) : 0,
        pagerank: pr.get(m.id), level: level.get(m.id), scc: inCycle.has(m.id) ? inCycle.get(m.id) : null,
        entry: m.entry || /^(apps?|examples?|tests?)\//.test(m.path) || /(^|\/)(test_|all_tests)/.test(m.path),
        isTest: /(^|\/)tests?\//.test(m.path),
        imports: [...m.imports.values()].map((e) => ({ to: e.to, kinds: [...e.kinds], conditional: e.conditional, weight: e.weight, cut: cutKey.has(m.id + ">" + e.to) })),
        externals: [...m.externals.entries()].sort((a, b) => b[1] - a[1]),
        types: m.types.map((t) => t.id),
        importers: [...radj.get(m.id)],
      });
    }

    const model = { modules: out, typeDefs, typeEdges, typeUsers: new Map([...typeUsers].map(([k, v]) => [k, [...v]])), sccs, unresolved, roots: [...roots] };
    model.hints = computeHints(model);
    return model;
  }

  function folderGraph(model, depth) {
    const nodes = new Map();
    const edges = new Map();
    for (const m of model.modules) {
      const f = dirAt(m.path, depth);
      if (!nodes.has(f)) nodes.set(f, { id: f, modules: 0, loc: 0, internal: 0, outgoing: 0, incoming: 0, types: 0 });
      const n = nodes.get(f);
      n.modules++; n.loc += m.loc; n.types += m.types.length;
    }
    const byId = new Map(model.modules.map((m) => [m.id, m]));
    for (const m of model.modules) {
      const a = dirAt(m.path, depth);
      for (const e of m.imports) {
        const b = dirAt(byId.get(e.to).path, depth);
        if (a === b) { nodes.get(a).internal++; continue; }
        const k = a + ">" + b;
        if (!edges.has(k)) edges.set(k, { from: a, to: b, weight: 0, count: 0 });
        const ed = edges.get(k);
        ed.weight += e.weight; ed.count++;
        nodes.get(a).outgoing++; nodes.get(b).incoming++;
      }
    }
    const adj = new Map([...nodes.keys()].map((k) => [k, new Set()]));
    for (const e of edges.values()) adj.get(e.from).add(e.to);
    const sccs = tarjan([...nodes.keys()], adj).filter((c) => c.length > 1).sort((a, b) => b.length - a.length);
    const cyc = new Set(sccs.flat());
    for (const n of nodes.values()) {
      n.cohesion = n.internal + n.outgoing ? n.internal / (n.internal + n.outgoing) : 1;
      n.inCycle = cyc.has(n.id);
    }
    // edges inside a folder-level SCC
    const sccOf = new Map();
    sccs.forEach((c, i) => c.forEach((x) => sccOf.set(x, i)));
    for (const e of edges.values()) e.inCycle = sccOf.has(e.from) && sccOf.get(e.from) === sccOf.get(e.to);
    return { nodes: [...nodes.values()], edges: [...edges.values()], sccs };
  }

  function computeHints(model) {
    const hints = [];
    const mods = model.modules.filter((m) => !m.isTest);
    const avg = (a) => a.reduce((x, y) => x + y, 0) / (a.length || 1);
    const fo = mods.map((m) => m.fanOut);
    const mean = avg(fo), sd = Math.sqrt(avg(fo.map((x) => (x - mean) ** 2)));
    const byId = new Map(model.modules.map((m) => [m.id, m]));

    for (const s of model.sccs) {
      const b = s.backEdges[0];
      hints.push({
        severity: "high", kind: "cycle",
        title: `Import cycle of ${s.modules.length} modules`,
        detail: b ? `Cheapest edge to cut: ${b.from} -> ${b.to} (weight ${b.weight}).` : "",
        modules: s.modules,
      });
    }
    for (const m of mods) {
      if (m.fanOut >= Math.max(15, mean + 2 * sd) && !m.entry)
        hints.push({ severity: "med", kind: "wide-fanout", title: `${m.id} imports ${m.fanOut} modules`, detail: "Wide fan-out: likely orchestrator or doing too much; consider splitting.", modules: [m.id] });
    }
    const p90 = [...mods].map((m) => m.fanIn).sort((a, b) => a - b)[Math.floor(mods.length * 0.9)] || 0;
    for (const m of mods) {
      if (m.fanIn >= Math.max(10, p90) && m.fanOut >= Math.max(8, mean) && m.loc > 200)
        hints.push({ severity: "med", kind: "hub", title: `${m.id} is a hub (in ${m.fanIn}, out ${m.fanOut}, ${m.loc} LOC)`, detail: "Heavily used and heavily dependent: changes ripple both ways.", modules: [m.id] });
    }
    for (const m of mods) {
      if (m.fanIn === 0 && !m.entry)
        hints.push({ severity: "low", kind: "orphan", title: `${m.id} is not imported anywhere`, detail: "Dead code candidate (or an undeclared entry point).", modules: [m.id] });
      else if (m.fanIn === 1 && m.loc < 40 && !m.entry)
        hints.push({ severity: "low", kind: "merge", title: `${m.id} (${m.loc} LOC) has a single importer`, detail: `Only ${m.importers[0]} uses it; consider inlining.`, modules: [m.id] });
    }
    // types used by exactly one foreign module: move candidates
    for (const d of model.typeDefs) {
      if (!d.exported) continue;
      const users = (model.typeUsers.get(d.id) || []).filter((u) => u !== d.module && !byId.get(u)?.isTest);
      if (users.length === 1 && model.typeDefs.length)
        hints.push({ severity: "low", kind: "move-type", title: `type ${d.name} used only by ${users[0]}`, detail: `Defined in ${d.module}; moving it next to its only user would drop a dependency.`, modules: [d.module, users[0]] });
    }
    const fg = folderGraph(model, 3);
    for (const n of fg.nodes) {
      if (n.modules >= 4 && n.cohesion < 0.25)
        hints.push({ severity: "low", kind: "cohesion", title: `folder ${n.id} has low cohesion (${(n.cohesion * 100).toFixed(0)}%)`, detail: `${n.internal} internal vs ${n.outgoing} outgoing imports.`, modules: [] });
    }
    for (const c of fg.sccs)
      hints.push({ severity: "high", kind: "folder-cycle", title: `Folder-level cycle: ${c.length} folders`, detail: c.join(", "), modules: [] });
    const order = { high: 0, med: 1, low: 2 };
    hints.sort((a, b) => order[a.severity] - order[b.severity]);
    return hints;
  }

  const api = { strip, parseImports, parseImportBody, parseTypes, tarjan, greedyOrder, pageRank, analyze, folderGraph, dirAt, EXCLUDE_DEFAULT };
  if (typeof module !== "undefined" && module.exports) module.exports = api;
  else root.NimParse = api;
})(typeof window !== "undefined" ? window : globalThis);
