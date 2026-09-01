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
        # declares one (see the `runtimeFreeWithRuntime` diagnostic below), so
        # it is enforced, not merely a side effect of the guest-only filter
        # used elsewhere.
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

      # Platform validation reads its diagnostics from the same parameterized
      # classifier every other rule uses, and asserts them inside mkVmSpecs so
      # `checkedMachines` forces them. It used to be a separate chain forced
      # only by `supportedPlatforms`, which meant a consumer reading
      # `machines`/`lib.machines` — the surface `archetypes` actually
      # consumes — could receive a machine with no `platform` at all, because
      # nothing on that path ever evaluated the assertion. The names below are
      # kept so this file still reads top-to-bottom, but the work now happens
      # once, in the chain everything forces.
      supportedPlatforms =
        builtins.seq (mkVmSpecs machines)
          (lib.unique (map (m: m.platform) (builtins.attrValues machines)));

      validRuntimes = [ "libvirt" "microvm" ];

      # Machine types that are not guests of this fleet and therefore carry no
      # `runtime` fact at all. A hypervisor is in the set because it is the
      # machine that runs the guests. A service machine is in it for a
      # different reason with the same consequence: some provider's hypervisor
      # runs it, nothing here can see or configure that, and there is no guest
      # module to select. The rejected alternative was `runtime = "rented"`,
      # which keeps every machine uniform at the cost of putting a fictional
      # virtualisation system in a field that otherwise names real ones —
      # something downstream would eventually try to look up a guest module
      # for.
      #
      # This assumes a service is a rented host. A service running as a local
      # guest is imaginable and is deliberately out of scope; when one appears,
      # the decision is whether `service` splits by where it runs.
      runtimeFreeTypes = [ "hypervisor" "service" ];

      isRuntimeFree = m: builtins.elem m.type runtimeFreeTypes;

      # The exported form of the same question, and the one consumers get.
      # Hoisted into this `let` rather than written inline in the `lib` output
      # so the interface witness below drives exactly the value `archetypes`
      # will call, not a second copy that could agree with itself.
      #
      # Named errors rather than the raw `attribute 'type' missing` that
      # `isRuntimeFree` raises on its own. `machineDiagnostics` was made
      # non-throwing on exactly this input, and an export that still threw
      # rawly would be the same defect wearing a different hat — worse, in
      # fact, because a raw attribute error is one `builtins.tryEval` cannot
      # catch, so a consumer could not even probe it.
      isGuestMachine = m:
        if !(m ? type) then
          throw "inventory lib.isGuestMachine: machine has no type"
        else if !(builtins.isString m.type) then
          throw "inventory lib.isGuestMachine: machine type must be a string"
        else
          !(isRuntimeFree m);

      # The one platform a service machine may declare. `platform` is the
      # chip-and-operating-system pair the build targets and says nothing about
      # who hosts the machine, so `lib.systems.flakeExposed` would accept ARM
      # today — and the first ARM machine would then fail somewhere confusing
      # during provisioning, because every machine in this fleet is x86 and
      # nothing here has ever built for another chip. Emulation is slow, a
      # separate build machine is itself a machine, and building on the target
      # needs the target running before it can be configured. So the door
      # closes here, early and legibly, and opens deliberately when someone
      # wants a cross-architecture build path.
      servicePlatform = "x86_64-linux";

      # Guest sizing fields a service machine must not declare. For a guest
      # these are instructions the hypervisor acts on; on a rented machine they
      # would be a description of what is being paid for, and nothing in the
      # file distinguishes the two. Refused rather than ignored, so nobody
      # edits the memory size of a rented host and wonders why nothing
      # happened. If a need for them appears, they get names that cannot be
      # mistaken for the guest fields.
      serviceGuestFields = [ "memory_mb" "vcpus" "disk_gb" "mac" ];

      # Pure, non-throwing classification of an arbitrary machine set into
      # six diagnostic sets. Each runtime predicate is guarded on the previous
      # condition (runtime-free-vs-guest by `type`, then `m ? runtime`, then
      # `isString`, then `elem`), and the two service predicates test
      # independent facts about a machine the runtime predicates have already
      # excused from carrying a runtime. So a machine with exactly one problem
      # trips exactly one diagnostic, no matter what order mkVmSpecs below
      # asserts them in. That disjointness is what lets the mutation checks
      # pin a sabotaged fixture to the one diagnostic it claims to exercise,
      # rather than only to whether evaluation failed for *some* reason.
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
      machineDiagnostics = ms:
        let
          # `type` is classified before anything reads it, so this function
          # keeps the "pure, non-throwing" property it claims. Without these
          # two guards a machine with no `type` aborted with a raw
          # `attribute 'type' missing` inside `isRuntimeFree` — an error
          # `builtins.tryEval` cannot even catch, so no fixture could pin it.
          typed = lib.filterAttrs (_: m: (m ? type) && builtins.isString m.type) ms;

          runtimeFree = lib.filterAttrs (_: m: isRuntimeFree m) typed;
          vms = lib.filterAttrs (_: m: !(isRuntimeFree m)) typed;
          services = lib.filterAttrs (_: m: m.type == "service") typed;
        in {
          missingType = lib.filterAttrs (_: m: !(m ? type)) ms;
          nonStringType =
            lib.filterAttrs (_: m: (m ? type) && !(builtins.isString m.type)) ms;

          # Platform presence and validity, in the classifier rather than in a
          # chain of their own, so mkVmSpecs can assert them and every consumer
          # that forces `machines` gets them. Guarded in the same style as the
          # runtime predicates: a machine with no platform trips exactly
          # `missingPlatform`, never also `invalidPlatform`.
          missingPlatform = lib.filterAttrs (_: m: !(m ? platform)) ms;
          invalidPlatform =
            lib.filterAttrs
              (_: m: (m ? platform)
                     && !(builtins.elem m.platform lib.systems.flakeExposed))
              ms;

          runtimeFreeWithRuntime = lib.filterAttrs (_: m: m ? runtime) runtimeFree;
          missingRuntime = lib.filterAttrs (_: m: !(m ? runtime)) vms;
          nonStringRuntime =
            lib.filterAttrs (_: m: (m ? runtime) && !(builtins.isString m.runtime)) vms;
          unknownRuntime =
            lib.filterAttrs
              (_: m: (m ? runtime) && builtins.isString m.runtime && !(builtins.elem m.runtime validRuntimes))
              vms;

          # Guarded on `m ? platform` so a service machine carrying no platform
          # at all trips `missingPlatform`, which names that problem, rather
          # than being reported here as the wrong shape of problem. `mkVmSpecs`
          # forces the shape rules before this one, so that is what a reader of
          # the error actually gets.
          serviceForeignPlatform =
            lib.filterAttrs (_: m: (m ? platform) && m.platform != servicePlatform) services;

          serviceGuestSizing =
            lib.filterAttrs (_: m: builtins.any (field: m ? ${field}) serviceGuestFields) services;
        };

      # Parameterized on an explicit machine set, rather than closing over
      # `machines`, so the mutation checks below can run this exact validation
      # chain against sabotaged copies and prove each assertion actually
      # fails, instead of only exercising the valid data.
      mkVmSpecs = ms:
        let
          diag = machineDiagnostics ms;

          # Shape before meaning: `type` and `platform` are what every rule
          # below classifies on, so a machine that is wrong about either is
          # told that rather than being reported as the wrong kind of problem.
          #
          # The ordering is produced by the explicit `builtins.seq` chain at the
          # end of this function, not by the order these bindings are written
          # in. That distinction is load-bearing and was got wrong once: a
          # let-binding's asserts fire when the binding is *forced*, so
          # threading `machineShape` through as `serviceShape`'s return value
          # made it the LAST thing evaluated, and a machine missing both
          # `platform` and `runtime` reported the runtime problem. The chain
          # below states the order in the order it happens.
          machineShape =
            assert lib.assertMsg (diag.missingType == {})
              "inventory machines missing type: ${lib.concatStringsSep ", " (builtins.attrNames diag.missingType)}";
            assert lib.assertMsg (diag.nonStringType == {})
              "inventory machines with non-string type: ${lib.concatStringsSep ", " (builtins.attrNames diag.nonStringType)}";
            assert lib.assertMsg (diag.missingPlatform == {})
              "inventory machines missing platform: ${lib.concatStringsSep ", " (builtins.attrNames diag.missingPlatform)}";
            assert lib.assertMsg (diag.invalidPlatform == {})
              "inventory machines with invalid Nix system: ${lib.concatStringsSep ", " (builtins.attrNames diag.invalidPlatform)}";
            ms;

          serviceShape =
            assert lib.assertMsg (diag.serviceForeignPlatform == {})
              "inventory service machines must declare platform ${servicePlatform} (nothing in this fleet has ever built for another chip; open the door once a cross-architecture build path exists): ${lib.concatStringsSep ", " (builtins.attrNames diag.serviceForeignPlatform)}";
            assert lib.assertMsg (diag.serviceGuestSizing == {})
              "inventory service machines must not declare guest sizing fields (${lib.concatStringsSep ", " serviceGuestFields}); a rented machine's size is what is being paid for, not an instruction anything here acts on: ${lib.concatStringsSep ", " (builtins.attrNames diag.serviceGuestSizing)}";
            true;

          runtimeShape =
            assert lib.assertMsg (diag.runtimeFreeWithRuntime == {})
              "inventory ${lib.concatStringsSep " and " runtimeFreeTypes} machines must not declare runtime: ${lib.concatStringsSep ", " (builtins.attrNames diag.runtimeFreeWithRuntime)}";
            assert lib.assertMsg (diag.missingRuntime == {})
              "inventory machines missing runtime: ${lib.concatStringsSep ", " (builtins.attrNames diag.missingRuntime)}";
            assert lib.assertMsg (diag.nonStringRuntime == {})
              "inventory machines with non-string runtime: ${lib.concatStringsSep ", " (builtins.attrNames diag.nonStringRuntime)}";
            assert lib.assertMsg (diag.unknownRuntime == {})
              "inventory machines with unknown runtime (expected one of: ${lib.concatStringsSep ", " validRuntimes}): ${lib.concatStringsSep ", " (builtins.attrNames diag.unknownRuntime)}";
            true;
        in
        # The order, stated once and enforced by forcing rather than by layout.
        builtins.seq machineShape
          (builtins.seq serviceShape
            (builtins.seq runtimeShape
              (lib.filterAttrs (_: m: !(isRuntimeFree m)) ms)));

      mkVmSpecsJson = ms: builtins.toJSON (lib.mapAttrs (name: m: {
        inherit (m) memory_mb vcpus disk_gb ip mac forge_key repos runtime;
        self_rebuild = m.self_rebuild or true;
      }) (mkVmSpecs ms));

      # Forces the machine validation chain even when a consumer reads the
      # raw `machines`/`lib.machines` surface instead of `lib.vmSpecsJson`.
      # `archetypes` consumes `inventory.machines` directly, and a
      # downstream `nix flake check` does not evaluate an input's own
      # checks, so without this nothing would catch bad runtime or service
      # data on that path (allod/inventory PR #10 review). `builtins.seq` forces
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

      # ---------------------------------------------------------------------
      # Shared mutation-witness machinery, hoisted out of the checks below
      # because two of them now drive the same validation chain: one for the
      # runtime fact, one for the service-machine shape. Splitting the checks
      # keeps each name honest about what it proves; sharing these keeps the
      # disjointness argument in one place rather than in two copies that can
      # disagree about which diagnostics exist.

      # Derived from the classifier rather than written out beside it. A
      # hand-maintained list here is a second registry of diagnostics that
      # nothing validates: add a diagnostic to `machineDiagnostics`, forget to
      # add its name here, and `pinnedTo` stops looking at it — so a fixture
      # that trips two diagnostics still reports as pinned to one. Reading the
      # names off an empty machine set costs nothing and cannot drift.
      diagnosticFields = builtins.attrNames (machineDiagnostics { });

      # True only if fixture `ms` trips exactly `field` (naming `machine`)
      # among the diagnostics, and none of the others. This is the actual fix
      # for the review finding: a boolean success/failure comparison could not
      # tell "the non-string assertion fired" apart from "a different assertion
      # fired and happened to also reject the same bad value," so a fixture
      # must instead be checked against the specific diagnostic set it claims
      # to exercise. Every fixture is checked against the whole field list, so
      # a service fixture also proves it disturbs no runtime diagnostic and
      # vice versa.
      pinnedTo = field: machine: ms:
        let
          diag = machineDiagnostics ms;
          hit = diag.${field};
          otherFields = lib.filter (f: f != field) diagnosticFields;
        in
        (builtins.attrNames hit == [ machine ])
        && lib.all (f: diag.${f} == {}) otherFields;

      # True if the real, consumed validation path (mkVmSpecsJson, which
      # mkVmSpecs feeds) actually throws for fixture `ms`. `pinnedTo` alone
      # would not catch a diagnostic that is computed correctly but never
      # asserted on by mkVmSpecs; this closes that gap. `deepSeq` forces the
      # generated JSON string fully, since a shallow WHNF force alone would not
      # walk every machine's fields.
      rejects = ms: !(builtins.tryEval (builtins.deepSeq (mkVmSpecsJson ms) true)).success;

      # True if the real path accepts `ms` — the positive half, so a rule that
      # rejects everything is a failure rather than a green check.
      accepts = ms: (builtins.tryEval (builtins.deepSeq (mkVmSpecsJson ms) true)).success;

      boolLiteral = v: if v then "true" else "false";

      # The shell `check` helper both mutation checks open with.
      checkPrelude = ''
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
      '';

      # A synthetic service machine in the shape the rules above admit: no
      # runtime, x86, and none of the four guest sizing fields. It is a check
      # fixture and never a member of `machines` — the first real service entry
      # is added when its host is rented, so that the entry describes something
      # that exists. Everything the service rules claim is proven by mutating
      # this.
      serviceFixture = {
        platform = "x86_64-linux";
        type = "service";
        ip = "192.0.2.20";
        forge_key = null;
        self_rebuild = false;
        repos = [];
      };

      machinesWithService = machines // { "service-1" = serviceFixture; };

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
          # reason" — see machineDiagnostics above for why that distinction
          # is load-bearing), that the real mkVmSpecsJson path actually
          # rejects every fixture, that neither runtime-free type can silently
          # acquire a runtime, that a synthetic guest accepts the microvm enum
          # value, and that the vm-specs-json drift check is not vacuous.
          #
          # The name is narrower than the diagnostic set it now shares with
          # service-machine-mutations, and stays that way on purpose:
          # allod/archetypes reads `inventory.checks.<system>.runtime-fact-mutations`
          # by name and throws when it is absent, because enum validation for
          # the runtime fact is this repo's contract to that one. Renaming it
          # would break that link for no gain.
          runtime-fact-mutations = pkgs.runCommand "runtime-fact-mutations-check"
            { nativeBuildInputs = [ pkgs.jq pkgs.diffutils ]; }
            (
              let
                machinesHypervisorWithRuntime = machines // {
                  nexus = machines.nexus // { runtime = "microvm"; };
                };

                # The second runtime-free type, proving the widened rule is
                # about the set rather than about hypervisors with an extra
                # name. A service machine has no honest runtime to declare, so
                # declaring one is the same error the hypervisor above makes.
                machinesServiceWithRuntime = machines // {
                  "service-1" = serviceFixture // { runtime = "libvirt"; };
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

                # The shape fixtures. `type` and `platform` are what every
                # other rule classifies on, so each needs its own witness or
                # the classifier's guards are asserted about nothing.
                machinesMissingType = machines // {
                  "privacy-1" = builtins.removeAttrs machines."privacy-1" [ "type" ];
                };

                machinesNonStringType = machines // {
                  "privacy-1" = machines."privacy-1" // { type = 42; };
                };

                machinesMissingPlatform = machines // {
                  "privacy-1" = builtins.removeAttrs machines."privacy-1" [ "platform" ];
                };

                machinesInvalidPlatform = machines // {
                  "privacy-1" = machines."privacy-1" // { platform = "not-a-nix-system"; };
                };

                # A service machine with no platform at all. This is the case
                # the serviceForeignPlatform guard deliberately declines: it
                # belongs to `missingPlatform`, which names the actual problem,
                # rather than being reported as a machine on the wrong chip.
                machinesServiceMissingPlatform = machines // {
                  "service-1" = builtins.removeAttrs serviceFixture [ "platform" ];
                };

                validDiag = machineDiagnostics machines;
                validHasNoDiagnostics = lib.all (f: validDiag.${f} == {}) diagnosticFields;

                microvmResult = builtins.tryEval (
                  (builtins.fromJSON (mkVmSpecsJson machinesMicrovm))."privacy-1".runtime == "microvm"
                );
                microvmAccepted = microvmResult.success && microvmResult.value;

                b = boolLiteral;

                realJson = builtins.toFile "vm-specs.json" vmSpecsJson;
              in
              ''
                ${checkPrelude}

                check "valid machines have no diagnostics"        true "${b validHasNoDiagnostics}"
                check "valid machines evaluate"                   true "${b (accepts machines)}"
                check "microvm runtime: accepted and survives mkVmSpecsJson" true "${b microvmAccepted}"

                check "hypervisor-with-runtime: pinned to its own diagnostic" true "${b (pinnedTo "runtimeFreeWithRuntime" "nexus" machinesHypervisorWithRuntime)}"
                check "hypervisor-with-runtime: fails mkVmSpecsJson"          true "${b (rejects machinesHypervisorWithRuntime)}"

                check "service-with-runtime: pinned to its own diagnostic" true "${b (pinnedTo "runtimeFreeWithRuntime" "service-1" machinesServiceWithRuntime)}"
                check "service-with-runtime: fails mkVmSpecsJson"          true "${b (rejects machinesServiceWithRuntime)}"

                check "missing runtime: pinned to its own diagnostic" true "${b (pinnedTo "missingRuntime" "allod-dev" machinesMissingRuntime)}"
                check "missing runtime: fails mkVmSpecsJson"          true "${b (rejects machinesMissingRuntime)}"

                check "non-string runtime: pinned to its own diagnostic" true "${b (pinnedTo "nonStringRuntime" "allod-dev" machinesNonStringRuntime)}"
                check "non-string runtime: fails mkVmSpecsJson"          true "${b (rejects machinesNonStringRuntime)}"

                check "unknown runtime: pinned to its own diagnostic" true "${b (pinnedTo "unknownRuntime" "allod-dev" machinesUnknownRuntime)}"
                check "unknown runtime: fails mkVmSpecsJson"          true "${b (rejects machinesUnknownRuntime)}"

                check "missing type: pinned to its own diagnostic" true "${b (pinnedTo "missingType" "privacy-1" machinesMissingType)}"
                check "missing type: fails mkVmSpecsJson"          true "${b (rejects machinesMissingType)}"

                check "non-string type: pinned to its own diagnostic" true "${b (pinnedTo "nonStringType" "privacy-1" machinesNonStringType)}"
                check "non-string type: fails mkVmSpecsJson"          true "${b (rejects machinesNonStringType)}"

                check "missing platform: pinned to its own diagnostic" true "${b (pinnedTo "missingPlatform" "privacy-1" machinesMissingPlatform)}"
                check "missing platform: fails mkVmSpecsJson"          true "${b (rejects machinesMissingPlatform)}"

                check "invalid platform: pinned to its own diagnostic" true "${b (pinnedTo "invalidPlatform" "privacy-1" machinesInvalidPlatform)}"
                check "invalid platform: fails mkVmSpecsJson"          true "${b (rejects machinesInvalidPlatform)}"

                # A platform-less service machine is the missing-platform
                # problem, not the foreign-platform one. Pinning it here is
                # what stops the serviceForeignPlatform guard from quietly
                # letting such a machine through the whole chain.
                check "service with no platform: pinned to missingPlatform" true "${b (pinnedTo "missingPlatform" "service-1" machinesServiceMissingPlatform)}"
                check "service with no platform: fails mkVmSpecsJson"       true "${b (rejects machinesServiceMissingPlatform)}"

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

          # Validator validation for the service-machine shape, the same way
          # runtime-fact-mutations does it for the runtime fact and sharing its
          # diagnostic set: a positive fixture proving the rules admit the
          # machine they are meant to describe, then one sabotage per rule,
          # each pinned to the diagnostic it names rather than to "evaluation
          # failed".
          #
          # There is no service machine in `machines` and there deliberately is
          # not one: the first entry is added when its host is rented, so that
          # it describes something real. Until then every service rule is
          # exercised against `serviceFixture`, which is why the rules can land
          # ahead of the machine at all.
          service-machine-mutations = pkgs.runCommand "service-machine-mutations-check"
            { nativeBuildInputs = [ pkgs.jq ]; }
            (
              let
                # A service machine on a chip nothing here builds for. Nix
                # itself knows this system, so `lib.systems.flakeExposed` is
                # happy with it and only the service rule refuses it — which is
                # the whole point of having the rule.
                machinesForeignPlatform = machines // {
                  "service-1" = serviceFixture // { platform = "aarch64-linux"; };
                };

                # The fields this check claims to cover, written out here
                # rather than read from `serviceGuestFields`. Deriving the
                # fixtures from the list under test would mean deleting a field
                # from production also deletes its own witness, leaving the
                # check green about a rule that no longer exists. The equality
                # assertion below is what makes the production list answerable
                # to this one: drop `mac` from `serviceGuestFields` and both
                # that assertion and the `mac` rejection go red.
                expectedGuestFields = [ "memory_mb" "vcpus" "disk_gb" "mac" ];

                # One sabotage per forbidden field, so a rule that only ever
                # catches `memory_mb` cannot pass by standing in for the rest.
                sizingFixtures = map (field: {
                  inherit field;
                  ms = machines // {
                    "service-1" = serviceFixture // { ${field} = 1; };
                  };
                }) expectedGuestFields;

                serviceJson = builtins.tryEval (
                  builtins.fromJSON (mkVmSpecsJson machinesWithService)
                );
                serviceAbsentFromSpecs =
                  serviceJson.success && !(serviceJson.value ? "service-1");

                b = boolLiteral;
              in
              ''
                ${checkPrelude}

                check "a well-formed service machine is accepted" true "${b (accepts machinesWithService)}"
                check "a well-formed service machine trips no diagnostic" true "${
                  b (lib.all (f: (machineDiagnostics machinesWithService).${f} == {}) diagnosticFields)
                }"

                # A service machine is not a guest this fleet provisions, so it
                # is excluded from vmSpecsJson for the same reason a hypervisor
                # is. Host shell tooling reads that file to size and start
                # guests; a rented host is neither sized nor started here.
                check "service machine absent from vmSpecsJson" true "${b serviceAbsentFromSpecs}"

                # The exported classification. Without these lines the export
                # had no witness at all: replacing it with `_: true` left both
                # mutation checks green, because nothing in this repo consumes
                # it — `archetypes` does. An exported interface that no check
                # can be shown to fail on is exactly what principle 11 refuses,
                # and the fact that its only consumers are in another repo is
                # the reason it needs a witness here rather than the reason it
                # does not.
                check "exported: a dev machine is a guest"        true  "${b (isGuestMachine { type = "dev"; })}"
                check "exported: a privacy machine is a guest"    true  "${b (isGuestMachine { type = "privacy"; })}"
                check "exported: a service machine is not"        false "${b (isGuestMachine { type = "service"; })}"
                check "exported: a hypervisor is not"             false "${b (isGuestMachine { type = "hypervisor"; })}"
                check "exported: no type is a catchable error"    false "${b (builtins.tryEval (isGuestMachine { })).success}"
                check "exported: non-string type is catchable"    false "${b (builtins.tryEval (isGuestMachine { type = 42; })).success}"
                check "exported: runtimeFreeTypes matches the rule" true "${
                  b (lib.sort (a: c: a < c) runtimeFreeTypes == [ "hypervisor" "service" ])
                }"

                check "foreign platform: pinned to its own diagnostic" true "${b (pinnedTo "serviceForeignPlatform" "service-1" machinesForeignPlatform)}"
                check "foreign platform: fails mkVmSpecsJson"          true "${b (rejects machinesForeignPlatform)}"

                # Ties the production list to the fixtures below, so a field
                # deleted from the rule cannot also delete its own witness.
                # Compared as sets: the rule refuses any field in the list, so
                # its order is not a property worth pinning, and a check that
                # pinned it would go red for a reordering that changes nothing.
                check "guest sizing field list is exactly what this check covers" true "${
                  b (lib.sort (a: c: a < c) serviceGuestFields
                     == lib.sort (a: c: a < c) expectedGuestFields)
                }"

                ${lib.concatMapStrings (fixture: ''
                  check "guest sizing field ${fixture.field}: pinned to its own diagnostic" true "${b (pinnedTo "serviceGuestSizing" "service-1" fixture.ms)}"
                  check "guest sizing field ${fixture.field}: fails mkVmSpecsJson"          true "${b (rejects fixture.ms)}"
                '') sizingFixtures}

                if [ "$errors" -gt 0 ]; then
                  echo "service-machine-mutations failed with $errors error(s)"
                  exit 1
                fi

                echo "service-machine-mutations passed: a well-formed service machine is accepted and stays out of vmSpecsJson, a foreign platform is refused, and each of ${lib.concatStringsSep ", " serviceGuestFields} is refused on its own"
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

        # Which machines are guests of this fleet, exported because the answer
        # is a machine fact and this repo owns machine facts (architecture
        # principle 8). `archetypes` needs the same split in at least three
        # places — vmFacts, the runtime-module selection check, and its own
        # builders — and every copy of the list is a copy that can be left
        # behind when a fourth runtime-free type appears. That is not
        # hypothetical: the hypervisor-only form of this predicate was already
        # stale in one archetypes check when `service` was added.
        inherit runtimeFreeTypes isGuestMachine;
      };

      checks = lib.genAttrs supportedPlatforms mkChecks;
    };
}
