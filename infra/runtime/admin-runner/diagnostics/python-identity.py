"""Capture the interpreter's own generated ABI before installed stdlib reuse."""
import json
import platform
import sys
import sysconfig

print(json.dumps({
    "abi": {
        "version_info": list(sys.version_info), "abiflags": sys.abiflags,
        "cache_tag": sys.implementation.cache_tag,
        "config": {name: sysconfig.get_config_var(name) for name in (
            "SOABI", "EXT_SUFFIX", "MULTIARCH", "Py_DEBUG", "Py_TRACE_REFS",
            "SIZEOF_VOID_P", "SIZEOF_LONG", "WITH_PYMALLOC",
        )},
    },
    "builtins": list(sys.builtin_module_names),
    "compiler": platform.python_compiler(),
    "configure": sysconfig.get_config_var("CONFIG_ARGS"),
}, sort_keys=True))
