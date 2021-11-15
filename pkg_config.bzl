def _success(value):
    return struct(error = None, value = value)

def _error(message):
    return struct(error = message, value = None)

def _unique(items):
    result = []
    added = {}
    for item in items:
        if not (item in added):
            added[item] = True
            result += [item]
    return result

def _split(result, delimeter = " "):
    if result.error != None:
        return result
    return _success(_unique([arg for arg in result.value.strip().split(delimeter) if arg]))

def _find_binary(ctx, binary_name):
    binary = ctx.which(binary_name)
    if binary == None:
        return _error("Unable to find binary: {}".format(binary_name))
    return _success(binary)

def _execute(ctx, binary, args):
    result = ctx.execute([binary] + args)
    if result.return_code != 0:
        return _error("Failed execute {} {}".format(binary, args))
    return _success(result.stdout)

def _pkg_config(ctx, pkg_config, pkg_name, args):
    return _execute(ctx, pkg_config, [pkg_name] + args)

def _check(ctx, pkg_config, pkg_name):
    exist = _pkg_config(ctx, pkg_config, pkg_name, ["--exists"])
    if exist.error != None:
        return _error("Package {} does not exist".format(pkg_name))

    if ctx.attr.version != "":
        version = _pkg_config(ctx, pkg_config, pkg_name, ["--exact-version", ctx.attr.version])
        if version.error != None:
            return _error("Require {} version = {}".format(pkg_name, ctx.attr.version))

    if ctx.attr.min_version != "":
        version = _pkg_config(ctx, pkg_config, pkg_name, ["--atleast-version", ctx.attr.min_version])
        if version.error != None:
            return _error("Require {} version >= {}".format(pkg_name, ctx.attr.min_version))

    if ctx.attr.max_version != "":
        version = _pkg_config(ctx, pkg_config, pkg_name, ["--max-version", ctx.attr.max_version])
        if version.error != None:
            return _error("Require {} version <= {}".format(pkg_name, ctx.attr.max_version))

    return _success(None)

def _extract_prefix(flags, prefix, strip = True):
    stripped, remain = [], []
    for arg in flags:
        if arg.startswith(prefix):
            if strip:
                stripped += [arg[len(prefix):]]
            else:
                stripped += [arg]
        else:
            remain += [arg]
    return stripped, remain

def _includes(ctx, pkg_config, pkg_name):
    includes = _split(_pkg_config(ctx, pkg_config, pkg_name, ["--cflags-only-I"]))
    if includes.error != None:
        return includes
    includes, unused = _extract_prefix(includes.value, "-I", strip = True)
    return _success(includes)

def _copts(ctx, pkg_config, pkg_name):
    return _split(_pkg_config(ctx, pkg_config, pkg_name, [
        "--cflags-only-other",
        "--libs-only-L",
    ] + _pkg_config_static(ctx)))

def _pkg_config_static(ctx):
    if ctx.attr.dynamic:
        return []
    return ["--static"]

def _linkopts(ctx, pkg_config, pkg_name):
    return _split(_pkg_config(ctx, pkg_config, pkg_name, [
        "--libs-only-other",
        "--libs-only-l",
    ] + _pkg_config_static(ctx)))

def _ignore_opts(opts, ignore_opts):
    remain = []
    for opt in opts:
        if opt not in ignore_opts:
            remain += [opt]
    return remain

def _symlinks(ctx, basename, srcpaths):
    ignore_includes = ctx.attr.ignore_includes
    result = []
    root = ctx.path("")
    base = root.get_child(basename)
    rootlen = len(str(base)) - len(basename)
    for idx, src in enumerate([ctx.path(p) for p in srcpaths]):
        if not src.exists:
            continue
        if str(src) in ignore_includes:
            continue
        dest = "{}_{}".format(base.get_child(src.basename), idx)
        ctx.symlink(src.realpath, dest)
        result += [str(dest)[rootlen:]]
    return result

def _lib_dirs(ctx, pkg_config, pkg_name):
    deps = _split(_pkg_config(ctx, pkg_config, pkg_name, [
        "--libs-only-L",
    ] + _pkg_config_static(ctx)))
    if deps.error != None:
        return deps
    result, unused = _extract_prefix(deps.value, "-L", strip = True)

    lib_dir = _pkg_config(ctx, pkg_config, pkg_name, ["--variable=libdir"])
    if lib_dir.error != None:
        return lib_dir
    lib_dir = lib_dir.value.strip()

    if lib_dir != "":
        result += [lib_dir]

    return _success(_unique(result))

def _lib_dynamic_file(ctx, lib):
    if "mac os" in ctx.os.name:
        return "lib{}.dylib".format(lib)
    return "lib{}.so".format(lib)

def _lib_static_file(ctx, lib):
    return "lib{}.a".format(lib)

def _deps(ctx, pkg_config, pkg_name):
    lib_dirs = _lib_dirs(ctx, pkg_config, pkg_name)
    if lib_dirs.error != None:
        return lib_dirs
    lib_dirs = lib_dirs.value

    libs = _split(_pkg_config(ctx, pkg_config, pkg_name, [
        "--libs-only-l",
    ] + _pkg_config_static(ctx)))
    if libs.error != None:
        return libs

    libs, unused = _extract_prefix(libs.value, "-l", strip = True)

    deps = {}
    for lib in _unique(libs):
        found = None
        for lib_dir in lib_dirs:
            if ctx.attr.dynamic:
                name = _lib_dynamic_file(ctx, lib)
                src = ctx.path(lib_dir).get_child(name)
                if src.exists:
                    link = "libs/{}".format(name)
                    ctx.symlink(src, ctx.path(link))
                    found = {"shared": link}
                    break
            name = _lib_static_file(ctx, lib)
            src = ctx.path(lib_dir).get_child(name)
            if src.exists:
                link = "libs/{}".format(name)
                ctx.symlink(src, ctx.path(link))
                found = {"static": link}
                break
        if found == None:
            return _error("can't find library '{}' in paths '{}'".format(lib, lib_dirs))
        dep = "lib{}_private".format(lib.replace("/", "_").replace(".", "_"))
        deps[dep] = found
    return _success(deps)

def _fmt_array(array):
    return ", ".join(['"{}"'.format(a) for a in array])

def _fmt_map(map):
    return ", ".join(['"{}": "{}"'.format(k, map[k]) for k in map])

def _fmt_glob(array):
    return _fmt_array(["{}/**/*.h".format(a) for a in array])

def _pkg_config_impl(ctx):
    pkg_name = ctx.attr.pkg_name
    if pkg_name == "":
        pkg_name = ctx.attr.name

    pkg_config = _find_binary(ctx, "pkg-config")
    if pkg_config.error != None:
        return pkg_config
    pkg_config = pkg_config.value

    check = _check(ctx, pkg_config, pkg_name)
    if check.error != None:
        return check

    includes = _includes(ctx, pkg_config, pkg_name)
    if includes.error != None:
        return includes
    includes = includes.value
    includes = _symlinks(ctx, "includes", includes)
    strip_include = "includes"
    if len(includes) == 1:
        strip_include = includes[0]
    if ctx.attr.strip_include != "":
        strip_include += "/" + ctx.attr.strip_include

    ignore_opts = ctx.attr.ignore_opts
    copts = _copts(ctx, pkg_config, pkg_name)
    if copts.error != None:
        return copts
    copts = _ignore_opts(copts.value, ignore_opts)

    linkopts = _linkopts(ctx, pkg_config, pkg_name)
    if linkopts.error != None:
        return linkopts
    linkopts = _ignore_opts(linkopts.value, ignore_opts)

    lib_dirs = _lib_dirs(ctx, pkg_config, pkg_name)
    if lib_dirs.error != None:
        return lib_dirs
    lib_dirs = lib_dirs.value

    deps = _deps(ctx, pkg_config, pkg_name)
    if deps.error != None:
        return deps
    deps = deps.value
    static_libs = {}
    shared_libs = {}
    for name in deps:
        dep = deps[name]
        if "static" in dep:
            static_libs[name] = dep["static"]
        if "shared" in dep:
            shared_libs[name] = dep["shared"]

    include_prefix = ctx.attr.name
    if ctx.attr.include_prefix != "":
        include_prefix = ctx.attr.include_prefix + "/" + ctx.attr.name

    build = ctx.template("BUILD", Label("//:BUILD.tmpl"), substitutions = {
        "%{name}": ctx.attr.name,
        "%{hdrs}": _fmt_glob(includes),
        "%{includes}": _fmt_array(includes),
        "%{copts}": _fmt_array(copts),
        "%{extra_copts}": _fmt_array(ctx.attr.copts),
        "%{extra_deps}": _fmt_array(ctx.attr.deps),
        "%{linkopts}": _fmt_array(linkopts),
        "%{extra_linkopts}": _fmt_array(ctx.attr.linkopts),
        "%{strip_include}": strip_include,
        "%{include_prefix}": include_prefix,
        "%{deps}": _fmt_array([":" + dep for dep in deps]),
        "%{shared_libs}": _fmt_map(shared_libs),
        "%{static_libs}": _fmt_map(static_libs),
    }, executable = False)

pkg_config = repository_rule(
    attrs = {
        "pkg_name": attr.string(doc = "Package name for pkg-config query, default to name."),
        "include_prefix": attr.string(doc = "Additional prefix when including file, e.g. third_party. Compatible with strip_include option to produce desired include paths."),
        "strip_include": attr.string(doc = "Strip prefix when including file, e.g. libs, files not included will be invisible. Compatible with include_prefix option to produce desired include paths."),
        "version": attr.string(doc = "Exact package version."),
        "min_version": attr.string(doc = "Minimum package version."),
        "max_version": attr.string(doc = "Maximum package version."),
        "deps": attr.string_list(doc = "Dependency targets."),
        "linkopts": attr.string_list(doc = "Extra linkopts value."),
        "copts": attr.string_list(doc = "Extra copts value."),
        "ignore_opts": attr.string_list(doc = "Ignore listed opts in copts or linkopts."),
        "dynamic": attr.bool(doc = "Use dynamic linking."),
        "ignore_includes": attr.string_list(doc = "Include directories exclude list."),
    },
    local = True,
    implementation = _pkg_config_impl,
)
