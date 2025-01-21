"extensions for bzlmod"

load(":pkg_config.bzl", rule_pkg_config = "pkg_config")

# TODO: it sucks that the API of the oci_pull macro has to be repeated here.
pkg_config = tag_class(attrs = {
    "name": attr.string(doc = "Repository name."),
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
    "system_includes": attr.string_dict(doc = "Addidional include directories (some pkg-config don't publish this directories). Value is used as destination path."),
    "ignore_includes": attr.string_list(doc = "Include directories exclude list."),
})

def _bazel_pkg_config_extension(module_ctx):
    root_direct_deps = []
    root_direct_dev_deps = []
    for mod in module_ctx.modules:
        for item in mod.tags.pkg_config:
            rule_pkg_config(
                name = item.name,
                pkg_name = item.pkg_name,
                include_prefix = item.include_prefix,
                strip_include = item.strip_include,
                version = item.version,
                min_version = item.min_version,
                max_version = item.max_version,
                deps = item.deps,
                linkopts = item.linkopts,
                copts = item.copts,
                ignore_opts = item.ignore_opts,
                dynamic = item.dynamic,
                system_includes = item.system_includes,
                ignore_includes = item.ignore_includes,
            )

            if mod.is_root:
                deps = root_direct_dev_deps if module_ctx.is_dev_dependency(item) else root_direct_deps
                deps.append(item.name)

    # Allow use_repo calls to be automatically managed by `bazel mod tidy`. See
    # https://docs.google.com/document/d/1dj8SN5L6nwhNOufNqjBhYkk5f-BJI_FPYWKxlB3GAmA/edit#heading=h.5mcn15i0e1ch
    return module_ctx.extension_metadata(
        root_module_direct_deps = root_direct_deps,
        root_module_direct_dev_deps = root_direct_dev_deps,
    )

bazel_pkg_config = module_extension(
    implementation = _bazel_pkg_config_extension,
    tag_classes = {
        "pkg_config": pkg_config,
    },
)
