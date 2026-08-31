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
| `lib.vmSpecsJson` | JSON string | VM-facing specs (hypervisor and service machines excluded), serialized to JSON |
| `checks.<system>.vm-specs-json` | derivation | fails if `scripts/vm-specs.json` diverges from `lib.vmSpecsJson` |
| `checks.<system>.repository-registry` | derivation | validates `scripts/repositories.json` against every raw machine, including hypervisors, and proves its required-alias guards fail under sabotage |
| `checks.<system>.runtime-fact-mutations` | derivation | proves a missing, non-string, or unknown `runtime` fails evaluation, that neither runtime-free type can declare one, that hypervisors stay excluded, that both public runtime examples are present, and that JSON drift is detected |
| `checks.<system>.service-machine-mutations` | derivation | proves a well-formed service machine is accepted and stays out of `vmSpecsJson`, and that a foreign platform and each guest sizing field are refused |

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
| `platform` | string | Nix system, e.g. `x86_64-linux`; required — asserted present and valid. Service machines must declare `x86_64-linux` |
| `type` | string | `dev`, `privacy`, `hypervisor`, or `service` |
| `runtime` | string | `libvirt` or `microvm`; required for guest machines — asserted present, a string, and a known value. Hypervisor and service machines carry no `runtime`, and declaring one is an error |
| `memory_mb` | int | RAM; guests only — refused on a service machine |
| `vcpus` | int | vCPU count; guests only — refused on a service machine |
| `disk_gb` | int | root disk size; guests only — refused on a service machine |
| `ip` | string \| null | management IP (examples use the RFC 5737 `192.0.2.0/24` documentation range) |
| `mac` | string | NIC MAC (examples use the QEMU `52:54:00` locally-administered prefix); guests only — refused on a service machine |
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

No `service` machine ships in the template. The first one is added when its host
is rented, so that the entry describes something real; until then every service
rule is exercised by the `service-machine-mutations` fixtures.

## Service machines

A `service` machine is a rented, internet-facing host — one this fleet did not
create and does not run. Three schema rules follow from that, and each is an
evaluation error rather than a silently ignored field:

- **No `runtime`.** `runtime` names the virtualisation system running a machine
  as a guest, and the framework uses it to select that guest's configuration. A
  rented host has no honest answer: some provider's hypervisor runs it, nothing
  here can see or configure that, and there is no guest module to select. This
  widens the existing hypervisor rule rather than inventing a category — the
  rejected alternative, `runtime = "rented"`, would put a fictional
  virtualisation system in a field that otherwise names real ones.
- **`platform` must be `x86_64-linux`.** `platform` is the chip-and-OS pair the
  build targets and says nothing about who hosts the machine, so any system Nix
  knows would otherwise pass — and the first ARM machine would fail somewhere
  confusing during provisioning, because nothing here has ever built for another
  chip. The door opens deliberately once a cross-architecture build path exists.
- **No `memory_mb`, `vcpus`, `disk_gb`, or `mac`.** For a guest these are
  instructions the hypervisor acts on; on a rented machine they would describe
  what is being paid for, and nothing in the file distinguishes the two. Refusing
  them stops someone editing the memory size of a rented host and waiting for
  something to happen.

Service machines are excluded from `lib.vmSpecsJson` for the same reason
hypervisors are: that file tells host tooling how to size and start guests, and
a rented host is neither sized nor started here.

This assumes a service is a rented host. A service running as a local guest is
imaginable and deliberately out of scope; when one appears, the decision is
whether `service` splits by where it runs.

## Derived VM specs

`lib.vmSpecsJson` maps every guest machine to only the fields host
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

## Shape assertions

`type` and `platform` are what every other rule classifies on, so they are
checked first. Evaluating the flake fails fast if:

- a machine has no `type` — `inventory machines missing type: <names>`
- a `type` is not a string — `inventory machines with non-string type: <names>`
- a machine has no `platform` — `inventory machines missing platform: <names>`
- a `platform` is not in `lib.systems.flakeExposed` —
  `inventory machines with invalid Nix system: <names>`

These run inside the `mkVmSpecs` chain that `checkedMachines` forces, so a
consumer reading `machines`/`lib.machines` triggers them. That matters because
`archetypes` reads exactly that surface: platform validation used to hang off
`lib.supportedPlatforms` alone, so a machine with no `platform` reached those
consumers unvalidated and only failed later, somewhere less obvious.

Inventory checks that `type` is present and a string; it does not check the
value against a set of known archetypes. That set belongs to `archetypes`, which
owns the builders and rejects a machine whose type has no builder.

`lib.supportedPlatforms` is the deduplicated list of the surviving platforms and
drives the per-system `checks` attribute set. `profiles` further asserts exactly
one supported platform when building its installer.

## Runtime assertions

Evaluating the flake fails fast for any guest machine — one whose `type` is
neither `hypervisor` nor `service` — if:

- `runtime` is missing — `inventory machines missing runtime: <names>`
- `runtime` is not a string — `inventory machines with non-string runtime: <names>`
- `runtime` is not `libvirt` or `microvm` — `inventory machines with unknown
  runtime (expected one of: libvirt, microvm): <names>`

and for any machine of a runtime-free type that declares one anyway —
`inventory hypervisor and service machines must not declare runtime: <names>`.

Hypervisor and service machines are exempt from the first three because they are
not guests of this fleet, so they carry no `runtime` fact and never appear in
`vmSpecsJson`. The `runtime-fact-mutations` check runs this exact validation
chain (via `mkVmSpecs`/`mkVmSpecsJson`, parameterized on an explicit machine set)
against sabotaged copies of `machines` and proves each failure mode actually
fails, that neither runtime-free type can silently acquire a runtime, that the
hypervisor stays excluded, that both public runtime examples exist, and that the
`vm-specs-json` drift check is not vacuous.

## Service assertions

Evaluating the flake fails fast for any `service` machine if:

- `platform` is present and is not `x86_64-linux` — `inventory service machines
  must declare platform x86_64-linux (…): <names>`. A service machine with no
  `platform` at all trips `missingPlatform` instead, which names the actual
  problem; the `runtime-fact-mutations` check pins that case so the guard cannot
  quietly become a hole.
- any of `memory_mb`, `vcpus`, `disk_gb`, `mac` is present — `inventory service
  machines must not declare guest sizing fields (…): <names>`

Both run in the same `mkVmSpecs` chain every consumer already forces, so reading
the raw `machines` surface triggers them too. The `service-machine-mutations`
check proves a well-formed service machine is accepted, that it stays out of
`vmSpecsJson`, and that each rule refuses its own sabotaged fixture with the
diagnostic it names. Its forbidden-field list is written out independently of the
production one and compared against it, so deleting a field from the rule cannot
also delete that field's witness.

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
