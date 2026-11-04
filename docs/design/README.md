# Design history

PerfLoop started inside [capcomd](https://github.com/MarvinAmador7/capcomd) as `tools/perfloop`, built to make capcomd
Desktop's window fast, and moved to this repository on 4 November 2026 with its history. These are its design documents
from that time, unchanged, so paths in them (`tools/perfloop`, `apps/menubar/app`, `deskbench`) are capcomd's:

- [SPEC.md](SPEC.md): the design, the capabilities and the migration phases.
- [CAPABILITIES.md](CAPABILITIES.md): C1–C10, what each gives an agent.
- [SCHEMAS.md](SCHEMAS.md): the JSON schemas.
- [FEASIBILITY.md](FEASIBILITY.md): the probes that proved each sense was possible.
- [JOURNEY.md](JOURNEY.md): how it was built, what it found, and what not to claim yet.
- [TOOL.md](TOOL.md): the gaps between "works on capcomd Desktop" and "works on your app", and their status.
- [replay.json](replay.json): the by-hand session of 30 October 2026 as a replay plan (SPEC §6.1).
