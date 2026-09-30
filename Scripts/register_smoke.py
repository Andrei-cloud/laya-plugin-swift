#!/usr/bin/env python3
"""Offline register() smoke probe for the Hermes native plugins
(hermes-laya + hermes-laya-handoff). Runs WITHOUT the engine/GPU/daemon:
registration must never need them (lazy engine doctrine).

Proves three things the live audit of 2026-09-30 showed nobody was
checking:
  1. the registered surface == plugin.yaml provides_tools / provides_hooks
     exactly (honest manifest), including the D6 jev_* aliases;
  2. every registered tool schema's required+optional properties map onto
     the laya_usecases signature it is wired to — either as a direct
     parameter or as a key of the object parameter named in _ARG_NEST
     (the supervise bug: schema carried flat facts, supervise_run takes
     ONE `facts` dict, every call died with a TypeError behind a green
     registration);
  3. _HANDLERS/_TOOLS/_TOOL_ALIASES agree with each other (no orphan map
     entries after a rename).

Exit 0 = all green. Run after EVERY change to register() or its lookup
tables, and before Scripts/install_hermes_plugin.sh ships a change.
"""
import importlib.util
import inspect
import json
import os
import sys
import types

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PKG = os.path.join(REPO, "hermes", "plugin")
sys.path.insert(0, os.path.join(PKG, "hermes-laya", "lib"))   # usecases sigs

import laya_usecases as U                                      # noqa: E402


def _manifest_list(doc_text, key):
    """Minimal flat-YAML list reader (stdlib only — the smoke must run in
    ANY interpreter, the host venv is not guaranteed here): returns the
    '- item' entries under 'key:'."""
    out, active = [], False
    for line in doc_text.splitlines():
        if line.startswith(f"{key}:"):
            active = True
            continue
        if active:
            s = line.strip()
            if s.startswith("- "):
                out.append(s[2:].split("#")[0].strip())
            elif s and not line.startswith(" "):
                active = False
    return out


def load_plugin(pkg_dir, alias):
    spec = importlib.util.spec_from_file_location(
        alias, os.path.join(pkg_dir, "__init__.py"),
        submodule_search_locations=[pkg_dir])
    m = importlib.util.module_from_spec(spec)
    sys.modules[alias] = m
    spec.loader.exec_module(m)
    return m


class FakeCtx:
    def __init__(self):
        self.tools, self.hooks, self.mw = [], [], []
        self.cmds, self.sps = [], []
        self.handlers = {}

    def register_tool(self, name, toolset, handler, schema):
        assert schema["name"] == name, f"schema/name drift: {name}"
        self.tools.append(name)
        self.handlers[name] = (handler, schema)

    def register_hook(self, name, fn):
        self.hooks.append(name)

    def register_middleware(self, name, fn):
        self.mw.append(name)

    def register_command(self, name, fn, description="", args_hint=""):
        self.cmds.append(name)

    def register_system_prompt_section(self, name, rule, max_chars):
        self.sps.append((name, max_chars, len(rule)))


def declared_tools(plugin_yaml_path):
    text = open(plugin_yaml_path).read()
    return text, set(_manifest_list(text, "provides_tools")), \
        set(_manifest_list(text, "provides_hooks"))


def check_signature(tool_name, schema, fn, arg_nest):
    """Every property the schema advertises (required OR optional) must
    reach the frozen signature — directly or nested into the object
    parameter _ARG_NEST names. This is the exact bug class that made
    laya_supervise and laya_escalate 100% dead wiring."""
    params = inspect.signature(fn).parameters
    props = set((schema.get("parameters") or {}).get("properties") or {})
    required = set((schema.get("parameters") or {}).get("required") or [])
    missing = []
    for p in props:
        if p in params:
            continue
        nest = arg_nest.get(fn.__name__)
        if nest and nest in params:
            continue  # adapter folds unknown keys into the object param
        missing.append(p)
    # required-but-not-advertised is manifest lying in the other direction
    undeclared_required = required - props
    return missing, sorted(undeclared_required)


def main():
    failures = []

    # ---- hermes-laya ----------------------------------------------------
    m = load_plugin(os.path.join(PKG, "hermes-laya"), "hermes_laya_smoke")
    doc, declared, hooks_declared = declared_tools(
        os.path.join(PKG, "hermes-laya", "plugin.yaml"))
    ctx = FakeCtx()
    m.register(ctx)

    want = set(m._TOOLS) | set(m._TOOL_ALIASES.values())
    if set(ctx.tools) != want:
        failures.append(f"registered tools != _TOOLS+aliases: "
                        f"{sorted(set(ctx.tools) ^ want)}")
    if declared != set(m._TOOLS) | set(m._TOOL_ALIASES.values()):
        failures.append(f"plugin.yaml provides_tools != _TOOLS+aliases: "
                        f"{sorted(declared ^ (set(m._TOOLS) | set(m._TOOL_ALIASES.values())))}")
    if not hooks_declared >= set(ctx.hooks):
        # honest manifest declares every VALID_HOOKS seam it registers
        failures.append(f"hooks not all declared in plugin.yaml: "
                        f"{sorted(set(ctx.hooks) - hooks_declared)}")
    if ctx.mw != ["llm_request"]:
        failures.append(f"middleware: {ctx.mw}")
    for name, budget, rendered in ctx.sps:
        if rendered > budget:
            failures.append(f"system prompt section over budget {name}: {rendered}/{budget}")

    # _HANDLERS <-> _TOOLS agreement
    if set(m._HANDLERS) != set(m._TOOLS):
        failures.append(f"_HANDLERS keys != _TOOLS: {sorted(set(m._HANDLERS) ^ set(m._TOOLS))}")
    for tool, (_desc, params, _ext) in m._TOOLS.items():
        fn_name = m._HANDLERS[tool]
        if not hasattr(U, fn_name):
            failures.append(f"{tool}: laya_usecases.{fn_name} missing")
            continue
        missing, undeclared = check_signature(tool, {"parameters": params},
                                              getattr(U, fn_name), m._ARG_NEST)
        if missing:
            failures.append(f"{tool}: schema properties reach no parameter "
                            f"and no _ARG_NEST target: {missing}")
        if undeclared:
            failures.append(f"{tool}: required not in properties: {undeclared}")
        # required params of the signature with NO default must be covered
        # by either a schema property or the nest adapter
        req = [p for p, v in inspect.signature(getattr(U, fn_name)).parameters.items()
               if v.default is inspect.Parameter.empty and p != "engine"]
        nest = m._ARG_NEST.get(fn_name)
        for p in req:
            if p not in params.get("properties", {}) and p != nest:
                failures.append(f"{tool}: signature REQUIRES '{p}' but the "
                                f"schema neither declares it nor nests into it")

    # handler return contract: JSON string even on the exception path
    for name, (handler, schema) in ctx.handlers.items():
        out = handler({"__impossible__": True})   # forces the fail-open path
        if not isinstance(out, str):
            failures.append(f"{name}: handler returned {type(out)} not str")
        else:
            json.loads(out)                        # must parse

    # ---- hermes-laya-handoff ---------------------------------------------
    mh = load_plugin(os.path.join(PKG, "hermes-laya-handoff"),
                     "hermes_laya_handoff_smoke")
    doc_h, declared_h, hooks_h = declared_tools(
        os.path.join(PKG, "hermes-laya-handoff", "plugin.yaml"))
    ctxh = FakeCtx()
    mh.register(ctxh)
    if declared_h:
        failures.append(f"handoff declares tools it must not: {sorted(declared_h)}")
    if not {"pre_gateway_dispatch", "pre_llm_call"} <= set(ctxh.hooks):
        failures.append(f"handoff hooks: {ctxh.hooks}")
    for name, budget, rendered in ctxh.sps:
        if rendered > budget:
            failures.append(f"handoff sp over budget: {rendered}/{budget}")

    if failures:
        print("REGISTER SMOKE: FAIL")
        for f in failures:
            print("  -", f)
        return 1
    print("registered:", sorted(ctx.tools))
    print("hooks:", ctx.hooks, "mw:", ctx.mw, "cmds:", sorted(ctx.cmds))
    print("handoff hooks:", ctxh.hooks, "cmds:", sorted(ctxh.cmds))
    print("REGISTER SMOKE: OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
