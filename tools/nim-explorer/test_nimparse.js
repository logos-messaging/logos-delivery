"use strict";
const assert = require("assert");
const N = require("./nimparse.js");

const specs = (src) => N.parseImports(src).map((s) => s.kind + ":" + s.spec);

// import forms
assert.deepStrictEqual(specs("import a, b/c"), ["import:a", "import:b/c"]);
assert.deepStrictEqual(specs("import std/[tables, sets], chronos"), ["import:std/tables", "import:std/sets", "import:chronos"]);
assert.deepStrictEqual(
  specs("import\n  a/[b, c/[d, e]],\n  f as g,\n  h\n\nlet x = 1"),
  ["import:a/b", "import:a/c/d", "import:a/c/e", "import:f", "import:h"]
);
assert.deepStrictEqual(specs("from ../x/y import z, w"), ["import:../x/y"]);
assert.deepStrictEqual(specs("export a, b/c\ninclude ./d"), ["export:a", "export:b/c", "include:./d"]);
assert.deepStrictEqual(specs('import "foo/bar.nim"'), ["import:foo/bar"]);
assert.deepStrictEqual(specs("import a except foo, bar"), ["import:a"]);
assert.deepStrictEqual(specs("import\n  a/[\n    b,\n    c\n  ], d"), ["import:a/b", "import:a/c", "import:d"]);

assert.deepStrictEqual(specs("import\n  p/q/\n    [a, b as c],\n  ./d\nlet x = 1"), ["import:p/q/a", "import:p/q/b", "import:./d"]);

assert.deepStrictEqual(specs('import "."/x, "../y"/z'), ["import:./x", "import:../y/z"]);

// comments and strings must not produce imports
assert.deepStrictEqual(specs('# import nope\n#[ import nope2\n#[nested]# import nope3 ]#\nlet s = """\nimport inside\n"""\nimport real'), ["import:real"]);
assert.deepStrictEqual(specs('let s = "import x"\nimport ok'), ["import:ok"]);
assert.strictEqual(N.parseImports("when defined(x):\n  import a")[0].conditional, true);
assert.strictEqual(N.parseImports("import a")[0].conditional, false);
assert.strictEqual(N.parseImports("proc exportc() = discard\nimportc").length, 0);

// types
const types = N.parseTypes(N.strip(`
type
  Color* = enum
    Red, Green
    Blue
  Base* = ref object of RootObj
    id*: int
  Foo* {.pure.} = object of Base
    color*: Color
    a*, b: seq[Bar]
    cb: proc (x: Color) {.gcsafe.}
    case k: Color
    of Red: r: Bar
    else: discard
  Bar[T] = object
    v: T
  Id* = distinct string
  Alias = Table[string, Foo]
  Pair = tuple[a: Foo, b: int]

type Solo* = object
  x: Foo

proc f() = discard
`, true));
const byName = Object.fromEntries(types.map((t) => [t.name, t]));
assert.deepStrictEqual(Object.keys(byName), ["Color", "Base", "Foo", "Bar", "Id", "Alias", "Pair", "Solo"]);
assert.strictEqual(byName.Color.kind, "enum");
assert.deepStrictEqual(byName.Color.members, ["Red", "Green", "Blue"]);
assert.strictEqual(byName.Base.kind, "ref object");
assert.strictEqual(byName.Foo.base, "Base");
assert.ok(byName.Foo.refs.some((r) => r.name === "Base" && r.kind === "inherits"));
assert.ok(byName.Foo.refs.some((r) => r.name === "Color" && r.kind === "has"));
assert.ok(byName.Foo.refs.some((r) => r.name === "Bar" && r.kind === "has"));
assert.ok(byName.Foo.refs.some((r) => r.name === "Color" && r.kind === "uses"));
assert.strictEqual(byName.Id.kind, "distinct");
assert.strictEqual(byName.Alias.kind, "alias");
assert.ok(byName.Alias.refs.some((r) => r.name === "Foo"));
assert.strictEqual(byName.Pair.kind, "tuple");
assert.ok(byName.Pair.refs.some((r) => r.name === "Foo"));
assert.ok(byName.Solo.refs.some((r) => r.name === "Foo"));
assert.strictEqual(byName.Solo.exported, true);
assert.strictEqual(byName.Bar.exported, false);

// SCC + cycle cutting
const adj = new Map([["a", new Set(["b"])], ["b", new Set(["c"])], ["c", new Set(["a", "d"])], ["d", new Set()]]);
const comps = N.tarjan([...adj.keys()], adj).filter((c) => c.length > 1);
assert.strictEqual(comps.length, 1);
assert.deepStrictEqual(comps[0].sort(), ["a", "b", "c"]);

// whole-repo analysis
const files = [
  { path: "pkg/a.nim", text: "import ./b, std/tables, chronos\ntype A* = object\n  b: B\n" },
  { path: "pkg/b.nim", text: "import ./a\ntype B* = object\n  x: int\n" },
  { path: "pkg/sub/c.nim", text: "import ../a, pkg/b\nexport ../b\n" },
  { path: "pkg/sub/d.nim", text: "import ./c\n" },
];
const model = N.analyze(files);
assert.strictEqual(model.modules.length, 4);
assert.strictEqual(model.sccs.length, 1);
assert.deepStrictEqual(model.sccs[0].modules, ["pkg/a", "pkg/b"]);
assert.strictEqual(model.sccs[0].backEdges.length, 1);
const a = model.modules.find((m) => m.id === "pkg/a");
assert.deepStrictEqual(a.externals.map((e) => e[0]).sort(), ["chronos", "std"]);
assert.ok(model.typeEdges.some((e) => e.from === "pkg/a:A" && e.to === "pkg/b:B" && e.kind === "has"));
const d = model.modules.find((m) => m.id === "pkg/sub/d");
assert.strictEqual(d.fanOut, 1);
const fg = N.folderGraph(model, 2);
assert.ok(fg.nodes.some((n) => n.id === "pkg/sub"));

console.log("all nimparse tests passed");
