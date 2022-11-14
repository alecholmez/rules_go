# Copyright 2014 The Bazel Authors. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

load(
    "//go/private:common.bzl",
    "get_versioned_shared_lib_extension",
    "has_simple_shared_lib_extension",
    "hdr_exts",
)
load(
    "//go/private:mode.bzl",
    "LINKMODE_NORMAL",
    "extldflags_from_cc_toolchain",
)

def cgo_configure(go, srcs, cdeps, cppopts, copts, cxxopts, clinkopts):
    """cgo_configure returns the inputs and compile / link options
    that are required to build a cgo archive.
    Args:
        go: a GoContext.
        srcs: list of source files being compiled. Include options are added
            for the headers.
        cdeps: list of Targets for C++ dependencies. Include and link options
            may be added.
        cppopts: list of C preprocessor options for the library.
        copts: list of C compiler options for the library.
        cxxopts: list of C++ compiler options for the library.
        clinkopts: list of linker options for the library.
    Returns: a struct containing:
        inputs: depset of files that must be available for the build.
        deps: depset of files for dynamic libraries.
        runfiles: runfiles object for the C/C++ dependencies.
        cppopts: complete list of preprocessor options
        copts: complete list of C compiler options.
        cxxopts: complete list of C++ compiler options.
        objcopts: complete list of Objective-C compiler options.
        objcxxopts: complete list of Objective-C++ compiler options.
        clinkopts: complete list of linker options.
    """
    if not go.cgo_tools:
        fail("Go toolchain does not support cgo")

    cppopts = list(cppopts)
    copts = go.cgo_tools.c_compile_options + copts
    cxxopts = go.cgo_tools.cxx_compile_options + cxxopts
    objcopts = go.cgo_tools.objc_compile_options + copts
    objcxxopts = go.cgo_tools.objcxx_compile_options + cxxopts
    clinkopts = extldflags_from_cc_toolchain(go) + clinkopts

    # NOTE(#2545): avoid unnecessary dynamic link
    if "-static-libstdc++" in clinkopts:
        clinkopts = [
            option
            for option in clinkopts
            if option not in ("-lstdc++", "-lc++")
        ]

    if go.mode != LINKMODE_NORMAL:
        for opt_list in (copts, cxxopts, objcopts, objcxxopts):
            if "-fPIC" not in opt_list:
                opt_list.append("-fPIC")

    seen_includes = {}
    seen_quote_includes = {}
    seen_system_includes = {}
    have_hdrs = any([f.basename.endswith(ext) for f in srcs for ext in hdr_exts])
    if have_hdrs:
        # Add include paths for all sources so we can use include paths relative
        # to any source file or any header file. The go command requires all
        # sources to be in the same directory, but that's not necessarily the
        # case here.
        #
        # Use -I so either <> or "" includes may be used (same as go command).
        for f in srcs:
            _include_unique(cppopts, "-I", f.dirname, seen_includes)

    inputs_direct = []
    inputs_transitive = []
    deps_direct = []
    lib_opts = []
    runfiles = go._ctx.runfiles(collect_data = True)

    # Always include the sandbox as part of the build. Bazel does this, but it
    # doesn't appear in the CompilationContext.
    _include_unique(cppopts, "-iquote", ".", seen_quote_includes)
    previous_alwayslink = False
    for d in cdeps:
        runfiles = runfiles.merge(d.data_runfiles)
        if CcInfo in d:
            cc_transitive_headers = d[CcInfo].compilation_context.headers
            inputs_transitive.append(cc_transitive_headers)

            # Just retrieve libs and flags but don't do anything else at the moment
            cc_libs, cc_link_flags = _cc_libs_and_flags(d)

            cc_defines = d[CcInfo].compilation_context.defines.to_list()
            cppopts.extend(["-D" + define for define in cc_defines])
            cc_includes = d[CcInfo].compilation_context.includes.to_list()
            for inc in cc_includes:
                _include_unique(cppopts, "-I", inc, seen_includes)
            cc_quote_includes = d[CcInfo].compilation_context.quote_includes.to_list()
            for inc in cc_quote_includes:
                _include_unique(cppopts, "-iquote", inc, seen_quote_includes)
            cc_system_includes = d[CcInfo].compilation_context.system_includes.to_list()
            for inc in cc_system_includes:
                _include_unique(cppopts, "-isystem", inc, seen_system_includes)
            for lib in cc_libs:
                lib_file = _cc_lib_file(lib)
                if lib_file != None:
                    inputs_direct.append(lib_file)
                    deps_direct.append(lib_file)

                    # If both static and dynamic variants are available, Bazel will only give
                    # us the static variant. We'll get one file for each transitive dependency,
                    # so the same file may appear more than once.
                    if lib_file.basename.startswith("lib"):
                        if has_simple_shared_lib_extension(lib_file.basename):
                            # If the loader would be able to find the library using rpaths,
                            # use -L and -l instead of hard coding the path to the library in
                            # the binary. This gives users more flexibility. The linker will add
                            # rpaths later. We can't add them here because they are relative to
                            # the binary location, and we don't know where that is.
                            libname = lib_file.basename[len("lib"):lib_file.basename.rindex(".")]
                            clinkopts.extend(["-L", lib_file.dirname, "-l", libname])
                            inputs_direct.append(lib_file)
                            continue
                        extension = get_versioned_shared_lib_extension(lib_file.basename)
                        if extension.startswith("so"):
                            # With a versioned .so file, we must use the full filename,
                            # otherwise the library will not be found by the linker.
                            libname = ":%s" % lib_file.basename
                            clinkopts.extend(["-L", lib_file.dirname, "-l", libname])
                            inputs_direct.append(lib_file)
                            continue
                        elif extension.startswith("dylib"):
                            # A standard versioned dylib is named as libMagick.2.dylib, which is
                            # treated as a simple shared library. Non-standard versioned dylibs such as
                            # libclntsh.dylib.12.1, users have to create a unversioned symbolic link,
                            # so it can be treated as a simple shared library too.
                            continue
                        else:
                            lib_opts.extend(_whole_archive_args(go, lib.alwayslink, previous_alwayslink))
                            lib_opts.append(lib_file.path)
                            previous_alwayslink = lib.alwayslink
            clinkopts.extend(cc_link_flags)

        elif hasattr(d, "objc"):
            cppopts.extend(["-D" + define for define in d.objc.define.to_list()])
            for inc in d.objc.include.to_list():
                _include_unique(cppopts, "-I", inc, seen_includes)
            for inc in d.objc.iquote.to_list():
                _include_unique(cppopts, "-iquote", inc, seen_quote_includes)
            for inc in d.objc.include_system.to_list():
                _include_unique(cppopts, "-isystem", inc, seen_system_includes)

            # TODO(jayconrod): do we need to link against dynamic libraries or
            # frameworks? We link against *_fully_linked.a, so maybe not?

        else:
            fail("unknown library has neither cc nor objc providers: %s" % d.label)


    if previous_alwayslink:
        # if necessary, ad e.g. the final -no-whole-archive
        lib_opts.extend(_whole_archive_args(go, False, previous_alwayslink))

    inputs = depset(direct = inputs_direct, transitive = inputs_transitive)
    deps = depset(direct = deps_direct)

    # HACK: some C/C++ toolchains will ignore libraries (including dynamic libs
    # specified with -l flags) unless they appear after .o or .a files with
    # undefined symbols they provide. Put all the .a files from cdeps first,
    # so that we actually link with -lstdc++ and others.
    clinkopts = lib_opts + clinkopts

    print("Here are the opts: ", cppopts, copts, cxxopts, clinkopts)
    return struct(
        inputs = inputs,
        deps = deps,
        runfiles = runfiles,
        cppopts = dedupe_opts(cppopts),
        copts = dedupe_opts(copts),
        cxxopts = dedupe_opts(cxxopts),
        objcopts = objcopts,
        objcxxopts = objcxxopts,
        clinkopts = dedupe_opts(clinkopts),
    )

# return a list of libraries to link and the user modifiable flags.
def _cc_libs_and_flags(target):
    lib_files = []
    flags = []
    for li in target[CcInfo].linking_context.linker_inputs.to_list():
        flags.extend(li.user_link_flags)
        for library_to_link in li.libraries:
            lib_files.append(library_to_link)

    return lib_files, flags

# Returns the library File to link for the given LibraryToLink.
def _cc_lib_file(library_to_link):
    if library_to_link.static_library != None:
        return library_to_link.static_library
    elif library_to_link.pic_static_library != None:
        return library_to_link.pic_static_library
    elif library_to_link.interface_library != None:
        return library_to_link.interface_library
    elif library_to_link.dynamic_library != None:
        return library_to_link.dynamic_library
    return None

# Returns any arguments necessary for linking the next library.
#
# Some linkers have a pair of flags where the first flag indicates that *all*
# following libraries are to be linked in their entirety, and the second flag
# turns that behavior back off.
# By knowing if the next library is to be linked in its entirety, and whether
# the same was true of the last library, we can leverage this pair of flags
# and minimize the number of args needed during linking.
def _whole_archive_args(go, alwayslink, previous_alwayslink):
    if go.mode.goos == "darwin":
        if alwayslink:
            # -force_load only works for the immediately following library,
            # so it must be specified for *every* library that has alwayslink.
            # There is no analog to the pair of -whole-archive and
            # -no-whole-archive.
            return ["-Wl,-force_load"]
        else:
            return []
    elif alwayslink and not previous_alwayslink:
        return ["-Wl,-whole-archive"]
    elif previous_alwayslink and not alwayslink:
        return ["-Wl,-no-whole-archive"]
    else:
        return []

def _include_unique(opts, flag, include, seen):
    if include in seen:
        return
    seen[include] = True
    opts.extend([flag, include])

# dedupe_opts cleans up the linking arguments to pull out any duplications.
# This greatly reduces the arg payload size to clang and cgo.
def dedupe_opts(target):
    seen = {}
    for i, t in enumerate(target):
        seen[t] = i
    deduped_copts = list(sorted(seen.keys(), key = lambda x: seen[x]))
    return deduped_copts
