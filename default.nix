{ pkgs ? (import <nixpkgs> {}), nodejs ? pkgs.nodejs-7_x}:
with pkgs;

rec {
  inherit (pkgs) yarn;

  # Generates the yarn.nix from the yarn.lock file
  generateYarnNix = yarnLock:
    pkgs.runCommand "yarn.nix" {}
      "${yarn2nix}/bin/yarn2nix ${yarnLock} > $out";

  loadOfflineCache = yarnNix:
    let
      pkg = pkgs.callPackage yarnNix {};
    in
      pkg.offline_cache;

  buildYarnPackageDeps = { name, packageJson, yarnLock, yarnNix ? null, pkgConfig ? {} }:
    let
      yarnNix_ =
        if yarnNix == null then (generateYarnNix yarnLock) else yarnNix;
      offlineCache =
        loadOfflineCache yarnNix_;
      moreBuildInputs = (pkgs.lib.flatten (builtins.map (key:
        pkgConfig.${key} . buildInputs or []
      ) (builtins.attrNames pkgConfig)));
      postInstall = (builtins.map (key:
        if (pkgConfig.${key} ? "postInstall") then
          ''
            test -e node_modules/${key} && (
              cd node_modules/${key}
              ${pkgConfig.${key}.postInstall}
            )
          ''
        else
          ""
      ) (builtins.attrNames pkgConfig));
    in
    stdenv.mkDerivation {
      name = "${name}-modules";

      phases = ["buildPhase"];
      buildInputs = [ yarn nodejs ] ++ moreBuildInputs;

      buildPhase = ''
        # Yarn writes cache directories etc to $HOME.
        export HOME=`pwd`/yarn_home

        cp ${packageJson} ./package.json
        cp ${yarnLock} ./yarn.lock

        yarn config --offline set yarn-offline-mirror ${offlineCache}

        # Do not look up in the registry, but in the offline cache.
        # TODO: Ask upstream to fix this mess.
        sed -i -E 's|^(\s*resolved\s*")https?://.*/|\1|' yarn.lock
        yarn install --offline --frozen-lockfile --ignore-engines --ignore-scripts

        ${pkgs.lib.concatStringsSep "\n" postInstall}

        mkdir $out
        mv node_modules $out/
        patchShebangs $out
      '';
    };

  buildYarnPackage = { name,
                       src,
                       packageJson,
                       yarnLock,
                       yarnNix ? null,
                       extraBuildInputs ? [],
                       pkgConfig ? {},
                       ... }@args:
    let
      deps = buildYarnPackageDeps {
        inherit name packageJson yarnLock yarnNix pkgConfig;
      };
      npmPackageName = if lib.hasAttr "npmPackageName" args
        then args.npmPackageName
        else (builtins.fromJSON (builtins.readFile "${src}/package.json")).name ;
      publishBinsFor = if lib.hasAttr "publishBinsFor" args
        then args.publishBinsFor
        else [npmPackageName];
    in stdenv.mkDerivation rec {
      inherit name;
      inherit src;

      buildInputs = [ yarn nodejs ] ++ extraBuildInputs;

      phases = ["unpackPhase" "yarnPhase" "fixupPhase"];

      yarnPhase = ''
        if [ -d node_modules ]; then
          echo "Node modules dir present. Removing."
          rm -rf node_modules
        fi

        if [ -d npm-packages-offline-cache ]; then
          echo "npm-pacakges-offline-cache dir present. Removing."
          rm -rf npm-packages-offline-cache
        fi

        mkdir -p $out/node_modules
        ln -s ${deps}/node_modules/* $out/node_modules/

        if [ -d $out/node_modules/${npmPackageName} ]; then
          echo "Error! There is already an ${npmPackageName} package in the top level node_modules dir!"
          exit 1
        fi

        mkdir $out/node_modules/${npmPackageName}/
        cp -r * $out/node_modules/${npmPackageName}/
      '';

      preFixup = ''
        mkdir $out/bin
        node ${./nix/fixup_bin.js} $out ${lib.concatStringsSep " " publishBinsFor}
      '';
  };

  yarn2nix = buildYarnPackage {
    name = "yarn2nix";
    src = ./.;
    packageJson = ./package.json;
    yarnLock = ./yarn.lock;
    yarnNix = ./yarn.nix;
  };
}
