{
  description = "Allod public machine inventory — template for agent-isolated VMs";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
  };

  outputs = { self, nixpkgs, ... }:
    let
      lib = nixpkgs.lib;

      machines = {
        allod-dev = {
          platform = "x86_64-linux";
          type = "dev";
          # Public microvm.nix example: later milestones select this machine
          # for the microvm guest module.
          runtime = "microvm";
          memory_mb = 8192;
          vcpus = 4;
          disk_gb = 50;
          ip = "192.0.2.10";
          mac = "52:54:00:00:00:10";
          forge_key = "allod_vm";
          self_rebuild = false;
          repos = [ "allod/tools" "allod/strategy" "allod/secrets" "allod/inventory" "allod/memory" "allod/archetypes" "allod/profiles" "allod/vm" "allod/nexus" "allod/deploy" ];
        };

        # Synthetic hypervisor example. `profiles` always injects a `nexus`
        # identity, so its machine set must contain a `nexus` entry for the
        # identity/machine assertion to hold. `vmSpecsJson` filters out
        # `type == "hypervisor"`, so this entry does not appear in
        # scripts/vm-specs.json and does not affect inventory's own checks.
        # Hypervisors are not guests: this entry deliberately carries no
        # `runtime` fact, and the runtime assertions below are scoped to
        # non-hypervisor machines only, so it never needs one and never
        # acquires a fake guest runtime.
        nexus = {
          platform = "x86_64-linux";
          type = "hypervisor";
          memory_mb = 16384;
          vcpus = 8;
          disk_gb = 200;
          ip = "192.0.2.2";
          mac = "52:54:00:00:00:02";
          forge_key = null;
          repos = [ "allod/nexus" "allod/inventory" "allod/secrets" ];

          # Illustrative synthetic hardware. `profiles` imports this as a NixOS
          # module for the hypervisor toplevel; `nexus.nixosModules.host`
          # provides systemd-boot, so this supplies only the root and EFI
          # filesystems. Replace with your machine's generated hardware config.
          hardware = { ... }: {
            boot.initrd.availableKernelModules = [ "nvme" "xhci_pci" "ahci" "usb_storage" ];
            boot.kernelModules = [ "kvm-intel" ];
            fileSystems."/" = {
              device = "/dev/disk/by-label/nixos";
              fsType = "ext4";
            };
            fileSystems."/boot" = {
              device = "/dev/disk/by-label/boot";
              fsType = "vfat";
            };
          };
        };

        privacy-1 = {
          platform = "x86_64-linux";
          type = "privacy";
          # Public libvirt example: this arc keeps the privacy VM on the
          # existing libvirt XML/Tor topology, so libvirt stays a tested,
          # first-class runtime path alongside microvm.
          runtime = "libvirt";
          memory_mb = 4096;
          vcpus = 2;
          disk_gb = 20;
          ip = "192.0.2.11";
          mac = "52:54:00:00:00:11";
          forge_key = null;
          self_rebuild = false;
          repos = [];
        };
      };

      missingPlatforms =
        lib.filterAttrs (_: m: !(m ? platform)) machines;

      platformMachines =
        assert lib.assertMsg (missingPlatforms == {})
          "inventory machines missing platform: ${lib.concatStringsSep ", " (builtins.attrNames missingPlatforms)}";
        machines;

      invalidPlatforms =
        lib.filterAttrs
          (_: m: !(builtins.elem m.platform lib.systems.flakeExposed))
          platformMachines;

      supportedPlatforms =
        assert lib.assertMsg (invalidPlatforms == {})
          "inventory machines with invalid Nix system: ${lib.concatStringsSep ", " (builtins.attrNames invalidPlatforms)}";
        lib.unique (map (m: m.platform) (builtins.attrValues platformMachines));

      validRuntimes = [ "libvirt" "microvm" ];

      # Parameterized on an explicit machine set, rather than closing over
      # `machines`, so the runtime-fact-mutations check below can run this
      # exact validation chain against sabotaged copies and prove each
      # assertion actually fails, instead of only exercising the valid data.
      mkVmSpecs = ms:
        let
          vms = lib.filterAttrs (_: m: m.type != "hypervisor") ms;

          missingRuntime =
            lib.filterAttrs (_: m: !(m ? runtime)) vms;

          runtimeDeclared =
            assert lib.assertMsg (missingRuntime == {})
              "inventory machines missing runtime: ${lib.concatStringsSep ", " (builtins.attrNames missingRuntime)}";
            vms;

          nonStringRuntime =
            lib.filterAttrs (_: m: !(builtins.isString m.runtime)) runtimeDeclared;

          stringRuntime =
            assert lib.assertMsg (nonStringRuntime == {})
              "inventory machines with non-string runtime: ${lib.concatStringsSep ", " (builtins.attrNames nonStringRuntime)}";
            runtimeDeclared;

          unknownRuntime =
            lib.filterAttrs (_: m: !(builtins.elem m.runtime validRuntimes)) stringRuntime;
        in
        assert lib.assertMsg (unknownRuntime == {})
          "inventory machines with unknown runtime (expected one of: ${lib.concatStringsSep ", " validRuntimes}): ${lib.concatStringsSep ", " (builtins.attrNames unknownRuntime)}";
        stringRuntime;

      mkVmSpecsJson = ms: builtins.toJSON (lib.mapAttrs (name: m: {
        inherit (m) memory_mb vcpus disk_gb ip mac forge_key repos runtime;
        self_rebuild = m.self_rebuild or true;
      }) (mkVmSpecs ms));

      vmSpecsJson = mkVmSpecsJson machines;

      mkChecks = system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          vm-specs-json = pkgs.runCommand "vm-specs-json-check"
            { nativeBuildInputs = [ pkgs.jq pkgs.diffutils ]; }
            ''
              expected=${builtins.toFile "expected.json" vmSpecsJson}
              jq -S . "$expected" > /tmp/expected-sorted.json
              jq -S . ${self}/scripts/vm-specs.json > /tmp/actual-sorted.json
              diff /tmp/expected-sorted.json /tmp/actual-sorted.json \
                || (echo "ERROR: scripts/vm-specs.json diverges from Nix inventory. Regenerate with:" && \
                    echo "  nix eval .#lib.vmSpecsJson --raw | jq -S . > scripts/vm-specs.json" && \
                    exit 1)
              touch "$out"
            '';

          repository-registry = pkgs.runCommand "repository-registry-check"
            { nativeBuildInputs = [ pkgs.jq ]; }
            ''
              registry=${self}/scripts/repositories.json

              jq empty "$registry" || { echo "ERROR: repositories.json is not valid JSON"; exit 1; }

              count=$(jq '.repositories | length' "$registry")
              if [ "$count" -eq 0 ]; then
                echo "ERROR: registry has no repository entries"
                exit 1
              fi

              errors=0
              for alias in $(jq -r '.repositories | keys[]' "$registry"); do
                source=$(jq -r --arg a "$alias" '.repositories[$a].source // empty' "$registry")
                remote=$(jq -r --arg a "$alias" '.repositories[$a].remote // empty' "$registry")
                checkout=$(jq -r --arg a "$alias" '.repositories[$a].checkout // empty' "$registry")

                if [ -z "$source" ] || [ -z "$remote" ] || [ -z "$checkout" ]; then
                  echo "ERROR: $alias: missing required field (source, remote, checkout)"
                  errors=$((errors + 1))
                  continue
                fi

                if [ "$source" != "forge" ] && [ "$source" != "git" ]; then
                  echo "ERROR: $alias: unknown source type '$source' (must be 'forge' or 'git')"
                  errors=$((errors + 1))
                fi

                if echo "$remote" | grep -qE '(\s|\.\.|^/|/$)'; then
                  echo "ERROR: $alias: unsafe remote value '$remote'"
                  errors=$((errors + 1))
                fi

                if echo "$checkout" | grep -qE '(\s|\.\.|^/|/$)'; then
                  echo "ERROR: $alias: unsafe checkout value '$checkout'"
                  errors=$((errors + 1))
                fi
              done

              specs=${self}/scripts/vm-specs.json
              for vm in $(jq -r 'keys[]' "$specs"); do
                dupes=$(jq -r --arg v "$vm" --slurpfile reg "$registry" \
                  '.[$v].repos as $aliases
                   | [ $aliases[] | . as $a | $reg[0].repositories[$a].checkout // empty ]
                   | map(select(. != ""))
                   | group_by(.) | map(select(length > 1)) | .[0][0] // empty' "$specs")
                if [ -n "$dupes" ]; then
                  echo "ERROR: VM '$vm' has duplicate checkout path: $dupes"
                  errors=$((errors + 1))
                fi
              done

              for vm in $(jq -r 'keys[]' "$specs"); do
                for repo_alias in $(jq -r --arg v "$vm" '.[$v].repos[]' "$specs"); do
                  if ! jq -e --arg a "$repo_alias" '.repositories[$a]' "$registry" >/dev/null 2>&1; then
                    echo "ERROR: VM '$vm' references unknown alias '$repo_alias'"
                    errors=$((errors + 1))
                  fi
                done
              done

              # Self-rebuild VMs need the framework and data checkouts required
              # by profiles flake evaluation.
              for vm in $(jq -r 'keys[]' "$specs"); do
                self_rebuild=$(jq -r --arg v "$vm" 'if .[$v] | has("self_rebuild") then .[$v].self_rebuild else true end' "$specs")
                if [ "$self_rebuild" = "true" ]; then
                  for required in profiles secrets inventory; do
                    if ! jq -e --arg v "$vm" --arg required "$required" \
                        '.[$v].repos | index($required)' "$specs" >/dev/null 2>&1; then
                      echo "ERROR: self-rebuild VM '$vm' is missing required '$required' alias"
                      errors=$((errors + 1))
                    fi
                  done
                fi
              done

              if [ "$errors" -gt 0 ]; then
                echo "Registry validation failed with $errors error(s)"
                exit 1
              fi

              echo "Registry validation passed: $count repositories, all checks OK"
              touch "$out"
            '';

          # Validator validation for the runtime fact (architecture.md
          # principle 11): proves the assertions added by mkVmSpecs actually
          # fail on sabotaged input, that hypervisors stay excluded rather
          # than acquiring a fake guest runtime, that the public examples
          # cover both enum values, and that the vm-specs-json drift check
          # is not vacuous.
          runtime-fact-mutations = pkgs.runCommand "runtime-fact-mutations-check"
            { nativeBuildInputs = [ pkgs.jq pkgs.diffutils ]; }
            (
              let
                machinesMissingRuntime = machines // {
                  "allod-dev" = builtins.removeAttrs machines."allod-dev" [ "runtime" ];
                };

                machinesNonStringRuntime = machines // {
                  "allod-dev" = machines."allod-dev" // { runtime = 42; };
                };

                machinesUnknownRuntime = machines // {
                  "allod-dev" = machines."allod-dev" // { runtime = "bhyve"; };
                };

                # `tryEval` catches the `assert`/`throw` failures the runtime
                # chain raises without aborting this flake's own evaluation,
                # so a sabotaged fixture can prove a failure rather than only
                # exercising the valid data. `deepSeq` forces the generated
                # JSON string fully, since a shallow WHNF force alone would
                # not walk every machine's `runtime` value.
                attempt = ms: builtins.tryEval (builtins.deepSeq (mkVmSpecsJson ms) true);

                results = {
                  valid = attempt machines;
                  missingRuntime = attempt machinesMissingRuntime;
                  nonStringRuntime = attempt machinesNonStringRuntime;
                  unknownRuntime = attempt machinesUnknownRuntime;
                };

                b = v: if v then "true" else "false";

                realJson = builtins.toFile "vm-specs.json" vmSpecsJson;
              in
              ''
                errors=0

                check() {
                  local label="$1" expected="$2" actual="$3"
                  if [ "$actual" != "$expected" ]; then
                    echo "ERROR: $label: expected success=$expected but got success=$actual"
                    errors=$((errors + 1))
                  else
                    echo "OK: $label (success=$actual)"
                  fi
                }

                check "valid machines evaluate"  true  "${b results.valid.success}"
                check "missing runtime fails"    false "${b results.missingRuntime.success}"
                check "non-string runtime fails" false "${b results.nonStringRuntime.success}"
                check "unknown runtime fails"    false "${b results.unknownRuntime.success}"

                if jq -e 'has("nexus")' ${realJson} >/dev/null; then
                  echo "ERROR: hypervisor entry 'nexus' leaked into vmSpecsJson (must not acquire a fake guest runtime)"
                  errors=$((errors + 1))
                else
                  echo "OK: hypervisor entry 'nexus' absent from vmSpecsJson"
                fi

                if ! jq -e '.["allod-dev"].runtime == "microvm"' ${realJson} >/dev/null; then
                  echo "ERROR: allod-dev is no longer the public microvm example"
                  errors=$((errors + 1))
                else
                  echo "OK: allod-dev is the public microvm example"
                fi

                if ! jq -e '.["privacy-1"].runtime == "libvirt"' ${realJson} >/dev/null; then
                  echo "ERROR: privacy-1 is no longer the public libvirt example"
                  errors=$((errors + 1))
                else
                  echo "OK: privacy-1 is the public libvirt example"
                fi

                # Prove the vm-specs-json drift check is not vacuous: mutate a
                # copy of the committed file and confirm the same key-sorted
                # diff idiom it runs actually disagrees.
                jq -S . ${realJson} > /tmp/real-sorted.json
                jq -S . ${self}/scripts/vm-specs.json > /tmp/committed-sorted.json
                diff /tmp/real-sorted.json /tmp/committed-sorted.json || {
                  echo "ERROR: committed vm-specs.json unexpectedly diverges before sabotage"
                  errors=$((errors + 1))
                }
                jq -S '.["allod-dev"].runtime = "bhyve"' /tmp/committed-sorted.json > /tmp/sabotaged-sorted.json
                if diff /tmp/real-sorted.json /tmp/sabotaged-sorted.json > /dev/null; then
                  echo "ERROR: drift sabotage produced no diff; vm-specs-json check would not catch real drift"
                  errors=$((errors + 1))
                else
                  echo "OK: sabotaged JSON diverges from generated JSON (drift detection proven)"
                fi

                if [ "$errors" -gt 0 ]; then
                  echo "runtime-fact-mutations failed with $errors error(s)"
                  exit 1
                fi

                echo "runtime-fact-mutations passed: valid data evaluates, each sabotaged fixture fails, hypervisor stays excluded, both public examples are present, and drift detection is proven"
                touch "$out"
              ''
            );
        };
    in
    {
      inherit machines;

      lib = {
        inherit machines supportedPlatforms vmSpecsJson;
      };

      checks = lib.genAttrs supportedPlatforms mkChecks;
    };
}
