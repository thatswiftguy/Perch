#!/usr/bin/env python3
"""Generate Perch.xcodeproj. Kept as a script so the project can be regenerated from
scratch if it is ever corrupted by a bad merge; Xcode remains the source of truth once
generated."""
import hashlib, os, pathlib, sys

ROOT = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".")
PROJ = ROOT / "Perch.xcodeproj"

def uid(key):
    return hashlib.md5(key.encode()).hexdigest()[:24].upper()

def q(s):
    """Quote pbxproj values that aren't bare identifiers."""
    if s == "":
        return '""'
    ok = set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_./$")
    return s if all(c in ok for c in s) else '"%s"' % s.replace('\\', '\\\\').replace('"', '\\"')

objects = []
def obj(u, comment, body):
    objects.append((u, comment, body))

def swift_files(d):
    return sorted(str(p.relative_to(ROOT)) for p in (ROOT / d).rglob("*.swift"))

TARGETS = {
    "PerchCore":      dict(dir="PerchCore", type="com.apple.product-type.library.static",
                           product="libPerchCore.a", ftype="archive.ar"),
    "perch-hook":     dict(dir="perch-hook", type="com.apple.product-type.tool",
                           product="perch-hook", ftype="compiled.mach-o.executable"),
    "Perch":          dict(dir="Perch", type="com.apple.product-type.application",
                           product="Perch.app", ftype="wrapper.application"),
    "PerchCoreTests": dict(dir="PerchCoreTests", type="com.apple.product-type.bundle.unit-test",
                           product="PerchCoreTests.xctest", ftype="wrapper.cfbundle"),
}
ORDER = ["PerchCore", "perch-hook", "Perch", "PerchCoreTests"]

# ---------------------------------------------------------------- file references
filerefs = {}   # path -> uuid
def fileref(path, ftype=None, tree='"<group>"', name=None):
    if path in filerefs:
        return filerefs[path]
    u = uid("fileref:" + path)
    filerefs[path] = u
    ext = os.path.splitext(path)[1]
    t = ftype or {
        ".swift": "sourcecode.swift", ".plist": "text.plist.xml",
        ".entitlements": "text.plist.entitlements", ".xcassets": "folder.assetcatalog",
    }.get(ext, "text")
    obj(u, os.path.basename(path),
        "{isa = PBXFileReference; lastKnownFileType = %s; path = %s; sourceTree = %s; };"
        % (t, q(os.path.basename(path)), tree))
    return u

products = {}
for name in ORDER:
    spec = TARGETS[name]
    u = uid("product:" + name)
    products[name] = u
    obj(u, spec["product"],
        "{isa = PBXFileReference; explicitFileType = %s; includeInIndex = 0; path = %s; "
        "sourceTree = BUILT_PRODUCTS_DIR; };" % (spec["ftype"], q(spec["product"])))

# ---------------------------------------------------------------- groups
def group(u, comment, children, path=None, name=None):
    parts = ["{isa = PBXGroup; children = ("]
    for cu, cc in children:
        parts.append("\t\t\t\t%s /* %s */," % (cu, cc))
    parts.append("\t\t\t);")
    if name:
        parts.append(" name = %s;" % q(name))
    if path:
        parts.append(" path = %s;" % q(path))
    parts.append(' sourceTree = "<group>"; };')
    obj(u, comment, "\n".join(parts[:-1]) + parts[-1])

target_sources = {}
group_children_root = []

for name in ORDER:
    spec = TARGETS[name]
    files = swift_files(spec["dir"])
    target_sources[name] = files

    # Nested folders (Views/, Notch/) become real groups so Xcode's navigator matches disk.
    by_sub = {}
    for f in files:
        rel = os.path.relpath(f, spec["dir"])
        sub = os.path.dirname(rel)
        by_sub.setdefault(sub, []).append(f)

    children = []
    for f in sorted(by_sub.get("", [])):
        children.append((fileref(f), os.path.basename(f)))
    for sub in sorted(k for k in by_sub if k):
        subu = uid("group:%s/%s" % (name, sub))
        subchildren = [(fileref(f), os.path.basename(f)) for f in sorted(by_sub[sub])]
        group(subu, sub, subchildren, path=sub)
        children.append((subu, sub))

    if name == "Perch":
        for extra in ["Perch/Assets.xcassets", "Perch/Info.plist", "Perch/Perch.entitlements"]:
            children.append((fileref(extra), os.path.basename(extra)))

    gu = uid("group:" + name)
    group(gu, name, children, path=spec["dir"])
    group_children_root.append((gu, name))

xcconfig = fileref("Config/Shared.xcconfig", ftype="text.xcconfig")
cfg_group = uid("group:Config")
group(cfg_group, "Config", [(xcconfig, "Shared.xcconfig")], path="Config")
group_children_root.append((cfg_group, "Config"))

prod_group = uid("group:Products")
group(prod_group, "Products", [(products[n], TARGETS[n]["product"]) for n in ORDER], name="Products")
group_children_root.append((prod_group, "Products"))

for extra in ["README.md", "LICENSE"]:
    if (ROOT / extra).exists():
        group_children_root.insert(0, (fileref(extra), extra))

root_group = uid("group:root")
group(root_group, None, group_children_root)

# ---------------------------------------------------------------- build phases
def buildfile(key, ref, comment, settings=None):
    u = uid("buildfile:" + key)
    s = " settings = {%s}; " % settings if settings else " "
    obj(u, comment, "{isa = PBXBuildFile; fileRef = %s;%s};" % (ref, s))
    return u

def phase(u, isa, comment, files, extra=""):
    lines = ["{isa = %s;" % isa, "\t\t\tbuildActionMask = 2147483647;", "\t\t\tfiles = ("]
    for fu, fc in files:
        lines.append("\t\t\t\t%s /* %s */," % (fu, fc))
    lines.append("\t\t\t);")
    if extra:
        lines.append(extra)
    lines.append("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    lines.append("\t\t};")
    obj(u, comment, "\n\t\t\t".join(lines[:1]) + "\n\t\t\t" + "\n\t\t\t".join(l.strip() for l in lines[1:]))

target_phases = {}
for name in ORDER:
    src = uid("phase:sources:" + name)
    files = [(buildfile("%s:%s" % (name, f), filerefs[f], os.path.basename(f)),
              os.path.basename(f) + " in Sources") for f in target_sources[name]]
    phase(src, "PBXSourcesBuildPhase", "Sources", files)

    fw = uid("phase:frameworks:" + name)
    fwfiles = []
    if name in ("Perch", "perch-hook", "PerchCoreTests"):
        fwfiles.append((buildfile("link:%s:PerchCore" % name, products["PerchCore"],
                                  "libPerchCore.a in Frameworks"), "libPerchCore.a in Frameworks"))
    phase(fw, "PBXFrameworksBuildPhase", "Frameworks", fwfiles)

    phases = [(src, "Sources"), (fw, "Frameworks")]

    if name == "Perch":
        res = uid("phase:resources:Perch")
        resfiles = [(buildfile("res:Assets", filerefs["Perch/Assets.xcassets"],
                               "Assets.xcassets in Resources"), "Assets.xcassets in Resources")]
        phase(res, "PBXResourcesBuildPhase", "Resources", resfiles)
        phases.append((res, "Resources"))

        # dstSubfolderSpec 6 = Contents/MacOS, where a helper executable belongs.
        cp = uid("phase:copy:hook")
        cpfile = buildfile("embed:perch-hook", products["perch-hook"], "perch-hook in Embed",
                           settings="ATTRIBUTES = (CodeSignOnCopy, ); ")
        phase(cp, "PBXCopyFilesBuildPhase", "Embed perch-hook",
              [(cpfile, "perch-hook in Embed perch-hook")],
              extra='dstPath = "";\n\t\t\tdstSubfolderSpec = 6;\n\t\t\tname = "Embed perch-hook";')
        phases.append((cp, "Embed perch-hook"))

    target_phases[name] = phases

# ---------------------------------------------------------------- dependencies
DEPS = {"Perch": ["PerchCore", "perch-hook"], "perch-hook": ["PerchCore"],
        "PerchCoreTests": ["PerchCore"]}
project_uid = uid("project")
target_uids = {n: uid("target:" + n) for n in ORDER}
target_deps = {}
for name, deps in DEPS.items():
    lst = []
    for d in deps:
        proxy = uid("proxy:%s->%s" % (name, d))
        obj(proxy, "PBXContainerItemProxy",
            "{isa = PBXContainerItemProxy; containerPortal = %s /* Project object */; "
            "proxyType = 1; remoteGlobalIDString = %s; remoteInfo = %s; };"
            % (project_uid, target_uids[d], q(d)))
        du = uid("dep:%s->%s" % (name, d))
        obj(du, "PBXTargetDependency",
            "{isa = PBXTargetDependency; target = %s /* %s */; targetProxy = %s; };"
            % (target_uids[d], d, proxy))
        lst.append((du, "PBXTargetDependency"))
    target_deps[name] = lst

# ---------------------------------------------------------------- build settings
BASE = {
    "ALWAYS_SEARCH_USER_PATHS": "NO",
    "CLANG_ENABLE_OBJC_ARC": "YES",
    "ENABLE_STRICT_OBJC_MSGSEND": "YES",
    "GCC_NO_COMMON_BLOCKS": "YES",
    "MACOSX_DEPLOYMENT_TARGET": "14.0",
    "SDKROOT": "macosx",
    "SWIFT_VERSION": "6.0",
    "COPY_PHASE_STRIP": "NO",
}
DEBUG = dict(BASE, **{
    "DEBUG_INFORMATION_FORMAT": "dwarf",
    "ENABLE_TESTABILITY": "YES",
    "GCC_OPTIMIZATION_LEVEL": "0",
    "ONLY_ACTIVE_ARCH": "YES",
    "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG",
    "SWIFT_OPTIMIZATION_LEVEL": "-Onone",
})
RELEASE = dict(BASE, **{
    "DEBUG_INFORMATION_FORMAT": '"dwarf-with-dsym"',
    "ENABLE_NS_ASSERTIONS": "NO",
    "SWIFT_COMPILATION_MODE": "wholemodule",
    "SWIFT_OPTIMIZATION_LEVEL": "-O",
})

# Signing is indirected through Config/Shared.xcconfig: ad-hoc by default so a fresh
# clone builds with no Apple account, overridable per developer via the git-ignored
# Config/Local.xcconfig. See also Scripts/release.sh for Developer ID builds.
SIGN = {
    "CODE_SIGN_STYLE": '"$(PERCH_CODE_SIGN_STYLE)"',
    "CODE_SIGN_IDENTITY": '"$(PERCH_CODE_SIGN_IDENTITY)"',
    "DEVELOPMENT_TEAM": '"$(PERCH_DEVELOPMENT_TEAM)"',
    "ENABLE_HARDENED_RUNTIME": "YES",
}
TARGET_SETTINGS = {
    "PerchCore": {"PRODUCT_NAME": "PerchCore", "SKIP_INSTALL": "YES",
                  "SWIFT_INSTALL_OBJC_HEADER": "NO"},
    "perch-hook": dict(SIGN, **{"PRODUCT_NAME": '"perch-hook"', "SKIP_INSTALL": "YES"}),
    "Perch": dict(SIGN, **{
        "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
        "CODE_SIGN_ENTITLEMENTS": "Perch/Perch.entitlements",
        "COMBINE_HIDPI_IMAGES": "YES",
        "CURRENT_PROJECT_VERSION": "1",
        "MARKETING_VERSION": "1.0.0",
        "INFOPLIST_FILE": "Perch/Info.plist",
        "PRODUCT_BUNDLE_IDENTIFIER": "com.yasir.perch",
        "PRODUCT_NAME": '"$(TARGET_NAME)"',
    }),
    "PerchCoreTests": dict(SIGN, **{
        "GENERATE_INFOPLIST_FILE": "YES",
        "PRODUCT_BUNDLE_IDENTIFIER": "com.yasir.perch.tests",
        "PRODUCT_NAME": '"$(TARGET_NAME)"',
    }),
}

def config(u, name, settings, base=None):
    lines = ["{isa = XCBuildConfiguration;"]
    if base:
        lines.append("baseConfigurationReference = %s /* Shared.xcconfig */;" % base)
    lines.append("buildSettings = {")
    for k in sorted(settings):
        lines.append("\t%s = %s;" % (k, settings[k]))
    lines.append("};")
    lines.append("name = %s;" % name)
    lines.append("};")
    obj(u, name, "\n\t\t\t".join(lines))

def configlist(u, comment, debug_u, release_u):
    obj(u, comment,
        "{isa = XCConfigurationList; buildConfigurations = (\n"
        "\t\t\t\t%s /* Debug */,\n\t\t\t\t%s /* Release */,\n"
        "\t\t\t); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; };"
        % (debug_u, release_u))

proj_debug, proj_release = uid("cfg:project:Debug"), uid("cfg:project:Release")
config(proj_debug, "Debug", DEBUG, base=xcconfig)
config(proj_release, "Release", RELEASE, base=xcconfig)
proj_cfglist = uid("cfglist:project")
configlist(proj_cfglist, "Build configuration list for PBXProject", proj_debug, proj_release)

target_cfglists = {}
for name in ORDER:
    d, r = uid("cfg:%s:Debug" % name), uid("cfg:%s:Release" % name)
    config(d, "Debug", TARGET_SETTINGS[name])
    config(r, "Release", TARGET_SETTINGS[name])
    cl = uid("cfglist:" + name)
    configlist(cl, "Build configuration list for %s" % name, d, r)
    target_cfglists[name] = cl

# ---------------------------------------------------------------- targets
for name in ORDER:
    spec = TARGETS[name]
    lines = ["{isa = PBXNativeTarget;",
             "buildConfigurationList = %s;" % target_cfglists[name], "buildPhases = ("]
    for pu, pc in target_phases[name]:
        lines.append("\t%s /* %s */," % (pu, pc))
    lines.append(");")
    lines.append("buildRules = ();")
    lines.append("dependencies = (")
    for du, dc in target_deps.get(name, []):
        lines.append("\t%s /* %s */," % (du, dc))
    lines.append(");")
    lines.append("name = %s;" % q(name))
    lines.append("productName = %s;" % q(name))
    lines.append("productReference = %s /* %s */;" % (products[name], spec["product"]))
    lines.append("productType = %s;" % q(spec["type"]))
    lines.append("};")
    obj(target_uids[name], name, "\n\t\t\t".join(lines))

# ---------------------------------------------------------------- project
attrs = "\n\t\t\t\t\t".join(
    "%s = {CreatedOnToolsVersion = 26.6;};" % target_uids[n] for n in ORDER)
obj(project_uid, "Project object",
    "{isa = PBXProject;\n"
    "\t\t\tattributes = {\n"
    "\t\t\t\tBuildIndependentTargetsInParallel = 1;\n"
    "\t\t\t\tLastSwiftUpdateCheck = 2660;\n"
    "\t\t\t\tLastUpgradeCheck = 2660;\n"
    "\t\t\t\tTargetAttributes = {\n\t\t\t\t\t%s\n\t\t\t\t};\n"
    "\t\t\t};\n"
    "\t\t\tbuildConfigurationList = %s;\n"
    "\t\t\tcompatibilityVersion = \"Xcode 14.0\";\n"
    "\t\t\tdevelopmentRegion = en;\n"
    "\t\t\thasScannedForEncodings = 0;\n"
    "\t\t\tknownRegions = (en, Base,);\n"
    "\t\t\tmainGroup = %s;\n"
    "\t\t\tproductRefGroup = %s /* Products */;\n"
    "\t\t\tprojectDirPath = \"\";\n"
    "\t\t\tprojectRoot = \"\";\n"
    "\t\t\ttargets = (\n%s\n\t\t\t);\n"
    "\t\t};" % (attrs, proj_cfglist, root_group, prod_group,
                "\n".join("\t\t\t\t%s /* %s */," % (target_uids[n], n) for n in ORDER)))

# ---------------------------------------------------------------- emit
PROJ.mkdir(parents=True, exist_ok=True)
out = ["// !$*UTF8*$!", "{", "\tarchiveVersion = 1;", "\tclasses = {", "\t};",
       "\tobjectVersion = 56;", "\tobjects = {", ""]
for u, comment, body in sorted(objects, key=lambda o: o[0]):
    tag = " /* %s */" % comment if comment else ""
    out.append("\t\t%s%s = %s" % (u, tag, body))
out += ["\t};", "\trootObject = %s /* Project object */;" % project_uid, "}", ""]
(PROJ / "project.pbxproj").write_text("\n".join(out))
print("wrote", PROJ / "project.pbxproj", "-", len(objects), "objects")

# ---------------------------------------------------------------- shared scheme
# Shared (not xcuserdata) so `xcodebuild -scheme Perch test` works on a fresh clone and
# in CI. Xcode's auto-generated schemes are per-user and never committed.
def buildable(name):
    return ('<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="%s" '
            'BuildableName="%s" BlueprintName="%s" '
            'ReferencedContainer="container:Perch.xcodeproj"></BuildableReference>'
            % (target_uids[name], TARGETS[name]["product"], name))

scheme = '''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2660" version="1.7">
   <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES">
      <BuildActionEntries>
         <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">
            %s
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.DebuggerFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES">
      <Testables>
         <TestableReference skipped="NO">
            %s
         </TestableReference>
      </Testables>
   </TestAction>
   <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES">
      <BuildableProductRunnable runnableDebuggingMode="0">
         %s
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES">
      <BuildableProductRunnable runnableDebuggingMode="0">
         %s
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction buildConfiguration="Debug"></AnalyzeAction>
   <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"></ArchiveAction>
</Scheme>
''' % (buildable("Perch"), buildable("PerchCoreTests"), buildable("Perch"), buildable("Perch"))

schemes = PROJ / "xcshareddata" / "xcschemes"
schemes.mkdir(parents=True, exist_ok=True)
(schemes / "Perch.xcscheme").write_text(scheme)
print("wrote", schemes / "Perch.xcscheme")
