{ nixpkgs ? <nixpkgs>
, officialRelease ? false
}:

let
  pkgs = import nixpkgs {};

  jobs = rec {
    tarball =
      { ionmonkeySrc ? { outPath = <ionmonkey>; }
      }:

      pkgs.releaseTools.sourceTarball {
        name = "ionmonkey-tarball";
        src = ionmonkeySrc;
        buildInputs = [];
        autoconf = pkgs.autoconf213;
        autoconfPhase = ''
          export VERSION=""
          export VERSION_SUFFIX=""

          eval "$preAutoconf"

          cd js/src/
          if test -x ./bootstrap; then ./bootstrap
          elif test -x ./bootstrap.sh; then ./bootstrap.sh
          elif test -x ./autogen.sh; then ./autogen.sh
          elif test -x ./autogen ; then ./autogen
          elif test -x ./reconf; then ./reconf
          elif test -f ./configure.in || test -f ./configure.ac; then
              autoreconf -i -f --verbose
          else
              echo "No bootstrap, bootstrap.sh, configure.in or configure.ac. Assuming this is not an GNU Autotools package."
          fi
          cd -

          eval "$postAutoconf"
        '';

        distPhase = ''
          runHook preDist

          dir=$(basename $(pwd))
          cd ..
          ensureDir "$out/tarballs"
          tar caf "$out/tarballs/$dir.tar.bz2" $dir
          cd -

          runHook postDist
        '';
        inherit officialRelease;
      };

    jsBuild =
      { tarball ? jobs.tarball {}
      , system ? builtins.currentSystem
      }:

      let pkgs = import nixpkgs { inherit system; }; in
      pkgs.releaseTools.nixBuild {
        name = "ionmonkey";
        src = tarball;
        postUnpack = ''
          sourceRoot=$sourceRoot/js/src
          echo Compile in $sourceRoot
        '';
        buildInputs = with pkgs; [ perl python ];
        configureFlags = [ "--enable-debug" "--disable-optimize" ];
        postInstall = ''
          ./config/nsinstall -t js $out/bin
        '';
        doCheck = false;

        meta = {
          description = "Build JS shell.";
          # Should think about reducing the priority of i686-linux.
          schedulingPriority = "100";
        };
      };

    jsCheck =
      { tarball ? jobs.tarball {}
      , build ? jobs.jsBuild {}
      , system ? builtins.currentSystem
      , jitTestOpt ? ""
      , jitTestIM ? true
      }:

      let pkgs = import nixpkgs { inherit system; }; in
      let opts =
        if jitTestIM then "--ion-tbpl ${jitTestOpt}"
        else jitTestOpt;
      in
      pkgs.releaseTools.nixBuild {
        name = "ionmonkey";
        src = tarball;
        buildInputs = with pkgs; [ python ];
        dontBuild = true;
        checkPhase = ''
          python ./js/src/jit-test/jit_test.py --no-progress --tinderbox -f ${opts} ${build}/bin/js
          touch $out
        '';
        dontInstall = true;
        dontFixup = true;

        meta = {
          description = "Run test suites.";
          schedulingPriority = if jitTestIM then "50" else "10";
        };
      };
  };

in
  jobs
