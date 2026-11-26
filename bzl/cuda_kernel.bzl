load("@bazel_tools//tools/cpp:toolchain_utils.bzl", "find_cpp_toolchain", "use_cpp_toolchain")
load("@rules_cc//cc:defs.bzl", "cc_binary", "cc_library")
load("@rules_cc//cc/common:cc_common.bzl", "cc_common")
load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")
load("@rules_cuda//cuda:defs.bzl", "CudaArchsInfo", "cuda_library", "find_cuda_toolchain")

def _cuda_kernel_impl(ctx):
    cuda_toolchain = find_cuda_toolchain(ctx)
    out = ctx.actions.declare_file(ctx.attr.out)

    args = ctx.actions.args()
    args.add("-x", "cu")

    arch_specs = ctx.attr._cuda_archs[CudaArchsInfo].arch_specs
    if ctx.attr.mode == "ptx":
        arch = arch_specs[0].stage1_arch if arch_specs else "80"
        args.add("-arch=compute_{}".format(arch))
        args.add("-ptx")
    else:
        for spec in arch_specs:
            for s2 in spec.stage2_archs:
                code = "compute_{}".format(s2.arch) if s2.virtual else "sm_{}".format(s2.arch)
                args.add("-gencode", "arch=compute_{},code={}".format(spec.stage1_arch, code))
        args.add("-fatbin")

    seen_inc = {}
    inc_dirs = [ctx.file.src.dirname, "."]
    transitive_hdrs = []
    for dep in ctx.attr.deps + [ctx.attr._cuda_runtime]:
        if CcInfo in dep:
            cctx = dep[CcInfo].compilation_context
            transitive_hdrs.append(cctx.headers)
            for inc in cctx.includes.to_list() + cctx.system_includes.to_list() + cctx.quote_includes.to_list():
                inc_dirs.append(inc)
    for inc in inc_dirs:
        if inc and inc not in seen_inc:
            seen_inc[inc] = True
            args.add("-I", inc)

    args.add_all(ctx.attr.copts)
    args.add("-o", out)
    args.add(ctx.file.src)

    inputs = depset(
        direct = [ctx.file.src] + ctx.files.hdrs,
        transitive = [cuda_toolchain.all_files] + transitive_hdrs,
    )

    env = {}
    for f in cuda_toolchain.all_files.to_list():
        if f.basename == "cicc":
            env["CICC_PATH"] = f.dirname
        elif f.basename == "libdevice.10.bc":
            env["NVVMIR_LIBRARY_DIR"] = f.dirname

    ctx.actions.run(
        executable = cuda_toolchain.compiler_executable,
        arguments = [args],
        inputs = inputs,
        outputs = [out],
        env = env,
        use_default_shell_env = True,
        mnemonic = "CudaKernelCompile",
        progress_message = "Compiling CUDA {} {}".format(ctx.attr.mode, ctx.attr.out),
    )

    return [DefaultInfo(files = depset([out]))]

cuda_kernel = rule(
    implementation = _cuda_kernel_impl,
    attrs = {
        "src": attr.label(allow_single_file = [".cu"], mandatory = True),
        "hdrs": attr.label_list(allow_files = True),
        "out": attr.string(mandatory = True),
        "mode": attr.string(values = ["fatbin", "ptx"], mandatory = True),
        "copts": attr.string_list(),
        "deps": attr.label_list(providers = [CcInfo]),
        "_cuda_archs": attr.label(default = Label("@rules_cuda//cuda:archs")),
        "_cuda_runtime": attr.label(default = Label("@rules_cuda//cuda:runtime")),
    },
    toolchains = ["@rules_cuda//cuda:toolchain_type"],
)

def cuda_sample_binary(
        name,
        cu_srcs = [],
        cc_srcs = [],
        hdrs = [],
        textual_hdrs = [],
        deps = [],
        data = [],
        includes = [],
        rdc = False,
        copts = [],
        host_copts = [],
        linkopts = [],
        args = [],
        env = {}):
    """Wrapper around cuda_library + cc_binary supporting mixed .cu/.cpp, includes, data, args, env, and linkopts."""
    has_culibos = "@cuda//:culibos_a" in deps
    base_deps = [d for d in deps if d != "@cuda//:culibos_a"]
    bin_deps = list(base_deps)
    if "@rules_cuda//cuda:runtime" not in bin_deps:
        bin_deps.append("@rules_cuda//cuda:runtime")

    hdr_lib_dep = []
    cc_hdrs = [h for h in hdrs if not h.endswith(".cuh") and not h.endswith(".cu")]
    cc_textual = [h for h in hdrs if h.endswith(".cuh") or h.endswith(".cu")] + list(textual_hdrs)
    if cc_hdrs or cc_textual or includes:
        hdr_lib_name = "_" + name + "_hdrs"
        cc_library(
            name = hdr_lib_name,
            hdrs = cc_hdrs,
            textual_hdrs = cc_textual,
            includes = includes,
        )
        hdr_lib_dep = [":" + hdr_lib_name]
        bin_deps.append(":" + hdr_lib_name)

    if cu_srcs:
        lib_name = "_" + name
        cuda_library(
            name = lib_name,
            srcs = cu_srcs,
            hdrs = hdrs,
            deps = base_deps + hdr_lib_dep,
            includes = includes,
            rdc = rdc,
            copts = copts,
            host_copts = host_copts,
            alwayslink = True,
        )
        bin_deps.append(":" + lib_name)

    if has_culibos:
        bin_deps.append("@cuda//:culibos_a")

    cc_binary(
        name = name,
        srcs = cc_srcs,
        deps = bin_deps,
        data = data,
        copts = host_copts,
        linkopts = linkopts,
        args = args,
        env = env,
    )

    cuda_sample_test(
        name = name + "_test",
        binary = ":" + name,
        data = data,
        sample_args = args,
        sample_env = env,
        size = "medium",
        timeout = "moderate",
        tags = ["gpu", "local"],
    )


def _nvrtc_builtins_impl(ctx):
    cc_toolchain = find_cpp_toolchain(ctx)
    feature_configuration = cc_common.configure_features(
        ctx = ctx,
        cc_toolchain = cc_toolchain,
        requested_features = ctx.features,
        unsupported_features = ctx.disabled_features,
    )
    libs = []
    for f in ctx.files.nvrtc_all_files:
        if "libnvrtc-builtins.so" in f.basename and not f.basename.endswith(".a"):
            libs.append(
                cc_common.create_library_to_link(
                    actions = ctx.actions,
                    feature_configuration = feature_configuration,
                    cc_toolchain = cc_toolchain,
                    dynamic_library = f,
                ),
            )
    if not libs:
        return [CcInfo()]
    linker_input = cc_common.create_linker_input(
        owner = ctx.label,
        libraries = depset(libs),
    )
    return [
        CcInfo(
            linking_context = cc_common.create_linking_context(
                linker_inputs = depset([linker_input]),
            ),
        ),
    ]

nvrtc_builtins = rule(
    implementation = _nvrtc_builtins_impl,
    attrs = {
        "nvrtc_all_files": attr.label(default = Label("@cuda//:nvrtc_all_files")),
        "_cc_toolchain": attr.label(default = Label("@bazel_tools//tools/cpp:current_cc_toolchain")),
    },
    toolchains = use_cpp_toolchain(),
    fragments = ["cpp"],
)


def _cccl_nv_target_impl(ctx):
    for f in ctx.files.cccl_all_files:
        if f.path.endswith("/nv/target") or f.basename == "target" and f.dirname.endswith("/nv"):
            return [DefaultInfo(files = depset([f]))]
    # Fallback empty marker if toolkit has no nv/target (e.g., CUDA 11.8)
    out = ctx.actions.declare_file("cccl_nv_target_none")
    ctx.actions.write(out, "")
    return [DefaultInfo(files = depset([out]))]

cccl_nv_target = rule(
    implementation = _cccl_nv_target_impl,
    attrs = {
        "cccl_all_files": attr.label(default = Label("@cuda//:cccl_all_files")),
    },
)

def _cuda_sample_test_impl(ctx):
    script = ctx.actions.declare_file(ctx.label.name + ".sh")
    bin_file = ctx.executable.binary
    bin_rpath = "./" + bin_file.short_path

    env_lines = []
    for k, v in ctx.attr.sample_env.items():
        expanded = ctx.expand_location(v, ctx.attr.data)
        env_lines.append('export {}="{}"'.format(k, expanded.replace('"', '\\"')))

    arg_items = []
    for a in ctx.attr.sample_args:
        expanded = ctx.expand_location(a, ctx.attr.data)
        arg_items.append('"{}"'.format(expanded.replace('"', '\\"')))

    content = """#!/usr/bin/env bash
set -uo pipefail
{env_block}
BIN="{bin_path}"
out=$(mktemp)
trap 'rm -f "$out"' EXIT
"$BIN" {args_str} 2>&1 | tee "$out"
rc=${{PIPESTATUS[0]}}
if [ "$rc" -eq 0 ]; then
  exit 0
fi
if [ "$rc" -eq 2 ] && grep -qiE '(waiv|waving|two gpus|two or more gpus)' "$out"; then
  echo "[WAIVED] $BIN exited with code 2 (EXIT_WAIVED)"
  exit 0
fi
if grep -q 'the provided PTX was compiled with an unsupported toolchain' "$out"; then
  echo "[WAIVED] $BIN requires a newer host CUDA driver for PTX JIT"
  exit 0
fi
exit "$rc"
""".format(
        env_block = "\n".join(env_lines),
        bin_path = bin_rpath,
        args_str = " ".join(arg_items),
    )

    ctx.actions.write(
        output = script,
        content = content,
        is_executable = True,
    )

    runfiles = ctx.runfiles(files = ctx.files.data + [bin_file])
    runfiles = runfiles.merge(ctx.attr.binary[DefaultInfo].default_runfiles)
    return [DefaultInfo(executable = script, runfiles = runfiles)]

cuda_sample_test = rule(
    implementation = _cuda_sample_test_impl,
    attrs = {
        "binary": attr.label(executable = True, cfg = "target", mandatory = True),
        "data": attr.label_list(allow_files = True),
        "sample_args": attr.string_list(),
        "sample_env": attr.string_dict(),
    },
    test = True,
)
