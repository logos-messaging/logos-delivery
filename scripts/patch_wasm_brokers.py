import re, glob

# Turn the macros' compile-time `{.error: "...".}` pragma into a macro-time
# `macros.error("...")` call. The pragma form is evaluated when the macro body
# is semchecked -- i.e. on plain `import brokers/request_broker` -- so under
# --threads:off the module cannot be imported at all, even by code that never
# invokes the mt mode. The call form fires only if the macro is actually used
# in that mode, which is the intended behaviour.
PAT = re.compile(
    r'( *)\{\.\n'
    r' *error:\n'
    r'((?: *"[^\n]*\n)+)'
    r' *\.\}\n'
)

total = 0
for path in sorted(glob.glob("wasm-deps/brokers/brokers/*.nim")):
    src = open(path).read()

    def repl(m):
        indent, body = m.group(1), m.group(2)
        parts = [ln.strip() for ln in body.strip().splitlines()]
        joined = ("\n" + indent + "    ").join(parts)
        return f"{indent}macros.error(\n{indent}    {joined}\n{indent})\n"

    out, n = PAT.subn(repl, src)
    if n:
        open(path, "w").write(out)
        total += n
        print(f"{path}: {n} site(s)")
print("total", total)
