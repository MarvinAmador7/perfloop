import PackagePlugin

/// Writes `PerfLoopBuildStamp.swift` (commit, dirty, source hash, toolchain, build time) into the target before every
/// build, so the binary knows what it was built from wherever it is copied (C5: `perfloop store add` refuses a bench
/// without a stamp). The file declares `let perfLoopBuildStamp`, which the bench hands to `Bench(…, stamp:)`
/// (PerfLoopHost). Use it on the bench's executable target:
///
///     .executableTarget(name: "MyAppBench", dependencies: [...], plugins: [.plugin(name: "PerfLoopStamp", package: "perfloop")])
///
/// A prebuild command runs every build; the file is rewritten only when the stamp changes, so a no-op build stays a
/// no-op. `/bin/sh` and `git` are system tools, which is all a prebuild command may run. The configuration comes from
/// `#if DEBUG` in PerfLoopHost: plugins aren't told it.
@main struct PerfLoopStamp: BuildToolPlugin {
  func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
    let out = context.pluginWorkDirectory.appending("out")
    // The package and its local (path) dependencies: the sources that make the binary. The script keeps only the
    // ones inside the package's own git checkout.
    let dirs = [context.package.directory] + context.package.dependencies.map(\.package.directory)
    return [.prebuildCommand(displayName: "Stamping \(target.name) with its commit", executable: Path("/bin/sh"),
                             arguments: ["-c", script, "stamp", out.string, context.pluginWorkDirectory.string] + dirs.map(\.string),
                             outputFilesDirectory: out)]
  }
}

// $1 output dir (compiled), $2 work dir (scratch), then the source dirs. Git never takes optional locks (the build's
// sandbox only lets it write in the work dir) and nothing here fails the build: no git means `commit` empty, dirty.
let script = ##"""
set -u
out="$1"; work="$2"; shift 2
mkdir -p "$out" "$work"
export GIT_OPTIONAL_LOCKS=0
sha() { if command -v shasum >/dev/null 2>&1; then shasum -a 256; else sha256sum; fi | cut -d' ' -f1; }
commit=""; dirty=1; source=""
top=$(git -C "$1" rev-parse --show-toplevel 2>/dev/null) || top=""
if [ -n "$top" ]; then
  commit=$(git -C "$top" rev-parse --short HEAD 2>/dev/null) || commit=""
  : > "$work/status"; : > "$work/source"
  for d in "$@"; do
    [ "$(git -C "$d" rev-parse --show-toplevel 2>/dev/null)" = "$top" ] || continue
    prefix=$(git -C "$d" rev-parse --show-prefix)
    git -C "$d" status --porcelain --untracked-files=no -- . >> "$work/status" 2>/dev/null
    { echo "$prefix"; git -C "$d" rev-parse "HEAD:$prefix" 2>/dev/null; git -C "$d" diff --binary HEAD -- . 2>/dev/null; } >> "$work/source"
  done
  [ -s "$work/status" ] && dirty=1 || dirty=0
  [ -n "$commit" ] && source="sha256:$(sha < "$work/source")"
fi
toolchain=""
dev="${DEVELOPER_DIR:-$(xcode-select -p 2>/dev/null || true)}"
if [ -n "$dev" ] && [ -f "$dev/../version.plist" ]; then
  v=$(plutil -extract CFBundleShortVersionString raw -o - "$dev/../version.plist" 2>/dev/null || true)
  b=$(plutil -extract ProductBuildVersion raw -o - "$dev/../version.plist" 2>/dev/null || true)
  [ -n "$v" ] && toolchain="Xcode $v ($b)"
fi
key="commit=$commit
dirty=$dirty
sourceHash=$source
toolchain=$toolchain"
if [ -f "$out/PerfLoopBuildStamp.swift" ] && [ -f "$work/key" ] && [ "$(cat "$work/key")" = "$key" ]; then exit 0; fi
{
  echo '// Generated before every build by the PerfLoopStamp plugin. Not in git; do not edit.'
  echo 'let perfLoopBuildStamp = #"""'
  echo "$key"
  echo "builtAt=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo '"""#'
} > "$work/PerfLoopBuildStamp.swift"
mv "$work/PerfLoopBuildStamp.swift" "$out/PerfLoopBuildStamp.swift"
printf '%s' "$key" > "$work/key"
"""##
