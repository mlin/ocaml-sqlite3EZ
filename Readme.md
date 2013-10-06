# [sqlite3EZ](http://github.com/mlin/ocaml-sqlite3EZ)

A thin wrapper for [sqlite3-ocaml](https://bitbucket.org/mmottl/sqlite3-ocaml)
with a simplified interface. Query results are processed with a functional
map/fold, transactions are aborted by exceptions, resource management is
handled by the garbage collector, etc.

### Installation

sqlite3EZ is available in [OPAM](http://opam.ocamlpro.com):
`opam install sqlite3EZ`. The findlib package name is also `sqlite3EZ`.

Manual build (with findlib): install
[sqlite3-ocaml](https://bitbucket.org/mmottl/sqlite3-ocaml) and
[ocaml+twt](https://github.com/mlin/twt);
`./configure && make && make install`

### [API documentation](http://mlin.github.io/ocaml-sqlite3EZ/Sqlite3EZ.html)
