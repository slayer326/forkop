# Upstream Forkop X 2.3.4–2.4.1 audit (2026-10-23)

Source: https://github.com/Screamshow/forkop-x/releases. Compare with the
upstream source tags rather than merging repositories: this fork has its own
mirror, installer, package rollback, sing-box lifecycle, and tests.

| Upstream release | Decision for this sing-box-based fork |
| --- | --- |
| 2.3.4 | Component explanations were tried as hover tooltips but removed at the user's request. The non-blocking capability load, mobile layout, Priority latency check, and file-descriptor limit were already ported in 1.0.52–1.0.53. Native Tailscale needs Xrust and is excluded. |
| 2.3.5 | The WhatsApp real-IP option requires a Meta subnet list, DNS reverse mapping, a startup validator, and a LuCI guard when editing or deleting rules. Do not copy only the checkbox: incomplete integration can leave Forkop unable to start after reboot. Its default-off per-connection QUIC block is unnecessary for users who keep QUIC enabled. Cross-core FakeIP cache preservation is not applicable until another core is supported. |
| 2.3.6 | The HTTPS DNS response fix is already in 1.0.53. Subscription certificate pinning depends on the newer core; do not advertise it for sing-box. |
| 2.3.7 | Subscription hot-reload and its rollback protocol require Xrust. The no-change subscription fast path and selector preservation already exist in this fork; keep the sing-box restart path. |
| 2.3.8 | Rename-safe URLTest/Priority filtering was ported in 1.0.54. |
| 2.3.9 | Pruning unused subscription outbounds and avoiding ICMP interception were ported in 1.0.54. The remaining removal of common nftables classifiers assumes upstream's different chain layout; it is not a safe standalone patch here. The Tailscale process fix does not apply. |
| 2.4.0–2.4.1 | Exit Node, Direct/DERP selection, LAN/IPv6 fixes, executable transport scripts, and `flock` dependency belong to native Tailscale/Xrust. No native Tailscale package or service is shipped in this fork, so copying them would add a second networking stack without a rollback contract. |

The Components tooltip was removed because it cluttered the interface. WhatsApp real-IP and
native Tailscale should be separate opt-in projects with their own integration
tests and router-specific validation, not folded into this stable sync.
