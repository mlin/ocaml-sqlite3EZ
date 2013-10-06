(** Thin wrapper for [Sqlite3] with a simplified interface

@see < https://bitbucket.org/mmottl/sqlite3-ocaml > sqlite3-ocaml
@see < http://mmottl.bitbucket.org/projects/sqlite3-ocaml/api/Sqlite3.html > Sqlite3 (sqlite3-ocaml documentation)
*)

(** @see < http://mmottl.bitbucket.org/projects/sqlite3-ocaml/api/Sqlite3.Rc.html > Sqlite3.Rc *)
module Rc : sig
	include module type of Sqlite3.Rc

(** @see < http://mmottl.bitbucket.org/projects/sqlite3-ocaml/api/Sqlite3.Data.html > Sqlite3.Data *)
module Data : sig
	include module type of Sqlite3.Data

(** raised whenever an SQLite operation returns an unsuccessful return code *)
exception Rc of Rc.t

(** raised when we are trying to handle an exception and another exception is
raised (e.g. we are executing a transaction, encounter an exception, and issue
a ROLLBACK command, which itself fails) *)
exception Finally of exn*exn

type db

val db_open : ?mode:[ `READONLY | `NO_CREATE] -> ?mutex:[ `FULL | `NO ] -> ?cache:[ `PRIVATE | `SHARED ] -> ?vfs:string -> string -> db
(** [as Sqlite3.db_open] *)

(** immediately close the database. The database connection will otherwise be
closed when garbage-collected. *)
val db_close : db -> unit

(** [with_db filename f] opens a database, applies [f], and returns the
result. The database is closed after [f] is evaluated, even if it raises an
exception. *)
val with_db : ?mode:[ `READONLY | `NO_CREATE] -> ?mutex:[ `FULL | `NO ] -> ?cache:[ `PRIVATE | `SHARED ] -> ?vfs:string -> string -> (db -> 'a) -> 'a

(** [transact db f] evaluates [f db] within a BEGIN..COMMIT transaction. If [f
db] evaluates successfully to [y], the transaction is committed and [y] is
returned. If the evaluation of [f db] raises an exception, the transaction is
rolled back and the exception is re-raised.

Note that BEGIN..COMMIT transactions cannot be nested in SQLite. Any attempt
to make a nested call to [transact] will raise an exception. *)
val transact : db -> (db -> 'a) -> 'a

(** [atomically db f] evaluates [f db] within a SAVEPOINT..RELEASE
transaction, which may be nested.

This implementation allows only parenthetically nested transactions, so there
is no need to name savepoints. *)
val atomically : db -> (db -> 'a) -> 'a

(** execute some imperative SQL statement(s). Multiple statements may be
separated by a semicolon. *)
val exec : db -> string -> unit

(** as [Sqlite3.last_insert_rowid] *)
val last_insert_rowid : db -> Int64.t

(** as [Sqlite3.changes] *)
val changes : db -> int

(** a compiled statement, can be either imperative or a query *)
type statement

(** prepare a statement from the SQL text. The given string must contain only
one SQL statement. The statement can be used multiple times (calls to
[Sqlite3.reset] are handled automatically). The statement is not actually
compiled until its first use. *)
val make_statement : db -> string -> statement

(** bind the given parameters and execute an imperative statement. An
exception is raised if the statement attempts to return result rows. *)
val statement_exec : statement -> Data.t array -> unit

(** [statement_query stmt params cons fold init] binds the given parameters
and executes a query. Each result row is first passed to [cons], which will
usually construct a value from the data. This value is then passed to [fold]
along with an intermediate value, which is [init] for the first row. This can
used to build a list or other data structure from all the results. *)
val statement_query : statement -> Data.t array -> (Data.t array -> 'a) -> ('a -> 'b -> 'b) -> 'b -> 'b

(** immediately finalize the statement, releasing any associated resources.
The statement will otherwise be finalized when garbage-collected. *)
val statement_finalize : statement -> unit

(**/**)
val db_handle : db -> Sqlite3.db
