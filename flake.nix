{
  description = "Allod public machine inventory — template for agent-isolated VMs";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
  };

  outputs = { self, nixpkgs, ... }:
    let
      lib = nixpkgs.lib;

      machines = {
        dev-1 = {
          platform = "x86_64-linux";
          type = "dev";
          memory_mb = 8192;
          vcpus = 4;
          disk_gb = 50;
          ip = "192.0.2.10";
          mac = "52:54:00:00:00:10";
          forge_key = "dev_1";
          self_rebuild = false;
          repos = [ "workspace-tools" "strategy" "allod/secrets" "allod/inventory" "allod/memory" ];
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

      vmSpecs = lib.filterAttrs (_: m: m.type != "hypervisor") machines;

      vmSpecsJson = builtins.toJSON (lib.mapAttrs (name: m: {
        inherit (m) memory_mb vcpus disk_gb ip mac forge_key repos;
        self_rebuild = m.self_rebuild or true;
      }) vmSpecs);

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

              # Development VMs require profiles unless self_rebuild is false
              for vm in $(jq -r 'keys[]' "$specs"); do
                forge_key=$(jq -r --arg v "$vm" '.[$v].forge_key' "$specs")
                self_rebuild=$(jq -r --arg v "$vm" 'if .[$v] | has("self_rebuild") then .[$v].self_rebuild else true end' "$specs")
                if [ "$forge_key" != "null" ] && [ "$self_rebuild" != "false" ]; then
                  if ! jq -e --arg v "$vm" '.[$v].repos | index("profiles")' "$specs" >/dev/null 2>&1; then
                    echo "ERROR: development VM '$vm' is missing required 'profiles' alias"
                    errors=$((errors + 1))
                  fi
                fi
              done

              if [ "$errors" -gt 0 ]; then
                echo "Registry validation failed with $errors error(s)"
                exit 1
              fi

              echo "Registry validation passed: $count repositories, all checks OK"
              touch "$out"
            '';
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
