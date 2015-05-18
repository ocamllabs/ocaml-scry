# Scry

A small tool to analyze the logs of a failed opam build and to give the hint about the cause at the best effort.

#####To Build:
```
opam pin add scry https://github.com/ocamllabs/ocaml-scry.git
cd ocaml-scry/
make
```

#####To Use:
We provide some scripts to crawl build logs from <a href="http://opam.ocaml.org/builds">opam.ocaml.org/builds</a> and do some automatic tests. Once you succeed in running the script `tests/run_test`, you will find some logs and analysis results under folder `tests/bulk_tests` as the file `local-<os>-ocaml-<version>-<pkg>.test` is the raw build log, and the result is in the file with the same name but ends with `.result`.

If you want to try it on your own build log, use the executable `scry` if installed:
```
scry path/to/build_logs
```
If provided multiple paths, the tool will just concatenate them and analyze it as one single build log.
