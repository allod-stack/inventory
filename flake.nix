{
  description = "Allod public machine inventory — template for agent-isolated VMs";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
  };

  outputs = { self, nixpkgs, ... }:
    let
      lib = nixpkgs.lib;

      machines = {
        # The operator's own development machine. It stays on libvirt: a dev
        # guest that fails to boot takes its own repair environment with it, so
        # the machine the work happens from is the last to move onto a new
        # runtime, not the first.
        allod-dev = {
          platform = "x86_64-linux";
          type = "dev";
          runtime = "libvirt";
          memory_mb = 8192;
          vcpus = 4;
          disk_gb = 50;
          ip = "192.0.2.10";
          mac = "52:54:00:00:00:10";
          forge_key = "allod_vm";
          self_rebuild = false;
          repos = [ "allod/tools" "allod/strategy" "allod/secrets" "allod/inventory" "allod/memory" "allod/archetypes" "allod/profiles" "allod/vm" "allod/nexus" "allod/deploy" ];
        };

        # The microvm example machine is deliberately absent until it exists.
        # A machine entry is not self-contained: adding one requires a matching
        # identity, a profile, and per-machine encrypted credentials, and
        # creating those needs a host key generated on the host. So the machine
        # that first selects the microvm runtime is added in the same change
        # that provisions it, rather than sitting here as data nothing can
        # build. The runtime enum's microvm branch is covered by the mutation
        # fixtures below, not by an example machine.

        # Synthetic hypervisor example. `profiles` always injects a `nexus`
        # identity, so its machine set must contain a `nexus` entry for the
        # identity/machine assertion to hold. `vmSpecsJson` filters out
        # `type == "hypervisor"`, so this entry does not appear in
        # scripts/vm-specs.json; repository validation still checks its repos.
        # Hypervisors are not guests: this entry deliberately carries no
        # `runtime` fact. Evaluation actively rejects a hypervisor that
        # declares one (see the `hypervisorWithRuntime` diagnostic below), so
        # it is enforced, not merely a side effect of the non-hypervisor
        # filter used elsewhere.
        nexus = {
          platform = "x86_64-linux";
          type = "hypervisor";
          memory_mb = 16384;
          vcpus = 8;
          disk_gb = 200;
          ip = "192.0.2.2";
          mac = "52:54:00:00:00:02";
          forge_key = null;
          repos = [ "allod/nexus" "allod/inventory" "allod/secrets" "allod/profiles" ];

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

      # Pure, non-throwing classification of an arbitrary machine set into
      # four diagnostic sets. Each predicate is guarded on the previous
      # condition (hypervisor-vs-guest by `type`, then `m ? runtime`, then
      # `isString`, then `elem`), which keeps the four sets disjoint: a
      # machine with exactly one problem trips exactly one diagnostic, no
      # matter what order mkVmSpecs below asserts them in. That disjointness
      # is what lets the runtime-fact-mutations check pin a sabotaged
      # fixture to the one diagnostic it claims to exercise, rather than
      # only to whether evaluation failed for *some* reason.
      #
      # This matters because the sets are not disjoint by accident: an
      # earlier, unguarded version computed `nonStringRuntime` and
      # `unknownRuntime` by re-filtering whatever the previous stage let
      # through, so `runtime = 42` failed `isString` but *also* failed
      # `builtins.elem 42 [ "libvirt" "microvm" ]` (Nix's `==` across types
      # is false, not a type error). A check that only asked "did evaluation
      # fail" could not tell those two apart, and deleting the non-string
      # assertion entirely left it green because the unknown-runtime
      # assertion caught the same fixture instead (allod/inventory PR #10
      # review). Guarding each predicate on the previous one so a machine
      # can only ever match its own diagnostic removes that blind spot at
      # the source, rather than papering over it in the check.
      runtimeDiagnostics = ms:
        let
          hypervisors = lib.filterAttrs (_: m: m.type == "hypervisor") ms;
          vms = lib.filterAttrs (_: m: m.type != "hypervisor") ms;
        in {
          hypervisorWithRuntime = lib.filterAttrs (_: m: m ? runtime) hypervisors;
          missingRuntime = lib.filterAttrs (_: m: !(m ? runtime)) vms;
          nonStringRuntime =
            lib.filterAttrs (_: m: (m ? runtime) && !(builtins.isString m.runtime)) vms;
          unknownRuntime =
            lib.filterAttrs
              (_: m: (m ? runtime) && builtins.isString m.runtime && !(builtins.elem m.runtime validRuntimes))
              vms;
        };

      # Parameterized on an explicit machine set, rather than closing over
      # `machines`, so the runtime-fact-mutations check below can run this
      # exact validation chain against sabotaged copies and prove each
      # assertion actually fails, instead of only exercising the valid data.
      mkVmSpecs = ms:
        let
          diag = runtimeDiagnostics ms;

          runtimeDeclared =
            assert lib.assertMsg (diag.hypervisorWithRuntime == {})
              "inventory hypervisor machines must not declare runtime: ${lib.concatStringsSep ", " (builtins.attrNames diag.hypervisorWithRuntime)}";
            assert lib.assertMsg (diag.missingRuntime == {})
              "inventory machines missing runtime: ${lib.concatStringsSep ", " (builtins.attrNames diag.missingRuntime)}";
            lib.filterAttrs (_: m: m.type != "hypervisor") ms;

          stringRuntime =
            assert lib.assertMsg (diag.nonStringRuntime == {})
              "inventory machines with non-string runtime: ${lib.concatStringsSep ", " (builtins.attrNames diag.nonStringRuntime)}";
            runtimeDeclared;
        in
        assert lib.assertMsg (diag.unknownRuntime == {})
          "inventory machines with unknown runtime (expected one of: ${lib.concatStringsSep ", " validRuntimes}): ${lib.concatStringsSep ", " (builtins.attrNames diag.unknownRuntime)}";
        stringRuntime;

      mkVmSpecsJson = ms: builtins.toJSON (lib.mapAttrs (name: m: {
        inherit (m) memory_mb vcpus disk_gb ip mac forge_key repos runtime;
        self_rebuild = m.self_rebuild or true;
      }) (mkVmSpecs ms));

      # Forces the runtime validation chain even when a consumer reads the
      # raw `machines`/`lib.machines` surface instead of `lib.vmSpecsJson`.
      # `archetypes` consumes `inventory.machines` directly, and a
      # downstream `nix flake check` does not evaluate an input's own
      # checks, so without this nothing would catch bad runtime data on
      # that path (allod/inventory PR #10 review). `builtins.seq` forces
      # `mkVmSpecs machines` for its assertions and then returns the
      # original `machines` value unchanged, so this is a validation
      # trip-wire, not a transform: consumers still see the same shape.
      checkedMachines = builtins.seq (mkVmSpecs machines) machines;

      vmSpecsJson = mkVmSpecsJson machines;

      # Repository validation consumes the raw machine set rather than the
      # guest-only vmSpecsJson projection. Only the fields needed by the
      # validator are serialized: hypervisor hardware is a module function
      # and therefore cannot be represented in JSON.
      machineRepositoriesJson = builtins.toJSON (lib.mapAttrs (_: m: {
        inherit (m) type repos;
        self_rebuild = m.self_rebuild or true;
      }) machines);

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
              machines=${builtins.toFile "machine-repositories.json" machineRepositoriesJson}

              validate_registry() {
                local candidate_registry="$1"
                local candidate_machines="$2"
                local errors=0
                local count
                local alias source remote checkout machine repo_alias dupes machine_type self_rebuild required_alias

                if ! jq empty "$candidate_registry"; then
                  echo "ERROR: repositories.json is not valid JSON"
                  return 1
                fi

                count=$(jq '.repositories | length' "$candidate_registry")
                if [ "$count" -eq 0 ]; then
                  echo "ERROR: registry has no repository entries"
                  return 1
                fi

                while IFS= read -r alias; do
                  source=$(jq -r --arg a "$alias" '.repositories[$a].source // empty' "$candidate_registry")
                  remote=$(jq -r --arg a "$alias" '.repositories[$a].remote // empty' "$candidate_registry")
                  checkout=$(jq -r --arg a "$alias" '.repositories[$a].checkout // empty' "$candidate_registry")

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
                done < <(jq -r '.repositories | keys[]' "$candidate_registry")

                while IFS= read -r machine; do
                  while IFS= read -r repo_alias; do
                    if ! jq -e --arg a "$repo_alias" '.repositories[$a]' "$candidate_registry" >/dev/null 2>&1; then
                      echo "ERROR: machine '$machine' references unknown alias '$repo_alias'"
                      errors=$((errors + 1))
                    fi
                  done < <(jq -r --arg machine "$machine" '.[$machine].repos[]' "$candidate_machines")

                  dupes=$(jq -r --arg machine "$machine" --slurpfile reg "$candidate_registry" \
                    '.[$machine].repos as $aliases
                     | [ $aliases[] | . as $a | $reg[0].repositories[$a].checkout // empty ]
                     | map(select(. != "")) | sort
                     | group_by(.) | map(select(length > 1)) | .[0][0] // empty' "$candidate_machines")
                  if [ -n "$dupes" ]; then
                    echo "ERROR: machine '$machine' has duplicate checkout path: $dupes"
                    errors=$((errors + 1))
                  fi

                  machine_type=$(jq -r --arg machine "$machine" '.[$machine].type' "$candidate_machines")
                  self_rebuild=$(jq -r --arg machine "$machine" '.[$machine].self_rebuild' "$candidate_machines")
                  if [ "$machine_type" = "hypervisor" ] || [ "$self_rebuild" = "true" ]; then
                    for required_alias in allod/profiles allod/secrets allod/inventory; do
                      if ! jq -e --arg machine "$machine" --arg required "$required_alias" \
                          '.[$machine].repos | index($required)' "$candidate_machines" >/dev/null 2>&1; then
                        echo "ERROR: $machine_type machine '$machine' is missing required alias '$required_alias'"
                        errors=$((errors + 1))
                      fi
                    done
                  fi
                done < <(jq -r 'keys[]' "$candidate_machines")

                if [ "$errors" -gt 0 ]; then
                  echo "Registry validation failed with $errors error(s)"
                  return 1
                fi

                echo "Registry validation passed: $count repositories, all machines checked"
              }

              validate_registry "$registry" "$machines"

              expected='["allod/inventory","allod/nexus","allod/profiles","allod/secrets"]'
              previous='["allod/inventory","allod/nexus","allod/secrets"]'
              actual=$(jq -c '.nexus.repos | sort' "$machines")
              if [ "$actual" != "$expected" ]; then
                echo "ERROR: public Nexus fixture must contain exactly nexus, inventory, secrets, and profiles"
                exit 1
              fi
              added=$(jq -cn --argjson actual "$actual" --argjson previous "$previous" '$actual - $previous')
              removed=$(jq -cn --argjson actual "$actual" --argjson previous "$previous" '$previous - $actual')
              if [ "$added" != '["allod/profiles"]' ] || [ "$removed" != '[]' ]; then
                echo "ERROR: public Nexus fixture delta must add only allod/profiles"
                exit 1
              fi
              echo "OK: public Nexus fixture adds only allod/profiles and retains its three existing aliases"

              for required_alias in allod/profiles allod/secrets allod/inventory; do
                sabotaged_machines=/tmp/machines-without-$(basename "$required_alias").json
                sabotage_log=/tmp/missing-$(basename "$required_alias").log
                jq --arg required "$required_alias" '.nexus.repos -= [$required]' "$machines" > "$sabotaged_machines"
                if validate_registry "$registry" "$sabotaged_machines" > "$sabotage_log" 2>&1; then
                  echo "ERROR: removing required Nexus alias '$required_alias' still passed validation"
                  exit 1
                fi
                if ! grep -F "hypervisor machine 'nexus' is missing required alias '$required_alias'" "$sabotage_log" >/dev/null; then
                  echo "ERROR: removal of '$required_alias' failed for an unexpected reason"
                  cat "$sabotage_log"
                  exit 1
                fi
                echo "OK: removing required Nexus alias '$required_alias' fails with its pinned diagnostic"
              done

              jq '.nexus.repos += ["fixture/unknown"]' "$machines" > /tmp/unknown-alias.json
              if validate_registry "$registry" /tmp/unknown-alias.json > /tmp/unknown-alias.log 2>&1; then
                echo "ERROR: an unknown hypervisor alias still passed validation"
                exit 1
              fi
              if ! grep -F "machine 'nexus' references unknown alias 'fixture/unknown'" /tmp/unknown-alias.log >/dev/null; then
                echo "ERROR: unknown alias sabotage failed for an unexpected reason"
                cat /tmp/unknown-alias.log
                exit 1
              fi
              echo "OK: an unknown hypervisor alias fails with its pinned diagnostic"

              jq '.repositories["fixture/profiles-copy"] = .repositories["allod/profiles"]' \
                "$registry" > /tmp/duplicate-registry.json
              jq '.nexus.repos += ["fixture/profiles-copy"]' "$machines" > /tmp/duplicate-machines.json
              if validate_registry /tmp/duplicate-registry.json /tmp/duplicate-machines.json > /tmp/duplicate.log 2>&1; then
                echo "ERROR: duplicate hypervisor checkout paths still passed validation"
                exit 1
              fi
              if ! grep -F "machine 'nexus' has duplicate checkout path: allod/profiles" /tmp/duplicate.log >/dev/null; then
                echo "ERROR: duplicate checkout sabotage failed for an unexpected reason"
                cat /tmp/duplicate.log
                exit 1
              fi
              echo "OK: duplicate hypervisor checkout paths fail with a pinned diagnostic"

              touch "$out"
            '';

          # Validator validation for the runtime fact (architecture.md
          # principle 11): proves each fixture is pinned to the one
          # diagnostic it targets (not just "evaluation failed for some
          # reason" — see runtimeDiagnostics above for why that distinction
          # is load-bearing), that the real mkVmSpecsJson path actually
          # rejects every fixture, that a hypervisor cannot silently acquire
          # a runtime, that a synthetic guest accepts the microvm enum value,
          # and that the vm-specs-json drift check is not vacuous.
          runtime-fact-mutations = pkgs.runCommand "runtime-fact-mutations-check"
            { nativeBuildInputs = [ pkgs.jq pkgs.diffutils ]; }
            (
              let
                machinesHypervisorWithRuntime = machines // {
                  nexus = machines.nexus // { runtime = "microvm"; };
                };

                machinesMissingRuntime = machines // {
                  "allod-dev" = builtins.removeAttrs machines."allod-dev" [ "runtime" ];
                };

                machinesNonStringRuntime = machines // {
                  "allod-dev" = machines."allod-dev" // { runtime = 42; };
                };

                machinesUnknownRuntime = machines // {
                  "allod-dev" = machines."allod-dev" // { runtime = "bhyve"; };
                };

                machinesMicrovm = machines // {
                  "privacy-1" = machines."privacy-1" // { runtime = "microvm"; };
                };

                allFields = [ "hypervisorWithRuntime" "missingRuntime" "nonStringRuntime" "unknownRuntime" ];

                # True only if fixture `ms` trips exactly `field` (naming
                # `machine`) among the four diagnostics, and none of the
                # other three. This is the actual fix for the review finding:
                # a boolean success/failure comparison could not tell "the
                # non-string assertion fired" apart from "a different
                # assertion fired and happened to also reject the same bad
                # value," so a fixture must instead be checked against the
                # specific diagnostic set it claims to exercise.
                pinnedTo = field: machine: ms:
                  let
                    diag = runtimeDiagnostics ms;
                    hit = diag.${field};
                    otherFields = lib.filter (f: f != field) allFields;
                  in
                  (builtins.attrNames hit == [ machine ])
                  && lib.all (f: diag.${f} == {}) otherFields;

                # True if the real, consumed validation path (mkVmSpecsJson,
                # which mkVmSpecs feeds) actually throws for fixture `ms`.
                # `pinnedTo` alone would not catch a diagnostic that is
                # computed correctly but never asserted on by mkVmSpecs;
                # this closes that gap. `deepSeq` forces the generated JSON
                # string fully, since a shallow WHNF force alone would not
                # walk every machine's `runtime` value.
                rejects = ms: !(builtins.tryEval (builtins.deepSeq (mkVmSpecsJson ms) true)).success;

                validDiag = runtimeDiagnostics machines;
                validHasNoDiagnostics = lib.all (f: validDiag.${f} == {}) allFields;

                microvmResult = builtins.tryEval (
                  (builtins.fromJSON (mkVmSpecsJson machinesMicrovm))."privacy-1".runtime == "microvm"
                );
                microvmAccepted = microvmResult.success && microvmResult.value;

                b = v: if v then "true" else "false";

                realJson = builtins.toFile "vm-specs.json" vmSpecsJson;
              in
              ''
                errors=0

                check() {
                  local label="$1" expected="$2" actual="$3"
                  if [ "$actual" != "$expected" ]; then
                    echo "ERROR: $label: expected $expected but got $actual"
                    errors=$((errors + 1))
                  else
                    echo "OK: $label ($actual)"
                  fi
                }

                check "valid machines have no runtime diagnostics" true "${b validHasNoDiagnostics}"
                check "valid machines evaluate"                    true "${b (!(rejects machines))}"
                check "microvm runtime: accepted and survives mkVmSpecsJson" true "${b microvmAccepted}"

                check "hypervisor-with-runtime: pinned to its own diagnostic" true "${b (pinnedTo "hypervisorWithRuntime" "nexus" machinesHypervisorWithRuntime)}"
                check "hypervisor-with-runtime: fails mkVmSpecsJson"          true "${b (rejects machinesHypervisorWithRuntime)}"

                check "missing runtime: pinned to its own diagnostic" true "${b (pinnedTo "missingRuntime" "allod-dev" machinesMissingRuntime)}"
                check "missing runtime: fails mkVmSpecsJson"          true "${b (rejects machinesMissingRuntime)}"

                check "non-string runtime: pinned to its own diagnostic" true "${b (pinnedTo "nonStringRuntime" "allod-dev" machinesNonStringRuntime)}"
                check "non-string runtime: fails mkVmSpecsJson"          true "${b (rejects machinesNonStringRuntime)}"

                check "unknown runtime: pinned to its own diagnostic" true "${b (pinnedTo "unknownRuntime" "allod-dev" machinesUnknownRuntime)}"
                check "unknown runtime: fails mkVmSpecsJson"          true "${b (rejects machinesUnknownRuntime)}"

                if jq -e 'has("nexus")' ${realJson} >/dev/null; then
                  echo "ERROR: hypervisor entry 'nexus' leaked into vmSpecsJson (must not acquire a fake guest runtime)"
                  errors=$((errors + 1))
                else
                  echo "OK: hypervisor entry 'nexus' absent from vmSpecsJson"
                fi

                # The machine the operator develops from is the last to move,
                # not the first. A dev guest that fails to boot takes its own
                # repair environment with it.
                if ! jq -e '.["allod-dev"].runtime == "libvirt"' ${realJson} >/dev/null; then
                  echo "ERROR: allod-dev must stay on libvirt; the first microvm selection is a purpose-made machine"
                  errors=$((errors + 1))
                else
                  echo "OK: allod-dev stays on libvirt"
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

                echo "runtime-fact-mutations passed: valid data has no diagnostics, the synthetic microvm guest is accepted, each sabotaged fixture is pinned to exactly the diagnostic it targets and fails the real mkVmSpecsJson path, hypervisor stays excluded, and drift detection is proven"
                touch "$out"
              ''
            );
        };
    in
    {
      machines = checkedMachines;

      lib = {
        machines = checkedMachines;
        inherit supportedPlatforms vmSpecsJson;
      };

      checks = lib.genAttrs supportedPlatforms mkChecks;
    };
}
