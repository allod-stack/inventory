# inventory

Consumer-owned machine inventory for the Allod VM stack. One Nix attrset
(`flake.nix`) declares which machines exist — platform, type, hardware sizing,
networking, forge key, and per-machine repo list — and the VM-facing subset is
mirrored to plain JSON for host-side shell tooling. This is the "what exists"
half of the split: the framework repos (`vm`, `nexus`) describe how the system
works; this repo decides which machines and repos are real. It ships as a
template with synthetic example machines; a real deployment forks it and
replaces the data.

This repo owns:

- the machine set (`machines`) — one entry per VM/host with platform, type,
  sizing, networking, forge key, and repo list
- the derived supported-platform list and VM-facing JSON string
  (`lib.supportedPlatforms`, `lib.vmSpecsJson`)
- the committed, generated `scripts/vm-specs.json` (VM sizing/networking/repos
  consumed by host shell tools)
- the repo registry `scripts/repositories.json` — alias → source/remote/checkout
- the platform and registry validation checks

This repo does **not** own:

- per-VM NixOS configs, secrets, and identities (`profiles`, `secrets`)
- host config and the provisioning scripts that read this data (`nexus`)
- shared VM framework modules (`vm`)

## Exported outputs

| Output | Type | Description |
|---|---|---|
| `machines` | attrset | raw machine definitions, keyed by machine name |
| `lib.machines` | attrset | the same machine set, re-exported under `lib` |
| `lib.supportedPlatforms` | list of string | unique Nix systems across all machines (asserted valid) |
| `lib.vmSpecsJson` | JSON string | VM-facing specs (hypervisors excluded), serialized to JSON |
| `checks.<system>.vm-specs-json` | derivation | fails if `scripts/vm-specs.json` diverges from `lib.vmSpecsJson` |
| `checks.<system>.repository-registry` | derivation | validates `scripts/repositories.json` against every raw machine, including hypervisors, and proves its required-alias guards fail under sabotage |
| `checks.<system>.runtime-fact-mutations` | derivation | proves a missing, non-string, or unknown `runtime` fails evaluation, that hypervisors stay excluded, that both public runtime examples are present, and that JSON drift is detected |

The flake's only input is `nixpkgs` (nixos-25.11). `checks` is generated per
entry in `lib.supportedPlatforms` (currently `x86_64-linux` only).

## Layout

```
flake.nix                   machine set, assertions, derived outputs, checks
scripts/vm-specs.json       generated VM specs (host shell tooling reads this)
scripts/repositories.json   repo registry: alias -> source/remote/checkout
```

## Machine schema

Each entry in `machines` is an attrset:

| Field | Type | Notes |
|---|---|---|
| `platform` | string | Nix system, e.g. `x86_64-linux`; required — asserted present and valid |
| `type` | string | `dev`, `privacy`, or `hypervisor` |
| `runtime` | string | `libvirt` or `microvm`; required for non-hypervisor machines — asserted present, a string, and a known value; hypervisor machines carry no `runtime` |
| `memory_mb` | int | RAM |
| `vcpus` | int | vCPU count |
| `disk_gb` | int | root disk size |
| `ip` | string \| null | management IP (examples use the RFC 5737 `192.0.2.0/24` documentation range) |
| `mac` | string | NIC MAC (examples use the QEMU `52:54:00` locally-administered prefix) |
| `forge_key` | string \| null | forge SSH key name, or `null` |
| `self_rebuild` | bool | optional; treated as `true` when omitted |
| `repos` | list of string | repo-registry aliases to check out on the machine |
| `hardware` | NixOS module | hypervisor-only; imported by `profiles` for the host toplevel |

Example machines shipped in the template: `allod-dev` (`dev`,
`runtime = "libvirt"`), `privacy-1` (`privacy`, `runtime = "libvirt"`), and
`nexus` (`hypervisor`, no `runtime`). The microvm enum path is covered by a
mutation fixture rather than a machine that cannot build without matching
private identity and profile data. The `nexus` entry is present because
`profiles` always injects a `nexus` identity and asserts a matching machine;
its `hardware` attr is illustrative and meant to be replaced with a real
generated hardware config.

## Derived VM specs

`lib.vmSpecsJson` maps every non-hypervisor machine to only the fields host
tooling needs — `memory_mb`, `vcpus`, `disk_gb`, `ip`, `mac`, `forge_key`,
`repos`, `self_rebuild`, `runtime` — dropping `platform`, `type`, and
`hardware`. `scripts/vm-specs.json` is the committed, key-sorted copy.
Regenerate it after editing `machines`:

```
nix eval .#lib.vmSpecsJson --raw | jq -S . > scripts/vm-specs.json
```

The `vm-specs-json` check diffs the committed file against the freshly evaluated
JSON and fails on any drift.

## Repo registry

`scripts/repositories.json` is a `{ "repositories": { <alias>: { … } } }` map.
Each alias resolves to:

| Field | Meaning |
|---|---|
| `source` | `forge` or `git` |
| `remote` | path/URL on the source (rejected if it contains whitespace, `..`, or a leading/trailing `/`) |
| `checkout` | workspace-relative checkout path (same safety constraints) |

A machine's `repos` list references these aliases; host scripts (`nexus`)
resolve an alias to its `remote`/`checkout` when cloning a machine's workspace.
The `repository-registry` check derives its machine input directly from the raw
`machines` attrset rather than from the guest-only `vmSpecsJson`. It enforces:
valid JSON, at least one entry, required fields present, a known `source`, safe
`remote`/`checkout` values, no duplicate checkout paths within any machine,
every machine-referenced alias defined, and the `allod/profiles`,
`allod/secrets`, and `allod/inventory` aliases on both self-rebuild guests and
every hypervisor. Mutation witnesses remove each required Nexus alias, add an
unknown alias, and create a duplicate checkout path to prove those guards fail
with the intended diagnostic. The public Nexus fixture is pinned to exactly
`allod/nexus`, `allod/inventory`, `allod/secrets`, and `allod/profiles`; its
declared delta adds only `allod/profiles` to the preceding fixture.

## Platform assertions

Evaluating the flake fails fast if:

- a machine has no `platform` — `inventory machines missing platform: <names>`
- a `platform` is not in `lib.systems.flakeExposed` —
  `inventory machines with invalid Nix system: <names>`

`lib.supportedPlatforms` is the deduplicated list of the surviving platforms and
drives the per-system `checks` attribute set. `profiles` further asserts exactly
one supported platform when building its installer.

## Runtime assertions

Evaluating the flake fails fast for any non-hypervisor (`type != "hypervisor"`)
machine if:

- `runtime` is missing — `inventory machines missing runtime: <names>`
- `runtime` is not a string — `inventory machines with non-string runtime: <names>`
- `runtime` is not `libvirt` or `microvm` — `inventory machines with unknown
  runtime (expected one of: libvirt, microvm): <names>`

Hypervisor machines are exempt: they are not guests, so they carry no
`runtime` fact and never appear in `vmSpecsJson` regardless of one. The
`runtime-fact-mutations` check runs this exact validation chain (via
`mkVmSpecs`/`mkVmSpecsJson`, parameterized on an explicit machine set) against
sabotaged copies of `machines` and proves each failure mode actually fails,
that the hypervisor stays excluded, that both public runtime examples exist,
and that the `vm-specs-json` drift check is not vacuous.

## Consumers

- `profiles` pins this repo as a flake input and reads `machines`,
  `lib.supportedPlatforms`, and `${inventory}/scripts/vm-specs.json`.
- `nexus` host scripts read `scripts/repositories.json` and
  `scripts/vm-specs.json` (path via the `INVENTORY` / `INVENTORY_CHECKOUT`
  environment) to resolve repos and per-VM IP, forge key, and self-rebuild flag
  during provisioning.

## Related repos

- `profiles` — per-VM NixOS configs; consumes this repo as a flake input
- `vm` — shared VM framework modules (disk layout, system/home boilerplate)
- `nexus` — host config and provisioning scripts that read this repo's JSON
- `secrets` — identities and credentials keyed by the same machine names
- `deploy` — top-level deployment flake that pins repo revisions

## Cloning

    git clone https://forge.anarch.diy/allod/inventory.git
