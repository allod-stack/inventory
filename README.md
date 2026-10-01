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
| `checks.<system>.runtime-fact-mutations` | derivation | proves a missing, non-string, or unknown `runtime` fails evaluation, that a hypervisor cannot declare one, that hypervisors stay excluded, that both public runtime examples are present, and that JSON drift is detected |
| `checks.<system>.data-disk-fact-mutations` | derivation | proves a malformed optional `data_disk` fails evaluation, that a hypervisor cannot declare one, and that a valid `data_disk` survives into the generated spec |
| `checks.<system>.host-fact-mutations` | derivation | proves a malformed optional `host` fails evaluation, that a hypervisor cannot declare one, that a guest is required to declare one once a second hypervisor exists, and that a valid `host` survives into the generated spec |
| `checks.<system>.host-provided-repos-mutations` | derivation | proves a malformed optional `host_provided_repos` fails evaluation, that a hypervisor cannot declare one, and that a valid `host_provided_repos` survives into the generated spec |

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
| `runtime` | string | `libvirt`, the one guest runtime; required for non-hypervisor machines — asserted present, a string, and a known value; hypervisor machines carry no `runtime`, and declaring one is an error |
| `memory_mb` | int | RAM |
| `vcpus` | int | vCPU count |
| `disk_gb` | int | root disk size |
| `ip` | string \| null | management IP (examples use the RFC 5737 `192.0.2.0/24` documentation range) |
| `mac` | string | NIC MAC (examples use the QEMU `52:54:00` locally-administered prefix) |
| `forge_key` | string \| null | forge SSH key name, or `null` |
| `self_rebuild` | bool | optional; treated as `true` when omitted |
| `repos` | list of string | repo-registry aliases to check out on the machine |
| `data_disk` | attrset | optional; a second disk that outlives reprovisioning. `{ path, size_gb }`: `path` absolute, no whitespace, `..`, comma, or trailing slash; `size_gb` optional, a positive integer, used only to create an image file that does not exist yet. Forbidden on a hypervisor |
| `host` | string | optional; the name of the hypervisor machine that runs this guest. Must name a known machine of type `hypervisor`. Forbidden on a hypervisor. Required on every guest once more than one hypervisor is declared |
| `host_provided_repos` | list of string | optional; `repos` aliases whose checkout the hypervisor supplies instead of the guest cloning them. Every member must also appear in `repos`. Forbidden on a hypervisor |
| `hardware` | NixOS module | hypervisor-only; imported by `profiles` for the host toplevel |

Example machines shipped in the template: `allod-dev` (`dev`,
`runtime = "libvirt"`), `privacy-1` (`privacy`, `runtime = "libvirt"`), and
`nexus` (`hypervisor`, no `runtime`). The `nexus` entry is present because
`profiles` always injects a `nexus` identity and asserts a matching machine;
its `hardware` attr is illustrative and meant to be replaced with a real
generated hardware config.

## Derived VM specs

`lib.vmSpecsJson` maps every guest machine to only the fields host
tooling needs — `memory_mb`, `vcpus`, `disk_gb`, `ip`, `mac`, `forge_key`,
`repos`, `self_rebuild`, `runtime`, `data_disk` when declared, and `host` when
declared — dropping `platform`, `type`, and `hardware`. `scripts/vm-specs.json`
is the committed, key-sorted copy.
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
| `preview_port` | optional; its presence means the repository is a site `allod site serve` can serve. An integer from 1024 to 65535, unique across the registry |
| `memory` | optional; `true` means the repository is a memory repository every dev VM clones and reads at session start. The VM framework's home-manager generator derives the harness memory bootstrap from the entries carrying this flag |

A machine's `repos` list references these aliases; host scripts (`nexus`)
resolve an alias to its `remote`/`checkout` when cloning a machine's workspace.
The `repository-registry` check derives its machine input directly from the raw
`machines` attrset rather than from the guest-only `vmSpecsJson`. It enforces:
valid JSON, at least one entry, required fields present, a known `source`, safe
`remote`/`checkout` values, no duplicate checkout paths within any machine,
every machine-referenced alias defined, a `preview_port` that is an integer from
1024 to 65535 and unique across the registry wherever the field is present, a
`memory` flag that is boolean wherever the field is present, and
the `allod/profiles`, `allod/secrets`, and `allod/inventory` aliases on both
self-rebuild guests and every hypervisor. Mutation witnesses remove each
required Nexus alias, add an unknown alias, create a duplicate checkout path,
give a fixture site an out-of-range `preview_port`, and give two fixture sites
the same one, to prove those guards fail with the intended diagnostic; a third
fixture site with a valid `preview_port` runs the accepting path, which the real
registry does not. The public Nexus fixture is pinned to exactly
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

These run first, before the runtime rules, so a machine that is wrong
about `type` or `platform` is told that rather than being reported as the wrong
kind of problem. The order is produced by an explicit `builtins.seq` chain at the
end of `mkVmSpecs` rather than by the order the bindings are written in — a
let-binding's assertions fire when the binding is *forced*, which is not the same
thing, and getting that wrong once made the shape rules evaluate last.

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
not `hypervisor` — if:

- `runtime` is missing — `inventory machines missing runtime: <names>`
- `runtime` is not a string — `inventory machines with non-string runtime: <names>`
- `runtime` is not `libvirt` — `inventory machines with unknown
  runtime (expected one of: libvirt): <names>`

and for a hypervisor that declares one anyway —
`inventory hypervisor machines must not declare runtime: <names>`.

Hypervisor machines are exempt from the first three because they are
not guests of this fleet, so they carry no `runtime` fact and never appear in
`vmSpecsJson`. The `runtime-fact-mutations` check runs this exact validation
chain (via `mkVmSpecs`/`mkVmSpecsJson`, parameterized on an explicit machine set)
against sabotaged copies of `machines` and proves each failure mode actually
fails, that a hypervisor cannot silently acquire a runtime, that the
hypervisor stays excluded, that both public runtime examples exist, and that the
`vm-specs-json` drift check is not vacuous.

## Data disk assertions

`data_disk` is optional; a machine that omits it is unaffected. When present,
evaluating the flake fails fast if:

- `data_disk` is not an attribute set — `inventory machines with non-attrset
  data_disk: <names>`
- `path` is missing, not a string, not absolute, or contains whitespace, `..`,
  a comma, or a trailing slash — `inventory machines with invalid data_disk
  path (must be absolute, without whitespace, .., a comma, or a trailing
  slash): <names>`
- `size_gb` is present and is not a positive integer — `inventory machines
  with invalid data_disk size_gb (must be a positive integer): <names>`
- `data_disk` has a key other than `path` or `size_gb` — `inventory machines
  with unknown data_disk keys (only path and size_gb allowed): <names>`
- a hypervisor machine declares one at all — `inventory hypervisor machines
  must not declare data_disk: <names>`

`scripts/vm-specs.json` carries `data_disk` only for a machine that declares
it, so a machine with none produces the same generated spec as before this
field existed. The `data-disk-fact-mutations` check runs this validation
against sabotaged copies of `machines`, one fixture per rule, and against one
fixture with a valid `data_disk` to prove the field reaches the generated
spec unchanged.

## Host assertions

`host` is optional; a guest that omits it is unaffected as long as at most one
hypervisor is declared. When present, evaluating the flake fails fast if:

- a hypervisor machine declares one at all — `inventory hypervisor machines
  must not declare host: <names>`
- `host` is not a string — `inventory machines with non-string host: <names>`
- `host` does not name a known machine — `inventory machines with unknown
  host: <names>`
- the named machine is not of type `hypervisor` — `inventory machines whose
  host is not a hypervisor: <names>`

and for a guest that omits it once more than one hypervisor is declared —
`inventory machines missing host (required once more than one hypervisor is
declared): <names>`. With one hypervisor, an absent `host` has nothing to
disambiguate and is not a diagnostic.

`scripts/vm-specs.json` carries `host` only for a machine that declares it,
the same optional spelling as `data_disk`, so a deployment with one
hypervisor produces the same generated spec as before this field existed.
The `host-fact-mutations` check runs this validation against sabotaged
copies of `machines`, one fixture per rule; its two-hypervisor fixtures add a
second synthetic hypervisor to a local copy of the machine set only, never to
`machines` itself, so `scripts/vm-specs.json` never needs a second real
hypervisor to stay covered.

## Host-provided-repos assertions

`host_provided_repos` is optional; a guest that omits it is unaffected. When
present, evaluating the flake fails fast if:

- a hypervisor machine declares one at all — `inventory hypervisor machines
  must not declare host_provided_repos: <names>`
- it is not a list of strings — `inventory machines with non-string-list
  host_provided_repos: <names>`
- a member is not also present in the machine's own `repos` — `inventory
  machines with host_provided_repos not in repos: <names>`

`scripts/vm-specs.json` carries `host_provided_repos` only for a machine that
declares it, the same optional spelling as `data_disk` and `host`, so no
public machine's generated spec changes. The guest bootstrap skip rule that
reads this field is tracked separately (`allod/tools`#268), as is the host
step that populates the checkout (`allod/nexus`#73). The
`host-provided-repos-mutations` check runs this validation against sabotaged
copies of `machines`, one fixture per rule, and against one fixture with a
valid `host_provided_repos` to prove the field reaches the generated spec
unchanged.

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
