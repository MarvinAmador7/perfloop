// PerfLoopProbe: what the app itself links (SPEC §3.1). Its parts land with Phase 2's adapter work: Knobs.swift
// (runtime knobs, C4), then the probe seam, the stretch sampler and the build-stamp reader as they move out of
// apps/menubar/app. Until then this module only names its protocol version, so the product exists and links.
public enum PerfLoopProbeInfo {
  /// The bench protocol this probe speaks (perfloop.manifest/1 `protocol`).
  public static let protocolVersion = 1
}
